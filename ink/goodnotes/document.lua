--[[
High-level `.goodnotes` document loader, incremental streaming saver,
exporter (from native `.inkaway` notebooks & drawings), duplicator, and CRDT
manifest inspector (`GNDoc`).

Future sync readiness:
  * Preserves `document_id`, `PageUUID`, `NoteLayerUUID = UUID(PageUUID) + 1`,
    per-device 64-bit `replica_id`, monotonically increasing `lamport`, LWW clocks,
    and CRDT tombstones across edits and saves.
  * `GNDoc.inspect(path)` reads only ZIP Central Directory + index streams +
    note object headers without decompressing PDF/image attachments or TPL data.
  * `GNDoc.duplicate(src, dst)` patches a fresh `document_id` into `CreateDocument`
    so duplicated notebooks never collide on sync.
]]

local ffi = require("ffi")
local Storage = require("ink/storage")
local Wire = require("ink/goodnotes/wire")
local Zip = require("ink/goodnotes/zip")
local PdfGen = require("ink/goodnotes/pdfgen")
local Mapper = require("ink/goodnotes/mapper")

local GNDoc = {}

GNDoc.EXT = "goodnotes"

local floor, max, format = math.floor, math.max, string.format
local sub = string.sub

-- A4 in 132 PPI Goodnotes units (`595.28 * 11/6` x `841.89 * 11/6`)
local A4_GN_W = 595.28 * Wire.PT_TO_GN
local A4_GN_H = 841.89 * Wire.PT_TO_GN

------------------------------------------------------------------------------
-- File & format predicates
------------------------------------------------------------------------------

function GNDoc.isPath(path)
    return type(path) == "string" and path:lower():match("%.goodnotes$") ~= nil
end

function GNDoc.validate(path)
    if type(path) ~= "string" or path == "" then return false, "no path" end
    if not Zip.isZip(path) then return false, "not a zip archive" end
    local arc, err = Zip.open(path)
    if not arc then return false, err end
    local ok, why = pcall(function()
        assert(arc:has("schema.pb"), "missing schema.pb")
        local sc = Wire.byField(Wire.parseMessage(assert(arc:read("schema.pb"))))
        local ver = Wire.getUInt(sc, 1, 0)
        assert(ver >= 1 and ver <= 100, "unsupported schema version: " .. tostring(ver))
        assert(arc:has("index.events.pb"), "missing index.events.pb")
        assert(arc:has("index.notes.pb"), "missing index.notes.pb")
        assert(arc:has("index.attachments.pb"), "missing index.attachments.pb")
        Wire.parseDelimited(assert(arc:read("index.events.pb")))
        Wire.parseDelimited(assert(arc:read("index.notes.pb")))
        Wire.parseDelimited(assert(arc:read("index.attachments.pb")))
    end)
    arc:close()
    if not ok then return false, tostring(why) end
    return true
end

------------------------------------------------------------------------------
-- Attachment extraction cache
------------------------------------------------------------------------------

local function sanitizeId(id)
    return (tostring(id or "doc"):gsub("[^%w%-_]", "_"))
end

local function detectExt(head)
    if type(head) ~= "string" then return "bin" end
    if head:find("%PDF-", 1, true) then return "pdf" end
    if sub(head, 1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if sub(head, 1, 3) == "\255\216\255" then return "jpg" end
    if sub(head, 1, 4) == "RIFF" and sub(head, 9, 12) == "WEBP" then return "webp" end
    return "bin"
end

pcall(ffi.cdef, "int mkdir(const char *path, unsigned int mode);")

local function ensureDirExist(path)
    if Storage.makePath(path) or Storage.isDir(path) then return true end
    local acc = sub(path, 1, 1) == "/" and "" or nil
    for part in path:gmatch("[^/]+") do
        acc = (acc and acc .. "/" or "") .. part
        if part ~= "." then pcall(ffi.C.mkdir, acc, 493) end
    end
    local probe = path .. "/.probe_" .. tostring(os.time())
    local f = io.open(probe, "wb")
    if f then f:close(); os.remove(probe); return true end
    return false
end

local function cacheDirForDoc(doc_id)
    local root = Storage.cacheDir() .. "/goodnotes"
    ensureDirExist(root)
    local d = root .. "/" .. sanitizeId(doc_id)
    ensureDirExist(d)
    return d
end

local function pruneCache(keep_dir)
    local root = Storage.cacheDir() .. "/goodnotes"
    local entries = Storage.list(root)
    if #entries <= 16 then return end
    table.sort(entries, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)
    local kept = 0
    for _i, e in ipairs(entries) do
        if e.mode == "directory" then
            if e.path == keep_dir or kept < 16 then
                kept = kept + 1
            else
                Storage.removeTree(e.path)
            end
        end
    end
end

local function ensureAttachmentCached(arc, att_index, doc_cache, att_id)
    local apath = att_index[att_id]
    if not apath or not arc:has(apath) then return nil end
    local e = arc:entry(apath)
    local blob_id = apath:match("^attachments/(.+)$") or att_id
    -- Check if any file with cached prefix `<blob_id>.` already exists with matching byte size
    for _i, ext in ipairs({ "pdf", "png", "jpg", "webp", "bin" }) do
        local cand = doc_cache .. "/" .. sanitizeId(blob_id) .. "." .. ext
        if Storage.exists(cand) and (not e or Storage.size(cand) == e.uncomp_size) then
            return cand
        end
    end
    local data = arc:read(apath)
    if not data or #data == 0 then return nil end
    local ext = detectExt(sub(data, 1, 1024))
    local dest = doc_cache .. "/" .. sanitizeId(blob_id) .. "." .. ext
    local ok = Storage.writeAtomic(dest, data)
    return ok and dest or nil
end

------------------------------------------------------------------------------
-- Event stream parsing & encoding
------------------------------------------------------------------------------

local function nowMs()
    return (os.time() or 0) * 1000.0
end

local function parseEvents(events_bytes)
    local msgs = Wire.parseDelimited(events_bytes)
    local raw_events = {}
    local doc_info = {
        document_id = nil,
        title = nil,
        folder_id = nil,
        active_page_id = nil,
        max_lamport = 0ULL,
        replica_ids = {},
    }
    local templates = {}
    local pages = {}
    local pages_by_id = {}
    local attachments = {}

    for idx, msg in ipairs(msgs) do
        local d = Wire.byField(Wire.parseMessage(msg))
        local entity_uuid = Wire.getStr(d, 1, "")
        local ev_tag, ev_val
        for k, list in pairs(d) do
            if k ~= 1 then ev_tag = k; ev_val = list[1].val; break end
        end
        raw_events[idx] = { idx = idx, entity_uuid = entity_uuid, tag = ev_tag, raw = msg, sub_raw = ev_val }

        if ev_tag and ev_val then
            local sd = Wire.byField(Wire.parseMessage(ev_val))
            local function bumpLamp(fn)
                if sd[fn] then doc_info.max_lamport = Wire.u64Max(doc_info.max_lamport, Wire.getU64(sd, fn, 0)) end
            end
            local function addReplica(fn)
                if sd[fn] then doc_info.replica_ids[Wire.u64ToDec(Wire.getU64(sd, fn, 0))] = true end
            end

            if ev_tag == 30 then   -- CreateDocument
                doc_info.document_id = Wire.getStr(sd, 1, entity_uuid)
                if sd[2] then
                    local td = Wire.byField(Wire.parseMessage(sd[2][1].val))
                    doc_info.title = Wire.getStr(td, 1)
                    doc_info.title_clock = td[2] and Wire.decLwwClock(td[2][1].val) or nil
                end
                if sd[3] then
                    local fd = Wire.byField(Wire.parseMessage(sd[3][1].val))
                    doc_info.folder_id = Wire.getStr(fd, 1)
                end
                bumpLamp(14); addReplica(13)

            elseif ev_tag == 6 then   -- RegisterAttachment
                local aid = Wire.getStr(sd, 1, entity_uuid)
                attachments[aid] = {
                    logical_id = aid,
                    blob_id = Wire.getStr(sd, 2, aid),
                    byte_size = Wire.getUInt(sd, 5, 0),
                }
                bumpLamp(15); addReplica(14)

            elseif ev_tag == 2 then   -- CreatePageTemplate
                local tid = Wire.getStr(sd, 2, entity_uuid)
                local sz = sd[8] and Wire.decSize(sd[8][1].val) or { w = A4_GN_W, h = A4_GN_H }
                local theme
                if sd[17] then
                    local ptd = Wire.byField(Wire.parseMessage(sd[17][1].val))
                    if ptd[1] then theme = Wire.getUInt(ptd, 1, 0) end
                end
                local ruling_kind = 0
                if sd[18] and sd[18][1].val ~= "" then
                    local rl = Wire.byField(Wire.parseMessage(sd[18][1].val))
                    ruling_kind = rl[5] and Wire.getUInt(rl, 5, 0) or 0
                end
                templates[tid] = {
                    template_id = tid,
                    logical_att_id = Wire.getStr(sd, 4, ""),
                    pdf_page = sd[5] and Wire.getUInt(sd, 5, 1) or 1,
                    is_builtin = sd[6] and Wire.getUInt(sd, 6, 0) ~= 0,
                    line_spacing = sd[7] and Wire.getF64(sd, 7, 32.0) or nil,
                    w_gn = (sz.w and sz.w > 10) and sz.w or A4_GN_W,
                    h_gn = (sz.h and sz.h > 10) and sz.h or A4_GN_H,
                    name = Wire.getStr(sd, 9, ""),
                    paper_theme = theme,
                    has_ruling = sd[13] ~= nil,
                    ruling_kind = ruling_kind,
                    ruling_layout = sd[18] and sd[18][1].val or nil,
                    event_idx = idx,
                }
                bumpLamp(16); addReplica(15)

            elseif ev_tag == 54 then   -- CreatePage
                local pid = Wire.getStr(sd, 2, entity_uuid)
                local tid, okey = "", ""
                local okey_clock = { counter = 0, tiebreaker = 0 }
                if sd[3] then
                    local tl = Wire.byField(Wire.parseMessage(sd[3][1].val))
                    tid = Wire.getStr(tl, 1, "")
                end
                if sd[4] then
                    local ol = Wire.byField(Wire.parseMessage(sd[4][1].val))
                    okey = Wire.getStr(ol, 1, "")
                    if ol[2] then okey_clock = Wire.decLwwClock(ol[2][1].val) end
                end
                local p = {
                    page_id = pid,
                    note_layer_id = Wire.uuidPlusOne(pid),
                    template_id = tid,
                    order_key = okey,
                    order_clock = okey_clock,
                    event_idx = idx,
                }
                pages[#pages + 1] = p
                pages_by_id[pid] = p
                bumpLamp(14); addReplica(13)

            elseif ev_tag == 10 then   -- UpdateCurrentPage
                doc_info.active_page_id = Wire.getStr(sd, 2)
                bumpLamp(14); addReplica(13)
            elseif ev_tag == 102 or ev_tag == 105 then
                bumpLamp(14); addReplica(13)
            elseif ev_tag == 103 then
                bumpLamp(19); addReplica(18)
            elseif ev_tag == 104 then
                bumpLamp(18); addReplica(17)
            end
        end
    end

    table.sort(pages, function(a, b)
        if a.order_key ~= b.order_key then return a.order_key < b.order_key end
        return a.event_idx < b.event_idx
    end)

    return raw_events, doc_info, templates, pages, pages_by_id, attachments
end

local function encodeEventEnvelope(entity_uuid, tag, sub_bytes)
    return Wire.encodeMessage({
        { 1, 2, entity_uuid },
        { tag, 2, sub_bytes },
    })
end

local function encCreateDocument(doc_id, title, folder_id, replica_id, lamport)
    local body = Wire.encodeMessage({
        { 1, 2, doc_id },
        { 2, 2, Wire.encLwwString(title or "Notebook", 1, Wire.randomU32()) },
        { 3, 2, Wire.encLwwString(folder_id or Wire.uuidV4(), 1, Wire.randomU32()) },
        { 6, 2, Wire.encLwwBytes("P", 1, Wire.randomU32()) },
        { 7, 2, Wire.encLwwString(folder_id or Wire.uuidV4(), 1, Wire.randomU32()) },
        { 9, 2, "auto" },
        { 10, 1, Wire.encF64(nowMs()) },
        { 11, 2, Wire.uuidV4() },
        { 13, 0, replica_id },
        { 14, 0, lamport },
        { 17, 2, "" },
        { 18, 2, "" },
        { 19, 2, Wire.encLwwEmpty(1, Wire.randomU32()) },
        { 20, 0, 24 },
    })
    return encodeEventEnvelope(doc_id, 30, body)
end

local function encRegisterAttachment(att_id, blob_id, byte_size, doc_id, is_pdf, pdf_pages, replica_id, lamport)
    local pdf_meta = is_pdf and Wire.encodeMessage({ { 1, 0, pdf_pages or 1 }, { 2, 0, 1 } }) or ""
    local body = Wire.encodeMessage({
        { 1, 2, att_id },
        { 2, 2, blob_id or att_id },
        { 5, 0, byte_size },
        { 6, 2, doc_id },
        { 10, 1, Wire.encF64(nowMs()) },
        { 11, 2, Wire.uuidV4() },
        { 12, 2, pdf_meta },
        { 14, 0, replica_id },
        { 15, 0, lamport },
        { 16, 0, 24 },
    })
    return encodeEventEnvelope(att_id, 6, body)
end

local function encCreatePageTemplate(doc_id, tpl_id, att_id, pdf_page, w_gn, h_gn, opts, replica_id, lamport)
    opts = opts or {}
    local fields = {
        Wire.fBytes(1, doc_id, true),
        Wire.fBytes(2, tpl_id, true),
        Wire.fBytes(4, att_id, true),
        { 5, 0, pdf_page or 1 },
        opts.is_builtin and { 6, 0, 1 } or nil,
        opts.line_spacing and Wire.fF64(7, opts.line_spacing, true) or nil,
        Wire.fBytes(8, Wire.encSize(w_gn, h_gn), true),
        Wire.fBytes(9, opts.name or "", true),
        { 10, 1, Wire.encF64(nowMs()) },
        Wire.fBytes(11, Wire.uuidV4(), true),
        opts.line_spacing and Wire.fBytes(12, Wire.encLwwDouble(opts.line_spacing, 1, Wire.randomU32()), true) or nil,
        opts.has_ruling and Wire.fBytes(13, Wire.encLwwUint32(1, 1, Wire.randomU32()), true) or nil,
        { 15, 0, replica_id },
        { 16, 0, lamport },
        opts.paper_theme and Wire.fBytes(17, Wire.encLwwUint32(opts.paper_theme, 1, Wire.randomU32()), true) or nil,
        (opts.ruling_layout and opts.ruling_layout ~= "") and Wire.fBytes(18, opts.ruling_layout, true) or nil,
        Wire.fBytes(19, Wire.encLwwEmpty(1, Wire.randomU32()), true),
        { 21, 0, 24 },
    }
    return encodeEventEnvelope(tpl_id, 2, Wire.encodeMessage(Wire.packFields(unpack(fields, 1, 18))))
end

local function encCreatePage(doc_id, page_id, tpl_id, order_key, replica_id, lamport)
    local page_style = Wire.encodeMessage({
        { 1, 2, Wire.encodeMessage({
            { 2, 2, Wire.encodeMessage({
                { 1, 2, Wire.encColor(0.866667, 0.866667, 0.866667, 1.0) },
                { 2, 2, Wire.encColor(1.0, 1.0, 1.0, 1.0) },
            }) },
        }) },
        { 2, 2, Wire.encLwwClock(1, Wire.randomU32()) },
    })
    local body = Wire.encodeMessage({
        { 1, 2, doc_id },
        { 2, 2, page_id },
        { 3, 2, Wire.encLwwString(tpl_id, 1, Wire.randomU32()) },
        { 4, 2, Wire.encLwwString(order_key, 1, Wire.randomU32()) },
        { 10, 1, Wire.encF64(nowMs()) },
        { 11, 2, Wire.uuidV4() },
        { 13, 0, replica_id },
        { 14, 0, lamport },
        { 15, 0, 24 },
        { 17, 2, page_style },
    })
    return encodeEventEnvelope(page_id, 54, body)
end

local function encNoteLayerCheckpoint(note_id, doc_id, replica_id, lamport)
    local body = Wire.encodeMessage({
        { 1, 2, note_id },
        { 10, 1, Wire.encF64(nowMs()) },
        { 11, 2, Wire.uuidV4() },
        { 13, 0, replica_id },
        { 14, 0, lamport },
        { 15, 0, 24 },
        { 16, 2, doc_id },
    })
    return encodeEventEnvelope(note_id, 102, body)
end

local function encUpdateCurrentPage(doc_id, page_id, replica_id, lamport)
    local body = Wire.encodeMessage({
        { 1, 2, doc_id },
        { 2, 2, page_id },
        { 3, 2, "InkAway:" .. doc_id },
        { 10, 1, Wire.encF64(nowMs()) },
        { 11, 2, Wire.uuidV4() },
        { 13, 0, replica_id },
        { 14, 0, lamport },
        { 15, 0, 24 },
    })
    return encodeEventEnvelope(doc_id, 10, body)
end

local function patchCreatePageFields(raw_sub, new_tpl_id, new_order_key, new_order_counter, new_lamport, replica_id)
    local fields = Wire.parseMessage(raw_sub)
    local out = {}
    local entity_id = ""
    for _i, f in ipairs(fields) do
        if f.field == 2 then entity_id = f.val end
        if f.field == 3 and new_tpl_id then
            local td = Wire.byField(Wire.parseMessage(f.val))
            local tc = td[2] and Wire.decLwwClock(td[2][1].val) or { counter = 0, tiebreaker = 0 }
            out[#out + 1] = { 3, 2, Wire.encLwwString(new_tpl_id, (tc.counter or 0) + 1, Wire.randomU32()) }
        elseif f.field == 4 and new_order_key then
            out[#out + 1] = { 4, 2, Wire.encLwwString(new_order_key, new_order_counter, Wire.randomU32()) }
        elseif f.field == 13 then
            out[#out + 1] = { 13, 0, replica_id }
        elseif f.field == 14 then
            out[#out + 1] = { 14, 0, new_lamport }
        else
            out[#out + 1] = { f.field, f.wt, f.wt == 0 and f.u64 or f.val }
        end
    end
    return encodeEventEnvelope(entity_id, 54, Wire.encodeMessage(out))
end

local function patchCreateDocumentId(raw_sub, new_doc_id, new_title)
    local fields = Wire.parseMessage(raw_sub)
    local out = {}
    for _i, f in ipairs(fields) do
        if f.field == 1 then
            out[#out + 1] = { 1, 2, new_doc_id }
        elseif f.field == 2 and new_title then
            out[#out + 1] = { 2, 2, Wire.encLwwString(new_title, 2, Wire.randomU32()) }
        else
            out[#out + 1] = { f.field, f.wt, f.wt == 0 and f.u64 or f.val }
        end
    end
    return encodeEventEnvelope(new_doc_id, 30, Wire.encodeMessage(out))
end

local function patchEnvelopeEntityDocId(ev_tag, raw_sub, new_doc_id)
    local doc_field = (ev_tag == 6 and 6) or (ev_tag == 102 and 16)
        or (ev_tag == 103 and 2) or (ev_tag == 105 and 2) or 1
    local fields = Wire.parseMessage(raw_sub)
    local out = {}
    for _i, f in ipairs(fields) do
        if f.field == doc_field then
            out[#out + 1] = { f.field, 2, new_doc_id }
        else
            out[#out + 1] = { f.field, f.wt, f.wt == 0 and f.u64 or f.val }
        end
    end
    return Wire.encodeMessage(out)
end

------------------------------------------------------------------------------
-- Loading & Lightweight Inspection
------------------------------------------------------------------------------

--- Lightweight sync & UI inspector: reads Central Directory, index streams,
--- and note object headers WITHOUT decompressing PDF/image attachments or TPL bytes.
function GNDoc.inspect(path)
    if not Zip.isZip(path) then return nil, "not a zip archive" end
    local arc, err = Zip.open(path)
    if not arc then return nil, err end
    local ok, res = pcall(function()
        local sc_bytes = assert(arc:read("schema.pb"))
        local sc_d = Wire.byField(Wire.parseMessage(sc_bytes))
        local schema_ver = Wire.getUInt(sc_d, 1, 0)

        local ev_bytes = assert(arc:read("index.events.pb"))
        local _re, doc_info, _tpls, gn_pages = parseEvents(ev_bytes)

        local notes_idx = {}
        for _i, rec in ipairs(Wire.parseDelimited(assert(arc:read("index.notes.pb")))) do
            local d = Wire.byField(Wire.parseMessage(rec))
            notes_idx[Wire.getStr(d, 1, "")] = Wire.getStr(d, 2, "")
        end

        local max_lamp = doc_info.max_lamport
        local page_summaries = {}
        for i, gp in ipairs(gn_pages) do
            local npath = notes_idx[gp.note_layer_id] or ("notes/" .. gp.note_layer_id)
            local raw = arc:has(npath) and (arc:read(npath) or "") or ""
            local active, tomb = 0, 0
            if #raw > 0 then
                local msgs = Wire.parseDelimited(raw)
                for k = 1, #msgs, 2 do
                    local hd = Wire.byField(Wire.parseMessage(msgs[k]))
                    local l = Wire.getU64(hd, 9, 0)
                    max_lamp = Wire.u64Max(max_lamp, l)
                    if hd[8] then doc_info.replica_ids[Wire.u64ToDec(Wire.getU64(hd, 8, 0))] = true end
                    if hd[3] and Wire.getUInt(hd, 3, 0) ~= 0 then tomb = tomb + 1 else active = active + 1 end
                end
            end
            page_summaries[i] = {
                page_id = gp.page_id,
                note_layer_id = gp.note_layer_id,
                order_key = gp.order_key,
                active_objects = active,
                tombstones = tomb,
            }
        end

        local replicas = {}
        for rid in pairs(doc_info.replica_ids) do replicas[#replicas + 1] = rid end
        table.sort(replicas)

        return {
            document_id = doc_info.document_id,
            title = doc_info.title,
            schema_version = schema_ver,
            max_lamport = Wire.u64ToDec(max_lamp),
            replica_ids = replicas,
            page_count = #gn_pages,
            pages = page_summaries,
        }
    end)
    arc:close()
    if not ok then return nil, tostring(res) end
    return res
end

--- Load a `.goodnotes` file into an Ink Away v2 notebook data table (`_gn` attached).
function GNDoc.load(path)
    if not Zip.isZip(path) then return nil, "not a zip archive" end
    local arc, err = Zip.open(path)
    if not arc then return nil, err end

    local ok, data = pcall(function()
        local sc_d = Wire.byField(Wire.parseMessage(assert(arc:read("schema.pb"))))
        local schema_ver = Wire.getUInt(sc_d, 1, 24)

        local notes_idx = {}
        for _i, rec in ipairs(Wire.parseDelimited(assert(arc:read("index.notes.pb")))) do
            local d = Wire.byField(Wire.parseMessage(rec))
            notes_idx[Wire.getStr(d, 1, "")] = Wire.getStr(d, 2, "")
        end

        local att_idx = {}
        for _i, rec in ipairs(Wire.parseDelimited(assert(arc:read("index.attachments.pb")))) do
            local d = Wire.byField(Wire.parseMessage(rec))
            att_idx[Wire.getStr(d, 1, "")] = Wire.getStr(d, 2, "")
        end

        local raw_events, doc_info, templates, gn_pages, _pby, att_meta = parseEvents(assert(arc:read("index.events.pb")))
        local doc_id = doc_info.document_id or Wire.uuidV4()
        local doc_cache = cacheDirForDoc(doc_id)
        pruneCache(doc_cache)

        local tpl_pdfs = {}
        local function extractAtt(aid)
            return ensureAttachmentCached(arc, att_idx, doc_cache, aid)
        end

        local out_pages = {}
        local active_idx = 1
        local doc_max_lamp = doc_info.max_lamport

        for i, gp in ipairs(gn_pages) do
            if gp.page_id == doc_info.active_page_id then active_idx = i end
            local tpl = templates[gp.template_id]
            local gn_w = (tpl and tpl.w_gn) or A4_GN_W
            local gn_h = (tpl and tpl.h_gn) or A4_GN_H
            local pw = max(200, floor(gn_w + 0.5))
            local ph = max(200, floor(gn_h + 0.5))
            local paper_rgb = (tpl and tpl.paper_theme == 2) and { 0x33, 0x33, 0x33 } or nil

            local pdf_path
            if tpl and tpl.logical_att_id ~= "" then
                pdf_path = tpl_pdfs[tpl.logical_att_id]
                if pdf_path == nil then
                    pdf_path = extractAtt(tpl.logical_att_id) or false
                    tpl_pdfs[tpl.logical_att_id] = pdf_path
                end
                pdf_path = pdf_path or nil
            end

            local npath = notes_idx[gp.note_layer_id] or ("notes/" .. gp.note_layer_id)
            local raw_note = arc:has(npath) and (arc:read(npath) or "") or ""
            local ops, layer_meta = Mapper.fromNoteLayer(raw_note, { extractAttachment = extractAtt })
            doc_max_lamp = Wire.u64Max(doc_max_lamp, layer_meta.max_lamport)

            out_pages[i] = {
                id = gp.page_id,
                ops = ops,
                src = (tpl and tpl.pdf_page) or 1,
                pdf_path = pdf_path,
                w = pw,
                h = ph,
                _gn_template_id = gp.template_id,
                _gn_paper_rgb = paper_rgb,
                _gn_builtin_tpl = (tpl and tpl.is_builtin) or false,
                _gn = {
                    page_id = gp.page_id,
                    note_layer_id = gp.note_layer_id,
                    template_id = gp.template_id,
                    order_key = gp.order_key,
                    order_clock = gp.order_clock,
                    gn_w = gn_w,
                    gn_h = gn_h,
                    event_idx = gp.event_idx,
                    meta = layer_meta,
                },
            }
        end

        if #out_pages == 0 then
            local pid = Wire.uuidV4()
            out_pages[1] = {
                id = pid, ops = {}, w = floor(A4_GN_W + 0.5), h = floor(A4_GN_H + 0.5),
            }
        end

        local p1 = out_pages[1]
        return {
            version = 2,
            kind = "notebook",
            format = "goodnotes",
            w = p1.w,
            h = p1.h,
            index = active_idx,
            template = {
                style = "blank",
                size = 40,
                strength = 45,
                pdf_path = p1.pdf_path,
                paper = p1._gn_paper_rgb,
            },
            pages = out_pages,
            _gn = {
                document_id = doc_id,
                title = doc_info.title,
                folder_id = doc_info.folder_id,
                schema_version = schema_ver,
                max_lamport = Wire.u64ToDec(doc_max_lamp),
                source_path = path,
                raw_events = raw_events,
                templates = templates,
                attachments = att_meta,
                att_idx = att_idx,
                notes_idx = notes_idx,
            },
        }
    end)

    arc:close()
    if not ok then return nil, tostring(data) end
    return data
end

------------------------------------------------------------------------------
-- LIS Helper for Minimal Page Reorder Keys
------------------------------------------------------------------------------

local function computeOrderAnchorSet(pages)
    -- Longest strictly increasing subsequence of existing `order_key`s
    local items = {}
    for i, pg in ipairs(pages) do
        local ok = pg._gn and pg._gn.order_key
        if ok and ok ~= "" then
            items[#items + 1] = { idx = i, key = ok }
        end
    end
    local n = #items
    if n == 0 then return {} end
    local dp, prev = {}, {}
    local best_len, best_i = 0, 1
    for i = 1, n do
        dp[i] = 1
        prev[i] = 0
        for j = 1, i - 1 do
            if items[j].key < items[i].key and dp[j] + 1 > dp[i] then
                dp[i] = dp[j] + 1
                prev[i] = j
            end
        end
        if dp[i] > best_len then
            best_len = dp[i]
            best_i = i
        end
    end
    local anchors = {}
    local cur = best_i
    while cur > 0 do
        anchors[items[cur].idx] = items[cur].key
        cur = prev[cur]
    end
    return anchors
end

------------------------------------------------------------------------------
-- Saving & Exporting to `.goodnotes`
------------------------------------------------------------------------------

local function isDarkPaperRGB(rgb)
    if type(rgb) ~= "table" then return false end
    return (0.299 * rgb[1] + 0.587 * rgb[2] + 0.114 * rgb[3]) < 110
end

local function paperKey(rgb)
    if type(rgb) ~= "table" then return "white" end
    return format("%d,%d,%d", rgb[1] or 255, rgb[2] or 255, rgb[3] or 255)
end

local function resolvePageTemplate(nb, idx)
    if nb.pageTemplate then return nb:pageTemplate(idx) end
    local page = nb.pages and nb.pages[idx]
    local tpl = nb.template or {}
    if page and type(page.paper) == "string" and page.paper ~= tpl.style then
        local view = {}
        for k, v in pairs(tpl) do view[k] = v end
        view.style = page.paper
        return view
    end
    return tpl
end

local function readFileBytes(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function pagePdfCount(pdf_bytes)
    -- Estimate PDF `/Count N` or default 1 cleanly
    local max_c = 1
    for c in (pdf_bytes or ""):gmatch("/Count%s+(%d+)") do
        local n = tonumber(c)
        if n and n > max_c then max_c = n end
    end
    return max_c
end

--- Compute clean 132 PPI target dimensions & uniform scale for a native Ink Away page.
local function targetGnSize(cw, ch)
    if not (cw and ch and cw > 0 and ch > 0) then return A4_GN_W, A4_GN_H, 1.0 end
    if cw > ch then
        local gn_h = A4_GN_W
        local gn_w = gn_h * (cw / ch)
        return gn_w, gn_h, gn_w / cw
    end
    local gn_w = A4_GN_W
    local gn_h = gn_w * (ch / cw)
    return gn_w, gn_h, gn_w / cw
end

--- Save a brand-new Goodnotes document (either native Ink Away -> Goodnotes export or fallback write).
local function writeFreshGoodnotes(nb, dest_path, opts)
    local replica_id = Wire.toU64(opts.replica_id or Wire.randomU64())
    local lamport = 0ULL
    local function nextLamp()
        lamport = Wire.u64Add(lamport, 1)
        return lamport
    end

    local doc_id = Wire.uuidV4()
    local folder_id = Wire.uuidV4()
    local title = opts.title or (dest_path:match("([^/]+)$") or "Notebook"):gsub("%.goodnotes$", "")

    local events = { encCreateDocument(doc_id, title, folder_id, replica_id, nextLamp()) }
    local entries = {}
    local att_index_msgs = {}
    local note_index_msgs = {}
    local att_seen = {}
    local pdf_att_by_path = {}
    local gen_tpl_cache = {}
    local max_obj_ver = 0

    local function regAttachment(blob, is_pdf, pdf_pages)
        local aid = Wire.uuidV4()
        entries["attachments/" .. aid] = blob
        att_index_msgs[#att_index_msgs + 1] = Wire.encodeMessage({ { 1, 2, aid }, { 2, 2, "attachments/" .. aid } })
        events[#events + 1] = encRegisterAttachment(aid, aid, #blob, doc_id, is_pdf, pdf_pages, replica_id, nextLamp())
        return aid
    end

    local sel = opts.indices
    local page_list = {}
    if sel then
        for _k, i in ipairs(sel) do
            if nb.pages[i] then page_list[#page_list + 1] = { nb_idx = i, page = nb.pages[i] } end
        end
    else
        for i, pg in ipairs(nb.pages) do page_list[i] = { nb_idx = i, page = pg } end
    end

    local last_order_key = nil
    local cur_page_id = nil
    local doc_cache = cacheDirForDoc(doc_id)

    for pos, item in ipairs(page_list) do
        local pg = item.page
        local pt = resolvePageTemplate(nb, item.nb_idx)
        local cw = pg.w or nb.w or 1091
        local ch = pg.h or nb.h or 1543
        local gn_w, gn_h, scale = targetGnSize(cw, ch)
        local tpl_spec = pg._gn_tpl_spec
        local src_tpl = pg._gn and nb._gn and nb._gn.templates and nb._gn.templates[pg._gn.template_id]
        if tpl_spec and tpl_spec.w_gn and tpl_spec.h_gn then
            gn_w, gn_h = tpl_spec.w_gn, tpl_spec.h_gn
            scale = gn_w / cw
        elseif pg._gn and pg._gn.gn_w and pg._gn.gn_h then
            gn_w, gn_h = pg._gn.gn_w, pg._gn.gn_h
            scale = gn_w / cw
        end

        -- Backing template PDF
        local tpl_id
        local paper_rgb = pg._gn_paper_rgb or (pt and pt.paper)
        local pdf_path = (tpl_spec and tpl_spec.pdf_path) or pg.pdf_path or (pt and pt.pdf_path)
        if pdf_path and Storage.exists(pdf_path) then
            local aid = pdf_att_by_path[pdf_path]
            if not aid then
                local pbytes = readFileBytes(pdf_path)
                if pbytes and #pbytes > 0 then
                    aid = regAttachment(pbytes, true, pagePdfCount(pbytes))
                    pdf_att_by_path[pdf_path] = aid
                end
            end
            if aid then
                local pno = pg.src or 1
                local meta_src = tpl_spec or src_tpl
                local p_theme = (meta_src and meta_src.paper_theme) or (isDarkPaperRGB(paper_rgb) and 2 or 1)
                local tkey = format("pdf|%s|%d|%.2f|%.2f|%d|%s", aid, pno, gn_w, gn_h, p_theme,
                    tostring(meta_src and meta_src.gn_name or ""))
                tpl_id = gen_tpl_cache[tkey]
                if not tpl_id then
                    tpl_id = Wire.uuidV4()
                    gen_tpl_cache[tkey] = tpl_id
                    events[#events + 1] = encCreatePageTemplate(doc_id, tpl_id, aid, pno, gn_w, gn_h, {
                        is_builtin = meta_src and meta_src.is_builtin or nil,
                        line_spacing = meta_src and meta_src.line_spacing or nil,
                        has_ruling = meta_src and meta_src.has_ruling or nil,
                        paper_theme = p_theme,
                        name = meta_src and (meta_src.gn_name or meta_src.name) or "",
                        ruling_layout = meta_src and meta_src.ruling_layout or nil,
                    }, replica_id, nextLamp())
                end
            end
        end

        if not tpl_id then
            local style = (pt and pt.style) or "blank"
            local spacing = (pt and pt.size) or 40
            local strength = (pt and pt.strength) or 45
            local paper = paper_rgb
            local tkey = format("vec|%s|%s|%s|%s|%.2f|%.2f", style, tostring(spacing), tostring(strength),
                paperKey(paper), gn_w, gn_h)
            tpl_id = gen_tpl_cache[tkey]
            if not tpl_id then
                local w_pt = gn_w / Wire.PT_TO_GN
                local h_pt = gn_h / Wire.PT_TO_GN
                local spacing_pt = (spacing * scale) / Wire.PT_TO_GN
                local pdf_bytes = PdfGen.buildTemplatePDF(w_pt, h_pt, style, spacing_pt, strength, paper)
                local aid = regAttachment(pdf_bytes, true, 1)
                tpl_id = Wire.uuidV4()
                gen_tpl_cache[tkey] = tpl_id
                events[#events + 1] = encCreatePageTemplate(doc_id, tpl_id, aid, 1, gn_w, gn_h, {
                    is_builtin = true,
                    line_spacing = spacing * scale,
                    has_ruling = (style ~= "blank"),
                    paper_theme = isDarkPaperRGB(paper) and 2 or 1,
                    name = style,
                }, replica_id, nextLamp())
            end
        end

        local pid = Wire.uuidV4()
        local nid = Wire.uuidPlusOne(pid)
        if item.nb_idx == nb.index or not cur_page_id then cur_page_id = pid end
        local okey = Wire.orderKeyBetween(last_order_key, nil)
        last_order_key = okey
        events[#events + 1] = encCreatePage(doc_id, pid, tpl_id, okey, replica_id, nextLamp())

        -- Encode page ops cleanly into notes/<NoteLayerUUID>
        local ops = pg.ops or {}
        if opts.bg_path and pos == 1 and Storage.exists(opts.bg_path) then
            local f = io.open(opts.bg_path, "rb")
            local h = f and f:read(262144) or ""
            if f then f:close() end
            local ok_http, Http = pcall(require, "ink/share/http")
            local iw, ih
            if ok_http and Http and Http.imageSize then iw, ih = Http.imageSize(h) end
            local bg_op = { kind = "image", x = 0, y = 0, w = cw, h = ch, path = opts.bg_path, natw = iw or cw, nath = ih or ch }
            local merged = { bg_op }
            for _k, op in ipairs(ops) do merged[#merged + 1] = op end
            ops = merged
        end

        -- Use empty meta so fresh UUIDs/scales are written cleanly (or preserve `_gn` attachments via page_meta if same scale)
        local dark_paper = isDarkPaperRGB(paper_rgb)
        local res = Mapper.toNoteLayer(ops, nil, {
            scale = scale, dark_paper = dark_paper, canvas_w = cw, canvas_h = ch,
            replica_id = replica_id, min_lamport = lamport,
        })
        lamport = Wire.u64Max(lamport, res.max_lamport)
        if #res.bytes > 0 and res.max_ver > max_obj_ver then max_obj_ver = res.max_ver end

        for _k, na in ipairs(res.new_attachments) do
            if not att_seen[na.att_id] then
                att_seen[na.att_id] = true
                entries["attachments/" .. na.att_id] = na.blob
                att_index_msgs[#att_index_msgs + 1] = Wire.encodeMessage({ { 1, 2, na.att_id }, { 2, 2, "attachments/" .. na.att_id } })
                events[#events + 1] = encRegisterAttachment(na.att_id, na.att_id, #na.blob, doc_id, false, nil, replica_id, nextLamp())
            end
        end

        local npath = "notes/" .. nid
        entries[npath] = res.bytes
        note_index_msgs[#note_index_msgs + 1] = Wire.encodeMessage({ { 1, 2, nid }, { 2, 2, npath } })
        if #res.bytes > 0 then
            events[#events + 1] = encNoteLayerCheckpoint(nid, doc_id, replica_id, nextLamp())
        end
    end

    if cur_page_id then
        events[#events + 1] = encUpdateCurrentPage(doc_id, cur_page_id, replica_id, nextLamp())
    end

    local schema_ver = max_obj_ver > 0 and max_obj_ver or 24
    entries["schema.pb"] = Wire.encodeMessage({ { 1, 0, schema_ver } })
    entries["document.info.pb"] = ""
    entries["index.notes.pb"] = Wire.encodeDelimited(note_index_msgs)
    entries["index.attachments.pb"] = Wire.encodeDelimited(att_index_msgs)
    entries["index.search.pb"] = ""
    entries["index.events.pb"] = Wire.encodeDelimited(events)

    local ok, err = Zip.write(dest_path, entries)
    if ok and not opts.indices and not opts.export_only then
        -- Populate `_gn` only if this notebook wasn't already a distinct native `.inkaway`
        local _unused = doc_cache
    end
    return ok, err
end

--- Save an open `.goodnotes` notebook incrementally via `Zip.patch` (zero recompression
--- of unchanged PDFs, photos, and untouched note layers), or export a native notebook.
function GNDoc.save(nb, dest_path, opts)
    opts = opts or {}
    local doc_gn = nb._gn
    if not doc_gn or opts.indices or opts.bg_path or not (doc_gn.source_path and Storage.exists(doc_gn.source_path)) then
        return writeFreshGoodnotes(nb, dest_path, opts)
    end

    local src_path = doc_gn.source_path
    local doc_id = doc_gn.document_id
    local replica_id = Wire.toU64(opts.replica_id or Wire.randomU64())
    local lamport = Wire.u64FromDec(doc_gn.max_lamport or "0")
    local function nextLamp()
        lamport = Wire.u64Add(lamport, 1)
        return lamport
    end

    local updates = {}
    local deletes = {}
    local new_events = {}
    local patched_events = {}   -- event_idx -> new_envelope_bytes
    local dropped_events = {}   -- event_idx -> true

    local anchors = computeOrderAnchorSet(nb.pages)
    local prev_key = nil
    local page_order_keys = {}
    for i = 1, #nb.pages do
        if anchors[i] then
            page_order_keys[i] = anchors[i]
            prev_key = anchors[i]
        else
            local next_k = nil
            for j = i + 1, #nb.pages do
                if anchors[j] then next_k = anchors[j]; break end
            end
            local ok = Wire.orderKeyBetween(prev_key, next_k)
            page_order_keys[i] = ok
            prev_key = ok
        end
    end

    local att_index = {}
    for aid, apath in pairs(doc_gn.att_idx or {}) do att_index[aid] = apath end
    local gen_tpl_cache = {}
    local doc_cache = cacheDirForDoc(doc_id)

    local function registerNewAttachment(blob, is_pdf, pdf_pages)
        local aid = Wire.uuidV4()
        local apath = "attachments/" .. aid
        updates[apath] = blob
        att_index[aid] = apath
        doc_gn.attachments[aid] = { logical_id = aid, blob_id = aid, byte_size = #blob }
        new_events[#new_events + 1] = encRegisterAttachment(aid, aid, #blob, doc_id, is_pdf, pdf_pages, replica_id, nextLamp())
        return aid
    end

    -- Track surviving existing `page_id`s so deleted pages are cleanly removed
    local kept_orig_pages = {}
    local notes_idx_list = {}
    local max_obj_ver = 0
    local refreshed = {}   -- i -> { ops_bytes, page_id, note_layer_id, template_id, order_key }

    local pdf_att_by_path = {}
    local function ensureSpecTemplate(pg, gn_w, gn_h)
        local tpl_spec = pg._gn_tpl_spec
        if tpl_spec and tpl_spec.pdf_path and Storage.exists(tpl_spec.pdf_path) then
            local aid = pdf_att_by_path[tpl_spec.pdf_path]
            if not aid then
                local pbytes = readFileBytes(tpl_spec.pdf_path)
                if pbytes and #pbytes > 0 then
                    aid = registerNewAttachment(pbytes, true, pagePdfCount(pbytes))
                    pdf_att_by_path[tpl_spec.pdf_path] = aid
                end
            end
            if aid then
                local w = tpl_spec.w_gn or gn_w
                local h = tpl_spec.h_gn or gn_h
                local tkey = format("spec|%s|%.2f|%.2f|%d|%s", aid, w, h,
                    tpl_spec.paper_theme or 1, tostring(tpl_spec.gn_name or ""))
                local tid = gen_tpl_cache[tkey]
                if not tid then
                    tid = Wire.uuidV4()
                    gen_tpl_cache[tkey] = tid
                    new_events[#new_events + 1] = encCreatePageTemplate(doc_id, tid, aid, 1, w, h, {
                        is_builtin = tpl_spec.is_builtin,
                        line_spacing = tpl_spec.line_spacing,
                        has_ruling = tpl_spec.has_ruling,
                        paper_theme = tpl_spec.paper_theme,
                        name = tpl_spec.gn_name or tpl_spec.name or "",
                        ruling_layout = tpl_spec.ruling_layout,
                    }, replica_id, nextLamp())
                    doc_gn.templates[tid] = {
                        template_id = tid, logical_att_id = aid, pdf_page = 1,
                        w_gn = w, h_gn = h, paper_theme = tpl_spec.paper_theme or 1,
                        is_builtin = tpl_spec.is_builtin, line_spacing = tpl_spec.line_spacing,
                        has_ruling = tpl_spec.has_ruling, name = tpl_spec.gn_name or tpl_spec.name or "",
                        ruling_layout = tpl_spec.ruling_layout,
                    }
                end
                return tid, w, h
            end
        end
        return nil, gn_w, gn_h
    end

    for i, pg in ipairs(nb.pages) do
        local pgn = pg._gn
        local order_key = page_order_keys[i]

        if pgn and pgn.page_id then
            kept_orig_pages[pgn.page_id] = true
            local pid = pgn.page_id
            local nid = pgn.note_layer_id or Wire.uuidPlusOne(pid)
            local npath = (doc_gn.notes_idx and doc_gn.notes_idx[nid]) or ("notes/" .. nid)

            -- Resolve possible template replacement on existing Goodnotes page
            local cur_tid = pgn.template_id
            local cw = pg.w or nb.w or floor(pgn.gn_w + 0.5)
            local new_tid, new_gn_w, new_gn_h = ensureSpecTemplate(pg, pgn.gn_w, pgn.gn_h)
            if new_tid and new_tid ~= cur_tid then
                cur_tid = new_tid
                pgn.template_id = new_tid
                pgn.gn_w = new_gn_w
                pgn.gn_h = new_gn_h
            end

            -- Patch CreatePage event when page template or order_key changed
            local tpl_changed = (new_tid ~= nil)
            local order_changed = (order_key ~= pgn.order_key)
            if (tpl_changed or order_changed) and pgn.event_idx and doc_gn.raw_events[pgn.event_idx] then
                local re = doc_gn.raw_events[pgn.event_idx]
                local cnt = ((pgn.order_clock and pgn.order_clock.counter) or 0) + 1
                patched_events[pgn.event_idx] = patchCreatePageFields(re.sub_raw,
                    tpl_changed and cur_tid or nil,
                    order_changed and order_key or nil,
                    cnt, nextLamp(), replica_id)
            end

            local scale = (pgn.gn_w and cw > 0) and (pgn.gn_w / cw) or 1.0
            local pt = resolvePageTemplate(nb, i)
            local dark_paper = isDarkPaperRGB(pg._gn_paper_rgb or (pt and pt.paper))

            local res = Mapper.toNoteLayer(pg.ops or {}, pgn.meta, {
                scale = scale, dark_paper = dark_paper,
                canvas_w = cw, canvas_h = pg.h or nb.h or floor(pgn.gn_h + 0.5),
                replica_id = replica_id, min_lamport = lamport,
            })
            lamport = Wire.u64Max(lamport, res.max_lamport)
            if #res.bytes > 0 and res.max_ver > max_obj_ver then max_obj_ver = res.max_ver end

            if res.changed then
                updates[npath] = res.bytes
                for _k, na in ipairs(res.new_attachments) do
                    updates["attachments/" .. na.att_id] = na.blob
                    att_index[na.att_id] = "attachments/" .. na.att_id
                    doc_gn.attachments[na.att_id] = { logical_id = na.att_id, blob_id = na.att_id, byte_size = #na.blob }
                    new_events[#new_events + 1] = encRegisterAttachment(
                        na.att_id, na.att_id, #na.blob, doc_id, false, nil, replica_id, nextLamp()
                    )
                end
                new_events[#new_events + 1] = encNoteLayerCheckpoint(nid, doc_id, replica_id, nextLamp())
                refreshed[i] = { dirty = true, res_bytes = res.bytes, pid = pid, nid = nid, npath = npath,
                    tid = cur_tid, order_key = order_key, gn_w = pgn.gn_w, gn_h = pgn.gn_h, event_idx = pgn.event_idx }
            else
                refreshed[i] = { dirty = false, pid = pid, nid = nid, npath = npath, tid = cur_tid,
                    order_key = order_key, gn_w = pgn.gn_w, gn_h = pgn.gn_h, event_idx = pgn.event_idx }
            end
            notes_idx_list[#notes_idx_list + 1] = { nid, npath }
        else
            -- New / added / duplicated page inside an open `.goodnotes` document
            local pid = Wire.isUUID(pg.id) and pg.id or Wire.uuidV4()
            -- Ensure no collision with existing page ids
            while kept_orig_pages[pid] do pid = Wire.uuidV4() end
            kept_orig_pages[pid] = true
            local nid = Wire.uuidPlusOne(pid)
            local npath = "notes/" .. nid

            local cw = pg.w or nb.w or floor(A4_GN_W + 0.5)
            local ch = pg.h or nb.h or floor(A4_GN_H + 0.5)
            local gn_w, gn_h = A4_GN_W, A4_GN_W * (ch / cw)
            local pt = resolvePageTemplate(nb, i)
            local paper_rgb = pg._gn_paper_rgb or (pt and pt.paper)
            local tpl_id = pg._gn_template_id
            local spec_tid, sw_gn, sh_gn = ensureSpecTemplate(pg, gn_w, gn_h)
            if spec_tid then
                tpl_id, gn_w, gn_h = spec_tid, sw_gn, sh_gn
            elseif tpl_id and doc_gn.templates[tpl_id] then
                local existing_tpl = doc_gn.templates[tpl_id]
                gn_w, gn_h = existing_tpl.w_gn, existing_tpl.h_gn
            else
                local style = (pt and pt.style) or "blank"
                local spacing = (pt and pt.size) or 40
                local strength = (pt and pt.strength) or 45
                local paper = paper_rgb
                local tkey = format("vec|%s|%s|%s|%s|%.2f|%.2f", style, tostring(spacing), tostring(strength),
                    paperKey(paper), gn_w, gn_h)
                tpl_id = gen_tpl_cache[tkey]
                if not tpl_id then
                    local pdf_bytes = PdfGen.buildTemplatePDF(
                        gn_w / Wire.PT_TO_GN, gn_h / Wire.PT_TO_GN,
                        style, (spacing * (gn_w / cw)) / Wire.PT_TO_GN, strength, paper
                    )
                    local aid = registerNewAttachment(pdf_bytes, true, 1)
                    tpl_id = Wire.uuidV4()
                    gen_tpl_cache[tkey] = tpl_id
                    local ev = encCreatePageTemplate(doc_id, tpl_id, aid, 1, gn_w, gn_h, {
                        is_builtin = true, line_spacing = spacing * (gn_w / cw),
                        has_ruling = (style ~= "blank"), paper_theme = isDarkPaperRGB(paper) and 2 or 1,
                        name = style,
                    }, replica_id, nextLamp())
                    new_events[#new_events + 1] = ev
                    doc_gn.templates[tpl_id] = {
                        template_id = tpl_id, logical_att_id = aid, pdf_page = 1,
                        w_gn = gn_w, h_gn = gn_h, paper_theme = isDarkPaperRGB(paper) and 2 or 1,
                    }
                end
            end

            local create_pg_ev = encCreatePage(doc_id, pid, tpl_id, order_key, replica_id, nextLamp())
            new_events[#new_events + 1] = create_pg_ev

            local scale = gn_w / cw
            local dark_paper = isDarkPaperRGB(paper_rgb)
            local res = Mapper.toNoteLayer(pg.ops or {}, nil, {
                scale = scale, dark_paper = dark_paper, canvas_w = cw, canvas_h = ch,
                replica_id = replica_id, min_lamport = lamport,
            })
            lamport = Wire.u64Max(lamport, res.max_lamport)
            if #res.bytes > 0 and res.max_ver > max_obj_ver then max_obj_ver = res.max_ver end

            for _k, na in ipairs(res.new_attachments) do
                updates["attachments/" .. na.att_id] = na.blob
                att_index[na.att_id] = "attachments/" .. na.att_id
                doc_gn.attachments[na.att_id] = { logical_id = na.att_id, blob_id = na.att_id, byte_size = #na.blob }
                new_events[#new_events + 1] = encRegisterAttachment(
                    na.att_id, na.att_id, #na.blob, doc_id, false, nil, replica_id, nextLamp()
                )
            end

            updates[npath] = res.bytes
            notes_idx_list[#notes_idx_list + 1] = { nid, npath }
            if #res.bytes > 0 then
                new_events[#new_events + 1] = encNoteLayerCheckpoint(nid, doc_id, replica_id, nextLamp())
            end
            refreshed[i] = { dirty = true, res_bytes = res.bytes, pid = pid, nid = nid, npath = npath,
                tid = tpl_id, order_key = order_key, gn_w = gn_w, gn_h = gn_h }
        end
    end

    -- Handle deleted pages cleanly: drop CreatePage event + delete notes/<NoteLayerUUID>
    for _idx, re in ipairs(doc_gn.raw_events) do
        if re.tag == 54 then
            local sd = Wire.byField(Wire.parseMessage(re.sub_raw))
            local pid = Wire.getStr(sd, 2, re.entity_uuid)
            if not kept_orig_pages[pid] then
                dropped_events[re.idx] = true
                local nid = Wire.uuidPlusOne(pid)
                local npath = (doc_gn.notes_idx and doc_gn.notes_idx[nid]) or ("notes/" .. nid)
                deletes[npath] = true
            end
        end
    end

    local cur_pg = refreshed[nb.index] or refreshed[1]
    if cur_pg then
        new_events[#new_events + 1] = encUpdateCurrentPage(doc_id, cur_pg.pid, replica_id, nextLamp())
    end

    -- Rebuild `index.events.pb`, `index.notes.pb`, `index.attachments.pb`, `schema.pb`
    local final_ev_msgs = {}
    local rebuilt_raw_events = {}
    for idx, re in ipairs(doc_gn.raw_events) do
        if not dropped_events[idx] then
            local msg = patched_events[idx] or re.raw
            final_ev_msgs[#final_ev_msgs + 1] = msg
            if patched_events[idx] then
                local d = Wire.byField(Wire.parseMessage(msg))
                rebuilt_raw_events[#rebuilt_raw_events + 1] = {
                    idx = #rebuilt_raw_events + 1, entity_uuid = Wire.getStr(d, 1, ""),
                    tag = re.tag, raw = msg, sub_raw = d[re.tag] and d[re.tag][1].val or re.sub_raw,
                }
            else
                rebuilt_raw_events[#rebuilt_raw_events + 1] = {
                    idx = #rebuilt_raw_events + 1, entity_uuid = re.entity_uuid,
                    tag = re.tag, raw = re.raw, sub_raw = re.sub_raw,
                }
            end
        end
    end
    for _i, msg in ipairs(new_events) do
        final_ev_msgs[#final_ev_msgs + 1] = msg
        local d = Wire.byField(Wire.parseMessage(msg))
        local tag, sub_raw
        for k, list in pairs(d) do if k ~= 1 then tag = k; sub_raw = list[1].val; break end end
        rebuilt_raw_events[#rebuilt_raw_events + 1] = {
            idx = #rebuilt_raw_events + 1, entity_uuid = Wire.getStr(d, 1, ""),
            tag = tag, raw = msg, sub_raw = sub_raw,
        }
    end

    local note_idx_msgs = {}
    local notes_map = {}
    for _i, pair in ipairs(notes_idx_list) do
        notes_map[pair[1]] = pair[2]
        note_idx_msgs[#note_idx_msgs + 1] = Wire.encodeMessage({ { 1, 2, pair[1] }, { 2, 2, pair[2] } })
    end

    local att_keys = {}
    for aid in pairs(att_index) do att_keys[#att_keys + 1] = aid end
    table.sort(att_keys)
    local att_idx_msgs = {}
    for _i, aid in ipairs(att_keys) do
        att_idx_msgs[#att_idx_msgs + 1] = Wire.encodeMessage({ { 1, 2, aid }, { 2, 2, att_index[aid] } })
    end

    local final_schema = max_obj_ver > 0 and max_obj_ver or 24
    updates["schema.pb"] = Wire.encodeMessage({ { 1, 0, final_schema } })
    updates["index.events.pb"] = Wire.encodeDelimited(final_ev_msgs)
    updates["index.notes.pb"] = Wire.encodeDelimited(note_idx_msgs)
    updates["index.attachments.pb"] = Wire.encodeDelimited(att_idx_msgs)

    local ok, err = Zip.patch(src_path, dest_path, updates, deletes)
    if not ok then return false, err end

    -- Refresh in-memory `_gn` state so subsequent autosaves & Undo remain incremental and accurate
    doc_gn.source_path = dest_path
    doc_gn.schema_version = final_schema
    doc_gn.max_lamport = Wire.u64ToDec(lamport)
    doc_gn.raw_events = rebuilt_raw_events
    doc_gn.att_idx = att_index
    doc_gn.notes_idx = notes_map

    -- Map page event_idx from rebuilt events
    local pg_ev_idx = {}
    for idx, re in ipairs(rebuilt_raw_events) do
        if re.tag == 54 then
            local sd = Wire.byField(Wire.parseMessage(re.sub_raw))
            pg_ev_idx[Wire.getStr(sd, 2, re.entity_uuid)] = idx
        end
    end

    local z_refresh
    local function extractUpdated(aid)
        if not z_refresh then z_refresh = Zip.open(dest_path) end
        return z_refresh and ensureAttachmentCached(z_refresh, att_index, doc_cache, aid) or nil
    end

    for i, rf in ipairs(refreshed) do
        local pg = nb.pages[i]
        pg.id = rf.pid
        pg._gn_template_id = rf.tid
        pg._gn_tpl_spec = nil
        if rf.dirty and rf.res_bytes then
            local new_ops, new_meta = Mapper.fromNoteLayer(rf.res_bytes, { extractAttachment = extractUpdated })
            -- Preserve existing op table identities where untouched/re-encoded isn't mid-stroke;
            -- replacing `pg.ops` when saved syncs _gn signatures cleanly for next autosave!
            pg.ops = new_ops
            pg._gn = {
                page_id = rf.pid,
                note_layer_id = rf.nid,
                template_id = rf.tid,
                order_key = rf.order_key,
                gn_w = rf.gn_w,
                gn_h = rf.gn_h,
                event_idx = pg_ev_idx[rf.pid],
                meta = new_meta,
            }
        elseif pg._gn then
            pg._gn.order_key = rf.order_key
            pg._gn.event_idx = pg_ev_idx[rf.pid]
        end
    end
    if z_refresh then z_refresh:close() end
    return true
end

------------------------------------------------------------------------------
-- Duplicate (Streaming ZIP Patch with Fresh DocumentUUID)
------------------------------------------------------------------------------

--- Copy a `.goodnotes` file while assigning a fresh `document_id` so duplicated
--- documents never collide in Cloud Sync or Mac Goodnotes Sync.
function GNDoc.duplicate(src_path, dest_path)
    if not Zip.isZip(src_path) then return Storage.copyFile(src_path, dest_path) end
    local arc, err = Zip.open(src_path)
    if not arc then return false, err end
    local ev_bytes = arc:read("index.events.pb")
    arc:close()
    if not ev_bytes then return Storage.copyFile(src_path, dest_path) end

    local ok, patched_ev = pcall(function()
        local raw_events = parseEvents(ev_bytes)
        local new_doc_id = Wire.uuidV4()
        local new_title = Storage.stem(dest_path)
        local msgs = {}
        for _i, re in ipairs(raw_events) do
            if re.tag == 30 then
                msgs[#msgs + 1] = patchCreateDocumentId(re.sub_raw, new_doc_id, new_title)
            elseif re.tag then
                local new_sub = patchEnvelopeEntityDocId(re.tag, re.sub_raw, new_doc_id)
                local ent = (re.tag == 10 or re.tag == 30) and new_doc_id or re.entity_uuid
                msgs[#msgs + 1] = encodeEventEnvelope(ent, re.tag, new_sub)
            else
                msgs[#msgs + 1] = re.raw
            end
        end
        return Wire.encodeDelimited(msgs)
    end)
    if not ok then return Storage.copyFile(src_path, dest_path) end
    return Zip.patch(src_path, dest_path, { ["index.events.pb"] = patched_ev })
end

--- Create a fresh single-page `.goodnotes` file at `dest_path` from materialized template `tpl_mat`.
function GNDoc.newFromTemplate(tpl_mat, dest_path, opts)
    if not tpl_mat then return false, "no template" end
    opts = opts or {}
    local pw = tpl_mat.w or max(200, floor((tpl_mat.w_gn or A4_GN_W) + 0.5))
    local ph = tpl_mat.h or max(200, floor((tpl_mat.h_gn or A4_GN_H) + 0.5))
    local data = {
        version = 2,
        kind = "notebook",
        format = "goodnotes",
        w = pw,
        h = ph,
        index = 1,
        template = {
            style = "blank",
            size = 40,
            strength = 45,
            pdf_path = tpl_mat.pdf_path,
            paper = tpl_mat.paper_rgb,
        },
        pages = {
            {
                ops = {},
                src = 1,
                pdf_path = tpl_mat.pdf_path,
                w = pw,
                h = ph,
                _gn_paper_rgb = tpl_mat.paper_rgb,
                _gn_builtin_tpl = true,
                _gn_tpl_spec = tpl_mat,
            },
        },
    }
    return GNDoc.save(data, dest_path, opts)
end

return GNDoc
