--[[
Goodnotes page template manager:
  * Loads the bundled Goodnotes templates under `ink/goodnotes/bundled_templates/`
  * Imports additional `.goodnotes` files as template packs into
    `<library>/.goodnotes-templates/` (extracting & deduplicating each unique
    `CreatePageTemplate` PDF + Goodnotes metadata)
  * Materializes any 2-color vector template into `dark`, `white`, or `yellow`
    paper on demand via `PdfRecolor` (cached under KOReader's cache dir)
]]

local ffi = require("ffi")
local bit = require("bit")
local Project = require("ink/project")
local Storage = require("ink/storage")
local Wire = require("ink/goodnotes/wire")
local Zip = require("ink/goodnotes/zip")
local PdfRecolor = require("ink/goodnotes/pdfrecolor")

local GNTemplates = {}

GNTemplates.DIR = ".goodnotes-templates"

local floor, max, format, byte, char, sub, concat = math.floor, math.max, string.format, string.byte, string.char, string.sub, table.concat

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

local function readBytes(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function toHex(s)
    if not s or s == "" then return "" end
    local out = {}
    for i = 1, #s do out[i] = format("%02x", byte(s, i)) end
    return concat(out)
end

local function fromHex(h)
    if type(h) ~= "string" or h == "" then return "" end
    return (h:gsub("%x%x", function(x) return char(tonumber(x, 16)) end))
end

local function sanitize(s)
    return (tostring(s or "tpl"):gsub("[^%w%-_]", "_"))
end

local function blobFingerprint(s)
    local crc = Zip.crc32(s)
    local adl = Zip.adler32(s)
    local fnv = bit.tobit(2166136261)
    for i = 1, #s, math.max(1, floor(#s / 4096)) do
        fnv = bit.bxor(fnv, byte(s, i))
        fnv = bit.tobit(bit.lshift(fnv, 24) + fnv * 403)
    end
    return format("%08x-%08x-%s-%d", crc, adl, bit.tohex(fnv), #s)
end

local function bundledDir()
    local src = debug.getinfo(1, "S").source
    local root = src and src:match("^@(.*/)[^/]+%.lua$")
    if root then return root .. "bundled_templates" end
    return "ink/goodnotes/bundled_templates"
end

local function cacheDir()
    local root = Storage.cacheDir() .. "/goodnotes_tpl"
    ensureDirExist(root)
    return root
end

function GNTemplates.userDir(lib_root)
    return lib_root and Storage.join(lib_root, GNTemplates.DIR) or nil
end

local function loadUserIndex(lib_root)
    local dir = GNTemplates.userDir(lib_root)
    if not dir then return {} end
    local raw = readBytes(Storage.join(dir, "index.lua"))
    if not raw then return {} end
    local t = Project.decode(raw)
    return type(t) == "table" and t or {}
end

local function saveUserIndex(lib_root, entries)
    local dir = GNTemplates.userDir(lib_root)
    if not dir or not ensureDirExist(dir) then return false, "cannot create template directory" end
    return Storage.writeAtomic(Storage.join(dir, "index.lua"), Project.encode(entries))
end

--- Return all available Goodnotes templates (bundled first, then user-imported).
function GNTemplates.list(lib_root)
    local out = {}
    local bdir = bundledDir()
    local b_ok, manifest = pcall(require, "ink/goodnotes/bundled_templates/manifest")
    if b_ok and type(manifest) == "table" then
        for _i, m in ipairs(manifest) do
            local p = Storage.join(bdir, m.file)
            if Storage.exists(p) then
                out[#out + 1] = {
                    id = m.id,
                    name = m.name,
                    gn_name = m.gn_name,
                    pdf_path = p,
                    w_gn = m.w_gn,
                    h_gn = m.h_gn,
                    w = max(200, floor(m.w_gn + 0.5)),
                    h = max(200, floor(m.h_gn + 0.5)),
                    paper_theme = m.paper_theme or 2,
                    orig_theme = m.orig_theme or "dark",
                    recolorable = m.recolorable == true,
                    is_builtin = m.is_builtin == true,
                    has_ruling = m.has_ruling == true,
                    line_spacing = m.line_spacing,
                    ruling_layout = fromHex(m.ruling_layout_hex),
                    bundled = true,
                }
            end
        end
    end

    local udir = GNTemplates.userDir(lib_root)
    if udir then
        for _i, m in ipairs(loadUserIndex(lib_root)) do
            local p = m.file and Storage.join(udir, m.file)
            if p and Storage.exists(p) then
                out[#out + 1] = {
                    id = m.id,
                    name = m.name,
                    gn_name = m.gn_name,
                    pdf_path = p,
                    w_gn = m.w_gn,
                    h_gn = m.h_gn,
                    w = max(200, floor((m.w_gn or 834.2) + 0.5)),
                    h = max(200, floor((m.h_gn or 1078.8) + 0.5)),
                    paper_theme = m.paper_theme or 1,
                    orig_theme = m.orig_theme or "white",
                    recolorable = m.recolorable == true,
                    is_builtin = m.is_builtin == true,
                    has_ruling = m.has_ruling == true,
                    line_spacing = m.line_spacing,
                    ruling_layout = fromHex(m.ruling_layout_hex),
                    bundled = false,
                }
            end
        end
    end
    return out
end

function GNTemplates.find(lib_root, id)
    if not id then return nil end
    for _i, tpl in ipairs(GNTemplates.list(lib_root)) do
        if tpl.id == id then return tpl end
    end
    return nil
end

--- Materialize `tpl` in `color_choice` ("dark", "white", "yellow", or "original"),
--- recoloring + caching the PDF on demand when the template is 2-color vector.
function GNTemplates.materialize(tpl, color_choice)
    if not tpl then return nil end
    local choice = (color_choice and PdfRecolor.THEMES[color_choice]) and color_choice or (tpl.orig_theme or "dark")
    local use_orig = (not tpl.recolorable) or (choice == "original") or (choice == tpl.orig_theme)

    local theme = use_orig and PdfRecolor.THEMES[tpl.orig_theme or "white"] or PdfRecolor.THEMES[choice]
    local pdf_path = tpl.pdf_path

    if not use_orig then
        local cdir = cacheDir()
        local cached = Storage.join(cdir, sanitize(tpl.id) .. "_" .. choice .. ".pdf")
        if not Storage.exists(cached) or (Storage.size(cached) or 0) == 0 then
            local orig_bytes = readBytes(tpl.pdf_path)
            if orig_bytes then
                local rec_bytes, changed = PdfRecolor.recolor(orig_bytes, choice)
                if changed then
                    Storage.writeAtomic(cached, rec_bytes)
                else
                    cached = tpl.pdf_path
                end
            end
        end
        if Storage.exists(cached) then pdf_path = cached end
    end

    local gn_name = tpl.gn_name or tpl.name or ""
    if not use_orig and theme and theme.gn_suffix and gn_name ~= "" then
        if gn_name:match("%s*%-%s*Black$") or gn_name:match("%s*%-%s*White$") or gn_name:match("%s*%-%s*Yellow$") then
            gn_name = gn_name:gsub("%s*%-%s*%a+$", " - " .. theme.gn_suffix)
        end
    end

    local p_theme = (not use_orig and theme) and theme.paper_theme or (tpl.paper_theme or 1)
    local p_rgb
    if use_orig then
        p_rgb = (tpl.orig_theme == "dark" or p_theme == 2) and { 0x33, 0x33, 0x33 }
            or (tpl.orig_theme == "yellow" and { 0xFA, 0xF3, 0xD7 } or nil)
    elseif theme then
        p_rgb = theme.paper_rgb
    end

    return {
        id = tpl.id,
        name = tpl.name,
        gn_name = gn_name,
        pdf_path = pdf_path,
        w_gn = tpl.w_gn,
        h_gn = tpl.h_gn,
        w = max(200, floor((tpl.w_gn or 834.2) + 0.5)),
        h = max(200, floor((tpl.h_gn or 1078.8) + 0.5)),
        paper_theme = p_theme,
        paper_rgb = p_rgb,
        line_spacing = tpl.line_spacing,
        has_ruling = tpl.has_ruling,
        is_builtin = tpl.is_builtin,
        ruling_layout = tpl.ruling_layout,
        color = use_orig and (tpl.orig_theme or "original") or choice,
    }
end

--- Import every unique template page inside `.goodnotes` file `src_path` into
--- `<lib_root>/.goodnotes-templates/`. Returns `added_count, skipped_count` or `nil, err`.
function GNTemplates.importPack(src_path, lib_root)
    local GNDoc = require("ink/goodnotes/document")
    local valid, err = GNDoc.validate(src_path)
    if not valid then return nil, err or "invalid goodnotes archive" end
    local udir = GNTemplates.userDir(lib_root)
    if not (udir and ensureDirExist(udir)) then return nil, "cannot create templates folder" end

    local arc, aerr = Zip.open(src_path)
    if not arc then return nil, aerr end

    local ok, res_or_err, skipped_res = pcall(function()
        local att_idx = {}
        for _i, rec in ipairs(Wire.parseDelimited(assert(arc:read("index.attachments.pb")))) do
            local d = Wire.byField(Wire.parseMessage(rec))
            att_idx[Wire.getStr(d, 1, "")] = Wire.getStr(d, 2, "")
        end

        local templates = {}
        local page_order = {}
        for _i, raw in ipairs(Wire.parseDelimited(assert(arc:read("index.events.pb")))) do
            local d = Wire.byField(Wire.parseMessage(raw))
            if d[2] then
                local sd = Wire.byField(Wire.parseMessage(d[2][1].val))
                local tid = Wire.getStr(sd, 2, Wire.getStr(d, 1, ""))
                local sz = sd[8] and Wire.decSize(sd[8][1].val) or { w = 834.2, h = 1078.8 }
                local theme
                if sd[17] then
                    local ptd = Wire.byField(Wire.parseMessage(sd[17][1].val))
                    if ptd[1] then theme = Wire.getUInt(ptd, 1, 1) end
                end
                templates[tid] = {
                    tid = tid,
                    logical_att_id = Wire.getStr(sd, 4, ""),
                    pdf_page = sd[5] and Wire.getUInt(sd, 5, 1) or 1,
                    is_builtin = sd[6] and Wire.getUInt(sd, 6, 0) ~= 0,
                    line_spacing = sd[7] and Wire.getF64(sd, 7, 32.0) or nil,
                    w_gn = (sz.w and sz.w > 10) and sz.w or 834.2,
                    h_gn = (sz.h and sz.h > 10) and sz.h or 1078.8,
                    gn_name = Wire.getStr(sd, 9, ""),
                    paper_theme = theme or 1,
                    has_ruling = sd[13] ~= nil,
                    ruling_layout = sd[18] and sd[18][1].val or "",
                }
            elseif d[54] then
                local sd = Wire.byField(Wire.parseMessage(d[54][1].val))
                local tid = sd[3] and Wire.getStr(Wire.byField(Wire.parseMessage(sd[3][1].val)), 1, "") or ""
                local okey = sd[4] and Wire.getStr(Wire.byField(Wire.parseMessage(sd[4][1].val)), 1, "") or ""
                if tid ~= "" then page_order[#page_order + 1] = { tid = tid, okey = okey } end
            end
        end
        table.sort(page_order, function(a, b) return a.okey < b.okey end)

        -- Ordered list of unique template IDs (page order first, then any unreferenced templates)
        local ordered_tids, seen_tid = {}, {}
        for _i, p in ipairs(page_order) do
            if templates[p.tid] and not seen_tid[p.tid] then
                seen_tid[p.tid] = true
                ordered_tids[#ordered_tids + 1] = p.tid
            end
        end
        for tid in pairs(templates) do
            if not seen_tid[tid] then
                seen_tid[tid] = true
                ordered_tids[#ordered_tids + 1] = tid
            end
        end

        -- Build fingerprint + name indices from existing bundled & user templates to prevent duplicates
        local existing = GNTemplates.list(lib_root)
        local known_fps = {}
        local used_names = {}
        for _i, e in ipairs(existing) do
            used_names[e.name:lower()] = true
            local bytes = readBytes(e.pdf_path)
            if bytes then known_fps[blobFingerprint(bytes) .. "|" .. tostring(e.pdf_page or 1)] = true end
        end

        local entries = loadUserIndex(lib_root)
        local pack_base = Storage.stem(src_path)
        local added, skipped, idx_num = 0, 0, 0

        for _i, tid in ipairs(ordered_tids) do
            local tpl = templates[tid]
            local apath = att_idx[tpl.logical_att_id]
            local blob = apath and arc:has(apath) and arc:read(apath) or nil
            if type(blob) == "string" and sub(blob, 1, 5) == "%PDF-" then
                idx_num = idx_num + 1
                local fp = blobFingerprint(blob) .. "|" .. tostring(tpl.pdf_page or 1)
                if known_fps[fp] then
                    skipped = skipped + 1
                else
                    known_fps[fp] = true
                    local insp = PdfRecolor.inspect(blob)
                    local base_name = PdfRecolor.guessName(insp, tpl.gn_name, tpl.line_spacing)
                    if base_name == "Template" then
                        base_name = (#ordered_tids > 1) and format("%s %d", pack_base, idx_num) or pack_base
                    end
                    local name = base_name
                    local suffix_n = 2
                    while used_names[name:lower()] do
                        name = format("%s (%d)", base_name, suffix_n)
                        suffix_n = suffix_n + 1
                    end
                    used_names[name:lower()] = true

                    local id = "user_" .. Wire.uuidV4():lower()
                    local file = id .. ".pdf"
                    local dest = Storage.join(udir, file)
                    local wf_ok, wf_err = Storage.writeAtomic(dest, blob)
                    if not wf_ok then error(wf_err or "write failed") end

                    entries[#entries + 1] = {
                        id = id,
                        name = name,
                        file = file,
                        gn_name = tpl.gn_name,
                        w_gn = tpl.w_gn,
                        h_gn = tpl.h_gn,
                        paper_theme = tpl.paper_theme,
                        orig_theme = insp.recolorable and insp.orig_theme
                            or (tpl.paper_theme == 2 and "dark" or "white"),
                        recolorable = insp.recolorable == true,
                        is_builtin = tpl.is_builtin == true,
                        has_ruling = tpl.has_ruling == true,
                        line_spacing = tpl.line_spacing,
                        ruling_layout_hex = toHex(tpl.ruling_layout),
                    }
                    added = added + 1
                end
            end
        end

        if added > 0 then
            local sok, serr = saveUserIndex(lib_root, entries)
            if not sok then error(serr or "index save failed") end
        end
        return added, skipped
    end)

    arc:close()
    if not ok then return nil, tostring(res_or_err) end
    return res_or_err, skipped_res
end

function GNTemplates.remove(lib_root, id)
    local entries = loadUserIndex(lib_root)
    local udir = GNTemplates.userDir(lib_root)
    local removed = false
    for i = #entries, 1, -1 do
        if entries[i].id == id then
            if udir and entries[i].file then os.remove(Storage.join(udir, entries[i].file)) end
            table.remove(entries, i)
            removed = true
        end
    end
    if not removed then return false end
    return saveUserIndex(lib_root, entries)
end

return GNTemplates
