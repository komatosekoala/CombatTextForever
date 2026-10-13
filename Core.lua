-- CombatTextForever core: shared helpers, saved settings, profiles, Blizzard combat text
-- CVars and slash commands.

local ADDON, ns = ...

ns.VERSION = "1.0.0"

local issecret = issecretvalue or function() return false end
ns.issecret = issecret

local ERROR_LIMIT = 10
local EXPORT_PREFIX = "CTF1:"

-- Blizzard's own damage numbers. They are switched off while CombatTextForever is showing
-- outgoing damage and back on whenever it cannot (unreadable contexts), so
-- numbers are never drawn twice and never missing. Healing and pet CVars are left alone
-- because this client gives addons no way to replace those numbers.
local DAMAGE_CVARS = {
	"floatingCombatTextCombatDamage_v2",
	"floatingCombatTextCombatLogPeriodicSpells_v2",
}

local GetCVarValue = (C_CVar and C_CVar.GetCVar) or GetCVar
local SetCVarValue = (C_CVar and C_CVar.SetCVar) or SetCVar

function ns.Print(msg)
	print("|cffffd200CombatTextForever|r " .. tostring(msg))
end

function ns.Copy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = ns.Copy(v)
	end
	return copy
end

function ns.SpellName(id)
	local name
	if C_Spell and C_Spell.GetSpellName then
		name = C_Spell.GetSpellName(id)
	elseif GetSpellInfo then
		name = GetSpellInfo(id)
	end
	if issecret(name) or name == nil then return "?" end
	return name
end

local errorCount = 0

-- Runs fn so that a bug costs one chat line instead of an error popup per hit. The
-- first message for each call site is kept in the saved variables.
function ns.Guard(where, fn, ...)
	local ok, err = pcall(fn, ...)
	if ok then return true end
	errorCount = errorCount + 1
	local errors = ns.db and ns.db.debug.errors
	if errors and errors[where] then
		errors[where].count = errors[where].count + 1
	else
		if errors then errors[where] = { count = 1, first = tostring(err) } end
		ns.Print(where .. " error: " .. tostring(err))
	end
	if errorCount == ERROR_LIMIT and ns.Engine then
		ns.Engine.Disable()
		ns.Print("combat events switched off after repeated errors. /reload to try again.")
	end
	return false
end

local listeners = {}

function ns.On(event, fn)
	listeners[event] = listeners[event] or {}
	table.insert(listeners[event], fn)
end

function ns.Fire(event, ...)
	for _, fn in ipairs(listeners[event] or {}) do
		ns.Guard(event, fn, ...)
	end
end

--------------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------------

ns.AREA_TEMPLATE = {
	style = "straight", -- straight, parabola, horizontal, static
	direction = "up",   -- up, down
	behavior = "right", -- parabola: side it curves to; horizontal: way it travels
	align = "CENTER",   -- LEFT, CENTER, RIGHT
	iconAlign = "LEFT", -- LEFT, RIGHT, NONE
	sticky = "pow",     -- crits: pow, hold, none
	width = 200,
	height = 260,
	x = 0,
	y = 0,
}

local function Area(overrides)
	local area = ns.Copy(ns.AREA_TEMPLATE)
	for k, v in pairs(overrides) do
		area[k] = v
	end
	return area
end

-- Areas that always exist. Their positions are also what "reset position" returns to.
ns.DEFAULT_AREAS = {
	Outgoing = Area({ x = 280, y = 20, align = "LEFT" }),
	Incoming = Area({ x = -280, y = 20, align = "RIGHT", iconAlign = "RIGHT" }),
	Notification = Area({ x = 0, y = 230, width = 420, height = 120, style = "static", sticky = "hold" }),
}

ns.defaults = {
	enabled = true,
	manageBlizzardText = true,
	locked = true,
	icons = true,
	names = false,
	classColors = true,
	animationSpeed = 100,
	font = { normal = "Game Default", crit = "Game Default", outline = "NONE", size = 20, critSize = 30, alpha = 100 },
	schoolColors = {
		outgoing = true, -- procs and poisons take the colour of their school
		incoming = true, -- so does spell damage taken: orange for fire, purple for shadow, ...
		colors = {
			[1] = { 1, 1, 1 },        -- physical
			[2] = { 1, 0.9, 0.5 },    -- holy
			[4] = { 1, 0.5, 0.2 },    -- fire
			[8] = { 0.45, 0.9, 0.4 }, -- nature
			[16] = { 0.5, 0.8, 1 },   -- frost
			[32] = { 0.7, 0.5, 1 },   -- shadow
			[64] = { 1, 0.6, 1 },     -- arcane
		},
	},
	partial = {
		glancing = { enabled = true, color = { 0.75, 0.75, 0.75 } },
		crushing = { enabled = true, color = { 1, 0.3, 0.3 } },
		blocked = { enabled = true, color = { 0.65, 0.65, 1 } },
		absorbed = { enabled = true, color = { 1, 1, 0.55 } },
		resisted = { enabled = true, color = { 0.75, 0.5, 1 } },
	},
	areas = ns.DEFAULT_AREAS,
	loot = {
		items = true,
		money = true,
		currency = true,
		quality = { [0] = false, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true },
		allow = "",
		exclude = "",
	},
	events = {},
	migrated = {}, -- one-time adjustments already applied to this profile
}

-- Makes `data` match `template`: missing or wrongly typed fields take the template's value.
local function Conform(data, template)
	for key, default in pairs(template) do
		if type(data[key]) ~= type(default) then
			data[key] = ns.Copy(default)
		elseif type(default) == "table" then
			Conform(data[key], default)
		end
	end
	return data
end

local function SameColor(a, b)
	for i = 1, 3 do
		if math.abs(a[i] - b[i]) > 0.01 then return false end
	end
	return true
end

local function ConformProfile(profile)
	-- School colouring used to be one switch for both directions.
	local schools = profile.schoolColors
	if type(schools) == "table" and schools.enabled ~= nil then
		if schools.enabled == false then schools.outgoing, schools.incoming = false, false end
		schools.enabled = nil
	end
	Conform(profile, ns.defaults)
	-- Incoming school colouring was switched off by default for one build. The owner wants
	-- spell damage taken coloured by school, so it is switched back on once for profiles
	-- that passed through that build.
	if not profile.migrated.schoolIncoming then
		profile.migrated.schoolIncoming = true
		profile.schoolColors.incoming = true
	end
	for name, area in pairs(profile.areas) do
		if type(name) ~= "string" or type(area) ~= "table" then
			profile.areas[name] = nil
		else
			Conform(area, ns.AREA_TEMPLATE)
		end
	end
	for key in pairs(profile.events) do
		if not ns.events[key] then profile.events[key] = nil end -- an event that no longer exists
	end
	for key, event in pairs(ns.events) do
		if type(profile.events[key]) ~= "table" then profile.events[key] = {} end
		local settings = Conform(profile.events[key], event.defaults)
		if not profile.areas[settings.area] then settings.area = event.defaults.area end
		for _, retired in ipairs(ns.retiredColors[key] or {}) do
			if SameColor(settings.color, retired) then
				settings.color = ns.Copy(event.defaults.color)
				break
			end
		end
	end
	return profile
end

--------------------------------------------------------------------------------
-- Export / import. A profile becomes a plain-text string; importing parses it with
-- a small reader of its own (nothing is ever executed) and then conforms the result.
--------------------------------------------------------------------------------

local function Serialize(value, out)
	local kind = type(value)
	if kind == "number" then
		out[#out + 1] = "n" .. tostring(value) .. ";"
	elseif kind == "boolean" then
		out[#out + 1] = value and "T" or "F"
	elseif kind == "string" then
		out[#out + 1] = "s" .. #value .. ":" .. value
	elseif kind == "table" then
		out[#out + 1] = "{"
		for k, v in pairs(value) do
			local keyKind, valueKind = type(k), type(v)
			if (keyKind == "number" or keyKind == "string")
				and (valueKind == "number" or valueKind == "boolean" or valueKind == "string" or valueKind == "table") then
				Serialize(k, out)
				Serialize(v, out)
			end
		end
		out[#out + 1] = "}"
	end
end

local function Deserialize(text, pos)
	local tag = text:sub(pos, pos)
	if tag == "n" then
		local stop = text:find(";", pos, true)
		local number = stop and tonumber(text:sub(pos + 1, stop - 1))
		if not number then error("bad number at " .. pos) end
		return number, stop + 1
	elseif tag == "T" then
		return true, pos + 1
	elseif tag == "F" then
		return false, pos + 1
	elseif tag == "s" then
		local colon = text:find(":", pos, true)
		local length = colon and tonumber(text:sub(pos + 1, colon - 1))
		if not length or length < 0 or colon + length > #text then error("bad string at " .. pos) end
		return text:sub(colon + 1, colon + length), colon + length + 1
	elseif tag == "{" then
		local result = {}
		pos = pos + 1
		while text:sub(pos, pos) ~= "}" do
			if pos > #text then error("unfinished table") end
			local key, value
			key, pos = Deserialize(text, pos)
			value, pos = Deserialize(text, pos)
			result[key] = value
		end
		return result, pos + 1
	end
	error("unexpected data at " .. pos)
end

-- "|" would be read as an escape code by an edit box, so it never appears in an export.
local function Escape(text)
	return (text:gsub("~", "~t"):gsub("|", "~p"):gsub("\n", "~n"))
end

local function Unescape(text)
	return (text:gsub("~n", "\n"):gsub("~p", "|"):gsub("~t", "~"))
end

--------------------------------------------------------------------------------
-- Profiles
--------------------------------------------------------------------------------

local charKey

function ns.CurrentProfileName()
	return ns.db.chars[charKey] or "Default"
end

function ns.ProfileNames()
	local names = {}
	for name in pairs(ns.db.profiles) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

function ns.SetProfile(name)
	if not ns.db.profiles[name] then return false end
	ns.db.chars[charKey] = name
	ns.profile = ConformProfile(ns.db.profiles[name])
	ns.Fire("ProfileChanged")
	return true
end

-- Creates `name` as a copy of the current profile and switches to it.
function ns.NewProfile(name)
	name = (name or ""):match("^%s*(.-)%s*$")
	if name == "" then return false, "type a name first" end
	if ns.db.profiles[name] then return false, "a profile with that name already exists" end
	ns.db.profiles[name] = ns.Copy(ns.profile)
	ns.SetProfile(name)
	return true
end

-- Overwrites the current profile with a copy of another one.
function ns.CopyProfileFrom(name)
	local source = ns.db.profiles[name]
	if not source or name == ns.CurrentProfileName() then return false, "pick a different profile to copy from" end
	ns.db.profiles[ns.CurrentProfileName()] = ns.Copy(source)
	ns.SetProfile(ns.CurrentProfileName())
	return true
end

function ns.ResetProfile()
	ns.db.profiles[ns.CurrentProfileName()] = {}
	ns.SetProfile(ns.CurrentProfileName())
end

function ns.DeleteProfile(name)
	if name == "Default" then return false, "the Default profile cannot be deleted" end
	if name == ns.CurrentProfileName() then return false, "switch to another profile before deleting this one" end
	if not ns.db.profiles[name] then return false, "no such profile" end
	ns.db.profiles[name] = nil
	for character, profile in pairs(ns.db.chars) do
		if profile == name then ns.db.chars[character] = "Default" end
	end
	return true
end

function ns.ExportProfile()
	local out = {}
	Serialize(ns.profile, out)
	return EXPORT_PREFIX .. Escape(table.concat(out))
end

-- Replaces the current profile's settings with an exported string.
function ns.ImportProfile(text)
	text = (text or ""):gsub("%s+$", ""):gsub("^%s+", "")
	if text:sub(1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then return false, "that is not a CombatTextForever export" end
	local ok, data = pcall(Deserialize, Unescape(text:sub(#EXPORT_PREFIX + 1)), 1)
	if not ok or type(data) ~= "table" then return false, "the export is damaged or incomplete" end
	ns.db.profiles[ns.CurrentProfileName()] = data
	ns.SetProfile(ns.CurrentProfileName())
	return true
end

--------------------------------------------------------------------------------
-- Blizzard combat text
--------------------------------------------------------------------------------

local function RestoreBlizzardText()
	local saved = ns.db.savedCVars
	if not saved then return end
	for _, name in ipairs(DAMAGE_CVARS) do
		if saved[name] ~= nil then pcall(SetCVarValue, name, saved[name]) end
	end
	ns.db.savedCVars = nil
end

function ns.ApplyBlizzardText()
	local profile = ns.profile
	if not (profile.enabled and profile.manageBlizzardText) then
		RestoreBlizzardText()
		return
	end
	if not ns.db.savedCVars then
		local saved = {}
		for _, name in ipairs(DAMAGE_CVARS) do
			saved[name] = GetCVarValue(name)
		end
		ns.db.savedCVars = saved
	end
	local wanted = ns.Engine.OutgoingLive() and "0" or "1"
	for _, name in ipairs(DAMAGE_CVARS) do
		local current = GetCVarValue(name)
		if current ~= nil and current ~= wanted then pcall(SetCVarValue, name, wanted) end
	end
end

function ns.SetEnabled(enabled)
	ns.profile.enabled = enabled and true or false
	if ns.profile.enabled then
		ns.Engine.Enable()
	else
		ns.Engine.Disable()
	end
	ns.ApplyBlizzardText()
	ns.Fire("EnabledChanged")
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local commands = {}

commands[""] = function() ns.OpenOptions() end
commands.options = commands[""]

function commands.on() ns.SetEnabled(true) ns.Print("enabled") end
function commands.off() ns.SetEnabled(false) ns.Print("disabled, Blizzard's combat text settings restored") end

function commands.status()
	for _, line in ipairs(ns.Engine.StatusLines()) do
		ns.Print(line)
	end
end

function commands.check()
	for _, line in ipairs(ns.Engine.CheckLines()) do
		ns.Print(line)
	end
end

function commands.test()
	for name in pairs(ns.profile.areas) do
		ns.Display.Test(name)
	end
end

function commands.unlock()
	ns.profile.locked = false
	ns.Display.Rebuild()
	ns.Print("scroll areas unlocked: drag them, then /ctf lock")
end

function commands.lock()
	ns.profile.locked = true
	ns.Display.Rebuild()
	ns.Print("scroll areas locked")
end

function commands.help()
	ns.Print("/ctf - options   /ctf status   /ctf test   /ctf check   /ctf lock   /ctf unlock   /ctf on   /ctf off")
end

SLASH_COMBATTEXTFOREVER1 = "/ctf"
SLASH_COMBATTEXTFOREVER2 = "/combattextforever"
SlashCmdList.COMBATTEXTFOREVER = function(msg)
	local cmd = (msg or ""):lower():match("^%s*(.-)%s*$")
	ns.Guard("/ctf " .. cmd, commands[cmd] or commands.help)
end

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

local function OnLogin()
	CombatTextForeverDB = type(CombatTextForeverDB) == "table" and CombatTextForeverDB or {}
	local db = CombatTextForeverDB
	ns.db = db
	db.profiles = type(db.profiles) == "table" and db.profiles or {}
	db.chars = type(db.chars) == "table" and db.chars or {}
	db.spells = type(db.spells) == "table" and db.spells or {}
	db.debug = { fights = type(db.debug) == "table" and db.debug.fights or {}, errors = {}, unknownDescriptors = {} }
	db.profiles.Default = db.profiles.Default or {}

	charKey = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
	if not db.profiles[db.chars[charKey] or ""] then db.chars[charKey] = "Default" end
	ns.profile = ConformProfile(db.profiles[db.chars[charKey]])

	-- Values left behind by a crash are put back before they are saved again.
	RestoreBlizzardText()

	ns.Display.Rebuild()
	if ns.profile.enabled then ns.Engine.Enable() end
	ns.ApplyBlizzardText()
	ns.SetupOptions()
	ns.Print(format("v%s loaded. /ctf opens the options.", ns.VERSION))
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		ns.Guard("startup", OnLogin)
	elseif not ns.db then
		return
	elseif event == "PLAYER_LOGOUT" then
		-- Leave the client as it was found, so removing the addon never strands a CVar.
		ns.Guard("logout", RestoreBlizzardText)
	else
		ns.Guard("blizzard text", ns.ApplyBlizzardText)
	end
end)

ns.On("ProfileChanged", function()
	ns.Display.Rebuild()
	if ns.profile.enabled then ns.Engine.Enable() else ns.Engine.Disable() end
	ns.ApplyBlizzardText()
end)
