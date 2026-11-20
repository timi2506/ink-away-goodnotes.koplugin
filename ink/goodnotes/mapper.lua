--[[
Bidirectional lossless mapper between Goodnotes `notes/<NoteLayerUUID>` object
streams and Ink Away page `ops` lists.

Lossless CRDT design:
  * Active Goodnotes objects (`ImageItem`, `StrokeItem`, `ShapeFillItem`,
    `StickyNoteItem`, `TextOrShapeItem`, `ConnectorItem`) keep their raw
    `[header_bytes, payload_bytes]` in `page_meta.raw_objects[id]` plus a
    deterministic geometry/style fingerprint `op._gn.sig`.
  * Untouched objects re-emit their exact original bytes untouched (preserving
    Format 2 outlines, Math Assist `f1.19/20` JSON, Study Tape attributes,
    Flowchart polygons, RichText hyperlinks/shadows, etc.).
  * Modified objects increment `revision.counter` + `lamport` under `replica_id`.
  * Deleted/erased objects emit proper Goodnotes tombstones (`is_deleted = 1`).
  * Original tombstones and unknown payload tags pass through untouched.
]]

local Canvas = require("ink/canvas")
local Cut = require("ink/cut")
local Geom = require("ink/geom")
local Shapes = require("ink/shapes")
local Symmetry = require("ink/symmetry")
local Wire = require("ink/goodnotes/wire")
local LZ4 = require("ink/goodnotes/lz4")
local Tpl = require("ink/goodnotes/tpl")
local RichText = require("ink/goodnotes/richtext")
local PdfGen = require("ink/goodnotes/pdfgen")
local Http = require("ink/share/http")

local Mapper = {}

local floor, max, abs = math.floor, math.max, math.abs
local concat, format = table.concat, string.format

local function clamp255(v)
    local n = floor((v or 0) * 255 + 0.5)
    if n < 0 then return 0 elseif n > 255 then return 255 end
    return n
end

local function gnColorToRGBAlpha(c)
    if not c then return { 0, 0, 0 }, 255 end
    return { clamp255(c.r), clamp255(c.g), clamp255(c.b) }, clamp255(c.a == nil and 1.0 or c.a)
end

local function rgbToGn01(rgb, alpha_255, dark_paper)
    local r, g, b = 0, 0, 0
    if type(rgb) == "table" then r, g, b = rgb[1] or 0, rgb[2] or 0, rgb[3] or 0 end
    if dark_paper and r == 0 and g == 0 and b == 0 then
        r, g, b = 255, 255, 255
    end
    return r / 255.0, g / 255.0, b / 255.0, (alpha_255 or 255) / 255.0
end

local function qNum(v)
    if v == nil then return "n" end
    if Wire.isNaN(v) then return "nan" end
    return format("%.2f", v)
end

------------------------------------------------------------------------------
-- Deterministic Ink Away Op Fingerprint (detects edits cleanly)
------------------------------------------------------------------------------

function Mapper.opSignature(op)
    if not op then return "" end
    local parts = {
        tostring(op.kind or ""),
        tostring(op.style or ""),
        tostring(op.shape or ""),
        op.closed and "1" or "0",
        op.fill and "1" or "0",
        op.hidden and "1" or "0",
        tostring(op.arrow or ""),
        qNum(op.width),
        tostring(op.alpha or 255),
        tostring(op.fill_alpha or ""),
        tostring(op.sym or ""),
        tostring(op.path or ""),
        qNum(op.x), qNum(op.y), qNum(op.w), qNum(op.h),
        qNum(op.angle),
        op.flip_h and "1" or "0",
        op.flip_v and "1" or "0",
        tostring(op.group or ""),
        tostring(op.size or ""),
        tostring(op.align or ""),
    }
    if op.color then
        parts[#parts + 1] = format("c:%d,%d,%d", op.color[1] or 0, op.color[2] or 0, op.color[3] or 0)
    end
    if op.fill_color then
        parts[#parts + 1] = format("f:%d,%d,%d", op.fill_color[1] or 0, op.fill_color[2] or 0, op.fill_color[3] or 0)
    end
    if op.pts then
        local np = #op.pts
        parts[#parts + 1] = "pts:" .. np
        if np > 0 then
            parts[#parts + 1] = qNum(op.pts[1]) .. "," .. qNum(op.pts[2]) .. "," .. qNum(op.pts[np - 1]) .. "," .. qNum(op.pts[np])
            local sx, sy = 0, 0
            for i = 1, np - 1, 2 do sx = sx + op.pts[i]; sy = sy + op.pts[i + 1] end
            parts[#parts + 1] = qNum(sx) .. "," .. qNum(sy)
        end
    end
    if op.pr then
        local sp = 0
        for _i, p in ipairs(op.pr) do sp = sp + p end
        parts[#parts + 1] = "pr:" .. #op.pr .. ":" .. sp
    end
    if op.paras then
        for _i, p in ipairs(op.paras) do
            parts[#parts + 1] = "|P:" .. tostring(p.bullet or "") .. (p.checked and "1" or "")
            for _j, s in ipairs(p.spans or {}) do
                parts[#parts + 1] = concat({
                    tostring(s.t or ""),
                    s.b and "b" or "",
                    s.i and "i" or "",
                    s.u and "u" or "",
                    s.s and "s" or "",
                    tostring(s.hl or ""),
                    tostring(s.sz or ""),
                    tostring(s.c or ""),
                }, "\1")
            end
        end
    end
    return concat(parts, ";")
end

------------------------------------------------------------------------------
-- Parsing Goodnotes Note Layer Pairs -> Structured Meta + Ink Away Ops
------------------------------------------------------------------------------

local function parseSnappedShape(raw)
    if not raw or raw == "" then return nil end
    local sd = Wire.byField(Wire.parseMessage(raw))
    local out = { stroke_width = sd[15] and Wire.getF32(sd, 15, 2.0) or nil }
    if sd[1] then
        local pd = Wire.byField(Wire.parseMessage(sd[1][1].val))
        local pts = {}
        for _i, entry in ipairs(pd[1] or {}) do
            pts[#pts + 1] = Wire.decPoint(entry.val)
        end
        out.polyline = pts
    end
    if sd[4] then
        local ed = Wire.byField(Wire.parseMessage(sd[4][1].val))
        out.ellipse = {
            center = Wire.decPoint(Wire.getBytes(ed, 1)),
            radii = Wire.decPoint(Wire.getBytes(ed, 2)),
            rotation_rad = sd[4] and Wire.getF32(ed, 3, 0.0) or 0.0,
        }
    end
    return out
end

local function parseFillGeom(raw)
    if not raw or raw == "" then return nil end
    local fg = Wire.byField(Wire.parseMessage(raw))
    local out = {}
    if fg[1] then
        local pd = Wire.byField(Wire.parseMessage(fg[1][1].val))
        local pts = {}
        for _i, entry in ipairs(pd[1] or {}) do
            pts[#pts + 1] = Wire.decPoint(entry.val)
        end
        out.polygon = pts
    end
    if fg[4] then
        local ed = Wire.byField(Wire.parseMessage(fg[4][1].val))
        out.ellipse = {
            center = Wire.decPoint(Wire.getBytes(ed, 1)),
            radii = Wire.decPoint(Wire.getBytes(ed, 2)),
            rotation_rad = Wire.getF32(ed, 3, 0.0),
        }
    end
    return (out.polygon or out.ellipse) and out or nil
end

local function ptsFromPoints(list, dx, dy)
    dx, dy = dx or 0, dy or 0
    local pts = {}
    for _i, p in ipairs(list or {}) do
        pts[#pts + 1] = p.x + dx
        pts[#pts + 1] = p.y + dy
    end
    return pts
end

local function trimClosingPoint(pts)
    local n = #pts
    if n >= 6 and abs(pts[1] - pts[n - 1]) < 0.01 and abs(pts[2] - pts[n]) < 0.01 then
        local trimmed = {}
        for i = 1, n - 2 do trimmed[i] = pts[i] end
        return trimmed
    end
    return pts
end

local function parseTextOrShapeGeom(pd)
    local size_spec = {}
    if pd[21] then
        local sc = Wire.byField(Wire.parseMessage(pd[21][1].val))
        if sc[2] then
            local f = Wire.byField(Wire.parseMessage(sc[2][1].val))
            size_spec = { mode = "fixed", w = Wire.getF32(f, 1, 160), h = Wire.getF32(f, 2, 40) }
        elseif sc[3] then
            local a = Wire.byField(Wire.parseMessage(sc[3][1].val))
            size_spec = {
                mode = "auto",
                min_w = Wire.getF32(a, 1, 32), max_w = Wire.getF32(a, 2, 600),
                min_h = Wire.getF32(a, 3, 32), max_h = Wire.getF32(a, 4, math.huge),
            }
        end
    end
    local shape_kind = {}
    if pd[22] then
        local sk = Wire.byField(Wire.parseMessage(pd[22][1].val))
        if sk[1] then
            local r1 = sk[1][1].val ~= "" and Wire.byField(Wire.parseMessage(sk[1][1].val)) or {}
            shape_kind = { kind = "rect", corner_radius = sk[1][1].val ~= "" and Wire.getF32(r1, 1, 0) or 0 }
        elseif sk[3] then
            local p3 = Wire.byField(Wire.parseMessage(sk[3][1].val))
            local inner = p3[1] and Wire.byField(Wire.parseMessage(p3[1][1].val)) or {}
            local verts = {}
            for _i, vraw in ipairs(inner[1] or {}) do
                local vd = Wire.byField(Wire.parseMessage(vraw.val))
                local pt = vd[1] and Wire.decPoint(vd[1][1].val) or { x = 0, y = 0 }
                verts[#verts + 1] = pt
            end
            local closed = not inner[2] or Wire.getUInt(inner, 2, 1) ~= 0
            shape_kind = { kind = "poly", vertices = verts, closed = closed }
        end
    end
    return size_spec, shape_kind
end

local function extractColorHolder(raw)
    if not raw or raw == "" then return nil end
    local d = Wire.byField(Wire.parseMessage(raw))
    return d[1] and Wire.decColor(d[1][1].val) or nil
end

local function imageDimsFromFile(path)
    local f = io.open(path, "rb")
    if not f then return nil, nil end
    local head = f:read(262144) or ""
    f:close()
    return Http.imageSize(head)
end

local function cloneOpWithGn(op, gn)
    gn.sig = Mapper.opSignature(op)
    op._gn = gn
    return op
end

--- Decode raw bytes of `notes/<NoteLayerUUID>` into `(ops, page_meta)`.
--- `ctx.extractAttachment(att_id)` should return `local_file_path, nil` or `nil, err`.
function Mapper.fromNoteLayer(note_bytes, ctx)
    ctx = ctx or {}
    local meta = {
        raw_objects = {},
        tombstones = {},
        passthrough = {},
        max_lamport = 0ULL,
        max_ver = 24,
        max_z = 0,
    }
    if not note_bytes or note_bytes == "" then
        return {}, meta
    end

    local msgs = Wire.parseDelimited(note_bytes)
    if #msgs % 2 ~= 0 then
        error("Expected even message count in Goodnotes note layer, got " .. #msgs)
    end

    local active_list = {}
    local sticky_origins = {}
    local fills_by_stroke = {}
    local paired_fills = {}

    for i = 1, #msgs, 2 do
        local hdr_bytes = msgs[i]
        local pay_bytes = msgs[i + 1]
        local hd = Wire.byField(Wire.parseMessage(hdr_bytes))
        local obj_id = Wire.getStr(hd, 1, "")
        local rev = hd[2] and Wire.decLwwClock(hd[2][1].val) or { counter = 0, tiebreaker = 0 }
        local is_del_hdr = hd[3] and Wire.getUInt(hd, 3, 0) ~= 0
        local att_id_hdr = Wire.getStr(hd, 4)
        local lamp = Wire.getU64(hd, 9, 0)
        local min_ver = Wire.getUInt(hd, 16, 24)
        local parent_hdr = Wire.getStr(hd, 20)

        meta.max_lamport = Wire.u64Max(meta.max_lamport, lamp)
        if min_ver > meta.max_ver then meta.max_ver = min_ver end

        local pay_top = Wire.parseMessage(pay_bytes)
        if #pay_top ~= 1 then
            meta.passthrough[#meta.passthrough + 1] = { header_bytes = hdr_bytes, payload_bytes = pay_bytes, object_id = obj_id }
        else
            local pfn = pay_top[1].field
            local pd = Wire.byField(Wire.parseMessage(pay_top[1].val))
            local is_del_pay = (pfn == 7 or pfn == 9) and pd[14] and Wire.getUInt(pd, 14, 0) ~= 0

            if is_del_hdr or is_del_pay then
                meta.tombstones[#meta.tombstones + 1] = {
                    object_id = obj_id, tag = pfn, revision = rev,
                    header_bytes = hdr_bytes, payload_bytes = pay_bytes,
                }
            elseif pfn ~= 1 and pfn ~= 7 and pfn ~= 9 and pfn ~= 20 and pfn ~= 21 and pfn ~= 22 then
                meta.passthrough[#meta.passthrough + 1] = {
                    object_id = obj_id, tag = pfn,
                    header_bytes = hdr_bytes, payload_bytes = pay_bytes,
                }
            else
                local z_tag = (pfn == 1 and 5) or (pfn == 9 and 3) or 7
                local z_order = pd[z_tag] and Wire.decZOrder(pd[z_tag][1].val) or { index = 0, tiebreaker = 0 }
                if z_order.index >= meta.max_z then meta.max_z = z_order.index + 1 end
                local rec = {
                    seq = #active_list + 1,
                    object_id = obj_id,
                    tag = pfn,
                    pd = pd,
                    revision = rev,
                    lamport = lamp,
                    min_ver = min_ver,
                    attachment_id = att_id_hdr,
                    parent_id = parent_hdr,
                    z_order = z_order,
                    header_bytes = hdr_bytes,
                    payload_bytes = pay_bytes,
                }
                meta.raw_objects[obj_id] = rec
                active_list[#active_list + 1] = rec

                if pfn == 20 and pd[20] then
                    local tr = Wire.byField(Wire.parseMessage(pd[20][1].val))
                    sticky_origins[obj_id] = tr[1] and Wire.decPoint(tr[1][1].val) or { x = 0, y = 0 }
                elseif pfn == 9 and pd[5] then
                    local sid = Wire.getStr(pd, 5)
                    if sid and sid ~= "" then fills_by_stroke[sid] = rec end
                end
            end
        end
    end

    table.sort(active_list, function(a, b)
        if a.z_order.index ~= b.z_order.index then return a.z_order.index < b.z_order.index end
        if a.z_order.tiebreaker ~= b.z_order.tiebreaker then return a.z_order.tiebreaker < b.z_order.tiebreaker end
        return a.seq < b.seq
    end)

    -- Mark paired fills in advance so z-order iteration folds them cleanly onto their snapped StrokeItem
    for _i, rec in ipairs(active_list) do
        if rec.tag == 7 and rec.pd[9] and rec.pd[9][1].val ~= "" and fills_by_stroke[rec.object_id] then
            paired_fills[fills_by_stroke[rec.object_id].object_id] = rec.object_id
        end
    end

    local ops = {}
    for _i, rec in ipairs(active_list) do
        local pfn, pd, obj_id = rec.tag, rec.pd, rec.object_id

        if pfn == 1 then   -- ImageItem
            local bb = Wire.decRect(Wire.getBytes(pd, 2))
            local att_id = Wire.getStr(pd, 4, rec.attachment_id)
            local img_path = ctx.extractAttachment and att_id and ctx.extractAttachment(att_id) or nil
            if img_path then
                local natw, nath = imageDimsFromFile(img_path)
                local op = {
                    kind = "image",
                    x = bb.x, y = bb.y,
                    w = max(4, bb.w), h = max(4, bb.h),
                    path = img_path,
                    natw = natw or max(1, floor(bb.w + 0.5)),
                    nath = nath or max(1, floor(bb.h + 0.5)),
                }
                ops[#ops + 1] = cloneOpWithGn(op, {
                    id = obj_id, tag = 1, att_id = att_id,
                    is_sticker = pd[6] and Wire.getUInt(pd, 6, 0) ~= 0 or false,
                    element_asset_id = Wire.getStr(pd, 7),
                    math_graph_id = Wire.getStr(pd, 19),
                    math_graph_json = Wire.getStr(pd, 20),
                })
            else
                -- Keep missing attachment image as passthrough so it is never lost on save
                meta.passthrough[#meta.passthrough + 1] = rec
            end

        elseif pfn == 7 then   -- StrokeItem
            local col_gn = Wire.decColor(Wire.getBytes(pd, 4))
            local rgb, alpha = gnColorToRGBAlpha(col_gn)
            local pen_type = Wire.getUInt(pd, 3, 0)
            local is_hl = pd[5] and Wire.getUInt(pd, 5, 0) ~= 0
            local has_tape = pd[20] and pd[20][1].val ~= ""
            local parent_id = rec.parent_id
            if not parent_id and pd[100] then
                local prd = Wire.byField(Wire.parseMessage(pd[100][1].val))
                parent_id = Wire.getStr(prd, 1)
            end
            local local_off = (pd[6] and pd[6][1].val ~= "") and Wire.decPoint(pd[6][1].val) or nil
            local dx, dy = 0, 0
            if parent_id and local_off then
                local po = sticky_origins[parent_id] or { x = 0, y = 0 }
                dx = local_off.x + po.x
                dy = local_off.y + po.y
            end
            local group_id = parent_id and ("gn:" .. parent_id) or nil

            local snapped = pd[9] and parseSnappedShape(pd[9][1].val) or nil
            if snapped and (snapped.polyline or snapped.ellipse) then
                local fill_rec = fills_by_stroke[obj_id]
                local fill_rgb, fill_alpha
                if fill_rec and fill_rec.pd[7] then
                    fill_rgb, fill_alpha = gnColorToRGBAlpha(Wire.decColor(fill_rec.pd[7][1].val))
                end
                local sw = snapped.stroke_width or 2.0
                if snapped.ellipse then
                    local el = snapped.ellipse
                    local rot_deg = (el.rotation_rad or 0) * 180 / math.pi
                    local op = {
                        kind = "shape", shape = "ellipse",
                        pts = {
                            el.center.x + dx - el.radii.x, el.center.y + dy - el.radii.y,
                            el.center.x + dx + el.radii.x, el.center.y + dy + el.radii.y,
                        },
                        angle = abs(rot_deg) > 0.05 and (el.rotation_rad) or nil,
                        width = max(1, sw), color = rgb, alpha = alpha,
                        fill_color = fill_rgb, fill_alpha = fill_alpha,
                        group = group_id,
                    }
                    ops[#ops + 1] = cloneOpWithGn(op, {
                        id = obj_id, tag = 7, fill_id = fill_rec and fill_rec.object_id or nil,
                        parent_id = parent_id, local_off = local_off,
                    })
                else
                    local pts = ptsFromPoints(snapped.polyline, dx, dy)
                    local npts = floor(#pts / 2)
                    local op
                    if npts == 2 then
                        op = {
                            kind = "shape", shape = "line", pts = pts,
                            width = max(1, sw), color = rgb, alpha = alpha, group = group_id,
                        }
                    else
                        local closed = fill_rec ~= nil
                        if npts >= 3 and abs(pts[1] - pts[#pts - 1]) < 0.01 and abs(pts[2] - pts[#pts]) < 0.01 then
                            closed = true
                            pts = trimClosingPoint(pts)
                        end
                        op = {
                            kind = "shape", shape = "poly", pts = pts, closed = closed or nil,
                            width = max(1, sw), color = rgb, alpha = alpha,
                            fill_color = fill_rgb, fill_alpha = fill_alpha,
                            group = group_id,
                        }
                    end
                    ops[#ops + 1] = cloneOpWithGn(op, {
                        id = obj_id, tag = 7, fill_id = fill_rec and fill_rec.object_id or nil,
                        parent_id = parent_id, local_off = local_off,
                    })
                end
            else
                local comp_tpl = Wire.getBytes(pd, 2)
                local raw_tpl = comp_tpl and LZ4.decompress(comp_tpl)
                local ok, dec = pcall(Tpl.decodeStroke, raw_tpl)
                local poly = (ok and dec) and Tpl.toPolyline(dec, dx, dy) or nil
                if poly and #poly.pts >= 2 then
                    local style = "solid"
                    if has_tape then
                        style = "solid"
                    elseif is_hl then
                        style = "highlighter"
                    elseif pen_type == 5 then
                        style = "pencil"
                    elseif pen_type == 1 and poly.pr then
                        style = "ballpoint"
                    end
                    local op = {
                        kind = "ink",
                        style = style,
                        width = max(1, poly.width or 2),
                        alpha = alpha,
                        color = rgb,
                        pts = poly.pts,
                        pr = (style == "ballpoint" or style == "pencil") and poly.pr or nil,
                        seed = poly.seed,
                        group = group_id,
                    }
                    ops[#ops + 1] = cloneOpWithGn(op, {
                        id = obj_id, tag = 7, parent_id = parent_id, local_off = local_off,
                        pen_type = pen_type, is_tape = has_tape, is_highlighter = is_hl,
                    })
                else
                    meta.passthrough[#meta.passthrough + 1] = rec
                end
            end

        elseif pfn == 9 and not paired_fills[obj_id] then   -- Standalone ShapeFillItem
            local fg = pd[4] and parseFillGeom(pd[4][1].val) or nil
            local rgb, alpha = gnColorToRGBAlpha(pd[7] and Wire.decColor(pd[7][1].val) or nil)
            if fg and fg.ellipse then
                local el = fg.ellipse
                local op = {
                    kind = "shape", shape = "ellipse", fill = true,
                    pts = { el.center.x - el.radii.x, el.center.y - el.radii.y, el.center.x + el.radii.x, el.center.y + el.radii.y },
                    angle = abs(el.rotation_rad or 0) > 1e-3 and el.rotation_rad or nil,
                    width = 1, color = rgb, alpha = alpha,
                }
                ops[#ops + 1] = cloneOpWithGn(op, { id = obj_id, tag = 9 })
            elseif fg and fg.polygon and #fg.polygon >= 3 then
                local pts = trimClosingPoint(ptsFromPoints(fg.polygon))
                local op = {
                    kind = "shape", shape = "poly", closed = true, fill = true,
                    pts = pts, width = 1, color = rgb, alpha = alpha,
                }
                ops[#ops + 1] = cloneOpWithGn(op, { id = obj_id, tag = 9 })
            end

        elseif pfn == 20 then   -- StickyNoteItem
            local tr = pd[20] and Wire.byField(Wire.parseMessage(pd[20][1].val)) or {}
            local origin = tr[1] and Wire.decPoint(tr[1][1].val) or { x = 0, y = 0 }
            local sc = pd[21] and Wire.byField(Wire.parseMessage(pd[21][1].val)) or {}
            local fsz = sc[2] and Wire.decSize(sc[2][1].val) or { w = 256, h = 256 }
            local ox, oy, sw, sh = origin.x, origin.y, fsz.w, fsz.h
            local bg_rgb, bg_alpha = gnColorToRGBAlpha(pd[30] and Wire.decColor(pd[30][1].val) or nil)
            local gid = "gn:" .. obj_id
            local edge = {
                max(0, floor(bg_rgb[1] * 0.72)),
                max(0, floor(bg_rgb[2] * 0.72)),
                max(0, floor(bg_rgb[3] * 0.72)),
            }
            local body_op = {
                kind = "shape", shape = "poly", closed = true, sbody = true, stk = "gn_sticky", group = gid,
                pts = { ox, oy, ox + sw, oy, ox + sw, oy + sh, ox, oy + sh },
                fill_color = bg_rgb, fill_alpha = bg_alpha, color = edge, alpha = bg_alpha, width = 1.5,
            }
            ops[#ops + 1] = cloneOpWithGn(body_op, {
                id = obj_id, tag = 20, part = "body",
                orig_x = ox, orig_y = oy, orig_w = sw, orig_h = sh,
                author_id = Wire.getStr(pd, 32), author_name = Wire.getStr(pd, 33),
            })
            local rt = pd[31] and RichText.decode(pd[31][1].val) or nil
            if rt and rt.plain_text ~= "" then
                local ins = rt.insets or {}
                local il, it, ir, ib = ins.left or 8, ins.top or 8, ins.right or 8, ins.bottom or 8
                local paras, align, font_sz = RichText.toInkParas(rt, 24)
                local txt_op = {
                    kind = "text", group = gid, stk = "gn_sticky_text",
                    x = ox + il, y = oy + it,
                    w = max(24, sw - il - ir), h = max(24, sh - it - ib),
                    auto_h = false, size = font_sz, align = align, paras = paras,
                }
                ops[#ops + 1] = cloneOpWithGn(txt_op, { id = obj_id, tag = 20, part = "text" })
            end

        elseif pfn == 21 then   -- TextOrShapeItem
            local tr = pd[20] and Wire.byField(Wire.parseMessage(pd[20][1].val)) or {}
            local origin = tr[1] and Wire.decPoint(tr[1][1].val) or { x = 0, y = 0 }
            local size_spec, shape_kind = parseTextOrShapeGeom(pd)
            local rt = pd[32] and RichText.decode(pd[32][1].val) or nil
            local is_textbox = pd[9] and Wire.getUInt(pd, 9, 0) ~= 0
            local bw, bh
            if size_spec.mode == "fixed" then
                bw, bh = size_spec.w, size_spec.h
            elseif rt and rt.measured_size and rt.measured_size.w > 1 then
                bw, bh = rt.measured_size.w, rt.measured_size.h
            else
                bw, bh = 160, 48
            end

            if is_textbox then
                local ins = (rt and rt.insets) or {}
                local il, it = ins.left or 0, ins.top or 0
                local paras, align, font_sz = RichText.toInkParas(rt, 24)
                local op = {
                    kind = "text",
                    x = origin.x + il, y = origin.y + it,
                    w = max(32, bw), h = max(20, bh),
                    auto_h = size_spec.mode == "auto" or nil,
                    size = font_sz, align = align, paras = paras,
                }
                ops[#ops + 1] = cloneOpWithGn(op, {
                    id = obj_id, tag = 21, part = "textbox",
                    orig_x = origin.x, orig_y = origin.y, orig_w = bw, orig_h = bh,
                })
            else
                local fill_col = pd[30] and extractColorHolder(pd[30][1].val) or nil
                local fill_rgb, fill_alpha
                if fill_col and (fill_col.a or 0) > 0.01 then
                    fill_rgb, fill_alpha = gnColorToRGBAlpha(fill_col)
                end
                local border_w, border_rgb, border_alpha = 2, { 0, 0, 0 }, 255
                if pd[31] then
                    local b31 = Wire.byField(Wire.parseMessage(pd[31][1].val))
                    border_w = Wire.getF32(b31, 1, 2.0)
                    local bcol = b31[3] and extractColorHolder(b31[3][1].val) or nil
                    if bcol then border_rgb, border_alpha = gnColorToRGBAlpha(bcol) end
                end
                local pts, shape_type, closed
                if shape_kind.kind == "poly" and #(shape_kind.vertices or {}) >= 3 then
                    shape_type = "poly"
                    closed = shape_kind.closed
                    pts = {}
                    for _k, v in ipairs(shape_kind.vertices) do
                        pts[#pts + 1] = origin.x + v.x * bw
                        pts[#pts + 1] = origin.y + v.y * bh
                    end
                else
                    shape_type = "rect"
                    closed = true
                    pts = { origin.x, origin.y, origin.x + bw, origin.y + bh }
                end
                local has_text = rt and rt.plain_text and rt.plain_text ~= ""
                local gid = has_text and ("gn:" .. obj_id) or nil
                local sh_op = {
                    kind = "shape", shape = shape_type, pts = pts, closed = closed or nil,
                    width = max(1, border_w), color = border_rgb, alpha = border_alpha,
                    fill_color = fill_rgb, fill_alpha = fill_alpha, group = gid,
                }
                ops[#ops + 1] = cloneOpWithGn(sh_op, {
                    id = obj_id, tag = 21, part = "shape",
                    orig_x = origin.x, orig_y = origin.y, orig_w = bw, orig_h = bh,
                })
                if has_text then
                    local paras, align, font_sz = RichText.toInkParas(rt, 20)
                    local tx_op = {
                        kind = "text", group = gid,
                        x = origin.x + 8, y = origin.y + 8,
                        w = max(24, bw - 16), h = max(20, bh - 16),
                        auto_h = false, size = font_sz, align = align, paras = paras,
                    }
                    ops[#ops + 1] = cloneOpWithGn(tx_op, { id = obj_id, tag = 21, part = "text" })
                end
            end

        elseif pfn == 22 then   -- ConnectorItem
            local sw = 2.0
            local srgb, salpha = { 0, 0, 0 }, 255
            if pd[32] then
                local st = Wire.byField(Wire.parseMessage(pd[32][1].val))
                sw = Wire.getF32(st, 1, 2.0)
                local scol = st[3] and extractColorHolder(st[3][1].val) or nil
                if scol then srgb, salpha = gnColorToRGBAlpha(scol) end
            end
            local arrow = (pd[31] and Wire.getUInt(pd, 31, 0) == 1) and "end" or nil
            if pd[20] then
                local p20 = Wire.byField(Wire.parseMessage(pd[20][1].val))
                local sp = p20[1] and Wire.decPoint(Wire.getBytes(Wire.byField(Wire.parseMessage(p20[1][1].val)), 1)) or { x = 0, y = 0 }
                local cp = Wire.decPoint(Wire.getBytes(p20, 2))
                local ep = p20[3] and Wire.decPoint(Wire.getBytes(Wire.byField(Wire.parseMessage(p20[3][1].val)), 1)) or { x = 0, y = 0 }
                local op = {
                    kind = "shape", shape = "curve", pts = { sp.x, sp.y, ep.x, ep.y, cp.x, cp.y },
                    width = max(1, sw), color = srgb, alpha = salpha, arrow = arrow,
                }
                ops[#ops + 1] = cloneOpWithGn(op, { id = obj_id, tag = 22 })
            elseif pd[21] then
                local p21 = Wire.byField(Wire.parseMessage(pd[21][1].val))
                local sp = p21[1] and Wire.decPoint(Wire.getBytes(Wire.byField(Wire.parseMessage(p21[1][1].val)), 1)) or { x = 0, y = 0 }
                local ep = p21[3] and Wire.decPoint(Wire.getBytes(Wire.byField(Wire.parseMessage(p21[3][1].val)), 1)) or { x = 0, y = 0 }
                local mid
                if p21[5] then
                    local m5 = Wire.byField(Wire.parseMessage(p21[5][1].val))
                    if m5[2] then mid = Wire.decPoint(m5[2][1].val) end
                end
                local op
                if mid and (abs(mid.x - sp.x) > 1 or abs(mid.y - sp.y) > 1) and (abs(mid.x - ep.x) > 1 or abs(mid.y - ep.y) > 1) then
                    op = {
                        kind = "shape", shape = "poly", closed = false,
                        pts = { sp.x, sp.y, mid.x, mid.y, ep.x, ep.y },
                        width = max(1, sw), color = srgb, alpha = salpha, arrow = arrow,
                    }
                else
                    op = {
                        kind = "shape", shape = "line",
                        pts = { sp.x, sp.y, ep.x, ep.y },
                        width = max(1, sw), color = srgb, alpha = salpha, arrow = arrow,
                    }
                end
                ops[#ops + 1] = cloneOpWithGn(op, { id = obj_id, tag = 22 })
            end
        end
    end

    return ops, meta
end

------------------------------------------------------------------------------
-- Encoding Ink Away Ops -> Goodnotes Note Layer Pairs (with Lossless Diff)
------------------------------------------------------------------------------

local function settleErases(ops, cw, ch)
    local out = {}
    local had_erase = false
    for _i, op in ipairs(ops or {}) do
        if op.kind == "erase" then
            had_erase = true
            if op.pts and #op.pts >= 2 then
                local opts = { text = not op.spare_text, pictures = op.ebg }
                local er = (op.width or 2) / 2
                for _j, f in ipairs(Symmetry.flips(op.sym)) do
                    local ep = f == 0 and op.pts or Symmetry.flipPoints(op.pts, f, cw, ch)
                    out = Cut.ops(out, ep, er, opts)
                end
            end
        elseif not op.hidden and op.kind ~= "link" then
            out[#out + 1] = op
        end
    end
    return out, had_erase
end

local function makeNotePair(obj_id, rev_cnt, rev_tie, min_ver, payload_tag, payload_bytes, replica_id, lamport, att_id, parent_id)
    local rev_bytes = Wire.encLwwClock(rev_cnt, rev_tie)
    local hdr = Wire.encodeMessage(Wire.packFields(
        Wire.fBytes(1, obj_id, true),
        Wire.fBytes(2, rev_bytes, true),
        Wire.fBytes(4, att_id),
        { 8, 0, replica_id },
        { 9, 0, lamport },
        { 14, 0, Wire.CONST_5381 },
        { 16, 0, min_ver },
        Wire.fBytes(20, parent_id)
    ))
    local pay = Wire.encodeMessage({ { payload_tag, 2, payload_bytes } })
    return hdr, pay
end

local function replaceOrAppendFields(raw_bytes, patches)
    local fields = raw_bytes and raw_bytes ~= "" and Wire.parseMessage(raw_bytes) or {}
    local out = {}
    local seen = {}
    for _i, f in ipairs(fields) do
        local rep = patches[f.field]
        if rep ~= nil then
            if not seen[f.field] and rep ~= false then
                out[#out + 1] = rep
            end
            seen[f.field] = true
        else
            out[#out + 1] = { f.field, f.wt, f.wt == 0 and f.u64 or f.val }
        end
    end
    for k, rep in pairs(patches) do
        if not seen[k] and rep ~= false then
            out[#out + 1] = rep
        end
    end
    return Wire.encodeMessage(out)
end

local function makeTombstonePair(orig_rec, replica_id, lamport)
    local new_cnt = ((orig_rec.revision and orig_rec.revision.counter) or 0) + 1
    local new_tie = Wire.randomU32()
    local rev_bytes = Wire.encLwwClock(new_cnt, new_tie)
    local pfn = orig_rec.tag
    local hdr = Wire.encodeMessage(Wire.packFields(
        Wire.fBytes(1, orig_rec.object_id, true),
        Wire.fBytes(2, rev_bytes, true),
        { 3, 0, 1 },
        Wire.fBytes(4, orig_rec.attachment_id),
        { 8, 0, replica_id },
        { 9, 0, lamport },
        { 14, 0, Wire.CONST_5381 },
        { 16, 0, orig_rec.min_ver or 24 },
        Wire.fBytes(20, orig_rec.parent_id)
    ))
    local orig_inner
    if orig_rec.payload_bytes and orig_rec.payload_bytes ~= "" then
        local od = Wire.byField(Wire.parseMessage(orig_rec.payload_bytes))
        orig_inner = od[pfn] and od[pfn][1].val or nil
    end
    local pay_inner
    if orig_inner then
        if pfn == 7 then
            local stub_tpl = Tpl.encodeFormat1({}, 2.0, 1.0)
            pay_inner = replaceOrAppendFields(orig_inner, {
                [2] = { 2, 2, LZ4.compress(stub_tpl) },
                [14] = { 14, 0, 1 },
                [15] = { 15, 2, rev_bytes },
            })
        elseif pfn == 9 then
            local nan = 0 / 0
            pay_inner = replaceOrAppendFields(orig_inner, {
                [2] = { 2, 2, Wire.encRect(nan, nan, nan, nan, true) },
                [14] = { 14, 0, 1 },
                [15] = { 15, 2, rev_bytes },
            })
        elseif pfn == 20 or pfn == 21 or pfn == 22 then
            pay_inner = replaceOrAppendFields(orig_inner, {
                [3] = { 3, 2, rev_bytes },
            })
        else
            pay_inner = replaceOrAppendFields(orig_inner, {
                [14] = { 14, 0, 1 },
                [15] = { 15, 2, rev_bytes },
            })
        end
    else
        if pfn == 7 then
            local stub_tpl = Tpl.encodeFormat1({}, 2.0, 1.0)
            pay_inner = Wire.encodeMessage(Wire.packFields(
                Wire.fBytes(1, orig_rec.object_id, true),
                Wire.fBytes(2, LZ4.compress(stub_tpl), true),
                Wire.fBytes(4, Wire.encColor(0, 0, 0, 1), true),
                Wire.fBytes(7, Wire.encZOrder(0, 0), true),
                { 14, 0, 1 },
                Wire.fBytes(15, rev_bytes, true),
                { 21, 0, orig_rec.min_ver or 24 }
            ))
        elseif pfn == 9 then
            local nan = 0 / 0
            pay_inner = Wire.encodeMessage(Wire.packFields(
                Wire.fBytes(1, orig_rec.object_id, true),
                Wire.fBytes(2, Wire.encRect(nan, nan, nan, nan, true), true),
                Wire.fBytes(3, Wire.encZOrder(0, 0), true),
                Wire.fBytes(5, orig_rec.object_id, true),
                Wire.fBytes(7, Wire.encColor(0, 0, 0, 1), true),
                { 14, 0, 1 },
                Wire.fBytes(15, rev_bytes, true),
                { 18, 0, 24 }
            ))
        elseif pfn == 20 or pfn == 21 or pfn == 22 then
            pay_inner = Wire.encodeMessage({
                { 1, 2, orig_rec.object_id },
                { 2, 0, orig_rec.min_ver or 35 },
                { 3, 2, rev_bytes },
            })
        else
            pay_inner = Wire.encodeMessage({
                { 1, 2, orig_rec.object_id },
                { 15, 2, rev_bytes },
                { 18, 0, orig_rec.min_ver or 24 },
            })
        end
    end
    local pay = Wire.encodeMessage({ { pfn, 2, pay_inner } })
    return hdr, pay
end

local function scaleFlatPts(pts, s)
    if s == 1.0 then return pts end
    local out = {}
    for i = 1, #pts do out[i] = pts[i] * s end
    return out
end

local function encodeInkStroke(op, obj_id, rev_cnt, rev_tie, z_idx, z_tie, scale, dark_paper, pts_override, parent_override)
    local style = op.style or "solid"
    local pts = scaleFlatPts(pts_override or op.pts or {}, scale)
    local r, g, b, a = rgbToGn01(op.color, op.alpha, dark_paper)
    local rev_bytes = Wire.encLwwClock(rev_cnt, rev_tie)
    local z_bytes = Wire.encZOrder(z_idx, z_tie)

    local pen_type
    local is_hl = 0
    local tpl_bytes
    local min_ver = 24
    local gn = op._gn

    if style == "highlighter" or (gn and gn.is_highlighter) then
        pen_type = 0
        is_hl = 1
        -- Goodnotes highlighters use translucent alpha (~0.5) so underlying dark ink/PDF text stays legible
        if not gn and (op.alpha == nil or op.alpha >= 200) then a = 0.5 end
        tpl_bytes = Tpl.encodeFormat1(pts, (op.width or 20) * scale, 1.0)
    elseif style == "pencil" then
        pen_type = 5
        min_ver = 25
        local pr01 = {}
        local n = floor(#pts / 2)
        for i = 1, n do
            pr01[i] = op.pr and op.pr[i] and (op.pr[i] / 255.0) or 0.75
        end
        tpl_bytes = Tpl.encodeFormat3(pts, pr01, (op.width or 2.0) * scale, op.seed, 1.0)
    elseif (style == "ballpoint" or style == "fountain" or style == "calligraphy") and op.pr and #op.pr > 0 then
        pen_type = 1
        local st = op.style and require("ink/raster").STYLES[op.style]
        local minf = (st and st.minf) or 0.5
        local w = (op.width or 2.0) * scale
        local hw = {}
        local n = floor(#pts / 2)
        for i = 1, n do
            local p = op.pr[i] or 200
            hw[i] = (w * 0.5) * (minf + (1 - minf) * (p / 255.0))
        end
        tpl_bytes = Tpl.encodeFormat2(pts, hw, w * 0.5, 1.0)
    else
        pen_type = 0
        tpl_bytes = Tpl.encodeFormat1(pts, (op.width or 2.0) * scale, 1.0)
    end

    local parent_id, local_off_bytes = nil, ""
    if parent_override and parent_override.id then
        parent_id = parent_override.id
        local_off_bytes = Wire.encPoint(parent_override.local_x or 0, parent_override.local_y or 0)
    elseif gn and gn.parent_id then
        parent_id = gn.parent_id
        if gn.local_off then
            local_off_bytes = Wire.encPoint(gn.local_off.x, gn.local_off.y)
        end
    end

    local pay_inner = Wire.encodeMessage(Wire.packFields(
        Wire.fBytes(1, obj_id, true),
        Wire.fBytes(2, LZ4.compress(tpl_bytes), true),
        Wire.fVarint(3, pen_type),
        Wire.fBytes(4, Wire.encColor(r, g, b, a), true),
        Wire.fVarint(5, is_hl),
        Wire.fBytes(6, local_off_bytes, true),
        Wire.fBytes(7, z_bytes, true),
        Wire.fBytes(9, "", true),
        Wire.fBytes(15, rev_bytes, true),
        Wire.fBytes(20, "", true),
        { 21, 0, min_ver },
        parent_id and { 100, 2, Wire.encodeMessage({ { 1, 2, parent_id } }) } or nil
    ))
    return 7, min_ver, pay_inner, parent_id
end

local function shapePolyPtsScaled(op, scale)
    local poly, closed = Shapes.outline(op)
    local out = {}
    for i = 1, #poly, 2 do
        out[#out + 1] = poly[i] * scale
        out[#out + 1] = poly[i + 1] * scale
    end
    if closed and #out >= 4 then
        out[#out + 1] = out[1]
        out[#out + 1] = out[2]
    end
    return out, closed
end

local function encodeShapeOp(op, obj_id, rev_cnt, rev_tie, z_idx, z_tie, scale, dark_paper, replica_id, lamport)
    -- Returns primary record + optional second record (StrokeItem + ShapeFillItem)
    local r, g, b, a = rgbToGn01(op.color, op.alpha, dark_paper)
    local sw = max(0.5, (op.width or 2) * scale)

    -- Pure single-head arrow connector -> ConnectorItem (`tag 22`). Bidirectional ("both") falls
    -- through to snapped StrokeItem so both arrowheads render cleanly.
    if op.arrow == "end" and (op.shape == "line" or op.shape == "curve") then
        local p = op.pts
        local path_field, path_bytes
        if op.shape == "curve" and #p >= 6 then
            path_field = 20
            path_bytes = Wire.encodeMessage({
                { 1, 2, Wire.encodeMessage({ { 1, 2, Wire.encPoint(p[1] * scale, p[2] * scale) } }) },
                { 2, 2, Wire.encPoint(p[5] * scale, p[6] * scale) },
                { 3, 2, Wire.encodeMessage({ { 1, 2, Wire.encPoint(p[3] * scale, p[4] * scale) } }) },
            })
        else
            path_field = 21
            path_bytes = Wire.encodeMessage({
                { 1, 2, Wire.encodeMessage({ { 1, 2, Wire.encPoint(p[1] * scale, p[2] * scale) } }) },
                { 3, 2, Wire.encodeMessage({ { 1, 2, Wire.encPoint(p[3] * scale, p[4] * scale) } }) },
                { 4, 0, 1 },
            })
        end
        local stroke_style = Wire.encodeMessage({
            { 1, 5, Wire.encF32(sw) },
            { 2, 2, Wire.encodeMessage({ { 1, 2, "" } }) },
            { 3, 2, Wire.encodeMessage({ { 1, 2, Wire.encColor(r, g, b, a) } }) },
        })
        local pay_inner = Wire.encodeMessage({
            { 1, 2, obj_id },
            { 2, 0, 31 },
            { 3, 2, Wire.encLwwClock(rev_cnt, rev_tie) },
            { 7, 2, Wire.encZOrder(z_idx, z_tie) },
            { path_field, 2, path_bytes },
            { 31, 0, 1 },
            { 32, 2, stroke_style },
        })
        local h, py = makeNotePair(obj_id, rev_cnt, rev_tie, 31, 22, pay_inner, replica_id, lamport)
        return { { hdr = h, pay = py, ver = 31 } }
    end

    if op.arrow == "both" and (op.shape == "line" or op.shape == "curve") then
        local outlines = Shapes.outlines(op)
        local out_records = {}
        local rev_bytes = Wire.encLwwClock(rev_cnt, rev_tie)
        for idx, line_pts in ipairs(outlines) do
            local eid = idx == 1 and obj_id or Wire.uuidV4()
            local scaled = scaleFlatPts(line_pts, scale)
            local poly_msgs = {}
            for j = 1, #scaled - 1, 2 do
                poly_msgs[#poly_msgs + 1] = { 1, 2, Wire.encPoint(scaled[j], scaled[j + 1]) }
            end
            local snapped_inner = Wire.encodeMessage({
                { 1, 2, Wire.encodeMessage(poly_msgs) },
                { 5, 2, Wire.encodeMessage({ { 2, 0, 1 } }) },
                { 15, 5, Wire.encF32(sw) },
            })
            local stub_tpl = Tpl.encodeFormat1({}, sw, 1.0)
            local stroke_inner = Wire.encodeMessage(Wire.packFields(
                Wire.fBytes(1, eid, true),
                Wire.fBytes(2, LZ4.compress(stub_tpl), true),
                Wire.fBytes(4, Wire.encColor(r, g, b, a), true),
                Wire.fBytes(6, "", true),
                Wire.fBytes(7, Wire.encZOrder(z_idx + idx - 1, z_tie), true),
                Wire.fBytes(9, snapped_inner, true),
                Wire.fBytes(15, rev_bytes, true),
                Wire.fBytes(20, "", true),
                { 21, 0, 24 }
            ))
            local sh, sp = makeNotePair(eid, rev_cnt, rev_tie, 24, 7, stroke_inner, replica_id, lamport)
            out_records[#out_records + 1] = { hdr = sh, pay = sp, ver = 24 }
        end
        return out_records
    end

    -- Closed filled shape or snapped shape
    local pts, closed = shapePolyPtsScaled(op, scale)
    local out_records = {}

    local has_fill = (op.fill or op.fill_color ~= nil) and closed
    if has_fill then
        local fr, fg, fb, fa
        if op.fill_color then
            fr, fg, fb, fa = rgbToGn01(op.fill_color, op.fill_alpha or 255, dark_paper)
        else
            fr, fg, fb, fa = r, g, b, a
        end
        local fill_id = (op._gn and op._gn.fill_id) or Wire.uuidV4()
        local minx, miny, maxx, maxy = Geom.bounds(pts)
        local poly_msgs = {}
        for i = 1, #pts - 1, 2 do
            poly_msgs[#poly_msgs + 1] = { 1, 2, Wire.encPoint(pts[i], pts[i + 1]) }
        end
        local fg_bytes = Wire.encodeMessage({ { 1, 2, Wire.encodeMessage(poly_msgs) } })
        local fill_rev = Wire.encLwwClock(0, z_tie)
        local fill_inner = Wire.encodeMessage(Wire.packFields(
            Wire.fBytes(1, fill_id, true),
            Wire.fBytes(2, Wire.encRect(minx, miny, maxx - minx, maxy - miny, true), true),
            Wire.fBytes(3, Wire.encZOrder(z_idx, z_tie), true),
            Wire.fBytes(4, fg_bytes, true),
            Wire.fBytes(5, obj_id, true),
            Wire.fBytes(6, "", true),
            Wire.fBytes(7, Wire.encColor(fr, fg, fb, fa), true),
            Wire.fBytes(15, fill_rev, true),
            { 18, 0, 24 }
        ))
        local fh, fp = makeNotePair(fill_id, 0, z_tie, 24, 9, fill_inner, replica_id, lamport)
        out_records[#out_records + 1] = { hdr = fh, pay = fp, ver = 24 }
        if op.fill then
            -- Pure filled shape (`op.fill == true` has no separate outline stroke unless fill_color is set)
            return out_records
        end
    end

    -- Outline as snapped `StrokeItem` (polygon / ellipse)
    local snapped_inner
    if op.shape == "ellipse" and #op.pts >= 4 then
        local p = op.pts
        local cx = (p[1] + p[3]) * 0.5 * scale
        local cy = (p[2] + p[4]) * 0.5 * scale
        local rx = abs(p[3] - p[1]) * 0.5 * scale
        local ry = abs(p[4] - p[2]) * 0.5 * scale
        local el_bytes = Wire.encodeMessage(Wire.packFields(
            Wire.fBytes(1, Wire.encPoint(cx, cy), true),
            Wire.fBytes(2, Wire.encPoint(rx, ry), true),
            Wire.fF32(3, op.angle or 0.0)
        ))
        snapped_inner = Wire.encodeMessage({
            { 4, 2, el_bytes },
            { 5, 2, Wire.encodeMessage({ { 2, 0, 1 } }) },
            { 15, 5, Wire.encF32(sw) },
        })
    else
        local poly_msgs = {}
        for i = 1, #pts - 1, 2 do
            poly_msgs[#poly_msgs + 1] = { 1, 2, Wire.encPoint(pts[i], pts[i + 1]) }
        end
        snapped_inner = Wire.encodeMessage({
            { 1, 2, Wire.encodeMessage(poly_msgs) },
            { 5, 2, Wire.encodeMessage({ { 2, 0, 1 } }) },
            { 15, 5, Wire.encF32(sw) },
        })
    end
    local stub_tpl = Tpl.encodeFormat1({}, sw, 1.0)
    local rev_bytes = Wire.encLwwClock(rev_cnt, rev_tie)
    local stroke_inner = Wire.encodeMessage(Wire.packFields(
        Wire.fBytes(1, obj_id, true),
        Wire.fBytes(2, LZ4.compress(stub_tpl), true),
        Wire.fBytes(4, Wire.encColor(r, g, b, a), true),
        Wire.fBytes(6, "", true),
        Wire.fBytes(7, Wire.encZOrder(z_idx, z_tie), true),
        Wire.fBytes(9, snapped_inner, true),
        Wire.fBytes(15, rev_bytes, true),
        Wire.fBytes(20, "", true),
        { 21, 0, 24 }
    ))
    local sh, sp = makeNotePair(obj_id, rev_cnt, rev_tie, 24, 7, stroke_inner, replica_id, lamport)
    out_records[#out_records + 1] = { hdr = sh, pay = sp, ver = 24 }
    return out_records
end

local function encodeTextBox(op, obj_id, rev_cnt, rev_tie, z_idx, z_tie, scale, dark_paper, replica_id, lamport)
    local rt_bytes = RichText.encode(op, {
        scale = scale, dark_paper = dark_paper, insets = { 10, 10, 10, 10 },
    })
    local ox = (op.x or 0) * scale
    local oy = (op.y or 0) * scale
    local max_w = max(80.0, (op.w or 200) * scale)
    local tr = Wire.encodeMessage({ { 1, 2, Wire.encPoint(ox, oy) }, { 3, 5, Wire.encF32(1.0) } })
    local sc = Wire.encodeMessage({
        { 3, 2, Wire.encodeMessage({ { 1, 5, Wire.encF32(32) }, { 2, 5, Wire.encF32(max_w) }, { 3, 5, Wire.encF32(32) }, { 4, 5, Wire.encF32(math.huge) } }) },
    })
    local pay_inner = Wire.encodeMessage({
        { 1, 2, obj_id },
        { 2, 0, 35 },
        { 3, 2, Wire.encLwwClock(rev_cnt, rev_tie) },
        { 7, 2, Wire.encZOrder(z_idx, z_tie) },
        { 9, 0, 1 },
        { 20, 2, tr },
        { 21, 2, sc },
        { 22, 2, Wire.encodeMessage({ { 1, 2, "" } }) },
        { 30, 2, Wire.encodeMessage({ { 1, 2, Wire.encodeMessage({ { 1, 2, Wire.encColor(1, 1, 1, 0) } }) } }) },
        { 31, 2, Wire.encodeMessage({ { 2, 2, Wire.encodeMessage({ { 1, 2, "" } }) }, { 3, 2, Wire.encodeMessage({ { 1, 2, Wire.encColor(1, 1, 1, 0) } }) } }) },
        { 32, 2, rt_bytes },
    })
    local h, py = makeNotePair(obj_id, rev_cnt, rev_tie, 35, 21, pay_inner, replica_id, lamport)
    return { hdr = h, pay = py, ver = 35 }
end

local function encodeImageRecord(att_id, blob_bytes, obj_id, x, y, w, h, rev_cnt, rev_tie, z_idx, z_tie, replica_id, lamport, gn)
    local pay_inner = Wire.encodeMessage(Wire.packFields(
        Wire.fBytes(1, obj_id, true),
        Wire.fBytes(2, Wire.encRect(x, y, w, h, true), true),
        Wire.fBytes(3, Wire.encRect(x + w * 0.5, y + h * 0.5, w, h, true), true),
        Wire.fBytes(4, att_id, true),
        Wire.fBytes(5, Wire.encZOrder(z_idx, z_tie), true),
        (gn and gn.is_sticker) and { 6, 0, 1 } or nil,
        Wire.fBytes(7, gn and gn.element_asset_id or nil),
        Wire.fBytes(15, Wire.encLwwClock(rev_cnt, rev_tie), true),
        { 18, 0, 24 },
        Wire.fBytes(19, gn and gn.math_graph_id or nil),
        Wire.fBytes(20, gn and gn.math_graph_json or nil)
    ))
    local hdr, pay = makeNotePair(obj_id, rev_cnt, rev_tie, 24, 1, pay_inner, replica_id, lamport, att_id)
    return { hdr = hdr, pay = pay, ver = 24, att_id = att_id, blob = blob_bytes }
end

local function readFileBytes(path)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Encode Ink Away `ops` back into a binary `notes/<NoteLayerUUID>` stream, reusing untouched
--- Goodnotes objects verbatim, updating edited ones, and emitting tombstones for deleted ones.
--- Returns `{ bytes, max_ver, max_lamport, new_attachments, has_changes }`.
function Mapper.toNoteLayer(ops, page_meta, ctx)
    ctx = ctx or {}
    local scale = ctx.scale or 1.0
    local dark_paper = ctx.dark_paper and true or false
    local cw, ch = ctx.canvas_w or 1091, ctx.canvas_h or 1543
    local replica_id = Wire.toU64(ctx.replica_id or Wire.randomU64())
    local lamport = page_meta and Wire.toU64(page_meta.max_lamport) or 0ULL
    if ctx.min_lamport then lamport = Wire.u64Max(lamport, Wire.toU64(ctx.min_lamport)) end

    local function nextLamport()
        lamport = Wire.u64Add(lamport, 1)
        return lamport
    end

    local settled = settleErases(ops, cw, ch)
    local raw_objects = (page_meta and page_meta.raw_objects) or {}

    -- Count how many surviving ops reference each original Goodnotes `id` (if >1 from Cut splitting,
    -- assign fresh UUIDs to pieces and tombstone the original ID). Also group multi-part objects (`20`, `21`).
    local id_counts = {}
    local group_parts = {}   -- obj_id -> { body = op, text = op, shape = op }
    for _i, op in ipairs(settled) do
        local gn = op._gn
        if gn and gn.id and raw_objects[gn.id] then
            if gn.part then
                local gp = group_parts[gn.id]
                if not gp then gp = {}; group_parts[gn.id] = gp end
                gp[gn.part] = op
            else
                id_counts[gn.id] = (id_counts[gn.id] or 0) + 1
            end
        end
    end

    local emitted_msgs = {}
    local max_ver = 24
    local seen_ids = {}
    local touched_orig = {}
    local detached_parent = {}
    local new_attachments = {}   -- list of { att_id = ..., blob = ..., is_pdf = false }
    local reused_blobs = {}      -- file_path -> att_id
    local z_cursor = (page_meta and page_meta.max_z) or 0
    local has_changes = false

    local function emitPair(hdr, pay, ver)
        emitted_msgs[#emitted_msgs + 1] = hdr
        emitted_msgs[#emitted_msgs + 1] = pay
        if ver and ver > max_ver then max_ver = ver end
    end

    for _i, op in ipairs(settled) do
        local gn = op._gn
        local orig = gn and gn.id and raw_objects[gn.id] or nil
        local same_sig = gn and (gn.sig == Mapper.opSignature(op)) or false

        if gn and orig and gn.part and gn.part ~= "textbox" and (gn.tag == 20 or gn.tag == 21) then
            -- Sticky note or Flowchart+Text group
            if not seen_ids[orig.object_id] then
                seen_ids[orig.object_id] = true
                local gp = group_parts[orig.object_id] or {}
                local all_unchanged = true
                for _k, part_op in pairs(gp) do
                    if not (part_op._gn and part_op._gn.sig == Mapper.opSignature(part_op)) then
                        all_unchanged = false
                        break
                    end
                end
                -- Also check if expected text part of sticky note was deleted
                if gn.tag == 20 and gp.body and (gp.body._gn.sig == Mapper.opSignature(gp.body))
                        and (not gp.text or gp.text._gn.sig == Mapper.opSignature(gp.text)) then
                    if orig.pd[31] and not gp.text then
                        local rt_check = RichText.decode(orig.pd[31][1].val)
                        if rt_check and rt_check.plain_text ~= "" then all_unchanged = false end
                    end
                elseif not gp.body and not gp.shape then
                    all_unchanged = false
                end

                if all_unchanged then
                    touched_orig[orig.object_id] = true
                    emitPair(orig.header_bytes, orig.payload_bytes, orig.min_ver)
                else
                    has_changes = true
                    touched_orig[orig.object_id] = true
                    -- Re-encode StickyNote (`tag 20`) or TextOrShape (`tag 21`) with updated origin/size/text
                    local ref_op = gp.body or gp.shape or gp.text
                    local x0, y0, x1, y1 = Canvas.opBox(ref_op)
                    local new_cnt = (orig.revision.counter or 0) + 1
                    local new_tie = Wire.randomU32()
                    local lamp = nextLamport()
                    local rev_bytes = Wire.encLwwClock(new_cnt, new_tie)
                    if gn.tag == 20 then
                        local bw, bh = max(24, (x1 - x0) * scale), max(24, (y1 - y0) * scale)
                        local rt_bytes = gp.text
                            and RichText.encode(gp.text, { scale = scale, measured_w = bw, measured_h = bh })
                            or RichText.encode(nil, { text = "", font_size = 24 })
                        local r, g, b, a = rgbToGn01(ref_op.fill_color or { 250, 231, 120 }, ref_op.fill_alpha or 255, false)
                        local tr = Wire.encodeMessage({ { 1, 2, Wire.encPoint(x0 * scale, y0 * scale) }, { 3, 5, Wire.encF32(1.0) } })
                        local sc = Wire.encodeMessage({
                            { 2, 2, Wire.encodeMessage({ { 1, 5, Wire.encF32(bw) }, { 2, 5, Wire.encF32(bh) }, { 3, 5, Wire.encF32(math.huge) } }) },
                        })
                        local inner = Wire.encodeMessage(Wire.packFields(
                            Wire.fBytes(1, orig.object_id, true),
                            { 2, 0, 35 },
                            Wire.fBytes(3, rev_bytes, true),
                            Wire.fBytes(7, Wire.encZOrder(orig.z_order.index, orig.z_order.tiebreaker), true),
                            { 20, 2, tr },
                            { 21, 2, sc },
                            Wire.fBytes(30, Wire.encColor(r, g, b, a), true),
                            Wire.fBytes(31, rt_bytes, true),
                            Wire.fBytes(32, ref_op._gn.author_id),
                            Wire.fBytes(33, ref_op._gn.author_name),
                            { 40, 0, 1 }, { 41, 0, 1 }
                        ))
                        local h, p = makeNotePair(orig.object_id, new_cnt, new_tie, 35, 20, inner, replica_id, lamp)
                        emitPair(h, p, 35)
                    elseif gp.text and not gp.shape then
                        local rec = encodeTextBox(gp.text, orig.object_id, new_cnt, new_tie,
                            orig.z_order.index, orig.z_order.tiebreaker, scale, dark_paper, replica_id, lamp)
                        emitPair(rec.hdr, rec.pay, rec.ver)
                    else
                        -- Moved/edited flowchart shape
                        local res = encodeShapeOp(gp.shape or ref_op, orig.object_id, new_cnt, new_tie,
                            orig.z_order.index, orig.z_order.tiebreaker, scale, dark_paper, replica_id, lamp)
                        for _r, item in ipairs(res) do emitPair(item.hdr, item.pay, item.ver) end
                    end
                end
            end

        elseif gn and orig and gn.part == "textbox" and gn.tag == 21 and same_sig and not seen_ids[orig.object_id] then
            seen_ids[orig.object_id] = true
            touched_orig[orig.object_id] = true
            emitPair(orig.header_bytes, orig.payload_bytes, orig.min_ver)

        elseif gn and orig and not gn.part and same_sig and (id_counts[orig.object_id] == 1) and not seen_ids[orig.object_id] then
            -- 100% Untouched Goodnotes object (StrokeItem, Snapped Shape+Fill, ImageItem, ConnectorItem, etc.)
            seen_ids[orig.object_id] = true
            touched_orig[orig.object_id] = true
            emitPair(orig.header_bytes, orig.payload_bytes, orig.min_ver)
            if gn.fill_id and raw_objects[gn.fill_id] then
                touched_orig[gn.fill_id] = true
                local fr = raw_objects[gn.fill_id]
                emitPair(fr.header_bytes, fr.payload_bytes, fr.min_ver)
            end

        elseif gn and orig and gn.parent_id and not same_sig and gn.tag == 7 and id_counts[orig.object_id] == 1 and not seen_ids[orig.object_id] then
            -- Child ink stroke on StickyNote that moved strictly with parent StickyNote keeps raw bytes
            local gp = group_parts[gn.parent_id]
            local body = gp and gp.body
            if body and body._gn then
                local bx0, by0 = Canvas.opBox(body)
                local bdx = bx0 - (body._gn.orig_x or bx0)
                local bdy = by0 - (body._gn.orig_y or by0)
                local test_clone = Canvas.cloneOp(nil, op)
                test_clone.group = op.group
                local pts_shifted = {}
                for k = 1, #op.pts, 2 do
                    pts_shifted[k] = op.pts[k] - bdx
                    pts_shifted[k + 1] = op.pts[k + 1] - bdy
                end
                test_clone.pts = pts_shifted
                if Mapper.opSignature(test_clone) == gn.sig then
                    seen_ids[orig.object_id] = true
                    touched_orig[orig.object_id] = true
                    emitPair(orig.header_bytes, orig.payload_bytes, orig.min_ver)
                else
                    detached_parent[op] = true
                end
            else
                detached_parent[op] = true
            end
        end

        -- Handle newly created OR modified/split ops not already emitted above
        local already_emitted = gn and orig and seen_ids[orig.object_id]
            and (id_counts[orig.object_id] == 1 or gn.part)
            and not detached_parent[op]
        if not already_emitted then
            has_changes = true
            local can_reuse_id = orig and (id_counts[orig.object_id] == 1) and not seen_ids[orig.object_id]
            local obj_id = can_reuse_id and orig.object_id or Wire.uuidV4()
            if can_reuse_id then
                seen_ids[orig.object_id] = true
                touched_orig[orig.object_id] = true
            end
            local rev_cnt = can_reuse_id and ((orig.revision.counter or 0) + 1) or 2
            local rev_tie = Wire.randomU32()

            if op.kind == "ink" and op.pts and #op.pts >= 2 then
                local grp_uid = type(op.group) == "string" and op.group:match("^gn:(.+)$") or nil
                local sticky_body = grp_uid and group_parts[grp_uid] and group_parts[grp_uid].body or nil
                local parent_override
                if sticky_body then
                    local bx0, by0 = Canvas.opBox(sticky_body)
                    parent_override = { id = grp_uid, local_x = -bx0 * scale, local_y = -by0 * scale }
                end
                for _f, fl in ipairs(Symmetry.flips(op.sym)) do
                    local fpts = fl == 0 and op.pts or Symmetry.flipPoints(op.pts, fl, cw, ch)
                    local eid = (fl == 0) and obj_id or Wire.uuidV4()
                    local z_idx = can_reuse_id and fl == 0 and orig.z_order.index or z_cursor
                    if not (can_reuse_id and fl == 0) then z_cursor = z_cursor + 1 end
                    local z_tie = Wire.randomU32()
                    local ptag, mver, pinner, pid = encodeInkStroke(
                        op, eid, rev_cnt, rev_tie, z_idx, z_tie, scale, dark_paper, fpts, parent_override
                    )
                    local h, py = makeNotePair(eid, rev_cnt, rev_tie, mver, ptag, pinner, replica_id, nextLamport(), nil, pid)
                    emitPair(h, py, mver)
                end

            elseif op.kind == "shape" and op.pts and #op.pts >= 4 then
                local z_idx = can_reuse_id and orig.z_order.index or z_cursor
                if not can_reuse_id then z_cursor = z_cursor + 1 end
                local recs = encodeShapeOp(op, obj_id, rev_cnt, rev_tie, z_idx, Wire.randomU32(), scale, dark_paper, replica_id, nextLamport())
                for _r, item in ipairs(recs) do
                    if gn and gn.fill_id and raw_objects[gn.fill_id] then touched_orig[gn.fill_id] = true end
                    emitPair(item.hdr, item.pay, item.ver)
                end

            elseif op.kind == "text" then
                local z_idx = can_reuse_id and orig.z_order.index or z_cursor
                if not can_reuse_id then z_cursor = z_cursor + 1 end
                local rec = encodeTextBox(op, obj_id, rev_cnt, rev_tie, z_idx, Wire.randomU32(), scale, dark_paper, replica_id, nextLamport())
                emitPair(rec.hdr, rec.pay, rec.ver)

            elseif op.kind == "image" then
                local z_idx = can_reuse_id and orig.z_order.index or z_cursor
                if not can_reuse_id then z_cursor = z_cursor + 1 end
                local z_tie = Wire.randomU32()
                if gn and gn.att_id and orig and gn.part == nil then
                    -- Moved/resized existing Goodnotes image or math graph: keep original attachment!
                    local rec = encodeImageRecord(
                        gn.att_id, nil, obj_id,
                        op.x * scale, op.y * scale, op.w * scale, op.h * scale,
                        rev_cnt, rev_tie, z_idx, z_tie, replica_id, nextLamport(), gn
                    )
                    emitPair(rec.hdr, rec.pay, rec.ver)
                else
                    local att_id = op.path and reused_blobs[op.path] or nil
                    local blob
                    if not att_id then
                        blob = readFileBytes(op.path)
                        if blob and #blob > 0 then
                            att_id = Wire.uuidV4()
                            reused_blobs[op.path] = att_id
                            new_attachments[#new_attachments + 1] = { att_id = att_id, blob = blob, is_pdf = false }
                        end
                    end
                    if att_id then
                        local rec = encodeImageRecord(
                            att_id, blob, obj_id,
                            op.x * scale, op.y * scale, op.w * scale, op.h * scale,
                            rev_cnt, rev_tie, z_idx, z_tie, replica_id, nextLamport(), nil
                        )
                        emitPair(rec.hdr, rec.pay, rec.ver)
                    end
                end

            elseif op.kind == "fill" and op.runs and #op.runs >= 3 then
                local png, fx, fy, fw, fh = PdfGen.encodeFillPNG(op, cw, ch, dark_paper)
                if png then
                    local z_idx = z_cursor
                    z_cursor = z_cursor + 1
                    local att_id = Wire.uuidV4()
                    new_attachments[#new_attachments + 1] = { att_id = att_id, blob = png, is_pdf = false }
                    local rec = encodeImageRecord(
                        att_id, png, Wire.uuidV4(),
                        fx * scale, fy * scale, fw * scale, fh * scale,
                        2, Wire.randomU32(), z_idx, Wire.randomU32(), replica_id, nextLamport(), nil
                    )
                    emitPair(rec.hdr, rec.pay, rec.ver)
                end
            end
        end
    end

    -- Emit CRDT tombstones for any previously active Goodnotes objects that were erased/deleted
    for id, orig in pairs(raw_objects) do
        if not touched_orig[id] then
            has_changes = true
            local th, tp = makeTombstonePair(orig, replica_id, nextLamport())
            emitPair(th, tp, orig.min_ver)
        end
    end

    -- Preserve all prior tombstones and unknown-tag passthrough objects verbatim
    for _i, t in ipairs(page_meta and page_meta.tombstones or {}) do
        emitPair(t.header_bytes, t.payload_bytes, t.min_ver)
    end
    for _i, p in ipairs(page_meta and page_meta.passthrough or {}) do
        emitPair(p.header_bytes, p.payload_bytes, p.min_ver)
    end

    return {
        bytes = #emitted_msgs > 0 and Wire.encodeDelimited(emitted_msgs) or "",
        max_ver = max_ver,
        max_lamport = lamport,
        new_attachments = new_attachments,
        changed = has_changes,
    }
end

return Mapper
