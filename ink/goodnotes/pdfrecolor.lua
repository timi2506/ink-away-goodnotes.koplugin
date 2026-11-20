--[[
Pure-Lua vector PDF inspector and 2-color paper theme recolorer for
Goodnotes template PDFs (`dark` / `white` / `yellow`).

Targets classic-xref `/FlateDecode` single-page vector template PDFs (such as
Goodnotes built-in papers), leaving multi-color illustrations/planners and
cross-reference-stream PDFs untouched (`recolorable = false`).
]]

local Zip = require("ink/goodnotes/zip")

local PdfRecolor = {}

local floor, format, sub, concat = math.floor, string.format, string.sub, table.concat

-- Standard Goodnotes paper palettes verified against Test.goodnotes & Template.goodnotes
PdfRecolor.THEMES = {
    dark = {
        id = "dark",
        paper_theme = 2,
        paper_rgb = { 0x33, 0x33, 0x33 },
        bg = { 0.2, 0.2, 0.2 },
        fg = { 0.34509805, 0.34901962, 0.35686275 },
        gn_suffix = "Black",
    },
    white = {
        id = "white",
        paper_theme = 1,
        paper_rgb = nil,
        bg = { 1, 1, 1 },
        fg = { 0.8156863, 0.8235294, 0.827451 },
        gn_suffix = "White",
    },
    yellow = {
        id = "yellow",
        paper_theme = 1,
        paper_rgb = { 0xFA, 0xF3, 0xD7 },
        bg = { 0.9803922, 0.9529412, 0.8431373 },
        fg = { 0.8392157, 0.8078431, 0.6627451 },
        gn_suffix = "Yellow",
    },
}

local function rgbKey(r, g, b)
    local function q(v)
        local n = floor((tonumber(v) or 0) * 255 + 0.5)
        if n < 0 then n = 0 elseif n > 255 then n = 255 end
        return n
    end
    return format("%d,%d,%d", q(r), q(g), q(b)), { q(r), q(g), q(b) }
end

local function fmtTriple(rgb)
    local function f(x)
        if x == 0 then return "0" end
        if x == 1 then return "1" end
        return format("%.8g", x)
    end
    return f(rgb[1]) .. " " .. f(rgb[2]) .. " " .. f(rgb[3])
end

local function classifyBgTheme(rgb255)
    if not rgb255 then return "white" end
    local lum = 0.299 * rgb255[1] + 0.587 * rgb255[2] + 0.114 * rgb255[3]
    if lum < 110 then return "dark" end
    if rgb255[1] >= 235 and rgb255[2] >= 225 and rgb255[3] <= 230 then return "yellow" end
    return "white"
end

-- Locate balanced `<< ... >>` dictionary starting at `pos` inside `pdf_bytes`.
-- Returns dict_start, dict_end (inclusive), respecting nested `<< ... >>`.
local function findBalancedDict(pdf, pos)
    local ds = pdf:find("<<", pos, true)
    if not ds then return nil end
    local depth, p, n = 0, ds, #pdf
    while p <= n do
        local open_i = pdf:find("<<", p, true)
        local close_i = pdf:find(">>", p, true)
        if not close_i then return nil end
        if open_i and open_i < close_i then
            depth = depth + 1
            p = open_i + 2
        else
            depth = depth - 1
            if depth == 0 then return ds, close_i + 1 end
            p = close_i + 2
        end
    end
    return nil
end

-- Parse numbered classic-xref PDF objects into a list of records plus trailer section.
local function parsePdfObjects(pdf)
    if type(pdf) ~= "string" or sub(pdf, 1, 5) ~= "%PDF-" then
        return nil, "not a PDF"
    end
    if pdf:find("/XRef", 1, true) or pdf:find("/ObjStm", 1, true) then
        return nil, "xref/object streams not supported"
    end
    local xref_pos = pdf:find("\nxref", 1, true) or pdf:find("\rxref", 1, true)
    if not xref_pos then return nil, "classic xref table not found" end
    xref_pos = xref_pos + 1

    local objs = {}
    local pos = 1
    while pos < xref_pos do
        local s, e, num_s, gen_s = pdf:find("(%d+)%s+(%d+)%s+obj", pos)
        if not s or s >= xref_pos then break end
        local ds, de = findBalancedDict(pdf, e + 1)
        if not ds or de >= xref_pos then return nil, "malformed object dictionary" end
        local dict_str = sub(pdf, ds, de)

        -- Look for either `stream` right after `>>` or `endobj`
        local after_ws = pdf:match("^%s*()", de + 1)
        if sub(pdf, after_ws, after_ws + 5) == "stream" then
            local hdr_end = after_ws + 6
            if sub(pdf, hdr_end, hdr_end + 1) == "\r\n" then
                hdr_end = hdr_end + 2
            elseif sub(pdf, hdr_end, hdr_end) == "\n" or sub(pdf, hdr_end, hdr_end) == "\r" then
                hdr_end = hdr_end + 1
            else
                return nil, "malformed stream header"
            end
            local slen = tonumber(dict_str:match("/Length%s+(%d+)%f[%s/>]"))
            if not slen then return nil, "indirect or missing stream /Length" end
            local stream_data = sub(pdf, hdr_end, hdr_end + slen - 1)
            local end_search = hdr_end + slen
            local es, ee = pdf:find("endstream%s*endobj", end_search)
            if not es or (es - end_search) > 4 then
                return nil, "stream end mismatch"
            end
            objs[#objs + 1] = {
                start_off = s,
                end_off = ee,
                num = tonumber(num_s),
                gen = tonumber(gen_s),
                dict_start = ds - s + 1,
                dict_end = de - s + 1,
                dict_str = dict_str,
                is_stream = true,
                stream_raw = stream_data,
                raw = sub(pdf, s, ee),
            }
            pos = ee + 1
        else
            local es, ee = pdf:find("endobj", de + 1, true)
            if not es or es >= xref_pos then return nil, "missing endobj" end
            objs[#objs + 1] = {
                start_off = s,
                end_off = ee,
                num = tonumber(num_s),
                gen = tonumber(gen_s),
                dict_start = ds - s + 1,
                dict_end = de - s + 1,
                dict_str = dict_str,
                is_stream = false,
                raw = sub(pdf, s, ee),
            }
            pos = ee + 1
        end
    end

    local tr_start = pdf:find("trailer", xref_pos, true)
    if not tr_start then return nil, "missing trailer" end
    local tds, tde = findBalancedDict(pdf, tr_start + 7)
    if not tds then return nil, "missing trailer dictionary" end

    return {
        prefix = sub(pdf, 1, objs[1] and (objs[1].start_off - 1) or (xref_pos - 1)),
        objs = objs,
        trailer_dict = sub(pdf, tds, tde),
    }
end

local function isContentStreamObj(obj, dec)
    if not dec or #dec == 0 then return false end
    if obj.dict_str:find("/N%s+%d+") or obj.dict_str:find("/Subtype%s*/Image") then return false end
    return dec:find("%d%s+scn") ~= nil or dec:find("%d%s+SCN") ~= nil
        or dec:find("%d%s+rg") ~= nil or dec:find("%d%s+RG") ~= nil
end

local function scanContentColors(dec)
    local keys = {}
    local seen = {}
    for r, g, b, op in dec:gmatch("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)%s+(scn)%f[^%a]") do
        local _ = op
        local k, rgb255 = rgbKey(r, g, b)
        if not seen[k] then seen[k] = rgb255; keys[#keys + 1] = k end
    end
    for r, g, b in dec:gmatch("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)%s+SCN%f[^%a]") do
        local k, rgb255 = rgbKey(r, g, b)
        if not seen[k] then seen[k] = rgb255; keys[#keys + 1] = k end
    end
    for r, g, b in dec:gmatch("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)%s+rg%f[^%a]") do
        local k, rgb255 = rgbKey(r, g, b)
        if not seen[k] then seen[k] = rgb255; keys[#keys + 1] = k end
    end
    for r, g, b in dec:gmatch("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)%s+RG%f[^%a]") do
        local k, rgb255 = rgbKey(r, g, b)
        if not seen[k] then seen[k] = rgb255; keys[#keys + 1] = k end
    end
    return keys, seen
end

--- Inspect a template PDF's structure, color count, and base ruling geometry.
function PdfRecolor.inspect(pdf_bytes)
    local parsed, err = parsePdfObjects(pdf_bytes)
    if not parsed then
        return { recolorable = false, reason = err, colors = {} }
    end

    local all_keys, key_rgb = {}, {}
    local content_streams = 0
    local curves, horiz_lines, vert_lines = 0, 0, 0

    for _i, obj in ipairs(parsed.objs) do
        if obj.is_stream and obj.dict_str:find("/FlateDecode", 1, true) then
            local dec = Zip.zlibDecompress(obj.stream_raw)
            if isContentStreamObj(obj, dec) then
                content_streams = content_streams + 1
                local ks, map = scanContentColors(dec)
                for _j, k in ipairs(ks) do
                    if not key_rgb[k] then
                        key_rgb[k] = map[k]
                        all_keys[#all_keys + 1] = k
                    end
                end
                for _c in dec:gmatch("%s+c%f[%s]") do curves = curves + 1 end
                local first_rect = true
                for x0, y0, x1, y1, x2, y2 in dec:gmatch(
                    "([%d%.]+)%s+([%d%.]+)%s+m%s+([%d%.]+)%s+([%d%.]+)%s+l%s+([%d%.]+)%s+([%d%.]+)%s+l%s+[%d%.]+%s+[%d%.]+%s+l%s+h%s+f"
                ) do
                    if first_rect then
                        first_rect = false
                    else
                        local w = math.abs((tonumber(x2) or 0) - (tonumber(x0) or 0))
                        local h = math.abs((tonumber(y2) or 0) - (tonumber(y0) or 0))
                        local _, _, _ = y0, x1, y1
                        if h < 2 and w > 10 then
                            horiz_lines = horiz_lines + 1
                        elseif w < 2 and h > 10 then
                            vert_lines = vert_lines + 1
                        end
                    end
                end
            end
        end
    end

    local ncolors = #all_keys
    local bg_key = all_keys[1]
    local fg_key = all_keys[2]
    local recolorable = (content_streams > 0 and ncolors >= 1 and ncolors <= 2)
    return {
        recolorable = recolorable,
        content_streams = content_streams,
        colors = all_keys,
        bg_key = bg_key,
        fg_key = fg_key,
        bg_rgb = bg_key and key_rgb[bg_key] or nil,
        fg_rgb = fg_key and key_rgb[fg_key] or nil,
        orig_theme = classifyBgTheme(bg_key and key_rgb[bg_key]),
        curves = curves,
        horiz_lines = horiz_lines,
        vert_lines = vert_lines,
    }
end

--- Infer a human-friendly template name when Goodnotes' `CreatePageTemplate.name` is an internal asset ID.
function PdfRecolor.guessName(insp, gn_name, line_spacing)
    if type(gn_name) == "string" and gn_name ~= "" then
        local trimmed = gn_name:match("^(.-)%s*%-%s*Black$")
            or gn_name:match("^(.-)%s*%-%s*White$")
            or gn_name:match("^(.-)%s*%-%s*Yellow$")
            or gn_name
        -- Skip UUID/internal builtin identifiers (`<UUID>_standard_1_3`)
        if not trimmed:match("^[%x%-]+_standard_") and not trimmed:match("^[%x%-]+$") then
            return trimmed
        end
    end
    if not insp then return "Template" end
    if insp.curves >= 100 then return "Dotted" end
    if insp.vert_lines >= 5 and insp.horiz_lines >= 5 then return "Grid" end
    if insp.horiz_lines == 0 and insp.vert_lines == 0 and insp.curves < 10 then return "Blank" end
    if insp.horiz_lines > 0 and insp.vert_lines == 0 then
        if not line_spacing then return "Music" end
        if line_spacing >= 40 then return "Ruled Wide" end
        return "Ruled Narrow"
    end
    return "Template"
end

--- Replace paper background + foreground ruling colors inside a 2-color vector Goodnotes template PDF
--- and rebuild exact classic `xref` offsets.
function PdfRecolor.recolor(pdf_bytes, target_theme_id)
    local theme = PdfRecolor.THEMES[target_theme_id]
    if not theme then return pdf_bytes, false end
    local parsed = parsePdfObjects(pdf_bytes)
    if not parsed then return pdf_bytes, false end
    local insp = PdfRecolor.inspect(pdf_bytes)
    if not insp.recolorable then return pdf_bytes, false end
    if insp.orig_theme == target_theme_id then return pdf_bytes, true end

    local bg_repl = fmtTriple(theme.bg)
    local fg_repl = fmtTriple(theme.fg)
    local bg_key = insp.bg_key
    local fg_key = insp.fg_key

    local changed_any = false
    local rebuilt = {}
    for _i, obj in ipairs(parsed.objs) do
        local obj_bytes = obj.raw
        if obj.is_stream and obj.dict_str:find("/FlateDecode", 1, true) then
            local dec = Zip.zlibDecompress(obj.stream_raw)
            if isContentStreamObj(obj, dec) then
                local out_dec = dec:gsub("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)(%s+[sSrR][cCgG][nN]?)%f[^%a]", function(r, g, b, op)
                    if op ~= " scn" and op ~= " SCN" and op ~= " rg" and op ~= " RG"
                            and not op:match("^%s+[sSrR][cCgG][nN]?$") then
                        return r .. " " .. g .. " " .. b .. op
                    end
                    local k = rgbKey(r, g, b)
                    if k == bg_key then
                        changed_any = true
                        return bg_repl .. op
                    elseif fg_key and k == fg_key then
                        changed_any = true
                        return fg_repl .. op
                    end
                    return r .. " " .. g .. " " .. b .. op
                end)
                if out_dec ~= dec then
                    local comp = Zip.zlibCompress(out_dec)
                    local new_dict = obj.dict_str:gsub("(/Length%s+)%d+(%f[%s/>])", "%1" .. tostring(#comp) .. "%2", 1)
                    local hdr_part = sub(obj.raw, 1, obj.dict_start - 1)
                    obj_bytes = hdr_part .. new_dict .. "\nstream\n" .. comp .. "\nendstream\nendobj"
                end
            end
        end
        rebuilt[#rebuilt + 1] = {
            num = obj.num,
            gen = obj.gen,
            bytes = obj_bytes,
        }
    end

    if not changed_any then return pdf_bytes, false end

    local parts = { parsed.prefix }
    local pos = #parsed.prefix
    if sub(parts[1], -1) ~= "\n" then
        parts[#parts + 1] = "\n"
        pos = pos + 1
    end

    local offsets = {}
    local max_num = 0
    for _i, item in ipairs(rebuilt) do
        offsets[item.num] = { off = pos, gen = item.gen }
        if item.num > max_num then max_num = item.num end
        local blk = item.bytes .. "\n\n"
        parts[#parts + 1] = blk
        pos = pos + #blk
    end

    local xref_off = pos
    local xref_rows = {
        format("xref\n0 %d\n", max_num + 1),
        "0000000000 65535 f \n",
    }
    for num = 1, max_num do
        local info = offsets[num]
        if info then
            xref_rows[#xref_rows + 1] = format("%010d %05d n \n", info.off, info.gen)
        else
            xref_rows[#xref_rows + 1] = "0000000000 65535 f \n"
        end
    end
    local tr_dict = parsed.trailer_dict:gsub("(/Size%s+)%d+(%f[%s/>])", "%1" .. tostring(max_num + 1) .. "%2", 1)
    parts[#parts + 1] = concat(xref_rows)
    parts[#parts + 1] = "trailer\n" .. tr_dict .. "\nstartxref\n" .. tostring(xref_off) .. "\n%%EOF\n"
    return concat(parts), true
end

return PdfRecolor
