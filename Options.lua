-- CombatTextForever options: a canvas page in the game's AddOns settings, built from
-- hand-made widgets on long-stable templates. Nothing is created until first shown.

local ADDON, ns = ...

local ROW_HEIGHT = 26
local LIST_WIDTH = 560

local panel = CreateFrame("Frame")
panel.name = "CombatTextForever"
panel:Hide()

local category
local built = false
local refreshers = {}
local scrollCount = 0

local function OnRefresh(fn)
	refreshers[#refreshers + 1] = fn
end

local function RefreshAll()
	if not built then return end
	for _, fn in ipairs(refreshers) do
		ns.Guard("options refresh", fn)
	end
end

--------------------------------------------------------------------------------
-- Widgets. Each takes get/set functions and registers how to repaint itself.
--------------------------------------------------------------------------------

local function Label(parent, text, template)
	local label = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlightSmall")
	label:SetJustifyH("LEFT")
	label:SetText(text)
	return label
end

-- `tip` is the one-line description shown when the mouse is over the box or its label.
local function Check(parent, text, get, set, tip)
	local box = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	box:SetSize(24, 24)
	box.label = Label(parent, text)
	box.label:SetPoint("LEFT", box, "RIGHT", 2, 0)
	-- Stretch the mouse area over the label, so hovering or clicking the text works too.
	box:SetHitRectInsets(0, -math.min(box.label:GetStringWidth() + 4, 420), 0, 0)
	box:SetScript("OnClick", function(self)
		local checked = self:GetChecked() and true or false
		ns.Guard("options", set, checked)
	end)
	box:SetScript("OnEnter", function(self)
		if not tip then return end
		GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
		GameTooltip:SetText(tip, 1, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	box:SetScript("OnLeave", function() GameTooltip:Hide() end)
	OnRefresh(function() box:SetChecked(get() and true or false) end)
	return box
end

local function Button(parent, text, width, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetText(text)
	button:SetScript("OnClick", function() ns.Guard("options", onClick) end)
	return button
end

local function Slider(parent, text, low, high, step, get, set)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(170, 36)
	local label = Label(holder, text)
	label:SetPoint("TOPLEFT")
	local value = Label(holder, "")
	value:SetPoint("TOPRIGHT")

	local slider = CreateFrame("Slider", nil, holder)
	slider:SetOrientation("HORIZONTAL")
	slider:SetPoint("BOTTOMLEFT")
	slider:SetPoint("BOTTOMRIGHT")
	slider:SetHeight(16)
	slider:SetMinMaxValues(low, high)
	slider:SetValueStep(step)
	if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
	local track = slider:CreateTexture(nil, "BACKGROUND")
	track:SetColorTexture(0, 0, 0, 0.6)
	track:SetPoint("LEFT")
	track:SetPoint("RIGHT")
	track:SetHeight(6)
	local thumb = slider:CreateTexture(nil, "OVERLAY")
	thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	thumb:SetSize(24, 24)
	slider:SetThumbTexture(thumb)

	local painting = false
	slider:SetScript("OnValueChanged", function(_, raw)
		local snapped = math.floor(raw / step + 0.5) * step
		value:SetText(tostring(snapped))
		if not painting then ns.Guard("options", set, snapped) end
	end)
	OnRefresh(function()
		local current = get()
		if type(current) ~= "number" then return end
		painting = true
		slider:SetValue(current)
		value:SetText(tostring(current))
		painting = false
	end)
	return holder
end

local function Edit(parent, width, get, set)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(width, 20)
	box:SetAutoFocus(false)
	local function Commit(self)
		ns.Guard("options", set, self:GetText())
	end
	box:SetScript("OnEnterPressed", function(self)
		Commit(self)
		self:ClearFocus()
	end)
	box:SetScript("OnEscapePressed", function(self)
		self:SetText(get() or "")
		self:ClearFocus()
	end)
	box:SetScript("OnEditFocusLost", Commit)
	OnRefresh(function()
		if box:HasFocus() then return end
		box:SetText(get() or "")
		box:SetCursorPosition(0)
	end)
	return box
end

-- `color` is the profile's own { r, g, b } table; it is changed in place.
local function PickColor(color, onChange)
	local old = { color[1], color[2], color[3] }
	local function Apply(r, g, b)
		color[1], color[2], color[3] = r, g, b
		onChange()
	end
	if ColorPickerFrame.SetupColorPickerAndShow then
		ColorPickerFrame:SetupColorPickerAndShow({
			r = old[1], g = old[2], b = old[3],
			hasOpacity = false,
			swatchFunc = function() Apply(ColorPickerFrame:GetColorRGB()) end,
			cancelFunc = function() Apply(old[1], old[2], old[3]) end,
		})
	else
		ColorPickerFrame.hasOpacity = false
		ColorPickerFrame.previousValues = old
		ColorPickerFrame.func = function() Apply(ColorPickerFrame:GetColorRGB()) end
		ColorPickerFrame.cancelFunc = function() Apply(old[1], old[2], old[3]) end
		ColorPickerFrame:SetColorRGB(old[1], old[2], old[3])
		ColorPickerFrame:Hide() -- a re-show is what makes the legacy picker pick up new values
		ColorPickerFrame:Show()
	end
end

-- `getColor` returns the { r, g, b } table to show and edit, or nil. `onChange`, if given,
-- is called with that table each time the picker changes it.
local function Swatch(parent, getColor, onChange)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(18, 18)
	local border = button:CreateTexture(nil, "BACKGROUND")
	border:SetAllPoints()
	border:SetColorTexture(0.9, 0.9, 0.9, 1)
	local fill = button:CreateTexture(nil, "ARTWORK")
	fill:SetPoint("TOPLEFT", 1, -1)
	fill:SetPoint("BOTTOMRIGHT", -1, 1)
	local function Paint()
		local color = getColor()
		if color then fill:SetColorTexture(color[1], color[2], color[3], 1) end
	end
	button:SetScript("OnClick", function()
		local color = getColor()
		if not color then return end
		ns.Guard("options", PickColor, color, function()
			Paint()
			if onChange then onChange(color) end
		end)
	end)
	OnRefresh(Paint)
	return button
end

-- Gives a frame a dark fill with a thin light edge.
local function Panelize(frame)
	local edge = frame:CreateTexture(nil, "BACKGROUND")
	edge:SetAllPoints()
	edge:SetColorTexture(0.45, 0.45, 0.45, 1)
	local fill = frame:CreateTexture(nil, "BORDER")
	fill:SetPoint("TOPLEFT", 1, -1)
	fill:SetPoint("BOTTOMRIGHT", -1, 1)
	fill:SetColorTexture(0.08, 0.08, 0.1, 0.97)
end

-- Dropdown list. One popup is shared by every dropdown box: it lists all the options of
-- whichever box opened it, marks the current one, and scrolls with the mouse wheel when
-- the list is long. Clicking anywhere else closes it.
local MENU_ROWS = 12
local MENU_ROW_HEIGHT = 18
local menu

local function CloseMenu()
	if not menu then return end
	menu.owner = nil
	menu.catcher:Hide()
	menu:Hide()
end

local function MenuRow(index)
	local row = menu.rows[index]
	if row then return row end
	row = CreateFrame("Button", nil, menu)
	row:SetHeight(MENU_ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 1, -1 - (index - 1) * MENU_ROW_HEIGHT)
	row:SetPoint("TOPRIGHT", -1, -1 - (index - 1) * MENU_ROW_HEIGHT)
	local hover = row:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	hover:SetColorTexture(1, 0.82, 0, 0.25)
	row.label = Label(row, "")
	row.label:SetPoint("LEFT", 8, 0)
	row:SetScript("OnClick", function(self)
		local owner, value = menu.owner, self.value
		CloseMenu()
		if owner then ns.Guard("options", owner.pick, value) end
	end)
	menu.rows[index] = row
	return row
end

local function PaintMenu()
	local options = menu.options
	local shown = math.min(#options, MENU_ROWS)
	local scrolls = #options > MENU_ROWS
	menu.footer:SetText(scrolls and format("%d-%d of %d (mouse wheel)", menu.offset + 1, menu.offset + shown, #options) or "")
	local width = math.max(menu.owner:GetWidth(), scrolls and (menu.footer:GetStringWidth() + 16) or 0)
	for index = 1, shown do
		local option = options[menu.offset + index]
		local row = MenuRow(index)
		row.value = option[1]
		row.label:SetText(option[2])
		if option[1] == menu.current then
			row.label:SetTextColor(1, 0.82, 0)
		else
			row.label:SetTextColor(1, 1, 1)
		end
		width = math.max(width, row.label:GetStringWidth() + 20)
		row:Show()
	end
	for index = shown + 1, #menu.rows do
		menu.rows[index]:Hide()
	end
	menu:SetSize(width, shown * MENU_ROW_HEIGHT + 2 + (scrolls and 18 or 0))
end

local function ScrollMenu(step)
	local last = math.max(0, #menu.options - MENU_ROWS)
	menu.offset = math.min(last, math.max(0, menu.offset + step))
	PaintMenu()
end

local function CreateMenu()
	-- An invisible full-screen button behind the list catches the click that closes it.
	local catcher = CreateFrame("Button", nil, UIParent)
	catcher:SetAllPoints(UIParent)
	catcher:SetFrameStrata("FULLSCREEN_DIALOG")
	catcher:RegisterForClicks("AnyUp")
	catcher:SetScript("OnClick", CloseMenu)
	catcher:Hide()

	menu = CreateFrame("Frame", nil, UIParent)
	menu:SetFrameStrata("TOOLTIP")
	menu:SetClampedToScreen(true)
	menu:EnableMouse(true)
	menu:EnableMouseWheel(true)
	Panelize(menu)
	menu.catcher, menu.rows, menu.offset = catcher, {}, 0
	menu.footer = Label(menu, "", "GameFontDisableSmall")
	menu.footer:SetPoint("BOTTOMLEFT", 8, 4)
	menu:SetScript("OnMouseWheel", function(_, delta) ns.Guard("options", ScrollMenu, -delta) end)
	menu:SetScript("OnUpdate", function()
		-- The box that opened the list went away (tab change, panel closed).
		if not (menu.owner and menu.owner:IsVisible()) then CloseMenu() end
	end)
	menu:Hide()
end

local function OpenMenu(owner, options, current)
	if not menu then CreateMenu() end
	if #options == 0 then return end
	menu.owner, menu.options, menu.current, menu.offset = owner, options, current, 0
	for index, option in ipairs(options) do
		if option[1] == current then
			-- Open with the current choice in view.
			menu.offset = math.min(math.max(0, #options - MENU_ROWS), math.max(0, index - MENU_ROWS))
		end
	end
	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
	PaintMenu()
	menu.catcher:Show()
	menu:Show()
end

-- A dropdown box over a list of { value, label } options.
local function Choice(parent, width, getOptions, get, set)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(width, 22)
	Panelize(button)
	local hover = button:CreateTexture(nil, "HIGHLIGHT")
	hover:SetAllPoints()
	hover:SetColorTexture(1, 1, 1, 0.08)
	local arrow = button:CreateTexture(nil, "OVERLAY")
	arrow:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
	arrow:SetSize(22, 22)
	arrow:SetPoint("RIGHT", 1, 0)
	local label = Label(button, "")
	label:SetPoint("LEFT", 8, 0)
	label:SetPoint("RIGHT", arrow, "LEFT", 0, 0)
	label:SetWordWrap(false)

	local function Paint()
		local current = get()
		for _, option in ipairs(getOptions()) do
			if option[1] == current then
				label:SetText(option[2])
				return
			end
		end
		label:SetText(current ~= nil and tostring(current) or "")
	end
	button.pick = function(value)
		set(value)
		Paint()
	end
	button:SetScript("OnClick", function(self) ns.Guard("options", OpenMenu, self, getOptions(), get()) end)
	OnRefresh(Paint)
	return button
end

local function Scroll(parent, width, height)
	scrollCount = scrollCount + 1
	local scroll = CreateFrame("ScrollFrame", "CombatTextForeverScroll" .. scrollCount, parent, "UIPanelScrollFrameTemplate")
	scroll:SetSize(width, height)
	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(width, 10)
	scroll:SetScrollChild(child)
	return scroll, child
end

local function Options(...)
	local list = {}
	for i = 1, select("#", ...), 2 do
		list[#list + 1] = { (select(i, ...)), (select(i + 1, ...)) }
	end
	return function() return list end
end

local function AreaOptions()
	local names = {}
	for name in pairs(ns.profile.areas) do
		names[#names + 1] = name
	end
	table.sort(names)
	local list = {}
	for _, name in ipairs(names) do
		list[#list + 1] = { name, name }
	end
	return list
end

--------------------------------------------------------------------------------
-- Events page
--------------------------------------------------------------------------------

local function BuildEvents(tab)
	local selected = ns.categories[1].key
	local rows = {}
	local scroll, child = Scroll(tab, LIST_WIDTH, 400)
	local note = Label(tab, "", "GameFontNormal")

	local function CreateRow(index)
		local row = CreateFrame("Frame", nil, child)
		row:SetSize(LIST_WIDTH, ROW_HEIGHT - 2)
		row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
		local function Current() return row.key and ns.profile.events[row.key] end

		row.check = Check(row, "", function()
			local s = Current()
			return s and s.enabled
		end, function(checked)
			local s = Current()
			if s then s.enabled = checked end
		end, "Show this event.")
		row.check:SetPoint("LEFT", 0, 0)
		row.check:SetHitRectInsets(0, -252, 0, 0)
		row.check.label:SetWidth(250)
		row.check.label:SetWordWrap(false)

		row.swatch = Swatch(row, function()
			local s = Current()
			return s and s.color
		end)
		row.swatch:SetPoint("LEFT", 285, 0)

		row.format = Edit(row, 110, function()
			local s = Current()
			return s and s.format or ""
		end, function(text)
			local s = Current()
			if s then s.format = text end
		end)
		row.format:SetPoint("LEFT", 320, 0)

		row.area = Choice(row, 110, AreaOptions, function()
			local s = Current()
			return s and s.area
		end, function(area)
			local s = Current()
			if s then s.area = area end
		end)
		row.area:SetPoint("LEFT", 445, 0)
		return row
	end

	local function ShowCategory()
		local keys = ns.eventList[selected] or {}
		for _, row in ipairs(rows) do
			row.format:ClearFocus() -- commits a pending edit to the event it belongs to
		end
		for index, key in ipairs(keys) do
			rows[index] = rows[index] or CreateRow(index)
			rows[index].key = key
			rows[index].check.label:SetText(ns.events[key].name)
			rows[index]:Show()
		end
		for index = #keys + 1, #rows do
			rows[index].key = nil
			rows[index]:Hide()
		end
		child:SetHeight(math.max(10, #keys * ROW_HEIGHT))
		note:SetText("")
		for _, entry in ipairs(ns.categories) do
			if entry.key == selected then note:SetText(entry.note or "") end
		end
	end

	local categoryOptions = {}
	for _, entry in ipairs(ns.categories) do
		categoryOptions[#categoryOptions + 1] = { entry.key, entry.name }
	end
	local picker = Choice(tab, 170, function() return categoryOptions end, function() return selected end, function(key)
		selected = key
		ShowCategory()
		RefreshAll()
	end)
	picker:SetPoint("TOPLEFT", 0, 0)

	local hint = Label(tab, "%a amount   %s spell   %n target   %r result   %e glancing / crushing / partial tags")
	hint:SetPoint("LEFT", picker, "RIGHT", 10, 0)

	local header = Label(tab, "Event", "GameFontNormalSmall")
	header:SetPoint("TOPLEFT", 28, -32)
	local colorHeader = Label(tab, "Colour", "GameFontNormalSmall")
	colorHeader:SetPoint("TOPLEFT", 276, -32)
	local formatHeader = Label(tab, "Format", "GameFontNormalSmall")
	formatHeader:SetPoint("TOPLEFT", 320, -32)
	local areaHeader = Label(tab, "Scroll area", "GameFontNormalSmall")
	areaHeader:SetPoint("TOPLEFT", 448, -32)

	scroll:SetPoint("TOPLEFT", 0, -50)
	note:SetPoint("TOPLEFT", 10, -70)
	note:SetWidth(LIST_WIDTH - 20)
	ShowCategory()
end

--------------------------------------------------------------------------------
-- Scroll areas page
--------------------------------------------------------------------------------

local function BuildAreas(tab)
	local selected = "Outgoing"
	local newName = ""

	local function Area()
		if not ns.profile.areas[selected] then selected = "Outgoing" end
		return ns.profile.areas[selected]
	end

	-- A get/set pair for one field of the selected area; setting redraws the areas.
	local function Field(name)
		return function() return Area()[name] end, function(value)
			Area()[name] = value
			ns.Display.Rebuild()
		end
	end

	local picker = Choice(tab, 170, AreaOptions, function() return Area() and selected end, function(name)
		selected = name
		RefreshAll()
	end)
	picker:SetPoint("TOPLEFT", 0, 0)
	Label(tab, "Area being edited"):SetPoint("LEFT", picker, "RIGHT", 10, 0)

	local nameBox = Edit(tab, 150, function() return newName end, function(text) newName = text end)
	nameBox:SetPoint("TOPLEFT", 6, -34)
	local create = Button(tab, "Create area", 100, function()
		nameBox:ClearFocus()
		local name = newName:match("^%s*(.-)%s*$")
		if name == "" then return ns.Print("type a name for the new area first") end
		if ns.profile.areas[name] then return ns.Print("an area with that name already exists") end
		ns.profile.areas[name] = ns.Copy(ns.AREA_TEMPLATE)
		selected, newName = name, ""
		ns.Display.Rebuild()
		RefreshAll()
	end)
	create:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
	local delete = Button(tab, "Delete area", 100, function()
		if ns.DEFAULT_AREAS[selected] then return ns.Print("the built-in areas cannot be deleted") end
		ns.profile.areas[selected] = nil
		for key, settings in pairs(ns.profile.events) do
			if settings.area == selected and ns.events[key] then settings.area = ns.events[key].defaults.area end
		end
		selected = "Outgoing"
		ns.Display.Rebuild()
		RefreshAll()
	end)
	delete:SetPoint("LEFT", create, "RIGHT", 8, 0)

	local choices = {
		{ "Animation style", "style", Options("straight", "Straight", "parabola", "Parabola", "horizontal", "Horizontal", "static", "Static") },
		{ "Scroll direction", "direction", Options("up", "Up", "down", "Down") },
		{ "Behavior (curve or travel side)", "behavior", Options("left", "Left", "right", "Right") },
		{ "Text align", "align", Options("LEFT", "Left", "CENTER", "Center", "RIGHT", "Right") },
		{ "Icon align", "iconAlign", Options("LEFT", "Left of text", "RIGHT", "Right of text", "NONE", "No icon") },
		{ "Sticky style for crits", "sticky", Options("pow", "Pow", "hold", "Hold in place", "none", "Scroll like the rest") },
	}
	for index, entry in ipairs(choices) do
		local get, set = Field(entry[2])
		local choice = Choice(tab, 170, entry[3], get, set)
		choice:SetPoint("TOPLEFT", 0, -70 - (index - 1) * 28)
		Label(tab, entry[1]):SetPoint("LEFT", choice, "RIGHT", 10, 0)
	end

	local sliders = {
		{ "Width", "width", 40, 800, 10 },
		{ "Height", "height", 40, 800, 10 },
		{ "X offset", "x", -1200, 1200, 5 },
		{ "Y offset", "y", -700, 700, 5 },
	}
	for index, entry in ipairs(sliders) do
		local get, set = Field(entry[2])
		local slider = Slider(tab, entry[1], entry[3], entry[4], entry[5], get, set)
		slider:SetPoint("TOPLEFT", 380, -70 - (index - 1) * 44)
	end

	local unlock = Check(tab, "Unlock areas so they can be dragged", function() return not ns.profile.locked end, function(checked)
		ns.profile.locked = not checked
		ns.Display.Rebuild()
	end, "Shows the areas on screen so you can drag them.")
	unlock:SetPoint("TOPLEFT", 0, -250)

	local reset = Button(tab, "Reset position", 120, function()
		local default = ns.DEFAULT_AREAS[selected]
		Area().x, Area().y = default and default.x or 0, default and default.y or 0
		ns.Display.Rebuild()
		RefreshAll()
	end)
	reset:SetPoint("TOPLEFT", 0, -284)
	local test = Button(tab, "Test this area", 120, function() ns.Display.Test(selected) end)
	test:SetPoint("LEFT", reset, "RIGHT", 8, 0)

	ns.On("AreaMoved", RefreshAll)
end

--------------------------------------------------------------------------------
-- Appearance page
--------------------------------------------------------------------------------

local SCHOOLS = { { 1, "Physical" }, { 2, "Holy" }, { 4, "Fire" }, { 8, "Nature" }, { 16, "Frost" }, { 32, "Shadow" }, { 64, "Arcane" } }
local PARTIALS = {
	{ "glancing", "Glancing", "Tags glancing blows." },
	{ "crushing", "Crushing", "Tags crushing blows." },
	{ "blocked", "Partial block", "Tags hits that were partly blocked." },
	{ "absorbed", "Partial absorb", "Tags hits that were partly absorbed." },
	{ "resisted", "Partial resist", "Tags hits that were partly resisted." },
}

local function BuildAppearance(tab)
	local function FontOptions()
		local list = {}
		for _, name in ipairs(ns.FontNames()) do
			list[#list + 1] = { name, name }
		end
		return list
	end
	local function Font(name)
		return function() return ns.profile.font[name] end, function(value) ns.profile.font[name] = value end
	end

	local fontChoices = {
		{ "Normal font", "normal", FontOptions },
		{ "Crit font", "crit", FontOptions },
		{ "Outline", "outline", Options("NONE", "None", "OUTLINE", "Thin", "THICKOUTLINE", "Thick") },
	}
	for index, entry in ipairs(fontChoices) do
		local get, set = Font(entry[2])
		local choice = Choice(tab, 200, entry[3], get, set)
		choice:SetPoint("TOPLEFT", 0, -(index - 1) * 28)
		Label(tab, entry[1]):SetPoint("LEFT", choice, "RIGHT", 10, 0)
	end

	local fontSliders = {
		{ "Normal size", "size", 8, 48, 1 },
		{ "Crit size", "critSize", 8, 64, 1 },
		{ "Opacity %", "alpha", 10, 100, 5 },
	}
	for index, entry in ipairs(fontSliders) do
		local get, set = Font(entry[2])
		Slider(tab, entry[1], entry[3], entry[4], entry[5], get, set):SetPoint("TOPLEFT", 380, -(index - 1) * 44)
	end
	Slider(tab, "Animation speed %", 25, 300, 5, function() return ns.profile.animationSpeed end, function(value)
		ns.profile.animationSpeed = value
	end):SetPoint("TOPLEFT", 380, -132)

	local toggles = {
		{ "Show ability names", "names", "Adds the ability name to damage numbers." },
		{ "Show skill icons", "icons", "Shows the ability's icon next to its number." },
		{ "Colour target names (%n) by class", "classColors", "Colours player names by class where %n is used." },
	}
	for index, entry in ipairs(toggles) do
		Check(tab, entry[1], function() return ns.profile[entry[2]] end, function(checked)
			ns.profile[entry[2]] = checked
		end, entry[3]):SetPoint("TOPLEFT", 0, -92 - (index - 1) * 26)
	end
	Check(tab, "Colour my procs and poisons by school", function() return ns.profile.schoolColors.outgoing end, function(checked)
		ns.profile.schoolColors.outgoing = checked
	end, "Uses the school colours below for your non-physical damage."):SetPoint("TOPLEFT", 0, -170)

	-- One swatch per kind of incoming damage; it sets the hit and the crit colour together.
	Label(tab, "Incoming damage colours", "GameFontNormal"):SetPoint("TOPLEFT", 380, -230)
	for index, entry in ipairs({ { "in.melee", "Melee taken" }, { "in.spell", "Spell taken" } }) do
		local swatch = Swatch(tab, function()
			local hit = ns.profile.events[entry[1] .. ".HIT"]
			return hit and hit.color
		end, function(color)
			local crit = ns.profile.events[entry[1] .. ".CRIT"]
			if crit then crit.color[1], crit.color[2], crit.color[3] = color[1], color[2], color[3] end
		end)
		swatch:SetPoint("TOPLEFT", 380, -252 - (index - 1) * 26)
		Label(tab, entry[2]):SetPoint("LEFT", swatch, "RIGHT", 6, 0)
	end
	Check(tab, "Colour spells taken by school", function() return ns.profile.schoolColors.incoming end, function(checked)
		ns.profile.schoolColors.incoming = checked
	end, "Uses the school colours instead of the Spell taken colour."):SetPoint("TOPLEFT", 380, -304)

	Label(tab, "Damage school colours", "GameFontNormal"):SetPoint("TOPLEFT", 0, -208)
	for index, entry in ipairs(SCHOOLS) do
		local swatch = Swatch(tab, function() return ns.profile.schoolColors.colors[entry[1]] end)
		swatch:SetPoint("TOPLEFT", ((index - 1) % 4) * 140, -230 - math.floor((index - 1) / 4) * 26)
		Label(tab, entry[2]):SetPoint("LEFT", swatch, "RIGHT", 6, 0)
	end

	Label(tab, "Partial effects (the tags added to a hit)", "GameFontNormal"):SetPoint("TOPLEFT", 0, -294)
	for index, entry in ipairs(PARTIALS) do
		local y = -316 - (index - 1) * 26
		Check(tab, entry[2], function() return ns.profile.partial[entry[1]].enabled end, function(checked)
			ns.profile.partial[entry[1]].enabled = checked
		end, entry[3]):SetPoint("TOPLEFT", 0, y)
		Swatch(tab, function() return ns.profile.partial[entry[1]].color end):SetPoint("TOPLEFT", 160, y - 3)
	end

	Button(tab, "Test all areas", 120, function()
		for name in pairs(ns.profile.areas) do
			ns.Display.Test(name)
		end
	end):SetPoint("TOPLEFT", 380, -190)
end

--------------------------------------------------------------------------------
-- Loot page
--------------------------------------------------------------------------------

local function BuildLoot(tab)
	local function Loot(name)
		return function() return ns.profile.loot[name] end, function(value) ns.profile.loot[name] = value end
	end
	local toggles = {
		{ "Show looted items", "items", "Shows items you loot." },
		{ "Show looted money", "money", "Shows money you loot." },
		{ "Show currency gains", "currency", "Shows currency you gain." },
	}
	for index, entry in ipairs(toggles) do
		local get, set = Loot(entry[2])
		Check(tab, entry[1], get, set, entry[3]):SetPoint("TOPLEFT", 0, -(index - 1) * 26)
	end

	Label(tab, "Item qualities to show", "GameFontNormal"):SetPoint("TOPLEFT", 0, -92)
	for quality = 0, 5 do
		local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
		local name = _G["ITEM_QUALITY" .. quality .. "_DESC"] or ("Quality " .. quality)
		local box = Check(tab, name, function() return ns.profile.loot.quality[quality] end, function(checked)
			ns.profile.loot.quality[quality] = checked
		end, "Shows items of this quality.")
		box:SetPoint("TOPLEFT", (quality % 3) * 180, -114 - math.floor(quality / 3) * 26)
		if color then box.label:SetTextColor(color.r, color.g, color.b) end
	end

	Label(tab, "Always show these items, whatever their quality (names or parts of names, comma separated)"):SetPoint("TOPLEFT", 0, -184)
	local allowGet, allowSet = Loot("allow")
	Edit(tab, 520, allowGet, allowSet):SetPoint("TOPLEFT", 6, -200)

	Label(tab, "Never show these items (names or parts of names, comma separated)"):SetPoint("TOPLEFT", 0, -236)
	local excludeGet, excludeSet = Loot("exclude")
	Edit(tab, 520, excludeGet, excludeSet):SetPoint("TOPLEFT", 6, -252)
end

--------------------------------------------------------------------------------
-- Profiles page
--------------------------------------------------------------------------------

local function BuildProfiles(tab)
	local newName, other = "", nil
	local message = Label(tab, "", "GameFontNormal")

	local function ProfileOptions()
		local list = {}
		for _, name in ipairs(ns.ProfileNames()) do
			list[#list + 1] = { name, name }
		end
		return list
	end
	local function Report(ok, problem, success)
		message:SetText(ok and success or ("Not done: " .. tostring(problem)))
		RefreshAll()
	end

	local current = Choice(tab, 200, ProfileOptions, ns.CurrentProfileName, function(name) ns.SetProfile(name) end)
	current:SetPoint("TOPLEFT", 0, 0)
	Label(tab, "Profile in use on this character"):SetPoint("LEFT", current, "RIGHT", 10, 0)

	local nameBox = Edit(tab, 194, function() return newName end, function(text) newName = text end)
	nameBox:SetPoint("TOPLEFT", 6, -36)
	Button(tab, "New profile from current", 190, function()
		nameBox:ClearFocus()
		local ok, problem = ns.NewProfile(newName)
		if ok then newName = "" end
		Report(ok, problem, "Created and switched to the new profile.")
	end):SetPoint("LEFT", nameBox, "RIGHT", 10, 0)

	local picker = Choice(tab, 200, ProfileOptions, function()
		if not other or not ns.db.profiles[other] then other = ns.ProfileNames()[1] end
		return other
	end, function(name) other = name end)
	picker:SetPoint("TOPLEFT", 0, -72)
	local copy = Button(tab, "Copy into current", 130, function()
		local ok, problem = ns.CopyProfileFrom(other)
		Report(ok, problem, "Copied " .. tostring(other) .. " into the current profile.")
	end)
	copy:SetPoint("LEFT", picker, "RIGHT", 10, 0)
	Button(tab, "Delete", 80, function()
		local ok, problem = ns.DeleteProfile(other)
		Report(ok, problem, "Deleted " .. tostring(other) .. ".")
	end):SetPoint("LEFT", copy, "RIGHT", 8, 0)

	Button(tab, "Reset current profile to defaults", 240, function()
		ns.ResetProfile()
		Report(true, nil, "The current profile is back to defaults.")
	end):SetPoint("TOPLEFT", 0, -108)

	Label(tab, "Export / import: Export fills the box (Ctrl+A, Ctrl+C to copy). Paste a string and press Import to replace the current profile.")
		:SetPoint("TOPLEFT", 0, -144)
	local scroll, child = Scroll(tab, LIST_WIDTH - 30, 150)
	scroll:SetPoint("TOPLEFT", 0, -164)
	local box = CreateFrame("EditBox", nil, child)
	box:SetMultiLine(true)
	box:SetAutoFocus(false)
	box:SetFontObject(ChatFontNormal)
	box:SetWidth(LIST_WIDTH - 40)
	box:SetPoint("TOPLEFT")
	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnTextChanged", function(self) child:SetHeight(math.max(150, self:GetHeight())) end)
	local backdrop = scroll:CreateTexture(nil, "BACKGROUND")
	backdrop:SetAllPoints()
	backdrop:SetColorTexture(0, 0, 0, 0.4)
	scroll:EnableMouse(true)
	scroll:SetScript("OnMouseDown", function() box:SetFocus() end)

	local export = Button(tab, "Export", 100, function()
		box:SetText(ns.ExportProfile())
		box:SetFocus()
		box:HighlightText()
		message:SetText("Exported the current profile.")
	end)
	export:SetPoint("TOPLEFT", 0, -324)
	Button(tab, "Import", 100, function()
		local ok, problem = ns.ImportProfile(box:GetText())
		Report(ok, problem, "Imported into the current profile.")
	end):SetPoint("LEFT", export, "RIGHT", 8, 0)

	message:SetPoint("TOPLEFT", 0, -356)
	message:SetWidth(LIST_WIDTH)
end

--------------------------------------------------------------------------------
-- Status page
--------------------------------------------------------------------------------

local LIMITS = {
	"What this client does not give addons, and so is not shown:",
	"  - who dealt a hit: in a group, other players' hits on your target appear as white swings too",
	"  - the amount removed by a partial resist, block or absorb (only that it happened), and overkill",
	"  - a pet's melee hits while you are swinging in melee beside it (they show as white swings)",
	"  - outgoing heals, and damage-over-time from procs you do not cast (Deadly Poison)",
	"White and ability hits are told apart by matching hits to your own casts; /ctf check tests that against the damage meter.",
}

local function BuildStatus(tab)
	Check(tab, "Enable CombatTextForever", function() return ns.profile.enabled end, ns.SetEnabled,
		"Turns the addon on or off."):SetPoint("TOPLEFT", 0, 0)
	Check(tab, "Switch Blizzard's damage numbers off while CombatTextForever is showing damage, and back on when it cannot",
		function() return ns.profile.manageBlizzardText end, function(checked)
			ns.profile.manageBlizzardText = checked
			ns.ApplyBlizzardText()
		end, "Stops damage numbers appearing twice."):SetPoint("TOPLEFT", 0, -26)
	-- The same switch as the "Short ability gained" row on the Events page.
	Check(tab, "Announce short abilities such as Slice and Dice", function()
		return ns.profile.events["note.buff"].enabled
	end, function(checked)
		ns.profile.events["note.buff"].enabled = checked
	end, "Effects up to 30 seconds, and your own class and racial abilities up to 60."):SetPoint("TOPLEFT", 0, -52)

	local status = Label(tab, "")
	status:SetPoint("TOPLEFT", 0, -118)
	status:SetWidth(LIST_WIDTH)
	status:SetJustifyV("TOP")
	local function Paint()
		local lines = ns.Engine.StatusLines()
		lines[#lines + 1] = " "
		for _, line in ipairs(ns.Engine.CheckLines()) do
			lines[#lines + 1] = line
		end
		lines[#lines + 1] = " "
		for _, line in ipairs(LIMITS) do
			lines[#lines + 1] = line
		end
		status:SetText(table.concat(lines, "\n"))
	end
	Button(tab, "Refresh", 100, Paint):SetPoint("TOPLEFT", 0, -86)
	OnRefresh(Paint)
end

--------------------------------------------------------------------------------
-- Page and registration
--------------------------------------------------------------------------------

local PAGES = {
	{ "Events", BuildEvents },
	{ "Scroll Areas", BuildAreas },
	{ "Appearance", BuildAppearance },
	{ "Loot", BuildLoot },
	{ "Profiles", BuildProfiles },
	{ "Status", BuildStatus },
}

local function Build()
	local title = Label(panel, "CombatTextForever " .. ns.VERSION, "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -12)

	local tabs = {}
	local function ShowTab(shown)
		for index, tab in ipairs(tabs) do
			tab:SetShown(index == shown)
		end
		RefreshAll()
	end
	for index, page in ipairs(PAGES) do
		local tab = CreateFrame("Frame", nil, panel)
		tab:SetPoint("TOPLEFT", 16, -72)
		tab:SetPoint("BOTTOMRIGHT", -16, 8)
		tab:Hide()
		tabs[index] = tab
		Button(panel, page[1], 94, function() ShowTab(index) end):SetPoint("TOPLEFT", 16 + (index - 1) * 97, -38)
		ns.Guard("options page " .. page[1], page[2], tab)
	end
	built = true
	ShowTab(1)
end

panel:SetScript("OnShow", function()
	if not built then
		ns.Guard("options", Build)
		built = true -- never rebuild, even after an error, or widgets would pile up
	end
	RefreshAll()
end)

function ns.SetupOptions()
	if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		local ok, result = pcall(Settings.RegisterCanvasLayoutCategory, panel, "CombatTextForever")
		if ok and result then
			category = result
			pcall(Settings.RegisterAddOnCategory, category)
		end
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
	end
end

function ns.OpenOptions()
	local opened = false
	if category and Settings and Settings.OpenToCategory then
		local id = (category.GetID and category:GetID()) or category.ID
		opened = pcall(Settings.OpenToCategory, id)
	elseif InterfaceOptionsFrame_OpenToCategory then
		opened = pcall(InterfaceOptionsFrame_OpenToCategory, panel)
	end
	if not opened then ns.Print("open the game's Options, then AddOns, then CombatTextForever") end
end

ns.On("ProfileChanged", RefreshAll)
