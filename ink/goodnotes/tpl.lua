--[[
Binary `tpl\x00` (`troydhanson/tpl`) stroke serializer/deserializer for Goodnotes
Formats 1, 2, and 3, plus adaptive polyline flattening and stroke encoding.

Formats supported:
  * Format 1 (`pen_type = 0`): `vuA(v)A(S(uu))A(S(uuuu))vA(f)`
    Ballpoint / Highlighter / Snapped-Shape stub (full width).
  * Format 2 (`pen_type = 1`): `vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)`
    Fountain / Brush (circular nib: centerline halfWidths + tessellated outlines)
    and Study Tape (ops 4, 5, 6 elliptical chisel nib).
  * Format 3 (`pen_type = 5`): `vuA(v)A(S(uuuuu))A(S(uuuuuuuuuuu))A(S(uu))A(v)A(S(uu))A(S(uuuu))A(u)`
    Pencil (base_full_width, per-segment seed, per-vertex pressure + shading params).
]]

local Wire = require("ink/goodnotes/wire")

local Tpl = {}

local byte, sub, concat = string.byte, string.sub, table.concat
local floor, sqrt, abs, sin, cos, atan2, acos = math.floor, math.sqrt, math.abs, math.sin, math.cos, math.atan2, math.acos
local decU16LE, encU16LE = Wire.decU16LE, Wire.encU16LE
local decU32LE, encU32LE = Wire.decU32LE, Wire.encU32LE
local decI32LE, encI32LE = Wire.decI32LE, Wire.encI32LE
local decU64LE, encU64LE = Wire.decU64LE, Wire.encU64LE
local u32ToF32, f32ToU32 = Wire.u32ToF32, Wire.f32ToU32

Tpl.FMT1 = "vuA(v)A(S(uu))A(S(uuuu))vA(f)"
Tpl.FMT2 = "vA(v)A(u)A(u)A(v)A(v)A(u)A(u)A(u)A(u)A(v)"
Tpl.FMT3 = "vuA(v)A(S(uuuuu))A(S(uuuuuuuuuuu))A(S(uu))A(v)A(S(uu))A(S(uuuu))A(u)"

------------------------------------------------------------------------------
-- Generic `tpl\x00` parser & byte-exact encoder
------------------------------------------------------------------------------

local function parseFmt(fmt, pos)
    local nodes = {}
    local p = pos or 1
    local n = #fmt
    while p <= n do
        local c = sub(fmt, p, p)
        if c == ")" then
            return nodes, p + 1
        elseif c == "A" or c == "S" then
            if sub(fmt, p + 1, p + 1) ~= "(" then
                error("Expected '(' after " .. c .. " in TPL format: " .. fmt)
            end
            local sub_nodes, np = parseFmt(fmt, p + 2)
            nodes[#nodes + 1] = { kind = c, sub = sub_nodes }
            p = np
        else
            nodes[#nodes + 1] = { kind = c }
            p = p + 1
        end
    end
    return nodes, p
end

local function readNodes(buf, pos, nodes)
    local vals = {}
    for idx, node in ipairs(nodes) do
        local k = node.kind
        if k == "v" then
            vals[idx] = decU16LE(buf, pos)
            pos = pos + 2
        elseif k == "u" then
            vals[idx] = decU32LE(buf, pos)   -- kept as raw uint32 for lossless NaN/-0.0
            pos = pos + 4
        elseif k == "i" then
            vals[idx] = decI32LE(buf, pos)
            pos = pos + 4
        elseif k == "f" then
            vals[idx] = decU64LE(buf, pos)
            pos = pos + 8
        elseif k == "c" then
            vals[idx] = byte(buf, pos)
            pos = pos + 1
        elseif k == "S" then
            local sv, np = readNodes(buf, pos, node.sub)
            vals[idx] = sv
            pos = np
        elseif k == "A" then
            local cnt = decU32LE(buf, pos)
            pos = pos + 4
            local arr = {}
            local single = (#node.sub == 1)
            for j = 1, cnt do
                local ev, np = readNodes(buf, pos, node.sub)
                arr[j] = single and ev[1] or ev
                pos = np
            end
            vals[idx] = arr
        else
            error("Unsupported TPL type char: " .. tostring(k))
        end
    end
    return vals, pos
end

--- Parse a `tpl\x00` binary buffer into `fmt, raw_values`.
function Tpl.parseRaw(buf)
    if type(buf) ~= "string" or #buf < 10 or sub(buf, 1, 4) ~= "tpl\0" then
        error("Invalid tpl magic header")
    end
    local total_sz = decU32LE(buf, 5)
    if total_sz ~= #buf then
        error(string.format("TPL size mismatch (%d != %d)", total_sz, #buf))
    end
    local nul = buf:find("\0", 9, true)
    if not nul then error("Unterminated TPL format string") end
    local fmt = sub(buf, 9, nul - 1)
    local nodes, endp = parseFmt(fmt, 1)
    if endp ~= #fmt + 1 then error("Unbalanced parentheses in TPL format: " .. fmt) end
    local vals, end_pos = readNodes(buf, nul + 1, nodes)
    if end_pos ~= #buf + 1 then
        error(string.format("Trailing bytes in TPL buffer: %d", #buf + 1 - end_pos))
    end
    return fmt, vals
end

local function writeNodes(out, vals, nodes)
    for idx, node in ipairs(nodes) do
        local v = vals[idx]
        local k = node.kind
        if k == "v" then
            out[#out + 1] = encU16LE(v)
        elseif k == "u" then
            out[#out + 1] = encU32LE(v)
        elseif k == "i" then
            out[#out + 1] = encI32LE(v)
        elseif k == "f" then
            out[#out + 1] = encU64LE(v)
        elseif k == "c" then
            out[#out + 1] = string.char(v % 256)
        elseif k == "S" then
            writeNodes(out, v, node.sub)
        elseif k == "A" then
            local arr = v or {}
            out[#out + 1] = encU32LE(#arr)
            local single_scalar = (#node.sub == 1 and node.sub[1].kind ~= "S")
            if single_scalar then
                for _j, item in ipairs(arr) do
                    writeNodes(out, { item }, node.sub)
                end
            elseif #node.sub == 1 and node.sub[1].kind == "S" then
                for _j, item in ipairs(arr) do
                    -- Inner item is either struct table wrapped once or tuple directly
                    writeNodes(out, { item }, node.sub)
                end
            else
                for _j, item in ipairs(arr) do
                    writeNodes(out, item, node.sub)
                end
            end
        end
    end
end

--- Re-encode `fmt, vals` back into exact `tpl\x00` bytes.
function Tpl.encodeRaw(fmt, vals)
    local nodes, endp = parseFmt(fmt, 1)
    if endp ~= #fmt + 1 then error("Unbalanced parentheses in TPL format: " .. fmt) end
    local body = {}
    writeNodes(body, vals, nodes)
    local payload = concat(body)
    local header_len = 8 + #fmt + 1
    return concat({ "tpl\0", encU32LE(header_len + #payload), fmt, "\0", payload })
end

------------------------------------------------------------------------------
-- Semantic Decoder (Formats 1, 2, 3)
------------------------------------------------------------------------------

--- Decode raw `tpl\x00` bytes into a structured stroke table.
function Tpl.decodeStroke(raw_tpl)
    local fmt, vals = Tpl.parseRaw(raw_tpl)
    if fmt == Tpl.FMT1 then
        local moves, quads = {}, {}
        for i, m in ipairs(vals[4]) do
            moves[i] = { u32ToF32(m[1]), u32ToF32(m[2]) }
        end
        for i, q in ipairs(vals[5]) do
            quads[i] = { u32ToF32(q[1]), u32ToF32(q[2]), u32ToF32(q[3]), u32ToF32(q[4]) }
        end
        return {
            format = 1,
            tpl_format = fmt,
            version = vals[1],
            full_width = u32ToF32(vals[2]),
            ops = vals[3],
            move_points = moves,
            quad_segments = quads,
            cap_flag = vals[6],
        }
    elseif fmt == Tpl.FMT2 then
        local c_ops = vals[2]
        local starts_f, segs_f = {}, {}
        for i, u in ipairs(vals[3]) do starts_f[i] = u32ToF32(u) end
        for i, u in ipairs(vals[4]) do segs_f[i] = u32ToF32(u) end
        local centerline = {}
        local si, qi = 1, 1
        for i, op in ipairs(c_ops) do
            if op == 0 then
                centerline[i] = {
                    op = "moveTo",
                    x = starts_f[si], y = starts_f[si + 1], halfWidth = starts_f[si + 2],
                }
                si = si + 3
            elseif op == 1 then
                centerline[i] = {
                    op = "quadTo",
                    cx = segs_f[qi], cy = segs_f[qi + 1], cHalfWidth = segs_f[qi + 2],
                    ex = segs_f[qi + 3], ey = segs_f[qi + 4], eHalfWidth = segs_f[qi + 5],
                }
                qi = qi + 6
            elseif op == 4 then
                centerline[i] = {
                    op = "ellipticalMoveTo",
                    x = starts_f[si], y = starts_f[si + 1],
                    majorR = starts_f[si + 2], angle = starts_f[si + 3],
                }
                si = si + 4
            elseif op == 5 then
                centerline[i] = {
                    op = "ellipticalQuadTo",
                    cx = segs_f[qi], cy = segs_f[qi + 1], cMajorR = segs_f[qi + 2],
                    ex = segs_f[qi + 3], ey = segs_f[qi + 4], eMajorR = segs_f[qi + 5],
                    cAngle = segs_f[qi + 6], eAngle = segs_f[qi + 7], flatness = segs_f[qi + 8],
                }
                qi = qi + 9
            end
        end
        return {
            format = 2,
            tpl_format = fmt,
            version = vals[1],
            centerline_ops = c_ops,
            centerline = centerline,
        }
    elseif fmt == Tpl.FMT3 then
        local moves, quads = {}, {}
        for i, s in ipairs(vals[4]) do
            moves[i] = {
                x = u32ToF32(s[1]), y = u32ToF32(s[2]),
                paramA = u32ToF32(s[3]), paramB = u32ToF32(s[4]),
                pressure = u32ToF32(s[5]),
            }
        end
        for i, q in ipairs(vals[5]) do
            quads[i] = {
                seed_u32 = q[1],
                cx = u32ToF32(q[2]), cy = u32ToF32(q[3]),
                cParamA = u32ToF32(q[4]), cParamB = u32ToF32(q[5]), cPressure = u32ToF32(q[6]),
                ex = u32ToF32(q[7]), ey = u32ToF32(q[8]),
                eParamA = u32ToF32(q[9]), eParamB = u32ToF32(q[10]), ePressure = u32ToF32(q[11]),
            }
        end
        return {
            format = 3,
            tpl_format = fmt,
            version = vals[1],
            base_full_width = u32ToF32(vals[2]),
            ops = vals[3],
            move_points = moves,
            quad_segments = quads,
        }
    end
    return { format = 0, tpl_format = fmt }
end

------------------------------------------------------------------------------
-- Adaptive Quadratic Bezier Flattening -> Ink Away Polylines + Pressures
------------------------------------------------------------------------------

local function quadFlatSubdiv(pts, pr, x0, y0, w0, cx, cy, cw, x1, y1, w1, ox, oy)
    -- Estimate flatness by midpoint deviation from chord
    local mx = (x0 + 2 * cx + x1) * 0.25
    local my = (y0 + 2 * cy + y1) * 0.25
    local lx = (x0 + x1) * 0.5
    local ly = (y0 + y1) * 0.5
    local err = sqrt((mx - lx) * (mx - lx) + (my - ly) * (my - ly))
    local chord = sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))
    local steps = math.max(1, math.min(16, math.ceil(math.max(err * 2.0, chord / 10.0))))
    for s = 1, steps do
        local t = s / steps
        local mt = 1 - t
        local a, b, c = mt * mt, 2 * mt * t, t * t
        pts[#pts + 1] = a * x0 + b * cx + c * x1 + ox
        pts[#pts + 1] = a * y0 + b * cy + c * y1 + oy
        if pr and w0 and cw and w1 then
            pr[#pr + 1] = a * w0 + b * cw + c * w1
        end
    end
end

--- Convert decoded TPL into Ink Away `{ pts = {x1,y1,...}, pr = {0..255,...}|nil, width = px, max_width = px }`.
--- Optional `ox, oy` adds an offset to every point before returning (used for sticky note child ink).
function Tpl.toPolyline(dec, ox, oy)
    ox, oy = ox or 0, oy or 0
    local pts = {}
    if dec.format == 1 then
        local mi, qi = 1, 1
        local px, py = 0, 0
        for _i, op in ipairs(dec.ops or {}) do
            if op == 0 then
                local mp = dec.move_points[mi]
                mi = mi + 1
                if mp then
                    px, py = mp[1], mp[2]
                    pts[#pts + 1] = px + ox
                    pts[#pts + 1] = py + oy
                end
            elseif op == 1 then
                local q = dec.quad_segments[qi]
                qi = qi + 1
                if q then
                    quadFlatSubdiv(pts, nil, px, py, nil, q[1], q[2], nil, q[3], q[4], nil, ox, oy)
                    px, py = q[3], q[4]
                end
            end
        end
        return { pts = pts, width = dec.full_width or 2.0 }
    elseif dec.format == 2 then
        local raw_r = {}
        local px, py, pr_cur = 0, 0, 1.0
        local max_r = 0.0
        for _i, cmd in ipairs(dec.centerline or {}) do
            if cmd.op == "moveTo" or cmd.op == "ellipticalMoveTo" then
                local r = cmd.halfWidth or cmd.majorR or 1.0
                if r > max_r then max_r = r end
                px, py, pr_cur = cmd.x, cmd.y, r
                pts[#pts + 1] = px + ox
                pts[#pts + 1] = py + oy
                raw_r[#raw_r + 1] = r
            elseif cmd.op == "quadTo" then
                local cr, er = cmd.cHalfWidth or pr_cur, cmd.eHalfWidth or pr_cur
                if cr > max_r then max_r = cr end
                if er > max_r then max_r = er end
                quadFlatSubdiv(pts, raw_r, px, py, pr_cur, cmd.cx, cmd.cy, cr, cmd.ex, cmd.ey, er, ox, oy)
                px, py, pr_cur = cmd.ex, cmd.ey, er
            elseif cmd.op == "ellipticalQuadTo" then
                local cr, er = cmd.cMajorR or pr_cur, cmd.eMajorR or pr_cur
                if cr > max_r then max_r = cr end
                if er > max_r then max_r = er end
                quadFlatSubdiv(pts, raw_r, px, py, pr_cur, cmd.cx, cmd.cy, cr, cmd.ex, cmd.ey, er, ox, oy)
                px, py, pr_cur = cmd.ex, cmd.ey, er
            end
        end
        local max_w = max_r * 2.0
        if max_w < 0.5 then max_w = 2.0 end
        local pr_u8 = {}
        -- Invert Ink Away's ballpoint pressure curve `factor = minf + (1 - minf) * p / 255` (`minf = 0.5`)
        -- using `ref_w = max_w` when strokes modulate strongly, clamped cleanly into 0..255.
        for i, r in ipairs(raw_r) do
            local ratio = (r * 2.0) / max_w
            local p = ((ratio - 0.5) / 0.5) * 255
            if p < 1 then p = 1 elseif p > 255 then p = 255 end
            pr_u8[i] = floor(p + 0.5)
        end
        return { pts = pts, pr = (#pr_u8 > 0) and pr_u8 or nil, width = max_w }
    elseif dec.format == 3 then
        local raw_p = {}
        local px, py, pp = 0, 0, 1.0
        local mi, qi = 1, 1
        for _i, op in ipairs(dec.ops or {}) do
            if op == 0 then
                local mp = dec.move_points[mi]
                mi = mi + 1
                if mp then
                    px, py, pp = mp.x, mp.y, mp.pressure or 1.0
                    pts[#pts + 1] = px + ox
                    pts[#pts + 1] = py + oy
                    raw_p[#raw_p + 1] = pp
                end
            elseif op == 1 then
                local q = dec.quad_segments[qi]
                qi = qi + 1
                if q then
                    quadFlatSubdiv(pts, raw_p, px, py, pp,
                        q.cx, q.cy, q.cPressure or pp,
                        q.ex, q.ey, q.ePressure or pp, ox, oy)
                    px, py, pp = q.ex, q.ey, q.ePressure or pp
                end
            end
        end
        local pr_u8 = {}
        for i, p in ipairs(raw_p) do
            local v = floor(p * 255 + 0.5)
            if v < 0 then v = 0 elseif v > 255 then v = 255 end
            pr_u8[i] = v
        end
        local seed = dec.quad_segments[1] and dec.quad_segments[1].seed_u32 or nil
        return { pts = pts, pr = (#pr_u8 > 0) and pr_u8 or nil, width = dec.base_full_width or 2.0, seed = seed }
    end
    return { pts = pts, width = 2.0 }
end

------------------------------------------------------------------------------
-- Encoders (Formats 1, 2, 3) from Ink Away polylines
------------------------------------------------------------------------------

local function midpointQuads(pts, vals_opt, default_v)
    local n = floor(#pts / 2)
    if n <= 0 then return {}, {}, {} end
    local ops = { 0 }
    local x0, y0 = pts[1], pts[2]
    local v0 = vals_opt and vals_opt[1] or default_v
    if n == 1 then
        return ops, { { x0, y0, v0 } }, {}
    end
    local quads = {}
    if n == 2 then
        local x1, y1 = pts[3], pts[4]
        local v1 = vals_opt and vals_opt[2] or default_v
        ops[2] = 1
        quads[1] = { (x0 + x1) * 0.5, (y0 + y1) * 0.5, (v0 + v1) * 0.5, x1, y1, v1 }
        return ops, { { x0, y0, v0 } }, quads
    end
    for i = 2, n - 1 do
        local cx, cy = pts[2 * i - 1], pts[2 * i]
        local cv = vals_opt and vals_opt[i] or default_v
        local nx, ny = pts[2 * i + 1], pts[2 * i + 2]
        local nv = vals_opt and vals_opt[i + 1] or default_v
        local ex, ey, ev
        if i == n - 1 then
            ex, ey, ev = nx, ny, nv
        else
            ex, ey, ev = (cx + nx) * 0.5, (cy + ny) * 0.5, (cv + nv) * 0.5
        end
        ops[#ops + 1] = 1
        quads[#quads + 1] = { cx, cy, cv, ex, ey, ev }
    end
    return ops, { { x0, y0, v0 } }, quads
end

--- Encode Format 1 TPL (Ballpoint / Highlighter / Snapped-Shape stub).
--- Pass empty `pts = {}` for a SnappedShape stub.
function Tpl.encodeFormat1(pts, full_width, scale)
    local s = scale or 1.0
    local scaled = {}
    for i = 1, #pts do scaled[i] = pts[i] * s end
    local ops, moves_raw, quads_raw = midpointQuads(scaled, nil, 1.0)
    local moves = {}
    for i, m in ipairs(moves_raw) do
        moves[i] = { f32ToU32(m[1]), f32ToU32(m[2]) }
    end
    local quads = {}
    for i, q in ipairs(quads_raw) do
        quads[i] = { f32ToU32(q[1]), f32ToU32(q[2]), f32ToU32(q[4]), f32ToU32(q[5]) }
    end
    return Tpl.encodeRaw(Tpl.FMT1, {
        2, f32ToU32((full_width or 2.0) * s), ops, moves, quads, 1, {},
    })
end

--- Emit CoreGraphics Y-up (`clockwise = 1`, decreasing angle in Y-down screen space) capsule outline
--- for circle `(x0, y0, r0)` -> `(x1, y1, r1)` into Format 2 outline arrays.
local function appendCircleOutline(sub_counts, o_ops, o_moves, o_arcs, o_arc_cw, cx, cy, r)
    sub_counts[#sub_counts + 1] = 3
    o_ops[#o_ops + 1] = 0
    o_moves[#o_moves + 1] = f32ToU32(cx + r)
    o_moves[#o_moves + 1] = f32ToU32(cy)
    -- Two 180-deg arcs with `cw = 1` (angle decreasing from 0 -> -pi -> -2pi)
    for _half = 1, 2 do
        local a0 = _half == 1 and 0.0 or -math.pi
        local a1 = _half == 1 and -math.pi or -2.0 * math.pi
        o_ops[#o_ops + 1] = 3
        o_arcs[#o_arcs + 1] = f32ToU32(cx)
        o_arcs[#o_arcs + 1] = f32ToU32(cy)
        o_arcs[#o_arcs + 1] = f32ToU32(r)
        o_arcs[#o_arcs + 1] = f32ToU32(a0)
        o_arcs[#o_arcs + 1] = f32ToU32(a1)
        o_arc_cw[#o_arc_cw + 1] = 1
    end
end

local function appendCapsuleOutline(sub_counts, o_ops, o_moves, o_lines, o_arcs, o_arc_cw, x0, y0, r0, x1, y1, r1)
    local dx, dy = x1 - x0, y1 - y0
    local d = sqrt(dx * dx + dy * dy)
    if d <= abs(r1 - r0) + 1e-4 then
        if r0 >= r1 then
            appendCircleOutline(sub_counts, o_ops, o_moves, o_arcs, o_arc_cw, x0, y0, r0)
        else
            appendCircleOutline(sub_counts, o_ops, o_moves, o_arcs, o_arc_cw, x1, y1, r1)
        end
        return
    end
    local sin_b = (r0 - r1) / d
    if sin_b > 1.0 then sin_b = 1.0 elseif sin_b < -1.0 then sin_b = -1.0 end
    local alpha = acos(sin_b)
    local theta = atan2(dy, dx)
    local top_a = theta - alpha
    local bot_a = theta + alpha
    local bot_back_a = bot_a - 2.0 * math.pi

    local mx = x0 + r0 * cos(top_a)
    local my = y0 + r0 * sin(top_a)
    local bx1 = x1 + r1 * cos(bot_a)
    local by1 = y1 + r1 * sin(bot_a)

    sub_counts[#sub_counts + 1] = 5
    -- 1. moveTo top tangent on C0
    o_ops[#o_ops + 1] = 0
    o_moves[#o_moves + 1] = f32ToU32(mx)
    o_moves[#o_moves + 1] = f32ToU32(my)
    -- 2. arc back of C0 (top_a down to bot_a - 2*pi, cw = 1)
    o_ops[#o_ops + 1] = 3
    o_arcs[#o_arcs + 1] = f32ToU32(x0); o_arcs[#o_arcs + 1] = f32ToU32(y0); o_arcs[#o_arcs + 1] = f32ToU32(r0)
    o_arcs[#o_arcs + 1] = f32ToU32(top_a); o_arcs[#o_arcs + 1] = f32ToU32(bot_back_a)
    o_arc_cw[#o_arc_cw + 1] = 1
    -- 3. lineTo bottom tangent on C1
    o_ops[#o_ops + 1] = 1
    o_lines[#o_lines + 1] = f32ToU32(bx1)
    o_lines[#o_lines + 1] = f32ToU32(by1)
    -- 4. arc front of C1 (bot_a down to top_a, cw = 1)
    o_ops[#o_ops + 1] = 3
    o_arcs[#o_arcs + 1] = f32ToU32(x1); o_arcs[#o_arcs + 1] = f32ToU32(y1); o_arcs[#o_arcs + 1] = f32ToU32(r1)
    o_arcs[#o_arcs + 1] = f32ToU32(bot_a); o_arcs[#o_arcs + 1] = f32ToU32(top_a)
    o_arc_cw[#o_arc_cw + 1] = 1
    -- 5. lineTo back to top tangent on C0
    o_ops[#o_ops + 1] = 1
    o_lines[#o_lines + 1] = f32ToU32(mx)
    o_lines[#o_lines + 1] = f32ToU32(my)
end

--- Encode Format 2 TPL (Fountain / Brush circular variable-width pen).
--- `half_widths` holds per-point half-width radii in target Goodnotes coordinates.
function Tpl.encodeFormat2(pts, half_widths, default_r, scale)
    local s = scale or 1.0
    local dr = (default_r or 1.0) * s
    local n = floor(#pts / 2)
    if n == 0 then
        return Tpl.encodeRaw(Tpl.FMT2, { 2, {}, {}, {}, {}, {}, {}, {}, {}, {}, {} })
    end
    local scaled, radii = {}, {}
    for i = 1, n do
        scaled[2 * i - 1] = pts[2 * i - 1] * s
        scaled[2 * i] = pts[2 * i] * s
        local r = (half_widths and half_widths[i]) and (half_widths[i] * s) or dr
        if r < 0.2 then r = 0.2 end
        radii[i] = r
    end

    local ops, moves_raw, quads_raw = midpointQuads(scaled, radii, dr)
    local starts_u, segs_u = {}, {}
    for _i, m in ipairs(moves_raw) do
        starts_u[#starts_u + 1] = f32ToU32(m[1])
        starts_u[#starts_u + 1] = f32ToU32(m[2])
        starts_u[#starts_u + 1] = f32ToU32(m[3])
    end
    for _i, q in ipairs(quads_raw) do
        segs_u[#segs_u + 1] = f32ToU32(q[1]); segs_u[#segs_u + 1] = f32ToU32(q[2]); segs_u[#segs_u + 1] = f32ToU32(q[3])
        segs_u[#segs_u + 1] = f32ToU32(q[4]); segs_u[#segs_u + 1] = f32ToU32(q[5]); segs_u[#segs_u + 1] = f32ToU32(q[6])
    end

    -- Build tessellated capsule outlines from flattened centerline points so Goodnotes renders exact widths.
    local sub_counts, o_ops, o_moves, o_lines, o_cubics, o_arcs, o_arc_cw = {}, {}, {}, {}, {}, {}, {}
    if n == 1 then
        appendCircleOutline(sub_counts, o_ops, o_moves, o_arcs, o_arc_cw, scaled[1], scaled[2], radii[1])
    else
        for i = 1, n - 1 do
            appendCapsuleOutline(
                sub_counts, o_ops, o_moves, o_lines, o_arcs, o_arc_cw,
                scaled[2 * i - 1], scaled[2 * i], radii[i],
                scaled[2 * i + 1], scaled[2 * i + 2], radii[i + 1]
            )
        end
    end

    return Tpl.encodeRaw(Tpl.FMT2, {
        2, ops, starts_u, segs_u, sub_counts, o_ops, o_moves, o_lines, o_cubics, o_arcs, o_arc_cw,
    })
end

--- Encode Format 3 TPL (Pencil with per-vertex pressure `0.0..1.0`).
function Tpl.encodeFormat3(pts, pressures_01, base_width, seed, scale)
    local s = scale or 1.0
    local n = floor(#pts / 2)
    local param_a = f32ToU32(0.805732)
    local param_b = f32ToU32(0.814237)
    if n == 0 then
        return Tpl.encodeRaw(Tpl.FMT3, {
            1, f32ToU32((base_width or 2.0) * s), {}, {}, {}, {}, {}, {}, {}, {},
        })
    end
    local scaled, pr = {}, {}
    for i = 1, n do
        scaled[2 * i - 1] = pts[2 * i - 1] * s
        scaled[2 * i] = pts[2 * i] * s
        pr[i] = pressures_01 and pressures_01[i] or 0.75
    end
    local ops, moves_raw, quads_raw = midpointQuads(scaled, pr, 0.75)
    local moves, quads = {}, {}
    for i, m in ipairs(moves_raw) do
        moves[i] = { f32ToU32(m[1]), f32ToU32(m[2]), param_a, param_b, f32ToU32(m[3]) }
    end
    local cur_seed = seed or Wire.randomU32()
    for i, q in ipairs(quads_raw) do
        cur_seed = (cur_seed * 1664525 + 1013904223) % 4294967296
        quads[i] = {
            cur_seed,
            f32ToU32(q[1]), f32ToU32(q[2]), param_a, param_b, f32ToU32(q[3]),
            f32ToU32(q[4]), f32ToU32(q[5]), param_a, param_b, f32ToU32(q[6]),
        }
    end
    return Tpl.encodeRaw(Tpl.FMT3, {
        1, f32ToU32((base_width or 2.0) * s), ops, moves, quads, {}, {}, {}, {}, {},
    })
end

return Tpl
