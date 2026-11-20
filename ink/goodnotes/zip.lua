--[[
Pure-LuaJIT ZIP reader, writer, and streaming zero-recompression patcher.

Why a dedicated ZIP module:
  * Headless tests run in bare LuaJIT where KOReader's `ffi/archiver` does not exist.
  * Updating a `.goodnotes` archive after editing one page must NOT recompress or
    decompress megabytes of unchanged PDF templates / photos on an e-ink CPU.
    `Zip.patch` streams unchanged entries directly as raw compressed bytes + CRC
    from `src_path` to `dest_path.tmp`, writes only modified/new entries, and
    replaces the target atomically.

DEFLATE / INFLATE backends (selected safely to avoid FFI cdef clashes in KOReader):
  * Compress (DEFLATE): `ffi/zlib` (KOReader C libz) -> FFI `libz` (`deflateInit2_(-15)`) -> STORE fallback.
  * Decompress (INFLATE): FFI `libz` (`inflateInit2_(-15)`) when standalone ->
    KOReader `ffi/archiver` for file reads -> pure-Lua RFC 1951 INFLATE fallback.
]]

local bit = require("bit")
local ffi = require("ffi")
local Wire = require("ink/goodnotes/wire")

local Zip = {}

local band, bor, bxor, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift
local byte, char, sub, concat = string.byte, string.char, string.sub, table.concat
local decU16LE, encU16LE = Wire.decU16LE, Wire.encU16LE
local decU32LE, encU32LE = Wire.decU32LE, Wire.encU32LE

local CHUNK_SIZE = 65536
local METHOD_STORE = 0
local METHOD_DEFLATE = 8

------------------------------------------------------------------------------
-- CRC-32 (ISO 3309 / PKZIP)
------------------------------------------------------------------------------

local CRC_TABLE = {}
for i = 0, 255 do
    local c = i
    for _b = 1, 8 do
        if band(c, 1) ~= 0 then
            c = bxor(rshift(c, 1), 0xEDB88320)
        else
            c = rshift(c, 1)
        end
    end
    CRC_TABLE[i] = c
end

function Zip.crc32(data, init)
    local crc = bxor(init or 0, 0xFFFFFFFF)
    for i = 1, #data do
        local b = byte(data, i)
        crc = bxor(rshift(crc, 8), CRC_TABLE[band(bxor(crc, b), 0xFF)])
    end
    -- Normalize to unsigned 32-bit Lua number
    crc = bxor(crc, 0xFFFFFFFF)
    if crc < 0 then crc = crc + 4294967296 end
    return crc
end

--- Compute RFC 1950 Adler-32 checksum of `data`.
function Zip.adler32(data)
    local a, b = 1, 0
    for i = 1, #data do
        a = (a + byte(data, i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

------------------------------------------------------------------------------
-- Pure-Lua RFC 1951 INFLATE (universal fallback for raw DEFLATE)
------------------------------------------------------------------------------

local LEN_BASE = {
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
}
local LEN_EXTRA = {
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
}
local DIST_BASE = {
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
}
local DIST_EXTRA = {
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local function buildHuffTree(lengths, max_sym)
    local counts = {}
    for i = 0, 15 do counts[i] = 0 end
    local max_len = 0
    for s = 0, max_sym do
        local l = lengths[s] or 0
        if l > 0 then
            counts[l] = counts[l] + 1
            if l > max_len then max_len = l end
        end
    end
    local next_code = {}
    local code = 0
    counts[0] = 0
    for bits = 1, max_len do
        code = (code + counts[bits - 1]) * 2
        next_code[bits] = code
    end
    local by_len = {}
    for l = 1, max_len do by_len[l] = {} end
    for s = 0, max_sym do
        local l = lengths[s] or 0
        if l > 0 then
            by_len[l][next_code[l]] = s
            next_code[l] = next_code[l] + 1
        end
    end
    return { max_len = max_len, by_len = by_len }
end

local FIXED_LIT_TREE, FIXED_DIST_TREE
local function getFixedTrees()
    if FIXED_LIT_TREE then return FIXED_LIT_TREE, FIXED_DIST_TREE end
    local ll, dl = {}, {}
    for s = 0, 143 do ll[s] = 8 end
    for s = 144, 255 do ll[s] = 9 end
    for s = 256, 279 do ll[s] = 7 end
    for s = 280, 287 do ll[s] = 8 end
    for s = 0, 31 do dl[s] = 5 end
    FIXED_LIT_TREE = buildHuffTree(ll, 287)
    FIXED_DIST_TREE = buildHuffTree(dl, 31)
    return FIXED_LIT_TREE, FIXED_DIST_TREE
end

local function inflateLua(src)
    local n = #src
    local pos = 1
    local bitbuf = 0
    local bitcnt = 0

    local function readBits(k)
        while bitcnt < k do
            local b = pos <= n and byte(src, pos) or 0
            if pos > n and bitcnt + (n - pos + 1) * 8 < k then
                -- Allow bit peeking cleanly; actual read past EOF errors if symbol missing
                error("Unexpected EOF in DEFLATE stream")
            end
            pos = pos + 1
            bitbuf = bor(bitbuf, lshift(b, bitcnt))
            bitcnt = bitcnt + 8
        end
        local v = band(bitbuf, lshift(1, k) - 1)
        bitbuf = rshift(bitbuf, k)
        bitcnt = bitcnt - k
        return v
    end

    local function readBit()
        if bitcnt == 0 then
            if pos > n then error("Unexpected EOF in DEFLATE stream") end
            bitbuf = byte(src, pos)
            pos = pos + 1
            bitcnt = 8
        end
        local b = band(bitbuf, 1)
        bitbuf = rshift(bitbuf, 1)
        bitcnt = bitcnt - 1
        return b
    end

    local function readSym(tree)
        local code = 0
        local by_len = tree.by_len
        for len = 1, tree.max_len do
            code = code * 2 + readBit()
            local sym = by_len[len] and by_len[len][code]
            if sym ~= nil then return sym end
        end
        error("Invalid Huffman symbol in DEFLATE stream")
    end

    local out = {}
    local out_len = 0

    local function pushByte(b)
        out_len = out_len + 1
        out[out_len] = b
    end

    local bfinal
    repeat
        bfinal = readBit()
        local btype = readBits(2)
        if btype == 0 then
            bitbuf = 0
            bitcnt = 0
            if pos + 3 > n then error("Truncated stored DEFLATE block") end
            local blen = decU16LE(src, pos)
            local nlen = decU16LE(src, pos + 2)
            pos = pos + 4
            if bxor(blen, nlen) ~= 0xFFFF then error("Corrupt stored DEFLATE block length") end
            if pos + blen - 1 > n then error("Truncated stored DEFLATE data") end
            for i = pos, pos + blen - 1 do pushByte(byte(src, i)) end
            pos = pos + blen
        elseif btype == 1 or btype == 2 then
            local lit_tree, dist_tree
            if btype == 1 then
                lit_tree, dist_tree = getFixedTrees()
            else
                local hlit = readBits(5) + 257
                local hdist = readBits(5) + 1
                local hclen = readBits(4) + 4
                local cl_lens = {}
                for i = 0, 18 do cl_lens[i] = 0 end
                for i = 1, hclen do cl_lens[CL_ORDER[i]] = readBits(3) end
                local cl_tree = buildHuffTree(cl_lens, 18)
                local all_lens = {}
                local idx = 0
                local total = hlit + hdist
                while idx < total do
                    local sym = readSym(cl_tree)
                    if sym < 16 then
                        all_lens[idx] = sym
                        idx = idx + 1
                    else
                        local rep_val = 0
                        local cnt
                        if sym == 16 then
                            if idx == 0 then error("Invalid repeat code 16") end
                            rep_val = all_lens[idx - 1]
                            cnt = 3 + readBits(2)
                        elseif sym == 17 then
                            cnt = 3 + readBits(3)
                        else
                            cnt = 11 + readBits(7)
                        end
                        for _k = 1, cnt do
                            all_lens[idx] = rep_val
                            idx = idx + 1
                        end
                    end
                end
                local ll, dl = {}, {}
                for i = 0, hlit - 1 do ll[i] = all_lens[i] end
                for i = 0, hdist - 1 do dl[i] = all_lens[hlit + i] end
                lit_tree = buildHuffTree(ll, hlit - 1)
                dist_tree = buildHuffTree(dl, hdist - 1)
            end
            while true do
                local sym = readSym(lit_tree)
                if sym < 256 then
                    pushByte(sym)
                elseif sym == 256 then
                    break
                else
                    local li = sym - 256
                    local length = LEN_BASE[li]
                    local lextra = LEN_EXTRA[li]
                    if lextra > 0 then length = length + readBits(lextra) end
                    local dsym = readSym(dist_tree) + 1
                    local dist = DIST_BASE[dsym]
                    local dextra = DIST_EXTRA[dsym]
                    if dextra > 0 then dist = dist + readBits(dextra) end
                    for _k = 1, length do
                        pushByte(out[out_len - dist + 1])
                    end
                end
            end
        else
            error("Invalid DEFLATE block type 3")
        end
    until bfinal == 1

    local parts = {}
    for i = 1, out_len, 4096 do
        local j = math.min(out_len, i + 4095)
        parts[#parts + 1] = char(unpack(out, i, j))
    end
    return concat(parts)
end

Zip._inflateLua = inflateLua

------------------------------------------------------------------------------
-- Native zlib bindings (only initialized outside KOReader's ffi/zlib)
------------------------------------------------------------------------------

local native_z
local native_z_checked = false

local function getNativeZlib()
    if native_z_checked then return native_z end
    native_z_checked = true
    -- Inside KOReader, `ffi/zlib` already declares zlib C symbols on `ffi.C`
    -- with `z_stream*`. Never redeclare those global C symbols if `ffi/zlib` exists.
    local ko_ok = pcall(require, "ffi/zlib")
    if ko_ok then return nil end

    local ok_cdef = pcall(ffi.cdef, [[
        typedef struct gn_z_stream_s {
            const unsigned char *next_in;
            unsigned int avail_in;
            unsigned long total_in;
            unsigned char *next_out;
            unsigned int avail_out;
            unsigned long total_out;
            const char *msg;
            void *state;
            void *zalloc;
            void *zfree;
            void *opaque;
            int data_type;
            unsigned long adler;
            unsigned long reserved;
        } gn_z_stream;
        const char *zlibVersion(void);
        int deflateInit2_(gn_z_stream *strm, int level, int method, int windowBits, int memLevel, int strategy, const char *version, int stream_size);
        int deflate(gn_z_stream *strm, int flush);
        int deflateEnd(gn_z_stream *strm);
        int inflateInit2_(gn_z_stream *strm, int windowBits, const char *version, int stream_size);
        int inflate(gn_z_stream *strm, int flush);
        int inflateEnd(gn_z_stream *strm);
    ]])
    if not ok_cdef then return nil end

    local lib
    for _i, name in ipairs({ "z", "libz.so.1", "/usr/lib/libz.1.dylib", "libz.dylib" }) do
        local ok, loaded = pcall(ffi.load, name)
        if ok and loaded then
            local vok = pcall(function() return loaded.zlibVersion() end)
            if vok then lib = loaded; break end
        end
    end
    native_z = lib
    return native_z
end

local function deflateNative(lib, raw)
    local strm = ffi.new("gn_z_stream")
    local ver = lib.zlibVersion()
    local rc = lib.deflateInit2_(strm, 6, 8, -15, 8, 0, ver, ffi.sizeof("gn_z_stream"))
    if rc ~= 0 then return nil, "deflateInit2 failed: " .. rc end
    local in_len = #raw
    local in_buf = in_len > 0 and ffi.cast("const unsigned char *", raw) or nil
    strm.next_in = in_buf
    strm.avail_in = in_len
    local out_cap = math.max(128, math.floor(in_len * 1.02) + 64)
    local out_buf = ffi.new("uint8_t[?]", out_cap)
    local parts = {}
    local fin = 4   -- Z_FINISH
    while true do
        strm.next_out = out_buf
        strm.avail_out = out_cap
        local drc = lib.deflate(strm, fin)
        local produced = out_cap - tonumber(strm.avail_out)
        if produced > 0 then parts[#parts + 1] = ffi.string(out_buf, produced) end
        if drc == 1 then break end   -- Z_STREAM_END
        if drc ~= 0 and drc ~= -5 then
            lib.deflateEnd(strm)
            return nil, "deflate failed: " .. drc
        end
    end
    lib.deflateEnd(strm)
    return concat(parts)
end

local function inflateNative(lib, comp, expected_len)
    local strm = ffi.new("gn_z_stream")
    local ver = lib.zlibVersion()
    local rc = lib.inflateInit2_(strm, -15, ver, ffi.sizeof("gn_z_stream"))
    if rc ~= 0 then return nil, "inflateInit2 failed: " .. rc end
    local in_len = #comp
    local in_buf = in_len > 0 and ffi.cast("const unsigned char *", comp) or nil
    strm.next_in = in_buf
    strm.avail_in = in_len
    local chunk = math.max(4096, math.min(262144, (expected_len or 0) + 64))
    local out_buf = ffi.new("uint8_t[?]", chunk)
    local parts = {}
    while true do
        strm.next_out = out_buf
        strm.avail_out = chunk
        local irc = lib.inflate(strm, 0)
        local produced = chunk - tonumber(strm.avail_out)
        if produced > 0 then parts[#parts + 1] = ffi.string(out_buf, produced) end
        if irc == 1 then break end   -- Z_STREAM_END
        if irc ~= 0 and irc ~= -5 then
            lib.inflateEnd(strm)
            return nil, "inflate failed: " .. irc
        end
        if produced == 0 and tonumber(strm.avail_in) == 0 then
            lib.inflateEnd(strm)
            return nil, "truncated deflate stream"
        end
    end
    lib.inflateEnd(strm)
    return concat(parts)
end

--- Raw DEFLATE compression. Returns `compressed_bytes, method`.
function Zip.deflate(raw)
    -- 1. Inside KOReader, use `ffi/zlib` and strip 2-byte zlib header + 4-byte Adler32.
    local zok, ko_zlib = pcall(require, "ffi/zlib")
    if zok and ko_zlib and ko_zlib.zlib_compress then
        local zdata = ko_zlib.zlib_compress(raw)
        if zdata and #zdata >= 6 and band(byte(zdata, 2), 0x20) == 0 then
            return sub(zdata, 3, -5), METHOD_DEFLATE
        end
    end
    -- 2. Standalone LuaJIT: use native libz directly.
    local lib = getNativeZlib()
    if lib then
        local comp = deflateNative(lib, raw)
        if comp then return comp, METHOD_DEFLATE end
    end
    -- 3. Universal safe fallback: STORE uncompressed (still 100% valid ZIP!).
    return raw, METHOD_STORE
end

--- Raw DEFLATE decompression.
function Zip.inflate(comp, expected_len)
    local lib = getNativeZlib()
    if lib then
        local dec, err = inflateNative(lib, comp, expected_len)
        if dec then return dec end
        return nil, err
    end
    local ok, dec = pcall(inflateLua, comp)
    if ok then return dec end
    return nil, dec
end

local function u32BE(v)
    return char(
        math.floor(v / 16777216) % 256,
        math.floor(v / 65536) % 256,
        math.floor(v / 256) % 256,
        v % 256
    )
end

--- Compress `raw` into RFC 1950 zlib format (2-byte header + deflate + 4-byte Adler-32).
function Zip.zlibCompress(raw)
    raw = tostring(raw or "")
    local zok, ko_zlib = pcall(require, "ffi/zlib")
    if zok and ko_zlib and ko_zlib.zlib_compress then
        local zdata = ko_zlib.zlib_compress(raw)
        if zdata and #zdata >= 6 then return zdata end
    end
    local lib = getNativeZlib()
    if lib then
        local comp = deflateNative(lib, raw)
        if comp then
            return "\x78\x9C" .. comp .. u32BE(Zip.adler32(raw))
        end
    end
    -- Fallback: valid RFC 1950 + stored RFC 1951 deflate blocks
    local blocks = { "\x78\x01" }
    local n = #raw
    if n == 0 then
        blocks[2] = "\x01\x00\x00\xFF\xFF"
    else
        local p = 1
        while p <= n do
            local take = math.min(65535, n - p + 1)
            local bfinal = (p + take > n) and 1 or 0
            local nlen = bxor(take, 0xFFFF)
            blocks[#blocks + 1] = char(bfinal, band(take, 0xFF), band(rshift(take, 8), 0xFF),
                band(nlen, 0xFF), band(rshift(nlen, 8), 0xFF)) .. sub(raw, p, p + take - 1)
            p = p + take
        end
    end
    blocks[#blocks + 1] = u32BE(Zip.adler32(raw))
    return concat(blocks)
end

--- Decompress RFC 1950 zlib stream `zbytes`. Returns `raw` or `nil, err`.
function Zip.zlibDecompress(zbytes, expected_len)
    if type(zbytes) ~= "string" or #zbytes < 6 then return nil, "truncated zlib stream" end
    local zok, ko_zlib = pcall(require, "ffi/zlib")
    if zok and ko_zlib and ko_zlib.zlib_uncompress then
        local ok, dec = pcall(ko_zlib.zlib_uncompress, zbytes)
        if ok and type(dec) == "string" then return dec end
    end
    local cmf, flg = byte(zbytes, 1, 2)
    if band(cmf, 0x0F) ~= 8 or (cmf * 256 + flg) % 31 ~= 0 then
        return nil, "invalid zlib header"
    end
    if band(flg, 0x20) ~= 0 then return nil, "preset zlib dictionary not supported" end
    return Zip.inflate(sub(zbytes, 3, -5), expected_len)
end

------------------------------------------------------------------------------
-- ZIP Parsing (Central Directory, Local Data Offset)
------------------------------------------------------------------------------

local function findEOCD(tail, base_off)
    -- Walk backwards for EOCD signature PK\x05\x06 (`0x06054B50`)
    local n = #tail
    for i = n - 21, 1, -1 do
        if byte(tail, i) == 0x50 and byte(tail, i + 1) == 0x4B
                and byte(tail, i + 2) == 0x05 and byte(tail, i + 3) == 0x06 then
            local clen = decU16LE(tail, i + 20)
            if i + 21 + clen <= n then
                return base_off + i - 1, tail, i
            end
        end
    end
    return nil, "ZIP End-of-Central-Directory not found"
end

local function parseCentralDirectory(cd_bytes, expected_count)
    local entries = {}
    local by_name = {}
    local pos, n = 1, #cd_bytes
    while pos <= n do
        if pos + 45 > n then return nil, "Truncated central directory entry" end
        if sub(cd_bytes, pos, pos + 3) ~= "PK\1\2" then
            return nil, "Bad central directory signature at " .. pos
        end
        local ver_made = decU16LE(cd_bytes, pos + 4)
        local ver_need = decU16LE(cd_bytes, pos + 6)
        local flags = decU16LE(cd_bytes, pos + 8)
        local method = decU16LE(cd_bytes, pos + 10)
        local mtime = decU16LE(cd_bytes, pos + 12)
        local mdate = decU16LE(cd_bytes, pos + 14)
        local crc32 = decU32LE(cd_bytes, pos + 16)
        local comp_size = decU32LE(cd_bytes, pos + 20)
        local uncomp_size = decU32LE(cd_bytes, pos + 24)
        local fname_len = decU16LE(cd_bytes, pos + 28)
        local extra_len = decU16LE(cd_bytes, pos + 30)
        local comment_len = decU16LE(cd_bytes, pos + 32)
        local ext_attr = decU32LE(cd_bytes, pos + 38)
        local local_off = decU32LE(cd_bytes, pos + 42)
        local hdr_end = pos + 45 + fname_len + extra_len + comment_len
        if hdr_end > n then return nil, "Truncated central directory entry fields" end
        local name = sub(cd_bytes, pos + 46, pos + 45 + fname_len)
        local extra = extra_len > 0 and sub(cd_bytes, pos + 46 + fname_len, pos + 45 + fname_len + extra_len) or ""
        local e = {
            name = name,
            ver_made = ver_made,
            ver_need = ver_need,
            flags = flags,
            method = method,
            mtime = mtime,
            mdate = mdate,
            crc32 = crc32,
            comp_size = comp_size,
            uncomp_size = uncomp_size,
            ext_attr = ext_attr,
            local_off = local_off,
            extra = extra,
        }
        entries[#entries + 1] = e
        by_name[name] = e
        pos = hdr_end + 1
    end
    if expected_count and expected_count ~= 0xFFFF and #entries ~= expected_count then
        return nil, string.format("CD count mismatch (%d != %d)", #entries, expected_count)
    end
    return entries, by_name
end

local Archive = {}
Archive.__index = Archive

function Zip.isZipBytes(head)
    if type(head) ~= "string" or #head < 4 then return false end
    local sig = sub(head, 1, 4)
    return sig == "PK\3\4" or sig == "PK\5\6" or sig == "PK\7\8"
end

function Zip.isZip(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(4) or ""
    f:close()
    return Zip.isZipBytes(head)
end

--- Open a ZIP file on disk without decompressing any entries (`Archive:read` loads on demand).
function Zip.open(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local fsize = f:seek("end")
    if not fsize or fsize < 22 then f:close(); return nil, "File too small to be a ZIP" end
    local tail_len = math.min(fsize, 65557)
    f:seek("set", fsize - tail_len)
    local tail = f:read(tail_len) or ""
    local eocd_off, tbuf, toff = findEOCD(tail, fsize - tail_len)
    if not eocd_off then f:close(); return nil, tbuf end

    local total_entries = decU16LE(tbuf, toff + 10)
    local cd_size = decU32LE(tbuf, toff + 12)
    local cd_off = decU32LE(tbuf, toff + 16)
    if cd_off + cd_size > fsize then f:close(); return nil, "Central directory out of bounds" end

    f:seek("set", cd_off)
    local cd_bytes = cd_size > 0 and (f:read(cd_size) or "") or ""
    if #cd_bytes ~= cd_size then f:close(); return nil, "Truncated central directory" end

    local entries, by_name = parseCentralDirectory(cd_bytes, total_entries)
    if not entries then f:close(); return nil, by_name end

    local self = setmetatable({
        path = path,
        file = f,
        size = fsize,
        entries = entries,
        by_name = by_name,
    }, Archive)
    return self
end

--- Wrap an in-memory ZIP byte string with the same read interface (for unit tests).
function Zip.fromBytes(data)
    if type(data) ~= "string" or #data < 22 then return nil, "Buffer too small" end
    local tail_off = math.max(0, #data - 65557)
    local tail = sub(data, tail_off + 1)
    local eocd_off, tbuf, toff = findEOCD(tail, tail_off)
    if not eocd_off then return nil, tbuf end

    local total_entries = decU16LE(tbuf, toff + 10)
    local cd_size = decU32LE(tbuf, toff + 12)
    local cd_off = decU32LE(tbuf, toff + 16)
    if cd_off + cd_size > #data then return nil, "Central directory out of bounds" end
    local cd_bytes = cd_size > 0 and sub(data, cd_off + 1, cd_off + cd_size) or ""
    local entries, by_name = parseCentralDirectory(cd_bytes, total_entries)
    if not entries then return nil, by_name end

    return setmetatable({
        buf = data,
        size = #data,
        entries = entries,
        by_name = by_name,
    }, Archive)
end

function Archive:close()
    if self._archiver then
        pcall(self._archiver.close, self._archiver)
        self._archiver = nil
    end
    if self.file then
        self.file:close()
        self.file = nil
    end
end

function Archive:list()
    local names = {}
    for i, e in ipairs(self.entries) do names[i] = e.name end
    return names
end

function Archive:has(name)
    return self.by_name[name] ~= nil
end

function Archive:entry(name)
    return self.by_name[name]
end

local function localDataOffset(arc, e)
    local hdr
    if arc.file then
        arc.file:seek("set", e.local_off)
        hdr = arc.file:read(30) or ""
    else
        hdr = sub(arc.buf, e.local_off + 1, e.local_off + 30)
    end
    if #hdr < 30 or sub(hdr, 1, 4) ~= "PK\3\4" then
        return nil, "Bad local header signature for " .. e.name
    end
    local fnl = decU16LE(hdr, 27)
    local exl = decU16LE(hdr, 29)
    return e.local_off + 30 + fnl + exl
end

--- Read raw compressed slice (`e.comp_size` bytes) for entry `name`.
function Archive:readRaw(name)
    local e = self.by_name[name]
    if not e then return nil, "missing entry: " .. tostring(name) end
    local off, err = localDataOffset(self, e)
    if not off then return nil, err end
    if e.comp_size == 0 then return "", e end
    if self.file then
        self.file:seek("set", off)
        local data = self.file:read(e.comp_size)
        if not data or #data ~= e.comp_size then return nil, "truncated entry: " .. name end
        return data, e
    end
    local data = sub(self.buf, off + 1, off + e.comp_size)
    if #data ~= e.comp_size then return nil, "truncated entry: " .. name end
    return data, e
end

--- Try C `ffi/archiver` inside KOReader when reading deflated file entries.
function Archive:readViaArchiver(name)
    if not (self.path and not self.buf) then return nil end
    if not self._archiver and self._archiver_failed ~= true then
        local ok, Archiver = pcall(require, "ffi/archiver")
        if ok and Archiver and Archiver.Reader then
            local r = Archiver.Reader:new()
            if r:open(self.path) then
                for _e in r:iterate() do end
                self._archiver = r
            else
                self._archiver_failed = true
            end
        else
            self._archiver_failed = true
        end
    end
    if self._archiver then
        local ok, data = pcall(self._archiver.extractToMemory, self._archiver, name)
        if ok and data ~= nil then return data end
    end
    return nil
end

--- Read and decompress entry `name`. Returns `bytes` or `nil, err`.
function Archive:read(name)
    local e = self.by_name[name]
    if not e then return nil, "missing entry: " .. tostring(name) end
    if band(e.flags, 0x01) ~= 0 then return nil, "encrypted entry not supported: " .. name end
    if e.method == METHOD_STORE then
        local raw, rerr = self:readRaw(name)
        if not raw then return nil, rerr end
        return raw
    end
    if e.method ~= METHOD_DEFLATE then
        return nil, "unsupported compression method " .. tostring(e.method) .. " for " .. name
    end
    -- When native libz is available (outside KOReader), it's fastest; inside KOReader use Archiver C reader first.
    if getNativeZlib() then
        local raw, rerr = self:readRaw(name)
        if not raw then return nil, rerr end
        return Zip.inflate(raw, e.uncomp_size)
    end
    local c_data = self:readViaArchiver(name)
    if c_data ~= nil then return c_data end
    local raw, rerr = self:readRaw(name)
    if not raw then return nil, rerr end
    return Zip.inflate(raw, e.uncomp_size)
end

--- Extract entry `name` directly to file `dest_path` atomically.
function Archive:extractToFile(name, dest_path)
    local data, err = self:read(name)
    if not data then return false, err end
    local Storage = require("ink/storage")
    return Storage.writeAtomic(dest_path, data)
end

------------------------------------------------------------------------------
-- ZIP Writer & Streaming Patcher
------------------------------------------------------------------------------

local function needsUtf8(name)
    for i = 1, #name do
        if byte(name, i) >= 0x80 then return true end
    end
    return false
end

local function encodeLocalHeader(name, method, flags, mtime, mdate, crc, comp_sz, uncomp_sz)
    -- Always clear bit 3 (data descriptor) since sizes/CRC are known upfront
    local clean_flags = band(flags or 0, 0xFFF7)
    if needsUtf8(name) then clean_flags = bor(clean_flags, 0x0800) end
    return concat({
        "PK\3\4",
        encU16LE(20),                  -- version needed: 2.0
        encU16LE(clean_flags),
        encU16LE(method),
        encU16LE(mtime or 0),
        encU16LE(mdate or 0x5421),     -- 2022-01-01 fallback date
        encU32LE(crc),
        encU32LE(comp_sz),
        encU32LE(uncomp_sz),
        encU16LE(#name),
        encU16LE(0),                   -- extra length
        name,
    }), clean_flags
end

local function encodeCDHeader(cd)
    return concat({
        "PK\1\2",
        encU16LE(cd.ver_made or 20),
        encU16LE(cd.ver_need or 20),
        encU16LE(cd.flags),
        encU16LE(cd.method),
        encU16LE(cd.mtime or 0),
        encU16LE(cd.mdate or 0x5421),
        encU32LE(cd.crc),
        encU32LE(cd.comp_size),
        encU32LE(cd.uncomp_size),
        encU16LE(#cd.name),
        encU16LE(0),                   -- extra_len
        encU16LE(0),                   -- comment_len
        encU16LE(0),                   -- disk_start
        encU16LE(0),                   -- internal_attr
        encU32LE(cd.ext_attr or 0),
        encU32LE(cd.local_off),
        cd.name,
    })
end

local function finishZip(wf, cds, offset, tmp_path, dest_path)
    local cd_parts = {}
    local cd_size = 0
    for i, cd in ipairs(cds) do
        local rec = encodeCDHeader(cd)
        cd_parts[i] = rec
        cd_size = cd_size + #rec
    end
    local cd_blob = concat(cd_parts)
    if #cd_blob > 0 and not wf:write(cd_blob) then
        wf:close(); os.remove(tmp_path)
        return false, "failed writing central directory"
    end
    local eocd = concat({
        "PK\5\6",
        encU16LE(0),
        encU16LE(0),
        encU16LE(#cds),
        encU16LE(#cds),
        encU32LE(cd_size),
        encU32LE(offset),
        encU16LE(0),
    })
    if not wf:write(eocd) then
        wf:close(); os.remove(tmp_path)
        return false, "failed writing EOCD"
    end
    local uok, util = pcall(require, "ffi/util")
    if uok and util and util.fsyncOpenedFile then pcall(util.fsyncOpenedFile, wf) end
    wf:close()
    local rok, rerr = os.rename(tmp_path, dest_path)
    if not rok then
        os.remove(dest_path)
        rok, rerr = os.rename(tmp_path, dest_path)
    end
    if not rok then
        os.remove(tmp_path)
        return false, rerr
    end
    return true
end

local function writeCompressedEntry(wf, offset, name, raw_data, store)
    local crc = Zip.crc32(raw_data)
    local comp, method
    if store then
        comp, method = raw_data, METHOD_STORE
    else
        comp, method = Zip.deflate(raw_data)
        if method == METHOD_DEFLATE and #comp >= #raw_data and #raw_data > 0 then
            comp, method = raw_data, METHOD_STORE
        end
    end
    local hdr, flags = encodeLocalHeader(name, method, 0, nil, nil, crc, #comp, #raw_data)
    if not wf:write(hdr) then return nil, "write failed" end
    if #comp > 0 and not wf:write(comp) then return nil, "write failed" end
    local cd = {
        flags = flags,
        method = method,
        crc = crc,
        comp_size = #comp,
        uncomp_size = #raw_data,
        local_off = offset,
        name = name,
    }
    return offset + #hdr + #comp, cd
end

--- Write a new ZIP archive atomically from ordered `{ { name = ..., data = ..., store = bool }, ... }`
--- or map `{ [name] = bytes }`.
function Zip.write(dest_path, entries)
    local list = {}
    if #entries > 0 then
        list = entries
    else
        local names = {}
        for k in pairs(entries) do names[#names + 1] = k end
        table.sort(names)
        for i, name in ipairs(names) do
            list[i] = { name = name, data = entries[name] }
        end
    end

    local tmp = dest_path .. ".tmp"
    os.remove(tmp)
    local wf, err = io.open(tmp, "wb")
    if not wf then return false, err end

    local cds = {}
    local offset = 0
    for _i, item in ipairs(list) do
        local noff, cd = writeCompressedEntry(wf, offset, item.name, item.data or "", item.store)
        if not noff then
            wf:close(); os.remove(tmp)
            return false, cd
        end
        offset = noff
        cds[#cds + 1] = cd
    end
    return finishZip(wf, cds, offset, tmp, dest_path)
end

--- Stream copy unchanged entries directly as raw compressed bytes from `src_path` to `dest_path`,
--- applying `updates` (`{ [name] = uncompressed_bytes }`) and `deletes` (`{ [name] = true }`).
--- Supports `src_path == dest_path` safely via temp file + atomic rename.
function Zip.patch(src_path, dest_path, updates, deletes)
    updates = updates or {}
    deletes = deletes or {}
    local src, oerr = Zip.open(src_path)
    if not src then return false, oerr end

    local tmp = dest_path .. ".tmp"
    os.remove(tmp)
    local wf, werr = io.open(tmp, "wb")
    if not wf then src:close(); return false, werr end

    local cds = {}
    local offset = 0
    local written = {}

    local function fail(why)
        wf:close()
        src:close()
        os.remove(tmp)
        return false, why
    end

    -- 1. Preserve original entry order, patching updated entries in-place and skipping deleted ones.
    for _i, e in ipairs(src.entries) do
        local name = e.name
        if not deletes[name] then
            if updates[name] ~= nil then
                local noff, cd = writeCompressedEntry(wf, offset, name, updates[name], false)
                if not noff then return fail(cd) end
                offset = noff
                cds[#cds + 1] = cd
                written[name] = true
            else
                -- Raw stream copy: zero decompression or recompression!
                local data_off, loerr = localDataOffset(src, e)
                if not data_off then return fail(loerr) end
                local hdr, clean_flags = encodeLocalHeader(
                    name, e.method, e.flags, e.mtime, e.mdate, e.crc32, e.comp_size, e.uncomp_size
                )
                if not wf:write(hdr) then return fail("write local header failed") end
                src.file:seek("set", data_off)
                local rem = e.comp_size
                while rem > 0 do
                    local take = math.min(CHUNK_SIZE, rem)
                    local chunk = src.file:read(take)
                    if not chunk or #chunk ~= take then return fail("truncated raw stream in " .. name) end
                    if not wf:write(chunk) then return fail("write stream failed") end
                    rem = rem - take
                end
                cds[#cds + 1] = {
                    ver_made = e.ver_made,
                    ver_need = e.ver_need,
                    flags = clean_flags,
                    method = e.method,
                    mtime = e.mtime,
                    mdate = e.mdate,
                    crc = e.crc32,
                    comp_size = e.comp_size,
                    uncomp_size = e.uncomp_size,
                    ext_attr = e.ext_attr,
                    local_off = offset,
                    name = name,
                }
                offset = offset + #hdr + e.comp_size
                written[name] = true
            end
        end
    end

    -- 2. Append new entries not present in original archive (sorted deterministically).
    local added = {}
    for name in pairs(updates) do
        if not written[name] and not deletes[name] then
            added[#added + 1] = name
        end
    end
    table.sort(added)
    for _i, name in ipairs(added) do
        local noff, cd = writeCompressedEntry(wf, offset, name, updates[name], false)
        if not noff then return fail(cd) end
        offset = noff
        cds[#cds + 1] = cd
    end

    src:close()
    return finishZip(wf, cds, offset, tmp, dest_path)
end

return Zip
