--[[
Goodnotes RichTextContainer / RichTextDocument <-> Ink Away `text` op codec.
Handles `f20.31` (StickyNoteItem) and `f21.32` (TextOrShapeItem) rich text
including Apple `bv41` LZ4 payloads and `-404` / `-60` / `-1` signed varints.
]]

local Wire = require("ink/goodnotes/wire")
local LZ4 = require("ink/goodnotes/lz4")
local Zip = require("ink/goodnotes/zip")

local RichText = {}

local floor, concat, sub = math.floor, table.concat, string.sub

local function clamp255(v)
    local n = floor((v or 0) * 255 + 0.5)
    if n < 0 then return 0 elseif n > 255 then return 255 end
    return n
end

local function packColor(c)
    if not c then return nil end
    return clamp255(c.r) * 65536 + clamp255(c.g) * 256 + clamp255(c.b)
end

local function unpackColor01(packed)
    if not packed then return 0.0, 0.0, 0.0 end
    if type(packed) == "table" then
        return (packed[1] or packed.r or 0) / 255.0,
            (packed[2] or packed.g or 0) / 255.0,
            (packed[3] or packed.b or 0) / 255.0
    end
    local r = floor(packed / 65536) % 256
    local g = floor(packed / 256) % 256
    local b = packed % 256
    return r / 255.0, g / 255.0, b / 255.0
end

local function contentHash8(rt_doc_bytes)
    local ok, Hash = pcall(require, "ink/sync/hash")
    if ok and Hash and Hash.sha256bin then
        local hok, bin = pcall(Hash.sha256bin, rt_doc_bytes)
        if hok and type(bin) == "string" and #bin >= 8 then
            return sub(bin, 1, 8)
        end
    end
    -- Deterministic 8-byte fallback when `ffi/sha2` is absent (headless core tests)
    local c1 = Zip.crc32(rt_doc_bytes, 0)
    local c2 = Zip.crc32(rt_doc_bytes, 0x9E3779B9)
    return Wire.encU32LE(c1) .. Wire.encU32LE(c2)
end

------------------------------------------------------------------------------
-- Decode RichTextContainer -> structured info + Ink Away `paras`
------------------------------------------------------------------------------

function RichText.decode(container_bytes)
    if not container_bytes or container_bytes == "" then return nil end
    local d = Wire.byField(Wire.parseMessage(container_bytes))

    local font_family = "Helvetica Neue"
    local def_size = 24.0
    local def_color = { r = 0.0, g = 0.0, b = 0.0, a = 1.0 }
    if d[5] then
        local sd = Wire.byField(Wire.parseMessage(d[5][1].val))
        if sd[1] then
            local cs = Wire.byField(Wire.parseMessage(sd[1][1].val))
            if cs[3] then def_color = Wire.decColor(cs[3][1].val) end
            if cs[30] then font_family = cs[30][1].val end
            if cs[40] then def_size = Wire.getF32(cs, 40, 24.0) end
        end
    end

    local measured = d[2] and Wire.decSize(d[2][1].val) or { w = 160.0, h = 40.0 }
    local insets = { top = 0.0, left = 0.0, bottom = 0.0, right = 0.0 }
    if d[10] then
        local ind = Wire.byField(Wire.parseMessage(d[10][1].val))
        insets.top = Wire.getF32(ind, 1, 0.0)
        insets.left = Wire.getF32(ind, 2, 0.0)
        insets.bottom = Wire.getF32(ind, 3, 0.0)
        insets.right = Wire.getF32(ind, 4, 0.0)
    end

    local runs = {}
    local plain_parts = {}
    if d[1] then
        local c = Wire.byField(Wire.parseMessage(d[1][1].val))
        local comp = Wire.getBytes(c, 2)
        if comp and comp ~= "" then
            local dec = LZ4.decompress(comp)
            if dec then
                local rt_fields = Wire.parseMessage(dec)
                for _i, entry in ipairs(rt_fields) do
                    if entry.field == 1 then
                        local rd = Wire.byField(Wire.parseMessage(entry.val))
                        local txt = Wire.getStr(rd, 1, "")
                        plain_parts[#plain_parts + 1] = txt
                        local r = { text = txt }
                        if rd[2] then
                            local cs = Wire.byField(Wire.parseMessage(rd[2][1].val))
                            local fsz = cs[40] and Wire.getF32(cs, 40, -404.0) or -404.0
                            r.char_style = {
                                text_color = cs[3] and Wire.decColor(cs[3][1].val) or nil,
                                hyperlink_url = Wire.getStr(cs, 4),
                                highlight_color = cs[5] and Wire.decColor(cs[5][1].val) or nil,
                                font_size = (fsz > 0) and fsz or nil,
                            }
                        end
                        if rd[3] then
                            local ps = Wire.byField(Wire.parseMessage(rd[3][1].val))
                            r.alignment = ps[4] and Wire.getUInt(ps, 4, 0) or 0
                        end
                        runs[#runs + 1] = r
                    end
                end
            end
        end
    end

    return {
        font_family = font_family,
        font_size = def_size,
        default_color = def_color,
        measured_size = measured,
        insets = insets,
        runs = runs,
        plain_text = concat(plain_parts),
    }
end

local ALIGN_FROM_GN = { [0] = "left", [1] = "right", [2] = "center", [3] = "left" }
local ALIGN_TO_GN = { left = 0, right = 1, center = 2 }

--- Convert decoded RichTextContainer table into Ink Away `paras`, `align`, `size`, `links`.
function RichText.toInkParas(rt, fallback_size)
    if not rt then return { { spans = { { t = "" } } } }, "left", fallback_size or 24 end
    local paras = { { spans = {} } }
    local first_align = "left"
    local got_align = false
    local def_sz = (rt.font_size and rt.font_size > 0) and rt.font_size or (fallback_size or 24)

    for _i, run in ipairs(rt.runs or {}) do
        if not got_align and run.alignment then
            first_align = ALIGN_FROM_GN[run.alignment] or "left"
            got_align = true
        end
        local cs = run.char_style or {}
        local base_style = {}
        local tc = cs.text_color
        if tc and (tc.a == nil or tc.a > 0.05) then
            local packed = packColor(tc)
            if packed ~= 0 then base_style.c = packed end
        elseif rt.default_color and (rt.default_color.a == nil or rt.default_color.a > 0.05) then
            local packed = packColor(rt.default_color)
            if packed ~= 0 then base_style.c = packed end
        end
        if cs.highlight_color and (cs.highlight_color.a == nil or cs.highlight_color.a > 0.05) then
            base_style.hl = packColor(cs.highlight_color)
        end
        if cs.hyperlink_url and cs.hyperlink_url ~= "" then
            base_style.u = true
        end
        if cs.font_size and cs.font_size > 0 and math.abs(cs.font_size - def_sz) > 0.5 then
            base_style.sz = cs.font_size / def_sz
        end

        local txt = run.text or ""
        local start = 1
        while true do
            local nl = txt:find("\n", start, true)
            local piece = nl and sub(txt, start, nl - 1) or sub(txt, start)
            if piece ~= "" then
                local span = { t = piece }
                for k, v in pairs(base_style) do span[k] = v end
                local cur_spans = paras[#paras].spans
                cur_spans[#cur_spans + 1] = span
            end
            if not nl then break end
            paras[#paras + 1] = { spans = {} }
            start = nl + 1
        end
    end

    for _i, p in ipairs(paras) do
        if #p.spans == 0 then p.spans[1] = { t = "" } end
    end
    return paras, first_align, def_sz
end

------------------------------------------------------------------------------
-- Encode Ink Away `text` op / parameters -> RichTextContainer protobuf
------------------------------------------------------------------------------

local function defaultParaInner1()
    return Wire.encodeMessage({ Wire.fBytes(1, "", true) })
end

local function defaultParaInner2(include_val)
    if not include_val then return "" end
    return Wire.encodeMessage({ Wire.fSigned64(1, -1) })
end

local function defaultParaInner3()
    return Wire.encodeMessage({ Wire.fSigned64(1, -1), Wire.fSigned64(2, -1) })
end

local function encodeCharStyle(r, g, b, a, hl_c, fsize, hyperlink)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fBytes(3, Wire.encColor(r, g, b, a or 1.0), true),
        Wire.fBytes(4, hyperlink),
        hl_c and Wire.fBytes(5, Wire.encColor(hl_c[1], hl_c[2], hl_c[3], 0.45), true) or nil,
        Wire.fF32(40, fsize or -404.0, true),
        Wire.fSigned64(60, -404, true),
        Wire.fF32(70, -404.0, true)
    ))
end

local function encodeParaStyle(align_num)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fBytes(1, defaultParaInner1(), true),
        Wire.fBytes(2, defaultParaInner2(true), true),
        Wire.fBytes(3, defaultParaInner3(), true),
        Wire.fVarint(4, align_num or 0)
    ))
end

local function spanPrefix(para, idx)
    if not para.bullet then return "" end
    if para.bullet == "disc" then return "\u{2022} " end
    if para.bullet == "number" then return tostring(idx) .. ". " end
    if para.bullet == "check" then return para.checked and "[x] " or "[ ] " end
    return ""
end

--- Encode Ink Away `text` op (or plain string spec) into `RichTextContainer` protobuf bytes.
function RichText.encode(op, opts)
    opts = opts or {}
    local scale = opts.scale or 1.0
    local dark_paper = opts.dark_paper and true or false
    local base_sz = ((op and op.size) or opts.font_size or 24) * scale
    local align_num = ALIGN_TO_GN[(op and op.align) or "left"] or 0

    local def_r, def_g, def_b = 0.0, 0.0, 0.0
    if opts.default_color then
        def_r, def_g, def_b = opts.default_color[1], opts.default_color[2], opts.default_color[3]
    elseif dark_paper then
        def_r, def_g, def_b = 1.0, 1.0, 1.0
    end

    local run_msgs = {}
    local paras = (op and op.paras) or { { spans = { { t = opts.text or "" } } } }
    local num_idx = 0
    for pi, para in ipairs(paras) do
        if para.bullet == "number" then num_idx = num_idx + 1 else num_idx = 0 end
        local spans = para.spans or {}
        if #spans == 0 then spans = { { t = "" } } end
        for si, sp in ipairs(spans) do
            local txt = sp.t or ""
            if si == 1 then txt = spanPrefix(para, num_idx) .. txt end
            if si == #spans and pi < #paras then txt = txt .. "\n" end
            local r, g, b = def_r, def_g, def_b
            if sp.c then r, g, b = unpackColor01(sp.c) end
            local hl_c
            if sp.hl == true then
                hl_c = { 1.0, 0.92, 0.23 }
            elseif type(sp.hl) == "number" then
                local hr, hg, hb = unpackColor01(sp.hl)
                hl_c = { hr, hg, hb }
            end
            local span_sz = -404.0
            if sp.sz and sp.sz ~= 1 then span_sz = base_sz * sp.sz end
            local run_msg = Wire.encodeMessage(Wire.packFields(
                Wire.fBytes(1, txt),
                Wire.fBytes(2, encodeCharStyle(r, g, b, 1.0, hl_c, span_sz, nil), true),
                Wire.fBytes(3, encodeParaStyle(align_num), true)
            ))
            run_msgs[#run_msgs + 1] = { 1, 2, run_msg }
        end
    end

    local rt_doc = Wire.encodeMessage(run_msgs)
    local comp = LZ4.compress(rt_doc)
    local content_msg = Wire.encodeMessage({
        { 2, 2, comp },
        { 3, 2, contentHash8(rt_doc) },
        { 4, 0, 1 },
    })

    local default_cs = Wire.encodeMessage({
        { 3, 2, Wire.encColor(def_r, def_g, def_b, 1.0) },
        { 30, 2, opts.font_family or "Helvetica Neue" },
        { 40, 5, base_sz },
        Wire.fSigned64(60, -60, true),
        Wire.fF32(70, -20.0, true),
    })
    local default_ps = Wire.encodeMessage({
        { 1, 2, defaultParaInner1() },
        { 2, 2, "" },
        { 3, 2, defaultParaInner3() },
    })
    local default_style = Wire.encodeMessage({
        { 1, 2, default_cs },
        { 2, 2, default_ps },
    })

    local mw = (op and op.w and (op.w * scale)) or opts.measured_w or 160.0
    local mh = (op and op.h and (op.h * scale)) or opts.measured_h or (base_sz * 1.4)
    local fields = {
        { 1, 2, content_msg },
        { 2, 2, Wire.encSize(mw, mh) },
        { 5, 2, default_style },
    }
    if opts.insets then
        local ins = Wire.encodeMessage(Wire.packFields(
            Wire.fF32(1, opts.insets[1] or 10.0),
            Wire.fF32(2, opts.insets[2] or 10.0),
            Wire.fF32(3, opts.insets[3] or 10.0),
            Wire.fF32(4, opts.insets[4] or 10.0)
        ))
        fields[#fields + 1] = { 10, 2, ins }
        fields[#fields + 1] = { 11, 2, "" }
    end
    return Wire.encodeMessage(fields)
end

return RichText
