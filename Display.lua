-- CombatTextForever display: named scroll areas and the texts animating inside them.

local ADDON, ns = ...

local Display = {}
ns.Display = Display

local SCROLL_TIME = 2.4 -- seconds for a text to cross its area at 100% animation speed
local STATIC_TIME = 3
local STICKY_TIME = 1.8
local POW_TIME = 0.18   -- how long a "pow" crit takes to shrink to normal size
local POW_SCALE = 1.9
local FADE_FROM = 0.7   -- fraction of a text's life after which it fades out
local MAX_BACKLOG = 1   -- seconds a text may be held back to avoid overlap
local LINE_PADDING = 4

ns.fonts = {
	["Game Default"] = STANDARD_TEXT_FONT,
	["Damage Numbers"] = DAMAGE_TEXT_FONT,
	["Friz Quadrata"] = "Fonts\\FRIZQT__.TTF",
	["Arial Narrow"] = "Fonts\\ARIALN.TTF",
	["Morpheus"] = "Fonts\\MORPHEUS.TTF",
	["Skurri"] = "Fonts\\SKURRI.TTF",
}

local function SharedMedia()
	return LibStub and LibStub("LibSharedMedia-3.0", true)
end

-- Built-in faces plus anything LibSharedMedia knows about, if another addon loaded it.
function ns.FontNames()
	local seen, names = {}, {}
	for name in pairs(ns.fonts) do
		seen[name] = true
		names[#names + 1] = name
	end
	local media = SharedMedia()
	if media then
		for _, name in ipairs(media:List("font")) do
			if not seen[name] then names[#names + 1] = name end
		end
	end
	table.sort(names)
	return names
end

local function FontPath(face)
	if ns.fonts[face] then return ns.fonts[face] end
	local media = SharedMedia()
	return (media and media:Fetch("font", face, true)) or STANDARD_TEXT_FONT
end

local function ApplyFont(fontString, face, size, outline)
	local flags = outline == "NONE" and "" or outline
	fontString:SetFont(FontPath(face), size, flags)
	if not fontString:GetFont() then fontString:SetFont(STANDARD_TEXT_FONT, size, flags) end
end

--------------------------------------------------------------------------------
-- Areas
--------------------------------------------------------------------------------

local areas = {}

local function PlaceArea(area, settings)
	area:ClearAllPoints()
	area:SetPoint("CENTER", UIParent, "CENTER", settings.x, settings.y)
	area:SetSize(settings.width, settings.height)
end

local function SavePosition(area)
	local settings = ns.profile.areas[area.name]
	local x, y = area:GetCenter()
	local parentX, parentY = UIParent:GetCenter()
	if not settings or not x or not parentX then return end
	settings.x, settings.y = math.floor(x - parentX + 0.5), math.floor(y - parentY + 0.5)
	PlaceArea(area, settings)
	ns.Fire("AreaMoved")
end

local function CreateArea(name)
	local area = CreateFrame("Frame", nil, UIParent)
	area.name = name
	area.lastStart = {}
	area:SetFrameStrata("HIGH")
	area:SetMovable(true)
	area:SetClampedToScreen(true)
	area:RegisterForDrag("LeftButton")
	area:SetScript("OnDragStart", area.StartMoving)
	area:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SavePosition(self)
	end)

	area.fill = area:CreateTexture(nil, "BACKGROUND")
	area.fill:SetAllPoints()
	area.fill:SetColorTexture(0.1, 0.55, 1, 0.3)
	area.label = area:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	area.label:SetPoint("CENTER")
	area.label:SetText(name .. "\n(drag me)")
	return area
end

-- Makes the on-screen areas match the profile: creates, moves, hides, locks.
function Display.Rebuild()
	local profile = ns.profile
	for name, settings in pairs(profile.areas) do
		local area = areas[name] or CreateArea(name)
		areas[name] = area
		PlaceArea(area, settings)
		area:EnableMouse(not profile.locked)
		area.fill:SetShown(not profile.locked)
		area.label:SetShown(not profile.locked)
		area:Show()
	end
	for name, area in pairs(areas) do
		if not profile.areas[name] then area:Hide() end
	end
end

--------------------------------------------------------------------------------
-- Texts
--------------------------------------------------------------------------------

local pool, active = {}, {}
local updater = CreateFrame("Frame")
updater:Hide()

local function Acquire()
	local text = table.remove(pool)
	if text then return text end
	text = CreateFrame("Frame", nil, UIParent)
	text:SetFrameStrata("HIGH")
	text.label = text:CreateFontString(nil, "OVERLAY")
	text.icon = text:CreateTexture(nil, "ARTWORK")
	return text
end

-- Seconds between two texts starting in the same area, so they do not overlap.
local function StartGap(settings, mode, lineHeight, life)
	if mode == "straight" or mode == "parabola" then
		return math.min(0.6, lineHeight / (settings.height / life))
	elseif mode == "horizontal" then
		return math.min(0.6, life * 0.15)
	end
	return 0 -- static and sticky texts stack instead
end

-- `crit` picks the crit font and the area's sticky style; `icon` is a texture or nil.
function Display.Show(areaName, message, r, g, b, crit, icon)
	local profile = ns.profile
	local settings, area = profile.areas[areaName], areas[areaName]
	if not settings or not area then return end
	local font = profile.font
	local size = crit and font.critSize or font.size
	local sticky = crit and settings.sticky ~= "none"

	local text = Acquire()
	local label = text.label
	ApplyFont(label, crit and font.crit or font.normal, size, font.outline)
	label:SetText(message)
	label:SetTextColor(r, g, b)

	local iconWidth = 0
	label:ClearAllPoints()
	text.icon:ClearAllPoints()
	if icon and profile.icons and settings.iconAlign ~= "NONE" then
		iconWidth = size + 3
		text.icon:SetTexture(icon)
		text.icon:SetSize(size, size)
		text.icon:Show()
		if settings.iconAlign == "RIGHT" then
			label:SetPoint("LEFT", text, "LEFT", 0, 0)
			text.icon:SetPoint("RIGHT", text, "RIGHT", 0, 0)
		else
			text.icon:SetPoint("LEFT", text, "LEFT", 0, 0)
			label:SetPoint("LEFT", text, "LEFT", iconWidth, 0)
		end
	else
		text.icon:Hide()
		label:SetPoint("LEFT", text, "LEFT", 0, 0)
	end
	text:SetSize((label:GetStringWidth() or 0) + iconWidth + 1, size + 2)

	local speed = 100 / math.max(10, profile.animationSpeed)
	text.area, text.settings = area, settings
	text.mode = sticky and "sticky" or settings.style
	text.pow = sticky and settings.sticky == "pow"
	text.life = (sticky and STICKY_TIME or text.mode == "static" and STATIC_TIME or SCROLL_TIME) * speed
	text.lineHeight = size + LINE_PADDING
	text.opacity = font.alpha / 100

	local now = GetTime()
	local earliest = (area.lastStart[text.mode] or 0) + StartGap(settings, text.mode, text.lineHeight, text.life)
	text.start = math.min(math.max(now, earliest), now + MAX_BACKLOG)
	area.lastStart[text.mode] = text.start

	text:SetAlpha(0)
	text:Show()
	active[#active + 1] = text
	updater:Show()
end

local ANCHOR_X = { LEFT = 0, CENTER = 0.5, RIGHT = 1 }
local stacked = {} -- [area] = { static = n, sticky = n }, rebuilt every frame

local function Stack(area, mode)
	local counts = stacked[area]
	if not counts then
		counts = { static = 0, sticky = 0 }
		stacked[area] = counts
	end
	local slot = counts[mode]
	counts[mode] = slot + 1
	return slot
end

local function Update()
	local now = GetTime()
	for _, counts in pairs(stacked) do
		counts.static, counts.sticky = 0, 0
	end

	-- Newest first, so stacked texts are pushed along by the ones that arrive after them.
	for i = #active, 1, -1 do
		local text = active[i]
		local age = now - text.start
		if age >= text.life then
			text:Hide()
			table.remove(active, i)
			pool[#pool + 1] = text
		elseif age >= 0 then
			local settings = text.settings
			local width, height = settings.width, settings.height
			local progress = age / text.life
			local up = settings.direction ~= "down"
			local x = (ANCHOR_X[settings.align] or 0.5) * width
			local y, scale = 0, 1

			if text.mode == "sticky" then
				y = height / 2 + Stack(text.area, "sticky") * text.lineHeight * (up and 1 or -1)
				if text.pow and age < POW_TIME then
					scale = POW_SCALE - (POW_SCALE - 1) * (age / POW_TIME)
				end
			elseif text.mode == "static" then
				local offset = Stack(text.area, "static") * text.lineHeight
				y = up and offset or (height - offset)
			elseif text.mode == "horizontal" then
				x = (settings.behavior == "left" and (1 - progress) or progress) * width
				y = height / 2
			else
				y = (up and progress or (1 - progress)) * height
				if text.mode == "parabola" then
					local bulge = 4 * progress * (1 - progress) * width * 0.5
					x = x + (settings.behavior == "left" and -bulge or bulge)
				end
			end

			text:SetScale(scale)
			text:ClearAllPoints()
			text:SetPoint(settings.align, text.area, "BOTTOMLEFT", x / scale, y / scale)
			local fade = progress < FADE_FROM and 1 or (1 - progress) / (1 - FADE_FROM)
			text:SetAlpha(fade * text.opacity)
		end
	end
	if #active == 0 then updater:Hide() end
end

updater:SetScript("OnUpdate", function()
	if not ns.Guard("display", Update) then
		-- A broken frame must not repeat every frame: drop what is on screen.
		for i = #active, 1, -1 do
			active[i]:Hide()
			pool[#pool + 1] = table.remove(active, i)
		end
		updater:Hide()
	end
end)

-- Sample texts for positioning an area and judging its settings.
function Display.Test(areaName)
	Display.Show(areaName, areaName .. " 123", 1, 1, 1, false)
	Display.Show(areaName, "Sinister Strike 456", 1, 0.82, 0, false)
	Display.Show(areaName, "Crit 789", 1, 0.5, 0.2, true)
end
