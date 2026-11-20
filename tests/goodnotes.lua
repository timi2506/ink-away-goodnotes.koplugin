-- Core `.goodnotes` codec, CRDT mapper, archive patcher, Project/Library/Notebook/
-- Trash/Search/Sync integration tests.
-- Run from plugin root with:  luajit tests/goodnotes.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local testenv = require("testenv")
local Wire = require("ink/goodnotes/wire")
local Zip = require("ink/goodnotes/zip")
local LZ4 = require("ink/goodnotes/lz4")
local Tpl = require("ink/goodnotes/tpl")
local RichText = require("ink/goodnotes/richtext")
local PdfGen = require("ink/goodnotes/pdfgen")
local PdfRecolor = require("ink/goodnotes/pdfrecolor")
local Mapper = require("ink/goodnotes/mapper")
local GNDoc = require("ink/goodnotes/document")
local GNTemplates = require("ink/goodnotes/templates")
local Project = require("ink/project")
local Library = require("ink/library")
local Notebook = require("ink/notebook")
local Trash = require("ink/trash")
local Search = require("ink/search")
local Storage = require("ink/storage")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local tmpdir = io.popen("mktemp -d"):read("*l")
local function rmTmp()
    os.execute("rm -rf '" .. tmpdir .. "'")
end

-- 1. Wire & UUID math
do
    local u = "68CFA805-47CB-4196-96F3-FAFBAC24A667"
    local up1 = Wire.uuidPlusOne(u)
    ok(up1 == "68CFA805-47CB-4196-96F3-FAFBAC24A668", "uuidPlusOne increments low byte")
    ok(Wire.uuidMinusOne(up1) == u, "uuidMinusOne reverses uuidPlusOne")

    local carry = "00000000-0000-0000-0000-0000000000FF"
    ok(Wire.uuidPlusOne(carry) == "00000000-0000-0000-0000-000000000100", "uuidPlusOne byte carry")

    local k1 = Wire.orderKeyBetween(nil, nil)
    local k2 = Wire.orderKeyBetween(k1, nil)
    local k_mid = Wire.orderKeyBetween(k1, k2)
    ok(k1 < k_mid and k_mid < k2, "orderKeyBetween maintains strict lexicographic order")

    local v = Wire.encodeVarint(123456789012345ULL)
    local dv = Wire.decodeVarintU64(v, 1)
    ok(Wire.u64ToDec(dv) == "123456789012345", "64-bit unsigned varint round-trip")
end

-- 2. LZ4 + TPL + Zip
do
    local pts = { 10, 20, 50, 80, 120, 130, 200, 260 }
    local raw_tpl = Tpl.encodeFormat1(pts, 3.0, 1.0)
    local comp = LZ4.compress(raw_tpl)
    ok(comp:sub(1, 4) == "bv41", "LZ4 writes bv41 header")
    ok(LZ4.decompress(comp) == raw_tpl, "LZ4 decompress round-trip")
    local fmt, vals = Tpl.parseRaw(raw_tpl)
    ok(Tpl.encodeRaw(fmt, vals) == raw_tpl, "TPL raw AST round-trip")

    local zpath = tmpdir .. "/test.zip"
    local w_ok = Zip.write(zpath, { ["a.txt"] = "hello world", ["sub/b.bin"] = string.rep("\1\2\3", 500) })
    ok(w_ok, "Zip.write succeeds")
    local arc = Zip.open(zpath)
    ok(arc and arc:read("a.txt") == "hello world", "Zip.open reads small entry")
    ok(arc and arc:read("sub/b.bin") == string.rep("\1\2\3", 500), "Zip.open reads deflated entry")
    if arc then arc:close() end

    local zpatch = tmpdir .. "/patched.zip"
    ok(Zip.patch(zpath, zpatch, { ["a.txt"] = "updated", ["new.txt"] = "added" }, { ["sub/b.bin"] = true }),
        "Zip.patch updates, adds and removes entries")
    local parc = Zip.open(zpatch)
    ok(parc and parc:read("a.txt") == "updated" and parc:read("new.txt") == "added" and not parc:has("sub/b.bin"),
        "Zip.patch result verified")
    if parc then parc:close() end
end

-- 3. RichText + PdfGen + Mapper
do
    local op = { kind = "text", x = 40, y = 60, w = 220, h = 44, size = 18, align = "center",
        paras = { { spans = { { t = "Heading", c = 0x0A141E } } } } }
    local rt_bytes = RichText.encode(op, { scale = 1.0 })
    local rt = RichText.decode(rt_bytes)
    ok(rt and rt.plain_text == "Heading", "RichText encode/decode plain text")
    local paras, align = RichText.toInkParas(rt, 18)
    ok(align == "center" and paras and paras[1] and paras[1].spans[1].t == "Heading"
        and paras[1].spans[1].c == 0x0A141E, "RichText preserves text, color and alignment")

    local pdf_bytes = PdfGen.buildTemplatePDF(595.28, 841.89, "lines", 28, 45)
    ok(pdf_bytes:sub(1, 5) == "%PDF-" and pdf_bytes:find("%%EOF", 1, true) ~= nil, "PdfGen creates valid PDF")

    local png_bytes = PdfGen.encodeFillPNG({ runs = { 0, 0, 8, 0, 1, 8 }, color = { 255, 0, 128 }, alpha = 200 }, 100, 100)
    ok(png_bytes and png_bytes:sub(1, 8) == "\137PNG\r\n\26\n", "PdfGen encodes valid PNG fill")

    local layer_ops = {
        { kind = "ink", color = { 255, 0, 0 }, width = 3, pts = { 10, 20, 40, 60, 80, 90 } },
        { kind = "ink", style = "highlighter", color = { 255, 255, 0 }, alpha = 128, width = 18, pts = { 20, 30, 120, 30 } },
        op,
    }
    local enc = Mapper.toNoteLayer(layer_ops, nil, { scale = 1.0, canvas_w = 600, canvas_h = 800, replica_id = "111" })
    ok(enc and #enc.bytes > 0 and enc.changed, "Mapper encodes Ink Away ops to NoteLayer")
    local rt_ops, rt_meta = Mapper.fromNoteLayer(enc.bytes)
    ok(#rt_ops == 3 and rt_ops[1]._gn and rt_ops[2].style == "highlighter" and rt_ops[3].kind == "text",
        "Mapper decodes strokes, highlighter and text back")
    local enc_same = Mapper.toNoteLayer(rt_ops, rt_meta, { scale = 1.0, canvas_w = 600, canvas_h = 800, replica_id = "111" })
    ok(not enc_same.changed, "Untouched decoded ops report changed=false for zero-reencode saves")
end

-- 4. Full Goodnotes document lifecycle (export -> load -> edit -> save -> duplicate -> trash -> search)
do
    local nb_src = Notebook.new(800, 1000, { style = "lines", size = 40, strength = 45, paper = { 255, 255, 255 } })
    nb_src.pages[1].ops = {
        { kind = "ink", color = { 0, 0, 255 }, width = 3, pts = { 40, 40, 120, 120 } },
        { kind = "text", x = 60, y = 100, w = 240, h = 40, size = 18,
          paras = { { spans = { { t = "Hello Goodnotes Search" } } } } },
    }
    nb_src:addPage()
    nb_src.pages[2].ops = {
        { kind = "shape", shape = "rect", pts = { 50, 50, 180, 160 }, width = 2, color = { 0, 0, 0 },
          fill_color = { 255, 220, 180 }, fill_alpha = 200 },
    }

    local gn_path = tmpdir .. "/Sample.goodnotes"
    local ok_save, serr = Project.saveNotebook(nb_src, gn_path, nil, { replica_id = "424242" })
    ok(ok_save, "Project.saveNotebook writes .goodnotes: " .. tostring(serr))
    ok(Project.isGoodnotes(gn_path) and Library.isDocument("Sample.goodnotes")
        and Library.isNotebookFile(gn_path), "Project & Library recognize .goodnotes")
    ok(GNDoc.validate(gn_path), "GNDoc.validate passes on created .goodnotes")

    local insp0 = GNDoc.inspect(gn_path)
    ok(insp0 and insp0.page_count == 2 and insp0.document_id ~= "", "GNDoc.inspect reads manifest")

    local loaded = Project.load(gn_path)
    ok(loaded and Project.isNotebook(loaded) and #loaded.pages == 2, "Project.load opens .goodnotes")
    ok(loaded.pages[2].ops[1] and loaded.pages[2].ops[1].fill_color ~= nil, "Loaded shape retains fill_color")

    local nb = Notebook.fromData(loaded)
    ok(nb:isGoodnotes() and nb:hasAnyPdf() and nb:pagePdf(1) ~= nil, "Notebook detects Goodnotes & PDF templates")

    -- Add stroke, delete an op (tombstone), add page, duplicate page
    table.insert(nb.pages[1].ops, { kind = "ink", color = { 0, 128, 0 }, width = 2.5, pts = { 200, 200, 300, 250 } })
    table.remove(nb.pages[1].ops, 1)   -- erase original blue stroke -> CRDT tombstone
    nb.index = 1
    nb:addPage()                        -- builtin template inherited cleanly without _gn
    nb:duplicatePage()

    ok(Project.saveNotebook(nb, gn_path, nil, { replica_id = "424242" }), "Incremental edit & save succeeds")
    ok(GNDoc.validate(gn_path), "Edited .goodnotes passes validate")

    local reloaded = Notebook.fromData(assert(Project.load(gn_path)))
    ok(reloaded:count() == 4, "Edited .goodnotes has 4 pages after add+duplicate")
    ok(#reloaded.pages[1].ops == 2 and reloaded.pages[1].ops[1].kind == "text", "Page 1 kept text + added green stroke and tombstoned blue stroke")

    -- Library duplicate gives fresh document_id
    local dup_path = Library.duplicate(gn_path, tmpdir)
    ok(dup_path and Project.isGoodnotes(dup_path), "Library.duplicate keeps .goodnotes extension")
    local insp_dup = GNDoc.inspect(dup_path)
    ok(insp_dup and insp_dup.document_id ~= insp0.document_id, "Duplicated .goodnotes gets new document_id")

    -- Search integration: quick skip vs full inside search
    local fast_rec = Search.readDocument(gn_path, false)
    ok(fast_rec and fast_rec.nb and fast_rec.full == false, "Search fast pass skips binary ZIP decompression")
    local full_rec = Search.readDocument(gn_path, true)
    ok(full_rec and full_rec.full and full_rec.pages[1] and full_rec.pages[1].x:find("Hello Goodnotes Search", 1, true),
        "Search inside indexes typed text in Goodnotes documents")

    -- Trash integration: retains .goodnotes extension on delete & restore
    local titem = Trash.putDocument(tmpdir, dup_path, true)
    ok(titem and titem.ext == "goodnotes" and not Storage.exists(dup_path), "Trash.putDocument moves .goodnotes")
    local rpath = Trash.restore(tmpdir, titem.id)
    ok(rpath and Project.isGoodnotes(rpath) and Storage.exists(rpath), "Trash.restore brings back .goodnotes")
end

-- 5. Optional real-device Goodnotes fixture verification (Test.goodnotes if present locally)
do
    local real_fixture = "/Users/timi2506/Downloads/kindle/KindleGoodnotes/Test.goodnotes"
    if Storage.exists(real_fixture) then
        local info = GNDoc.inspect(real_fixture)
        ok(info and info.document_id == "68CFA805-47CB-4196-96F3-FAFBAC24A667" and info.page_count == 4,
            "Test.goodnotes manifest matches expected doc UUID and 4 pages")
        local data = GNDoc.load(real_fixture)
        ok(data and #data.pages == 4, "Test.goodnotes loads all 4 pages")
        ok(data.pages[1].w == 1091 and data.pages[4].w == 1122, "Test.goodnotes keeps per-page A4 & US Letter sizes")
        ok(#data.pages[1].ops == 1 and #data.pages[2].ops >= 120 and #data.pages[3].ops >= 25,
            "Test.goodnotes maps page strokes, shapes, sticky notes & text")
        local cp = tmpdir .. "/Test_edit.goodnotes"
        ok(GNDoc.save(data, cp, { replica_id = "9999" }), "Test.goodnotes untouched save succeeds")
        ok(GNDoc.validate(cp), "Saved Test.goodnotes passes validation")
    end
end

    -- 6. zlib + PdfRecolor + Goodnotes bundled templates + template packs
    do
        local payload = string.rep("Hello Goodnotes zlib stream! ", 40)
        local z = Zip.zlibCompress(payload)
        ok(Zip.zlibDecompress(z) == payload, "Zip.zlibCompress/zlibDecompress round-trip")

        local lib_dir = tmpdir .. "/tpl_lib"
        local b_list = GNTemplates.list(lib_dir)
        ok(#b_list == 6, "GNTemplates bundles 6 Goodnotes templates")

        local seen_names = {}
        for _i, tpl in ipairs(b_list) do
            seen_names[tpl.name] = true
            local raw_pdf = assert(io.open(tpl.pdf_path, "rb")):read("*a")
            local insp = PdfRecolor.inspect(raw_pdf)
            ok(insp.recolorable and insp.orig_theme == "dark", "Bundled template " .. tpl.name .. " is recolorable dark")

            for _c, target_color in ipairs({ "white", "yellow" }) do
                local rec_pdf, changed = PdfRecolor.recolor(raw_pdf, target_color)
                local rec_insp = PdfRecolor.inspect(rec_pdf)
                ok(changed and rec_insp.orig_theme == target_color,
                    tpl.name .. " recolors cleanly to " .. target_color)
                -- Check classic xref pointer integrity
                local sx = tonumber(rec_pdf:match("startxref%s+(%d+)"))
                ok(sx and rec_pdf:sub(sx + 1, sx + 4) == "xref",
                    tpl.name .. " (" .. target_color .. ") has exact startxref offset")
            end
        end
        ok(seen_names["Dotted"] and seen_names["Grid"] and seen_names["Blank"]
            and seen_names["Ruled Narrow"] and seen_names["Ruled Wide"] and seen_names["Music"],
            "All 6 expected bundled template names present")

        -- Create notebook from Grid in White & Dotted in Yellow, save, edit, reload
        local grid_tpl = assert(GNTemplates.find(lib_dir, "gn_grid"))
        local mat_white = GNTemplates.materialize(grid_tpl, "white")
        ok(mat_white.paper_theme == 1 and mat_white.paper_rgb == nil, "Materialized White grid sets light theme")
        local tpl_doc = tmpdir .. "/FromGridWhite.goodnotes"
        ok(GNDoc.newFromTemplate(mat_white, tpl_doc, { replica_id = "8888" }), "GNDoc.newFromTemplate succeeds")
        ok(GNDoc.validate(tpl_doc), "New notebook from template passes validate")

        -- Change page 1's template to Music (Yellow) & add page 2 from Dotted (Dark)
        local loaded_tpl_nb = Notebook.fromData(assert(Project.load(tpl_doc)))
        local music_mat = GNTemplates.materialize(assert(GNTemplates.find(lib_dir, "gn_music")), "yellow")
        loaded_tpl_nb.pages[1]._gn_tpl_spec = music_mat
        loaded_tpl_nb.pages[1].pdf_path = music_mat.pdf_path
        loaded_tpl_nb.pages[1]._gn_paper_rgb = music_mat.paper_rgb
        loaded_tpl_nb.pages[1]._gn_template_id = nil
        local dotted_mat = GNTemplates.materialize(assert(GNTemplates.find(lib_dir, "gn_dotted")), "dark")
        local pg2 = loaded_tpl_nb:newPage(1)
        pg2.pdf_path = dotted_mat.pdf_path
        pg2.w, pg2.h = dotted_mat.w, dotted_mat.h
        pg2._gn_paper_rgb = dotted_mat.paper_rgb
        pg2._gn_builtin_tpl = true
        pg2._gn_tpl_spec = dotted_mat
        loaded_tpl_nb.pages[2] = pg2
        ok(Project.saveNotebook(loaded_tpl_nb, tpl_doc, nil, { replica_id = "8888" }),
            "Changed/added Goodnotes templates save cleanly")
        local rt_tpl_nb = assert(Project.load(tpl_doc))
        local p1_pdf = assert(io.open(rt_tpl_nb.pages[1].pdf_path, "rb")):read("*a")
        local p2_pdf = assert(io.open(rt_tpl_nb.pages[2].pdf_path, "rb")):read("*a")
        ok(#rt_tpl_nb.pages == 2
            and PdfRecolor.inspect(p1_pdf).orig_theme == "yellow"
            and PdfRecolor.inspect(p2_pdf).orig_theme == "dark"
            and rt_tpl_nb.pages[2]._gn_paper_rgb ~= nil,
            "Reloaded notebook retains both Yellow Music and Dark Dotted page themes")

        -- Pack importer: dedups bundled pack & imports custom pack
        local pack_fixture = "/Users/timi2506/Downloads/Template.goodnotes"
        if Storage.exists(pack_fixture) then
            local a1, s1 = GNTemplates.importPack(pack_fixture, lib_dir)
            ok(a1 == 0 and s1 == 6, "Importing Template.goodnotes skips 6 already-bundled templates")
        end
        local a2, s2 = GNTemplates.importPack(tpl_doc, lib_dir)
        ok(a2 and a2 >= 1, "Importing custom template pack adds distinct user templates: " .. tostring(a2))
        local a3 = GNTemplates.importPack(tpl_doc, lib_dir)
        ok(a3 == 0, "Re-importing same template pack skips duplicates")
        local ulist = GNTemplates.list(lib_dir)
        ok(#ulist == 6 + a2, "User templates appear alongside bundled templates")
        local removed_custom = 0
        for _i, t in ipairs(ulist) do
            if not t.bundled and GNTemplates.remove(lib_dir, t.id) then removed_custom = removed_custom + 1 end
        end
        ok(removed_custom == a2 and #GNTemplates.list(lib_dir) == 6, "GNTemplates.remove cleans up user templates only")
    end

rmTmp()
print(("goodnotes: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
