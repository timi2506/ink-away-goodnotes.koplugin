--[[
Compact vector PDF page generator for Goodnotes backing templates, plus a tiny
pure-Lua RGBA PNG encoder for rasterizing Ink Away flood-fill (`kind = "fill"`)
ops into transparent Goodnotes `ImageItem`s.

Plain Lua + `bit`, requiring no MuPDF or Blitbuffer C libraries.
]]

local bit = require("bit")
local ffi = require("ffi")
local Template = require("ink/template")
local Zip = require("ink/goodnotes/zip")

local PdfGen = {}

local floor, min, max, format, concat = math.floor, math.min, math.max, string.format, table.concat
local char, byte = string.char, string.byte
local band, rshift = bit.band, bit.rshift

local function u32BE(v)
    return char(
        band(rshift(v, 24), 0xFF),
        band(rshift(v, 16), 0xFF),
        band(rshift(v, 8), 0xFF),
        band(v, 0xFF)
    )
end

local function adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + byte(s, i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

------------------------------------------------------------------------------
-- Paper & ruling colour helpers (matching ink/paint.lua)
------------------------------------------------------------------------------

local function isDarkPaper(rgb)
    if type(rgb) ~= "table" then return false end
    return (0.299 * rgb[1] + 0.587 * rgb[2] + 0.114 * rgb[3]) < 110
end

local function strengthToLevel(s)
    local lvl = floor(255 - (s or 45) / 100 * 255 + 0.5)
    if lvl < 0 then return 0 elseif lvl > 255 then return 255 end
    return lvl
end

local function rulingRGB(paper, strength)
    local lvl = strengthToLevel(strength)
    local p = paper or { 255, 255, 255 }
    if isDarkPaper(p) then
        local k = (255 - lvl) / 255
        return {
            floor(p[1] + (255 - p[1]) * k + 0.5),
            floor(p[2] + (255 - p[2]) * k + 0.5),
            floor(p[3] + (255 - p[3]) * k + 0.5),
        }
    end
    local k = lvl / 255
    return { floor(p[1] * k + 0.5), floor(p[2] * k + 0.5), floor(p[3] * k + 0.5) }
end

local function pdfNum(v)
    if v == floor(v) then return format("%d", v) end
    return format("%.3f", v)
end

local function rgbCmd(rgb, op)
    return format("%.4f %.4f %.4f %s\n", (rgb[1] or 255) / 255, (rgb[2] or 255) / 255, (rgb[3] or 255) / 255, op)
end

------------------------------------------------------------------------------
-- Vector PDF Template Page Builder
------------------------------------------------------------------------------

--- Build a single-page `%PDF-1.4` containing the paper fill and optional crisp
--- vector ruling from `Template.render`. Dimensions are in PDF points (72 DPI).
function PdfGen.buildTemplatePDF(w_pt, h_pt, style, spacing_pt, strength, paper)
    local cmds = {}
    local bg = (type(paper) == "table") and paper or { 255, 255, 255 }
    cmds[#cmds + 1] = rgbCmd(bg, "rg")
    cmds[#cmds + 1] = format("0 0 %s %s re f\n", pdfNum(w_pt), pdfNum(h_pt))

    if style and style ~= "blank" and (spacing_pt or 0) > 0 then
        local rule_rgb = rulingRGB(paper, strength)
        cmds[#cmds + 1] = rgbCmd(rule_rgb, "rg")

        -- Work in crisp ~1 px-per-point or scaled coordinate space so Template.render
        -- outputs exact geometry without huge PDF streams; map via `pt_scale`.
        local px_scale = 1.5
        local tw = max(1, floor(w_pt * px_scale + 0.5))
        local th = max(1, floor(h_pt * px_scale + 0.5))
        local tsize = max(4, floor(spacing_pt * px_scale + 0.5))
        local kx = w_pt / tw
        local ky = h_pt / th

        -- Coalesce consecutive rows of identical `[x, len]` runs into single PDF rectangles!
        local open = {}   -- key -> { x, len, y0, y1 }
        local rects = {}
        local last_y = -1
        local row_keys = {}

        local function flushRow()
            for key, r in pairs(open) do
                if not row_keys[key] then
                    rects[#rects + 1] = r
                    open[key] = nil
                end
            end
            row_keys = {}
        end

        Template.render(style, tw, th, tsize, function(x, y, len)
            local rx = floor(x + 0.5)
            local ry = floor(y + 0.5)
            local rlen = floor(len + 0.5)
            if rlen <= 0 or ry < 0 or ry >= th then return end
            if ry ~= last_y then
                if ry == last_y + 1 then
                    flushRow()
                else
                    for k, r in pairs(open) do rects[#rects + 1] = r; open[k] = nil end
                    row_keys = {}
                end
                last_y = ry
            end
            local key = rx .. ":" .. rlen
            row_keys[key] = true
            local cur = open[key]
            if cur then
                cur.y1 = ry + 1
            else
                open[key] = { x = rx, len = rlen, y0 = ry, y1 = ry + 1 }
            end
        end)
        for _k, r in pairs(open) do rects[#rects + 1] = r end

        for _i, r in ipairs(rects) do
            local px = r.x * kx
            local pw = r.len * kx
            local py_top = r.y0 * ky
            local ph = (r.y1 - r.y0) * ky
            local py_bot = h_pt - py_top - ph
            cmds[#cmds + 1] = format("%s %s %s %s re ", pdfNum(px), pdfNum(py_bot), pdfNum(pw), pdfNum(ph))
        end
        if #rects > 0 then cmds[#cmds + 1] = "f\n" end
    end

    local stream = concat(cmds)
    local comp, method = Zip.deflate(stream)
    local dict
    if method == 8 then
        -- Wrap raw deflate as zlib stream (`78 9C` + raw + Adler-32 BE)
        local zstream = "\120\156" .. comp .. u32BE(adler32(stream))
        dict = format("<< /Length %d /Filter /FlateDecode >>", #zstream)
        stream = zstream
    else
        dict = format("<< /Length %d >>", #stream)
    end

    local objs = {
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
        format("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %s %s] /Contents 4 0 R /Resources << >> >>\nendobj\n",
            pdfNum(w_pt), pdfNum(h_pt)),
        format("4 0 obj\n%s\nstream\n%s\nendstream\nendobj\n", dict, stream),
    }

    local parts = { "%PDF-1.4\n" }
    local offsets = {}
    local pos = #parts[1]
    for i, body in ipairs(objs) do
        offsets[i] = pos
        parts[#parts + 1] = body
        pos = pos + #body
    end
    local xref_off = pos
    parts[#parts + 1] = format("xref\n0 %d\n0000000000 65535 f \n", #objs + 1)
    for i = 1, #objs do
        parts[#parts + 1] = format("%010d 00000 n \n", offsets[i])
    end
    parts[#parts + 1] = format("trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", #objs + 1, xref_off)
    return concat(parts)
end

------------------------------------------------------------------------------
-- Pure-Lua RGBA PNG Encoder (for flood-fill / bitmap ImageItems)
------------------------------------------------------------------------------

local function pngChunk(ctype, data)
    local body = ctype .. data
    return u32BE(#data) .. body .. u32BE(Zip.crc32(body))
end

local function zlibCompressRGBA(raw)
    local comp, method = Zip.deflate(raw)
    if method == 8 then
        return "\120\156" .. comp .. u32BE(adler32(raw))
    end
    -- Stored zlib blocks (uncompressed)
    local blocks = { "\120\1" }
    local n = #raw
    local p = 1
    while p <= n do
        local take = min(65535, n - p + 1)
        local last = (p + take - 1 >= n) and 1 or 0
        local nlen = 65535 - take
        blocks[#blocks + 1] = char(
            last,
            band(take, 0xFF), band(rshift(take, 8), 0xFF),
            band(nlen, 0xFF), band(rshift(nlen, 8), 0xFF)
        ) .. raw:sub(p, p + take - 1)
        p = p + take
    end
    blocks[#blocks + 1] = u32BE(adler32(raw))
    return concat(blocks)
end

--- Encode an Ink Away flood-fill op (`op.runs = {x, y, len, ...}`) into a tight-cropped
--- transparent RGBA PNG byte string. Returns `png_bytes, bx, by, bw, bh` or `nil` if empty.
function PdfGen.encodeFillPNG(op, canvas_w, canvas_h, dark_paper)
    local runs = op.runs
    if not runs or #runs < 3 then return nil end

    local minx, miny = math.huge, math.huge
    local maxx, maxy = -math.huge, -math.huge
    for i = 1, #runs, 3 do
        local x, y, len = floor(runs[i]), floor(runs[i + 1]), floor(runs[i + 2])
        if len > 0 and y >= 0 and y < canvas_h then
            local x0 = max(0, x)
            local x1 = min(canvas_w - 1, x + len - 1)
            if x1 >= x0 then
                if x0 < minx then minx = x0 end
                if x1 > maxx then maxx = x1 end
                if y < miny then miny = y end
                if y > maxy then maxy = y end
            end
        end
    end
    if maxx < minx or maxy < miny then return nil end

    local w = maxx - minx + 1
    local h = maxy - miny + 1
    local c = op.color or { 0, 0, 0 }
    local r, g, b = c[1] or 0, c[2] or 0, c[3] or 0
    if dark_paper and r == 0 and g == 0 and b == 0 then r, g, b = 255, 255, 255 end
    local a = op.alpha or 255

    local stride = 1 + w * 4
    local buf = ffi.new("uint8_t[?]", h * stride)   -- zero-initialized (filter 0 + transparent RGBA)
    for i = 1, #runs, 3 do
        local x, y, len = floor(runs[i]), floor(runs[i + 1]), floor(runs[i + 2])
        if y >= miny and y <= maxy and len > 0 then
            local x0 = max(minx, x)
            local x1 = min(maxx, x + len - 1)
            local row_base = (y - miny) * stride + 1
            for xx = x0 - minx, x1 - minx do
                local o = row_base + xx * 4
                buf[o], buf[o + 1], buf[o + 2], buf[o + 3] = r, g, b, a
            end
        end
    end
    local idat = zlibCompressRGBA(ffi.string(buf, h * stride))
    local ihdr = u32BE(w) .. u32BE(h) .. "\8\6\0\0\0"
    local png = "\137PNG\r\n\26\n"
        .. pngChunk("IHDR", ihdr)
        .. pngChunk("IDAT", idat)
        .. pngChunk("IEND", "")
    return png, minx, miny, w, h
end

return PdfGen
