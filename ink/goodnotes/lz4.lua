--[[
Apple `COMPRESSION_LZ4` stream codec (`bv41` / `bv4-` / `bv4$` frame format).
Used by Goodnotes for compressed `tpl\x00` strokes (`StrokeItem.compressed_tpl`)
and `RichTextDocument` payloads (`RichTextContent.compressed_richtext`).

Pure LuaJIT (`ffi`, standard string/table) for byte-accurate parity with
Apple's `libcompression.dylib` (`COMPRESSION_LZ4 = 0x100`).
]]

local bit = require("bit")
local ffi = require("ffi")
local Wire = require("ink/goodnotes/wire")

local LZ4 = {}

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local byte, char, sub, concat = string.byte, string.char, string.sub, table.concat
local decU16LE, decU32LE = Wire.decU16LE, Wire.decU32LE
local encU16LE, encU32LE = Wire.encU16LE, Wire.encU32LE

------------------------------------------------------------------------------
-- Raw LZ4 block decompression & compression
------------------------------------------------------------------------------

local function decompressBlock(src, uncomp_len)
    if uncomp_len == 0 then return "" end
    local dst = ffi.new("uint8_t[?]", uncomp_len)
    local sp, slen = 1, #src
    local dp = 0

    local function readExtLen(init)
        local len = init
        if len == 15 then
            while true do
                if sp > slen then error("LZ4 block truncated in extended length") end
                local b = byte(src, sp)
                sp = sp + 1
                len = len + b
                if b ~= 255 then break end
            end
        end
        return len
    end

    while sp <= slen do
        local tok = byte(src, sp)
        sp = sp + 1
        local lit_len = readExtLen(rshift(tok, 4))
        if lit_len > 0 then
            if sp + lit_len - 1 > slen then error("LZ4 literal overflow") end
            if dp + lit_len > uncomp_len then error("LZ4 output literal overflow") end
            for i = 0, lit_len - 1 do
                dst[dp + i] = byte(src, sp + i)
            end
            sp = sp + lit_len
            dp = dp + lit_len
        end
        if sp > slen then break end

        if sp + 1 > slen then error("LZ4 truncated match offset") end
        local offset = decU16LE(src, sp)
        sp = sp + 2
        if offset == 0 or offset > dp then error("LZ4 invalid match offset " .. offset .. " at dp=" .. dp) end

        local match_len = 4 + readExtLen(band(tok, 0x0F))
        if dp + match_len > uncomp_len then error("LZ4 output match overflow") end
        -- Copy byte-by-byte to support overlapping RLE copies (`offset < match_len`).
        for i = 0, match_len - 1 do
            dst[dp + i] = dst[dp - offset + i]
        end
        dp = dp + match_len
    end

    if dp ~= uncomp_len then
        error(string.format("LZ4 decoded size mismatch (%d != expected %d)", dp, uncomp_len))
    end
    return ffi.string(dst, uncomp_len)
end

local function writeLenExt(parts, rem)
    while rem >= 255 do
        parts[#parts + 1] = "\255"
        rem = rem - 255
    end
    parts[#parts + 1] = char(rem)
end

local function compressBlock(src)
    local n = #src
    if n == 0 then return "" end
    local parts = {}

    if n < 13 then
        local tok = lshift(math.min(n, 15), 4)
        parts[#parts + 1] = char(tok)
        if n >= 15 then writeLenExt(parts, n - 15) end
        parts[#parts + 1] = src
        return concat(parts)
    end

    local htab = {}
    local anchor = 1
    local pos = 1
    local limit = n - 12   -- leaves room for 4B match + >= 5B trailing literals

    while pos <= limit do
        local key = decU32LE(src, pos)
        local ref = htab[key]
        htab[key] = pos
        if not ref or pos - ref > 65535 or ref == pos then
            pos = pos + 1
        else
            local ml = 4
            local end_lim = n - 4   -- strict `<` ensures last 5 bytes `[n-4..n]` remain literals
            while pos + ml < end_lim and byte(src, ref + ml) == byte(src, pos + ml) do
                ml = ml + 1
            end
            local lit_len = pos - anchor
            local ml_code = ml - 4
            local tok = bor(lshift(math.min(lit_len, 15), 4), math.min(ml_code, 15))
            parts[#parts + 1] = char(tok)
            if lit_len >= 15 then writeLenExt(parts, lit_len - 15) end
            if lit_len > 0 then parts[#parts + 1] = sub(src, anchor, pos - 1) end
            parts[#parts + 1] = encU16LE(pos - ref)
            if ml_code >= 15 then writeLenExt(parts, ml_code - 15) end

            pos = pos + ml
            anchor = pos
            if pos <= limit and pos >= 3 then
                htab[decU32LE(src, pos - 2)] = pos - 2
            end
        end
    end

    -- Trailing literals (mandatory >= 5 bytes when matches occurred)
    local rem_lit = n - anchor + 1
    local tok = lshift(math.min(rem_lit, 15), 4)
    parts[#parts + 1] = char(tok)
    if rem_lit >= 15 then writeLenExt(parts, rem_lit - 15) end
    if rem_lit > 0 then parts[#parts + 1] = sub(src, anchor, n) end
    return concat(parts)
end

------------------------------------------------------------------------------
-- Apple `bv41` / `bv4-` / `bv4$` stream framing
------------------------------------------------------------------------------

function LZ4.decompress(data)
    if type(data) ~= "string" then return nil, "expected string" end
    local pos, n = 1, #data
    local chunks = {}
    while pos <= n do
        if pos + 3 > n then return nil, "truncated bv4 frame header at " .. pos end
        local magic = sub(data, pos, pos + 3)
        if magic == "bv4$" then
            break
        elseif magic == "bv4-" then
            if pos + 7 > n then return nil, "truncated bv4- header" end
            local raw_sz = decU32LE(data, pos + 4)
            pos = pos + 8
            if pos + raw_sz - 1 > n then return nil, "truncated bv4- payload" end
            if raw_sz > 0 then chunks[#chunks + 1] = sub(data, pos, pos + raw_sz - 1) end
            pos = pos + raw_sz
        elseif magic == "bv41" then
            if pos + 11 > n then return nil, "truncated bv41 header" end
            local uncomp_sz = decU32LE(data, pos + 4)
            local comp_sz = decU32LE(data, pos + 8)
            pos = pos + 12
            if pos + comp_sz - 1 > n then return nil, "truncated bv41 payload" end
            local comp = comp_sz > 0 and sub(data, pos, pos + comp_sz - 1) or ""
            pos = pos + comp_sz
            local ok, dec = pcall(decompressBlock, comp, uncomp_sz)
            if not ok then return nil, dec end
            chunks[#chunks + 1] = dec
        else
            return nil, "unknown bv4 magic at " .. pos
        end
    end
    return concat(chunks)
end

function LZ4.compress(data, opts)
    opts = opts or {}
    local chunk_size = opts.chunk_size or 65536
    local allow_uncomp = opts.allow_uncompressed and true or false
    local out = {}
    local n = #data
    if n == 0 then
        return "bv41" .. encU32LE(0) .. encU32LE(0) .. "bv4$"
    end
    for off = 1, n, chunk_size do
        local chunk = sub(data, off, math.min(n, off + chunk_size - 1))
        local comp = compressBlock(chunk)
        if allow_uncomp and #comp + 12 >= #chunk + 8 then
            out[#out + 1] = "bv4-"
            out[#out + 1] = encU32LE(#chunk)
            out[#out + 1] = chunk
        else
            out[#out + 1] = "bv41"
            out[#out + 1] = encU32LE(#chunk)
            out[#out + 1] = encU32LE(#comp)
            out[#out + 1] = comp
        end
    end
    out[#out + 1] = "bv4$"
    return concat(out)
end

return LZ4
