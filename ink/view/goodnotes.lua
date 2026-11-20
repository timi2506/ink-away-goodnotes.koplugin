--[[
Importing and exporting `.goodnotes` documents, managing Goodnotes page
templates (bundled + user-imported template packs, Dark / White / Yellow paper
variants), and maintaining persistent per-device CRDT replica identity.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Accent = require("ink/accent")
local Library = require("ink/library")
local Paint = require("ink/paint")
local Project = require("ink/project")
local Storage = require("ink/storage")
local Theme = require("ink/ui/theme")
local _ = require("ink/l10n")
local GNDoc = require("ink/goodnotes/document")
local GNTemplates = require("ink/goodnotes/templates")
local Wire = require("ink/goodnotes/wire")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local HINT = Blitbuffer.ColorRGB32(0x90, 0x90, 0x90, 0xFF)
local TILE_BG = Paint.TILE_BG

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local function fallbackStyleForTemplate(name)
    local low = tostring(name or ""):lower()
    if low:find("dot", 1, true) then return "dots" end
    if low:find("grid", 1, true) or low:find("square", 1, true) then return "grid" end
    if low:find("music", 1, true) then return "music" end
    if low:find("ruled", 1, true) or low:find("line", 1, true) then return "lines" end
    return "blank"
end

local InkAwayView = {}

-- Stable per-device 64-bit CRDT replica identifier, persisted in KOReader
-- settings so every edit from this reader contributes clean causal history for
-- future sync / Mac Goodnotes sync.
function InkAwayView:goodnotesReplicaId()
    local id = self:getSetting("inkaway_gn_replica_id")
    if type(id) == "string" and id:match("^%d+$") and id ~= "0" then return id end
    id = Wire.u64ToDec(Wire.randomU64())
    self:setSetting("inkaway_gn_replica_id", id)
    return id
end

-- Preferred Goodnotes template paper color ("dark" | "white" | "yellow").
function InkAwayView:goodnotesTemplateColor()
    local c = self:getSetting("inkaway_gn_tpl_color")
    if c == "dark" or c == "white" or c == "yellow" then return c end
    return "dark"
end

------------------------------------------------------------------------------
-- Importing & Exporting `.goodnotes` Documents
------------------------------------------------------------------------------

-- Pick a `.goodnotes` file from KOReader's storage and import it into folder `dir`.
function InkAwayView:openGoodnotesPicker(dir)
    self:pickFile(self:homeDir(), function(path) self:importGoodnotesFile(path, dir) end,
        function(name) return Project.isGoodnotes(name) end,
        "notebook", _("No Goodnotes files or folders here."),
        _("Import Goodnotes file\u{2026}"))
end

-- Copy `src_path` into the library folder `dir` (redirecting Imported -> Library),
-- validate its Goodnotes archive structure, refresh Library/Shelf, and open it.
function InkAwayView:importGoodnotesFile(src_path, dir)
    if not Storage.exists(src_path) then
        self:tell(_("That Goodnotes file could not be found."))
        return false
    end
    local valid, err = GNDoc.validate(src_path)
    if not valid then
        self:tell(_("Could not open that Goodnotes file.\n") .. tostring(err))
        return false
    end
    local moved
    dir, moved = self:writableDir(dir or self:docDir())
    local dest = Storage.uniquePath(dir, Storage.stem(src_path), Project.GN_EXT)
    local ok, cerr = Storage.copyFile(src_path, dest)
    if not ok then
        self:tell(_("Could not import that Goodnotes file.\n") .. tostring(cerr))
        return false
    end
    if self._library then self:refreshLibrary() end
    if self:openDocument(dest) then
        if moved then self:noteNotImported("doc", Storage.stem(dest)) end
        return true
    end
    os.remove(dest)
    return false
end

-- Export the open notebook or drawing to a `.goodnotes` archive at `path`.
function InkAwayView:writeGoodnotes(path, opts)
    opts = opts or {}
    local target = path
    if not Project.isGoodnotes(target) then
        target = Storage.join(Storage.dirName(path), Storage.fileName(Storage.baseName(path), Project.GN_EXT))
    end
    local nb = self.notebook
    local ok, err
    if nb then
        self:nbSyncOut()
        ok, err = GNDoc.save(nb, target, {
            replica_id = self:goodnotesReplicaId(),
            export_only = true,
            indices = opts.indices,
            title = Storage.stem(target),
        })
    else
        local grid = self.grid_on and self.grid_style or "blank"
        local doc = {
            version = 2,
            kind = "notebook",
            w = self.canvas.w,
            h = self.canvas.h,
            index = 1,
            template = {
                style = grid,
                size = self.grid_size or 40,
                strength = self.grid_strength or 45,
                paper = self.paper,
            },
            pages = { { ops = self.canvas.ops } },
        }
        ok, err = GNDoc.save(doc, target, {
            replica_id = self:goodnotesReplicaId(),
            export_only = true,
            bg_path = self.bg_path,
            title = Storage.stem(target),
        })
    end
    if ok then
        if self.exportDone then
            self:exportDone(target)
        else
            self:tell(string.format(_("Saved:\n%s"), Storage.shortPath(target)))
        end
        return true
    end
    self:tell(_("Could not export.\n") .. tostring(err))
    return false
end

------------------------------------------------------------------------------
-- Goodnotes Page Templates (Bundled & Template Packs)
------------------------------------------------------------------------------

function InkAwayView:goodnotesTemplatePreview(tpl, color_choice, w, h)
    local mat = GNTemplates.materialize(tpl, color_choice)
    if not mat then return nil end
    local cache = self._wave_cache
    if not cache then cache = {}; self._wave_cache = cache end
    local id = table.concat({ "gntpl", tpl.id, mat.color or "", w, h, Screen.bb:getType() }, "|")
    local e = cache[id]
    if e then return e.bb end

    local bb
    if mat.pdf_path and Storage.exists(mat.pdf_path) then
        local ok_doc, doc = pcall(function() return require("document/documentregistry"):openDocument(mat.pdf_path) end)
        if ok_doc and doc then
            local ok_ren, rendered = pcall(self.renderPdfPage, self, doc, 1, w, h)
            pcall(function() doc:close() end)
            if ok_ren and rendered then
                if rendered:getWidth() == w and rendered:getHeight() == h then
                    bb = rendered
                else
                    bb = Blitbuffer.new(w, h, rendered:getType())
                    local paper = mat.paper_rgb or { 255, 255, 255 }
                    bb:fill(Blitbuffer.ColorRGB32(paper[1], paper[2], paper[3], 0xFF))
                    local rw, rh = rendered:getWidth(), rendered:getHeight()
                    bb:blitFrom(rendered, math.floor((w - rw) / 2), math.floor((h - rh) / 2), 0, 0, rw, rh)
                    rendered:free()
                end
            end
        end
    end
    if not bb then
        bb = Blitbuffer.new(w, h, Screen.bb:getType())
        local style = fallbackStyleForTemplate(tpl.name)
        Paint.paintPaper(bb, w, h, {
            style = style,
            size = math.max(6, math.floor(h / 9)),
            strength = 70,
            paper = mat.paper_rgb or { 255, 255, 255 },
        }, nil)
    end
    Paint.outline(bb, 0, 0, w, h, HINT, 1)
    cache[id] = { bb = bb }
    return bb
end

function InkAwayView:goodnotesTemplateTile(tpl, color_choice, tileW, tileH, deleting, cb)
    local a = Accent.get()
    local label_h = Screen:scaleBySize(26)
    local ph = tileH - label_h - Screen:scaleBySize(18)
    local pw = math.floor(ph * 0.77)
    if pw > tileW - Screen:scaleBySize(16) then
        pw = tileW - Screen:scaleBySize(16)
        ph = math.floor(pw / 0.77)
    end
    local ok, page_bb = pcall(self.goodnotesTemplatePreview, self, tpl, color_choice, pw, ph)
    local sel = deleting and not tpl.bundled
    local fg = sel and a.text or BLACK
    local vg = VerticalGroup:new{ align = "center", fgcolor = fg }
    if ok and page_bb then
        table.insert(vg, Theme.keep(ImageWidget:new{
            image = page_bb, width = pw, height = ph, image_disposable = false, fgcolor = BLACK,
        }))
    end
    table.insert(vg, vspan(4))
    local label_text = tpl.name or ""
    if deleting and tpl.bundled then label_text = label_text .. " *" end
    table.insert(vg, TextWidget:new{
        text = label_text,
        face = Font:getFace("cfont", 14),
        bold = true,
        max_width = tileW - Screen:scaleBySize(10),
        fgcolor = fg,
    })
    if sel and a.chromatic then return self:accentButton(tileW, tileH, Screen:scaleBySize(14), vg, cb) end
    local b = Button:new{
        text = "", width = tileW, height = tileH, bordersize = 0,
        radius = Screen:scaleBySize(14), background = sel and a.fill or TILE_BG,
        margin = 0, padding = 0, callback = cb, show_parent = self,
    }
    self:setButtonLabel(b, vg)
    return b
end

-- Create a new native `.goodnotes` notebook in `dir` initialized with materialized template `tpl_mat`.
function InkAwayView:startGoodnotesFromTemplate(tpl_mat, dir)
    if not tpl_mat then return false end
    local moved
    dir, moved = self:writableDir(dir or self:docDir())
    local dest = Storage.uniquePath(dir, Library.defaultName(self:docKindLabel("notebook")), Project.GN_EXT)
    local ok, err = GNDoc.newFromTemplate(tpl_mat, dest, { replica_id = self:goodnotesReplicaId() })
    if not ok then
        self:tell(_("Could not create Goodnotes notebook.\n") .. tostring(err))
        return false
    end
    if self._library then self:refreshLibrary() end
    if self:openDocument(dest) then
        if moved then self:noteNotImported("new") end
        return true
    end
    os.remove(dest)
    return false
end

-- Insert a new page created from materialized template `tpl_mat` after the current page.
function InkAwayView:nbAddGoodnotesTemplate(tpl_mat)
    local nb = self.notebook
    if not (nb and tpl_mat) then return false end
    self:nbSyncOut()
    local page = nb:newPage(1)
    page.pdf_path = tpl_mat.pdf_path
    page.w = tpl_mat.w
    page.h = tpl_mat.h
    page._gn_paper_rgb = tpl_mat.paper_rgb
    page._gn_builtin_tpl = true
    page._gn_tpl_spec = tpl_mat
    table.insert(nb.pages, nb.index + 1, page)
    nb.index = nb.index + 1
    self:nbLoad()
    self:markDirty()
    return true
end

-- Replace the current page's template inside an open `.goodnotes` notebook.
function InkAwayView:nbChangeGoodnotesTemplate(tpl_mat)
    local nb = self.notebook
    local page = nb and nb.pages[nb.index]
    if not (page and tpl_mat) then return false end
    self:nbSyncOut()
    page.src = 1
    page.pdf_path = tpl_mat.pdf_path
    page.w = tpl_mat.w
    page.h = tpl_mat.h
    page._gn_paper_rgb = tpl_mat.paper_rgb
    page._gn_builtin_tpl = true
    page._gn_template_id = nil
    page._gn_tpl_spec = tpl_mat
    if nb.index == 1 then
        nb.w = tpl_mat.w
        nb.h = tpl_mat.h
        nb.template.pdf_path = tpl_mat.pdf_path
        nb.template.paper = tpl_mat.paper_rgb
    end
    self._bg_src = nil
    if self.bg_bb then self.bg_bb:free(); self.bg_bb = nil end
    self:dropPageThumb(page)
    self:nbPageChanged(page)
    self:nbLoad()
    return true
end

-- Pick a `.goodnotes` file and import every template page it contains into the template library.
function InkAwayView:openGoodnotesTemplatePackPicker(on_done)
    self:pickFile(self:homeDir(), function(path) self:importGoodnotesTemplatePack(path, on_done) end,
        function(name) return Project.isGoodnotes(name) end,
        "template", _("No Goodnotes files or folders here."),
        _("Import Goodnotes templates\u{2026}"))
end

function InkAwayView:importGoodnotesTemplatePack(src_path, on_done)
    local added, skipped_or_err = GNTemplates.importPack(src_path, self:libraryDir())
    if not added then
        self:tell(_("Could not import Goodnotes templates.\n") .. tostring(skipped_or_err))
        return false
    end
    if added > 0 then
        self:showNotice(string.format(added == 1 and _("Imported 1 template") or _("Imported %d templates"), added), 3)
    else
        self:showNotice(_("All templates in that file are already installed."), 3)
    end
    if on_done then on_done() end
    return true
end

local GN_TPLS_PER_PAGE = 6

-- Visual chooser for Goodnotes templates (bundled + imported packs) with live
-- Dark / White / Yellow paper switching.
function InkAwayView:openGoodnotesTemplates(opts)
    opts = opts or {}
    local mode = opts.mode or "new"
    local field = opts.field or "_gntpl_dialog"
    self:closeSheet(field)
    local content_w, gap = self:sheetWidth()
    local deleting = opts.deleting and true or false
    local page = 0
    local root = self:libraryDir()

    local build = function()
        local list = GNTemplates.list(root)
        local has_custom = false
        for _i, t in ipairs(list) do if not t.bundled then has_custom = true; break end end
        if deleting and not has_custom then deleting = false end

        local pages = math.max(1, math.ceil(#list / GN_TPLS_PER_PAGE))
        if page >= pages then page = pages - 1 end
        local color_choice = self:goodnotesTemplateColor()

        local rows = GN_TPLS_PER_PAGE / 3
        local tileW = math.floor((content_w - 2 * gap) / 3)
        local chrome = Screen:scaleBySize(160 + (pages > 1 and 52 or 0) + (has_custom and 48 or 48))
        local tileH = math.min(math.floor(tileW * 1.15),
            math.max(Screen:scaleBySize(80), math.floor((math.floor(self.screen_h * 0.85) - chrome) / rows)))

        local closeSelf = function() self:closeSheet(field) end
        local title = deleting and _("Delete template")
            or mode == "change_page" and _("Page template")
            or mode == "add_page" and _("New page from template")
            or _("Goodnotes templates")

        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(title, content_w, _("Cancel"), closeSelf))
        add(vspan(12))

        if not deleting then
            add(self:sheetLabel(_("Paper"), true))
            add(vspan(6))
            add(self:segmentedRow({
                { "dark", _("Dark") },
                { "white", _("White") },
                { "yellow", _("Yellow") },
            }, color_choice, content_w, function(v)
                self:setSetting("inkaway_gn_tpl_color", v)
                self:rebuildSheet(field)
            end))
            add(vspan(12))
        end

        local first = page * GN_TPLS_PER_PAGE
        for r = 0, rows - 1 do
            local row = HorizontalGroup:new{ align = "center" }
            for c = 1, 3 do
                local tpl = list[first + r * 3 + c]
                if tpl then
                    if c > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
                    table.insert(row, self:goodnotesTemplateTile(tpl, deleting and "original" or color_choice,
                        tileW, tileH, deleting, function()
                            if deleting then
                                if tpl.bundled then
                                    self:showNotice(_("Built-in templates cannot be deleted."), 2)
                                    return
                                end
                                self:ask{
                                    title = string.format(_("Delete the template \u{201C}%s\u{201D}?"), tpl.name),
                                    ok_text = _("Delete"),
                                    ok_icon = "trash",
                                    on_ok = function()
                                        GNTemplates.remove(root, tpl.id)
                                        self:rebuildSheet(field)
                                    end,
                                }
                                return
                            end
                            local mat = GNTemplates.materialize(tpl, color_choice)
                            closeSelf()
                            if mode == "new" then
                                if opts.on_before then opts.on_before() end
                                self:startGoodnotesFromTemplate(mat, opts.dir)
                            elseif mode == "add_page" then
                                self:nbAddGoodnotesTemplate(mat)
                            elseif mode == "change_page" then
                                self:nbChangeGoodnotesTemplate(mat)
                            end
                        end))
                end
            end
            if r > 0 then add(vspan(gap)) end
            add(row)
        end

        if pages > 1 then
            add(vspan(gap))
            add(self:pagerRow(page, pages, content_w, gap, function(d)
                page = (page + d) % pages
                self:rebuildSheet(field)
            end))
        end

        add(vspan(14))
        local imp_btn = self:actionButton(_("Import pack\u{2026}"),
            has_custom and math.floor((content_w - gap) / 2) or content_w, function()
                self:openGoodnotesTemplatePackPicker(function() self:rebuildSheet(field) end)
            end)
        if has_custom then
            add(HorizontalGroup:new{ align = "center", imp_btn, HorizontalSpan:new{ width = gap },
                self:actionButton(deleting and _("Back") or _("Delete\u{2026}"), math.floor((content_w - gap) / 2),
                    function() deleting = not deleting; self:rebuildSheet(field) end) })
        else
            add(imp_btn)
        end
        return content
    end
    self:showSheet(field, build)
end

return InkAwayView
