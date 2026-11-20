--[[
Low-level binary & Protocol Buffer wire primitives for `.goodnotes` archives.
Plain LuaJIT (`bit`, `ffi`) so headless tests and KOReader both run it directly.

Critical invariants handled explicitly here:
  * 64-bit unsigned (`uint64_t`) and signed (`int64_t`) varints do not round
    through Lua's 53-bit `double`, preserving exact `replica_id`, `lamport`,
    and negative two's-complement sentinels (`-1`, `-60`, `-404`).
  * `NoteLayerUUID == UUID(PageUUID).int + 1` (exact 128-bit big-endian +1).
  * Fractional ASCII `order_key` generation preserves sorted page order.
]]

local bit = require("bit")
local ffi = require("ffi")

local Wire = {}

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local byte, char, sub, concat, format = string.byte, string.char, string.sub, table.concat, string.format
local floor = math.floor

Wire.GOODNOTES_PPI = 132.0
Wire.PDF_DPI = 72.0
Wire.PT_TO_GN = Wire.GOODNOTES_PPI / Wire.PDF_DPI   -- 11/6
Wire.CONST_5381 = 5381

-- Reusable FFI unions for IEEE-754 float32 / float64 <-> raw bytes.
local f32_u = ffi.new("union { float f; uint32_t u; uint8_t b[4]; }")
local f64_u = ffi.new("union { double d; uint64_t u; uint8_t b[8]; }")

------------------------------------------------------------------------------
-- Little-endian fixed integer & IEEE-754 float helpers
------------------------------------------------------------------------------

function Wire.decU16LE(s, pos)
    local b1, b2 = byte(s, pos, pos + 1)
    return b1 + b2 * 256
end

function Wire.encU16LE(v)
    return char(band(v, 0xFF), band(rshift(v, 8), 0xFF))
end

function Wire.decU32LE(s, pos)
    local b1, b2, b3, b4 = byte(s, pos, pos + 3)
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

function Wire.encU32LE(v)
    return char(
        band(v, 0xFF),
        band(rshift(v, 8), 0xFF),
        band(rshift(v, 16), 0xFF),
        band(rshift(v, 24), 0xFF)
    )
end

function Wire.decI32LE(s, pos)
    local u = Wire.decU32LE(s, pos)
    if u >= 2147483648 then return u - 4294967296 end
    return u
end

function Wire.encI32LE(v)
    if v < 0 then v = v + 4294967296 end
    return Wire.encU32LE(v)
end

function Wire.decF32(s, pos)
    local b1, b2, b3, b4 = byte(s, pos or 1, (pos or 1) + 3)
    f32_u.b[0], f32_u.b[1], f32_u.b[2], f32_u.b[3] = b1, b2, b3, b4
    return tonumber(f32_u.f)
end

function Wire.encF32(f)
    f32_u.f = f
    return char(f32_u.b[0], f32_u.b[1], f32_u.b[2], f32_u.b[3])
end

function Wire.f32ToU32(f)
    f32_u.f = f
    return tonumber(f32_u.u)
end

function Wire.u32ToF32(u)
    f32_u.u = u
    return tonumber(f32_u.f)
end

function Wire.decF64(s, pos)
    local p = pos or 1
    for i = 0, 7 do f64_u.b[i] = byte(s, p + i) end
    return tonumber(f64_u.d)
end

function Wire.encF64(d)
    f64_u.d = d
    return ffi.string(f64_u.b, 8)
end

function Wire.decU64LE(s, pos)
    local p = pos or 1
    for i = 0, 7 do f64_u.b[i] = byte(s, p + i) end
    return ffi.new("uint64_t", f64_u.u)
end

function Wire.encU64LE(u)
    f64_u.u = Wire.toU64(u)
    return ffi.string(f64_u.b, 8)
end

function Wire.f64ToU64(d)
    f64_u.d = d
    return ffi.new("uint64_t", f64_u.u)
end

function Wire.u64ToF64(u)
    f64_u.u = Wire.toU64(u)
    return tonumber(f64_u.d)
end

------------------------------------------------------------------------------
-- Exact 64-bit unsigned integer utilities (avoids Lua double 53-bit truncation)
------------------------------------------------------------------------------

local U64_ZERO = 0ULL
local I64_ZERO = 0LL

--- Convert number, string (decimal), or cdata to a `uint64_t` value.
function Wire.toU64(v)
    if v == nil then return U64_ZERO end
    if type(v) == "cdata" then return ffi.cast("uint64_t", v) end
    if type(v) == "string" then return Wire.u64FromDec(v) end
    if v < 0 then return ffi.cast("uint64_t", ffi.cast("int64_t", v)) end
    return ffi.cast("uint64_t", v)
end

--- Convert signed integer (`-404`, `-60`, `-1`, or `int64_t` cdata) to `uint64_t` two's-complement bits.
function Wire.i64ToU64(v)
    if type(v) == "cdata" then return ffi.cast("uint64_t", v) end
    return ffi.cast("uint64_t", ffi.cast("int64_t", v or 0))
end

--- Interpret `uint64_t` cdata as Lua signed number when within 53 bits, or exact cdata `int64_t`.
function Wire.u64ToI64Num(u)
    local s = ffi.cast("int64_t", Wire.toU64(u))
    if s >= -9007199254740991LL and s <= 9007199254740991LL then
        return tonumber(s)
    end
    return s
end

--- Parse an arbitrary unsigned decimal string cleanly into `uint64_t`.
function Wire.u64FromDec(str)
    if type(str) == "cdata" then return ffi.cast("uint64_t", str) end
    if type(str) == "number" then return ffi.cast("uint64_t", str) end
    local s = tostring(str or "0"):match("^%s*(%d+)")
    if not s or s == "" then return U64_ZERO end
    local acc = 0ULL
    for i = 1, #s do
        acc = acc * 10ULL + ffi.cast("uint64_t", byte(s, i) - 48)
    end
    return acc
end

--- Format a `uint64_t` cleanly as a decimal string without the `"ULL"` suffix.
function Wire.u64ToDec(v)
    local u = Wire.toU64(v)
    return (tostring(u):gsub("ULL$", ""))
end

function Wire.u64Max(a, b)
    local ua, ub = Wire.toU64(a), Wire.toU64(b)
    return ua > ub and ua or ub
end

function Wire.u64Add(a, b)
    return Wire.toU64(a) + Wire.toU64(b)
end

--- Compare two `uint64_t` values (-1, 0, 1).
function Wire.u64Cmp(a, b)
    local ua, ub = Wire.toU64(a), Wire.toU64(b)
    if ua < ub then return -1 end
    if ua > ub then return 1 end
    return 0
end

function Wire.u64IsZero(v)
    return Wire.toU64(v) == U64_ZERO
end

------------------------------------------------------------------------------
-- Entropy, Random 32/64/128-bit & Goodnotes UUIDs
------------------------------------------------------------------------------

local rng_state = ffi.new("uint64_t", 0)
local rng_seq = 0

local function mixEntropy()
    rng_seq = rng_seq + 1
    local t = os.time() or 1
    local c = floor((os.clock() or 0) * 1e6)
    local addr = tonumber(tostring({}):match("0x(%x+)"), 16) or 1337
    local seed = Wire.toU64(t) * 6364136223846793005ULL + Wire.toU64(c) * 1442695040888963407ULL
        + Wire.toU64(addr) + Wire.toU64(rng_seq)
    if seed == U64_ZERO then seed = 0x9E3779B97F4A7C15ULL end
    rng_state = seed
end

--- Return `n` pseudo-random bytes (uses `/dev/urandom` when available, else SplitMix64).
function Wire.randomBytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local b = f:read(n)
        f:close()
        if b and #b == n then return b end
    end
    if rng_state == I64_ZERO or rng_state == U64_ZERO then mixEntropy() end
    local out = {}
    while #out * 8 < n do
        rng_state = rng_state + 0x9E3779B97F4A7C15ULL
        local z = rng_state
        z = bit.bxor(z, bit.rshift(z, 30)) * 0xBF58476D1CE4E5B9ULL
        z = bit.bxor(z, bit.rshift(z, 27)) * 0x94D049BB133111EBULL
        z = bit.bxor(z, bit.rshift(z, 31))
        out[#out + 1] = Wire.encU64LE(z)
    end
    return sub(concat(out), 1, n)
end

function Wire.randomU32()
    return Wire.decU32LE(Wire.randomBytes(4), 1)
end

function Wire.randomU64()
    local u = Wire.decU64LE(Wire.randomBytes(8), 1)
    if u == U64_ZERO then u = 1ULL end
    return u
end

--- Generate an uppercase hyphenated UUIDv4 string.
function Wire.uuidV4()
    local raw = { byte(Wire.randomBytes(16), 1, 16) }
    raw[7] = bor(band(raw[7], 0x0F), 0x40)   -- version 4
    raw[9] = bor(band(raw[9], 0x3F), 0x80)   -- variant RFC 4122
    return format(
        "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
        unpack(raw, 1, 16)
    )
end

local function uuidToBytes(uuid_str)
    if type(uuid_str) ~= "string" then return nil end
    local hex = uuid_str:gsub("%-", "")
    if #hex ~= 32 or not hex:match("^%x+$") then return nil end
    local bytes = {}
    for i = 1, 16 do
        bytes[i] = tonumber(sub(hex, i * 2 - 1, i * 2), 16)
    end
    return bytes
end

local function bytesToUuid(bytes)
    return format(
        "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
        unpack(bytes, 1, 16)
    )
end

function Wire.isUUID(s)
    return type(s) == "string" and s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

function Wire.normalizeUUID(s)
    local b = uuidToBytes(s)
    return b and bytesToUuid(b) or s
end

--- Exact 128-bit big-endian +1 (enforces `NoteLayerUUID = UUID(PageUUID).int + 1`).
function Wire.uuidPlusOne(uuid_str)
    local b = uuidToBytes(uuid_str)
    if not b then return nil end
    for i = 16, 1, -1 do
        local v = b[i] + 1
        if v < 256 then
            b[i] = v
            break
        end
        b[i] = 0
    end
    return bytesToUuid(b)
end

--- Exact 128-bit big-endian -1 (recovers `PageUUID` from `NoteLayerUUID`).
function Wire.uuidMinusOne(uuid_str)
    local b = uuidToBytes(uuid_str)
    if not b then return nil end
    for i = 16, 1, -1 do
        if b[i] > 0 then
            b[i] = b[i] - 1
            break
        end
        b[i] = 255
    end
    return bytesToUuid(b)
end

------------------------------------------------------------------------------
-- Lexicographic fractional ASCII order keys (Goodnotes `CreatePage.order_key`)
------------------------------------------------------------------------------

-- Alphabet in strict ASCII order (45 < 48..57 < 65..90 < 95 < 97..122).
local ORD_ALPHA = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz"
local ORD_RANK = {}
for i = 1, #ORD_ALPHA do ORD_RANK[byte(ORD_ALPHA, i)] = i end
local ORD_N = #ORD_ALPHA

--- Generate a fractional key strictly between ASCII strings `a` and `b`
--- (`a < key < b`, where `nil` means unbounded on that side).
function Wire.orderKeyBetween(a, b)
    if a and b and a >= b then
        error("orderKeyBetween: expected a < b, got " .. tostring(a) .. " >= " .. tostring(b))
    end
    local out = {}
    local i = 1
    while true do
        local ca = (a and i <= #a) and byte(a, i) or 0
        local cb = (b and i <= #b) and byte(b, i) or 127
        local ra = ORD_RANK[ca] or (ca == 0 and 0 or 1)
        local rb = ORD_RANK[cb] or (cb == 127 and (ORD_N + 1) or ORD_N)
        if not a and b then ra = 0 end
        -- When `a` is exhausted and `b` starts with lowest symbol `"-"` at position `i`, append step
        if rb - ra > 1 then
            local mid = floor((ra + rb) / 2)
            out[#out + 1] = sub(ORD_ALPHA, mid, mid)
            local cand = concat(out)
            if (not a or a < cand) and (not b or cand < b) then return cand end
        end
        if ra == rb then
            out[#out + 1] = ra > 0 and sub(ORD_ALPHA, ra, ra) or sub(ORD_ALPHA, 1, 1)
        else
            -- `rb == ra + 1`: pick lower prefix `a`'s char (if > 0) and continue deeper between (a, nil)
            if ra == 0 then
                out[#out + 1] = sub(ORD_ALPHA, 1, 1)
                a = nil
            else
                out[#out + 1] = sub(ORD_ALPHA, ra, ra)
                b = nil
            end
        end
        i = i + 1
        if i > 64 then
            -- Deterministic safety tail strictly > a
            local tail = (a or "") .. "V"
            if (not a or a < tail) and (not b or tail < b) then return tail end
            return (a or "") .. "0"
        end
    end
end

------------------------------------------------------------------------------
-- Varint & Raw Protobuf Wire Codec
------------------------------------------------------------------------------

--- Encode a 64-bit unsigned/int64 varint into canonical 1..10 byte string.
function Wire.encodeVarint(v)
    local u = Wire.toU64(v)
    if u < 0x80ULL then return char(tonumber(u)) end
    local b = {}
    while u >= 0x80ULL do
        b[#b + 1] = bor(tonumber(band(u, 0x7FULL)), 0x80)
        u = rshift(u, 7)
    end
    b[#b + 1] = tonumber(u)
    return char(unpack(b))
end

--- Decode base-128 varint starting at 1-based byte index `pos` in `buf`.
--- Returns `u64_cdata, next_pos` (and `number` convenience when within 53 bits if caller wants `tonumber`).
function Wire.decodeVarintU64(buf, pos)
    local n = #buf
    local acc = 0ULL
    local shift = 0
    local p = pos
    for _step = 1, 10 do
        if p > n then error("Truncated varint at byte " .. p) end
        local b = byte(buf, p)
        p = p + 1
        local low = ffi.cast("uint64_t", band(b, 0x7F))
        if shift == 0 then
            acc = low
        else
            acc = bor(acc, lshift(low, shift))
        end
        if b < 0x80 then
            return acc, p
        end
        shift = shift + 7
    end
    error("Overlong varint at byte " .. pos)
end

--- Parse raw protobuf message `[s..e]` into ordered list `{ { field, wt, raw, u64, num }, ... }`.
--- Returns `fields` or calls `error` on corrupt wire framing.
function Wire.parseMessage(buf, s, e)
    local pos = s or 1
    local stop = e or #buf
    local out = {}
    while pos <= stop do
        if pos > stop then break end
        local tag, np = Wire.decodeVarintU64(buf, pos)
        pos = np
        local fn = tonumber(rshift(tag, 3))
        local wt = tonumber(band(tag, 7ULL))
        if fn == 0 then error("Invalid protobuf field 0 at byte " .. pos) end
        if wt == 0 then
            local u64, np2 = Wire.decodeVarintU64(buf, pos)
            local raw_len = np2 - pos
            local num = (u64 <= 0x1FFFFFFFFFFFFFULL) and tonumber(u64) or nil
            out[#out + 1] = { field = fn, wt = 0, u64 = u64, num = num, val = num or u64, raw = sub(buf, pos, np2 - 1), raw_len = raw_len }
            pos = np2
        elseif wt == 1 then
            if pos + 7 > stop then error("Truncated fixed64 at field " .. fn) end
            out[#out + 1] = { field = fn, wt = 1, val = sub(buf, pos, pos + 7) }
            pos = pos + 8
        elseif wt == 2 then
            local ln64, np2 = Wire.decodeVarintU64(buf, pos)
            local ln = tonumber(ln64)
            pos = np2
            if pos + ln - 1 > stop then error("Truncated length-delimited field " .. fn) end
            out[#out + 1] = { field = fn, wt = 2, val = sub(buf, pos, pos + ln - 1) }
            pos = pos + ln
        elseif wt == 5 then
            if pos + 3 > stop then error("Truncated fixed32 at field " .. fn) end
            out[#out + 1] = { field = fn, wt = 5, val = sub(buf, pos, pos + 3) }
            pos = pos + 4
        else
            error("Unsupported protobuf wire type " .. tostring(wt) .. " at field " .. fn)
        end
    end
    return out
end

--- Safe wrapper around `Wire.parseMessage` returning `fields, err`.
function Wire.tryParseMessage(buf, s, e)
    local ok, res = pcall(Wire.parseMessage, buf, s, e)
    if ok then return res end
    return nil, res
end

--- Index parsed fields by `field` number -> `{ [field] = { entry1, ... } }`.
function Wire.byField(fields)
    local map = {}
    for _i, entry in ipairs(fields) do
        local list = map[entry.field]
        if not list then
            list = {}
            map[entry.field] = list
        end
        list[#list + 1] = entry
    end
    return map
end

--- Convenience readers on `map = Wire.byField(fields)`.
function Wire.getBytes(map, fn)
    local l = map[fn]
    return l and l[1].val or nil
end

function Wire.getStr(map, fn, default)
    local l = map[fn]
    return l and l[1].val or default
end

function Wire.getUInt(map, fn, default)
    local l = map[fn]
    if not l then return default or 0 end
    local e = l[1]
    return e.num or tonumber(e.u64)
end

function Wire.getU64(map, fn, default)
    local l = map[fn]
    if not l then return default and Wire.toU64(default) or U64_ZERO end
    return l[1].u64
end

function Wire.getI64(map, fn, default)
    local l = map[fn]
    if not l then return default or 0 end
    return Wire.u64ToI64Num(l[1].u64)
end

function Wire.getF32(map, fn, default)
    local l = map[fn]
    return l and Wire.decF32(l[1].val, 1) or (default or 0.0)
end

function Wire.getF64(map, fn, default)
    local l = map[fn]
    return l and Wire.decF64(l[1].val, 1) or (default or 0.0)
end

--- Encode field constructors: `{ field, wt, val }` (respecting proto3 zero-omission unless `force`).
function Wire.fVarint(fn, v, force)
    local u = Wire.toU64(v)
    if not force and u == U64_ZERO then return nil end
    return { fn, 0, u }
end

function Wire.fSigned64(fn, v, force)
    local u = Wire.i64ToU64(v)
    if not force and u == U64_ZERO then return nil end
    return { fn, 0, u }
end

function Wire.fF32(fn, f, force)
    if not force and (f == nil or f == 0.0) then return nil end
    return { fn, 5, Wire.encF32(f) }
end

function Wire.fF64(fn, d, force)
    if not force and (d == nil or d == 0.0) then return nil end
    return { fn, 1, Wire.encF64(d) }
end

function Wire.fBytes(fn, s, force)
    if s == nil then return nil end
    if not force and s == "" then return nil end
    return { fn, 2, s }
end

--- Encode `{ { fn, wt, val }, ... }` (nil slots in sparse list tolerated up to max_idx? Prefer array builder).
function Wire.encodeMessage(fields)
    local parts = {}
    for _i, f in ipairs(fields) do
        local fn, wt, val = f[1], f[2], f[3]
        parts[#parts + 1] = Wire.encodeVarint(Wire.toU64(fn) * 8ULL + Wire.toU64(wt))
        if wt == 0 then
            parts[#parts + 1] = Wire.encodeVarint(val)
        elseif wt == 1 then
            parts[#parts + 1] = type(val) == "string" and val or Wire.encF64(val)
        elseif wt == 2 then
            local s = tostring(val or "")
            parts[#parts + 1] = Wire.encodeVarint(#s)
            parts[#parts + 1] = s
        elseif wt == 5 then
            parts[#parts + 1] = type(val) == "string" and val or Wire.encF32(val)
        else
            error("encodeMessage: unsupported wire type " .. tostring(wt))
        end
    end
    return concat(parts)
end

--- Build a field list omitting nil entries without leaving holes.
function Wire.packFields(...)
    local out = {}
    local n = select("#", ...)
    for i = 1, n do
        local v = select(i, ...)
        if v ~= nil then out[#out + 1] = v end
    end
    return out
end

--- Parse varint length-delimited protobuf stream into list of raw message byte strings.
function Wire.parseDelimited(buf)
    local out = {}
    local pos, n = 1, #buf
    while pos <= n do
        local ln64, np = Wire.decodeVarintU64(buf, pos)
        local ln = tonumber(ln64)
        pos = np
        if pos + ln - 1 > n then
            error("Truncated delimited message (" .. ln .. "B > " .. (n - pos + 1) .. "B)")
        end
        out[#out + 1] = ln == 0 and "" or sub(buf, pos, pos + ln - 1)
        pos = pos + ln
    end
    return out
end

function Wire.encodeDelimited(msgs)
    local parts = {}
    for _i, m in ipairs(msgs) do
        parts[#parts + 1] = Wire.encodeVarint(#m)
        parts[#parts + 1] = m
    end
    return concat(parts)
end

------------------------------------------------------------------------------
-- Shared Goodnotes Submessages (Point, Size, Rect, Color, LwwClock, ZOrder)
------------------------------------------------------------------------------

function Wire.decPoint(raw)
    if not raw or raw == "" then return { x = 0.0, y = 0.0 } end
    local d = Wire.byField(Wire.parseMessage(raw))
    return { x = Wire.getF32(d, 1, 0.0), y = Wire.getF32(d, 2, 0.0) }
end

function Wire.encPoint(x, y)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fF32(1, x or 0.0),
        Wire.fF32(2, y or 0.0)
    ))
end

function Wire.decSize(raw)
    if not raw or raw == "" then return { w = 0.0, h = 0.0 } end
    local d = Wire.byField(Wire.parseMessage(raw))
    return { w = Wire.getF32(d, 1, 0.0), h = Wire.getF32(d, 2, 0.0) }
end

function Wire.encSize(w, h)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fF32(1, w or 0.0),
        Wire.fF32(2, h or 0.0)
    ))
end

function Wire.decRect(raw)
    if not raw or raw == "" then return { x = 0.0, y = 0.0, w = 0.0, h = 0.0 } end
    local d = Wire.byField(Wire.parseMessage(raw))
    local pt = Wire.decPoint(Wire.getBytes(d, 1))
    local sz = Wire.decSize(Wire.getBytes(d, 2))
    return { x = pt.x, y = pt.y, w = sz.w, h = sz.h }
end

function Wire.encRect(x, y, w, h, force_zero)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fBytes(1, Wire.encPoint(x, y), force_zero),
        Wire.fBytes(2, Wire.encSize(w, h), force_zero)
    ))
end

function Wire.decColor(raw)
    if not raw or raw == "" then return { r = 0.0, g = 0.0, b = 0.0, a = 0.0 } end
    local d = Wire.byField(Wire.parseMessage(raw))
    return {
        r = Wire.getF32(d, 1, 0.0),
        g = Wire.getF32(d, 2, 0.0),
        b = Wire.getF32(d, 3, 0.0),
        a = Wire.getF32(d, 4, 0.0),
    }
end

function Wire.encColor(r, g, b, a)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fF32(1, r or 0.0),
        Wire.fF32(2, g or 0.0),
        Wire.fF32(3, b or 0.0),
        Wire.fF32(4, a == nil and 1.0 or a)
    ))
end

function Wire.decLwwClock(raw)
    if not raw or raw == "" then return { counter = 0, tiebreaker = 0 } end
    local d = Wire.byField(Wire.parseMessage(raw))
    return { counter = Wire.getUInt(d, 1, 0), tiebreaker = Wire.getUInt(d, 2, 0) }
end

function Wire.encLwwClock(counter, tiebreaker)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fVarint(1, counter or 0),
        Wire.fVarint(2, tiebreaker or 0)
    ))
end

function Wire.decZOrder(raw)
    if not raw or raw == "" then return { index = 0, tiebreaker = 0 } end
    local outer = Wire.byField(Wire.parseMessage(raw))
    local inner_raw = Wire.getBytes(outer, 1)
    if not inner_raw then return { index = 0, tiebreaker = 0 } end
    local inner = Wire.byField(Wire.parseMessage(inner_raw))
    return { index = Wire.getUInt(inner, 1, 0), tiebreaker = Wire.getUInt(inner, 2, 0) }
end

function Wire.encZOrder(index, tiebreaker)
    return Wire.encodeMessage({
        { 1, 2, Wire.encLwwClock(index or 0, tiebreaker or 0) },
    })
end

function Wire.encLwwString(val, counter, tiebreaker)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fBytes(1, val or ""),
        Wire.fBytes(2, Wire.encLwwClock(counter, tiebreaker), true)
    ))
end

function Wire.encLwwBytes(val, counter, tiebreaker)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fBytes(1, val or ""),
        Wire.fBytes(2, Wire.encLwwClock(counter, tiebreaker), true)
    ))
end

function Wire.encLwwDouble(val, counter, tiebreaker)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fF64(1, val or 0.0),
        Wire.fBytes(2, Wire.encLwwClock(counter, tiebreaker), true)
    ))
end

function Wire.encLwwUint32(val, counter, tiebreaker)
    return Wire.encodeMessage(Wire.packFields(
        Wire.fVarint(1, val or 0),
        Wire.fBytes(2, Wire.encLwwClock(counter, tiebreaker), true)
    ))
end

function Wire.encLwwEmpty(counter, tiebreaker)
    return Wire.encodeMessage({
        { 2, 2, Wire.encLwwClock(counter, tiebreaker) },
    })
end

--- Compare float for NaN (`v ~= v`).
function Wire.isNaN(v)
    return v ~= v
end

return Wire
