-- View-level integration tests for `.goodnotes` import, editing, saving,
-- renaming, exporting (both notebooks and drawings) and Wi-Fi HTTP/receive wiring.
-- Run from plugin root with:  luajit tests/goodnotes_view.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local UIManager = require("ui/uimanager")
local Notebook = require("ink/notebook")
local Project = require("ink/project")
local Storage = require("ink/storage")
local GNDoc = require("ink/goodnotes/document")
local Http = require("ink/share/http")
local Page = require("ink/share/page")

_G.G_reader_settings = {
    data = require("testenv").settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local tmpdir = io.popen("mktemp -d"):read("*l")
local InkAwayView = require("ink/view")

local function newView()
    local view = InkAwayView:new{ modal = true }
    UIManager:show(view)
    return view
end

do
    local view = newView()
    local rid1 = view:goodnotesReplicaId()
    local rid2 = view:goodnotesReplicaId()
    ok(type(rid1) == "string" and rid1:match("^%d+$") and rid1 == rid2,
        "goodnotesReplicaId persists a stable 64-bit decimal id")

    -- Create an external .goodnotes file to import
    local src_nb = Notebook.new(800, 1000, { style = "grid", size = 40, strength = 45 })
    src_nb.pages[1].ops = { { kind = "ink", color = { 0, 0, 0 }, width = 2.5, pts = { 20, 30, 120, 130 } } }
    local ext_gn = tmpdir .. "/ImportMe.goodnotes"
    ok(GNDoc.save(src_nb, ext_gn, { replica_id = "77" }), "fixture .goodnotes created")

    -- Import into library folder and verify view state
    local lib_dir = view:libraryDir()
    ok(view:importGoodnotesFile(ext_gn, lib_dir), "importGoodnotesFile imports and opens .goodnotes")
    ok(Project.isGoodnotes(view.doc_path) and view.notebook ~= nil and view.notebook:isGoodnotes(),
        "view opens .goodnotes directly in library with native Goodnotes notebook state")
    ok(view.nb_fit == true and view:docHasContent(), "Goodnotes document enables page fitting and docHasContent")

    -- Add a stroke in canvas, save incrementally, reload
    table.insert(view.canvas.ops, { kind = "ink", color = { 255, 0, 0 }, width = 4, pts = { 50, 50, 150, 150 } })
    view:markDirty()
    ok(view:saveDocument(true), "saveDocument writes back to .goodnotes")
    local reloaded = Project.load(view.doc_path)
    ok(reloaded and #reloaded.pages[1].ops == 2, "edited stroke persisted inside .goodnotes")

    -- Rename preserves .goodnotes extension
    view:renameDocument("Renamed Notes")
    ok(Project.isGoodnotes(view.doc_path) and Storage.baseName(view.doc_path) == "Renamed Notes.goodnotes",
        "renameDocument keeps .goodnotes extension")
    ok(Storage.exists(view.doc_path), "renamed .goodnotes file exists on disk")

    -- Export current Goodnotes notebook slice via writeGoodnotes
    local exp_nb = tmpdir .. "/ExportedNB.goodnotes"
    ok(view:writeGoodnotes(exp_nb, { indices = { 1 } }), "writeGoodnotes exports notebook")
    ok(GNDoc.validate(exp_nb), "exported notebook .goodnotes passes validation")

    -- Goodnotes Templates UI & view actions (start, add page, change page, pack import)
    local GNTemplates = require("ink/goodnotes/templates")
    local tpl_grid = assert(GNTemplates.find(lib_dir, "gn_grid"))
    local mat_white = GNTemplates.materialize(tpl_grid, "white")
    ok(view:startGoodnotesFromTemplate(mat_white, lib_dir), "startGoodnotesFromTemplate opens new .goodnotes notebook")
    ok(Project.isGoodnotes(view.doc_path) and view.notebook and view.notebook:isGoodnotes(),
        "template notebook opens in Goodnotes mode")
    local tpl_music = GNTemplates.materialize(assert(GNTemplates.find(lib_dir, "gn_music")), "yellow")
    ok(view:nbAddGoodnotesTemplate(tpl_music), "nbAddGoodnotesTemplate inserts page with Yellow Music template")
    ok(view.notebook:count() == 2 and view.notebook.index == 2, "notebook moved to newly added template page")
    local tpl_dotted = GNTemplates.materialize(assert(GNTemplates.find(lib_dir, "gn_dotted")), "dark")
    ok(view:nbChangeGoodnotesTemplate(tpl_dotted), "nbChangeGoodnotesTemplate replaces current page template")
    ok(view:saveDocument(true), "saveDocument persists Goodnotes template changes")
    local tpl_reloaded = Project.load(view.doc_path)
    ok(tpl_reloaded and #tpl_reloaded.pages == 2, "template notebook reloads with 2 pages")
    ok(view:importGoodnotesTemplatePack(ext_gn), "importGoodnotesTemplatePack imports pack into library templates")
    view:openGoodnotesTemplates{ mode = "new", dir = lib_dir }
    ok(view._gntpl_dialog ~= nil, "openGoodnotesTemplates builds template picker sheet cleanly")
    view:closeSheet("_gntpl_dialog")

    -- Single-page drawing export via writeGoodnotes
    view:newDrawing(lib_dir)
    table.insert(view.canvas.ops, { kind = "ink", color = { 10, 20, 30 }, width = 3, pts = { 10, 10, 90, 90 } })
    local exp_draw = tmpdir .. "/ExportedDraw.goodnotes"
    ok(view:writeGoodnotes(exp_draw), "writeGoodnotes exports single-page drawing")
    local dloaded = GNDoc.load(exp_draw)
    ok(dloaded and #dloaded.pages == 1 and #dloaded.pages[1].ops == 1, "exported drawing opens with 1 page and 1 stroke")

    -- Share / Receive wiring
    ok(Http.TYPES.goodnotes == "application/octet-stream", "Http.TYPES defines goodnotes")
    ok(Http.isZip("PK\3\4extra") and Http.sniff("PK\3\4") == nil, "Http.isZip detects ZIP without changing Http.sniff")
    local uhtml = Page.uploadCard{ allowed = true, url = "/t/upload", nonce = "n1",
        limits = view.RECEIVE_LIMITS.limits, max_pixels = view.RECEIVE_LIMITS.max_pixels }
    ok(uhtml:find(".goodnotes", 1, true) ~= nil and view.IMPORTED_SUB.goodnotes == "Goodnotes",
        "Wi-Fi transfer page and receive folder advertise Goodnotes support")

    view:onCloseWidget()
end

os.execute("rm -rf '" .. tmpdir .. "'")
print(("goodnotes_view: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
