-- CombatTextForever event registry: every event the addon can show, with its default
-- toggle, colour, format string and scroll area. The options panel edits per-profile
-- copies of these defaults.
--
-- Format tokens: %a amount, %s spell or item name, %n target name, %r result
-- (Miss, Dodge, ...), %e extra (glancing / crushing / partial tags, or the message).

local ADDON, ns = ...

ns.events = {}
ns.eventList = {}

-- Colours that used to be defaults, by event. A saved profile still holding one of these
-- never had its colour chosen by the user, so it follows the default to its new value.
ns.retiredColors = {}

ns.categories = {
	{ key = "outgoing", name = "Outgoing Player" },
	{ key = "incoming", name = "Incoming Player" },
	{ key = "petout", name = "Outgoing Pet" },
	{ key = "petin", name = "Incoming Pet" },
	{ key = "note", name = "Notification" },
}

ns.MISS_TYPES = { "MISS", "DODGE", "PARRY", "BLOCK", "ABSORB", "RESIST", "IMMUNE", "EVADE", "DEFLECT", "REFLECT" }

local MISS_NAMES = {
	MISS = "miss", DODGE = "dodge", PARRY = "parry", BLOCK = "block", ABSORB = "absorb",
	RESIST = "resist", IMMUNE = "immune", EVADE = "evade", DEFLECT = "deflect", REFLECT = "reflect",
}

local function Add(category, key, name, color, format, area, enabled)
	ns.events[key] = {
		category = category,
		name = name,
		defaults = { enabled = enabled ~= false, color = color, format = format, area = area },
	}
	ns.eventList[category] = ns.eventList[category] or {}
	table.insert(ns.eventList[category], key)
end

local function Dim(color)
	return { color[1] * 0.8, color[2] * 0.8, color[3] * 0.8 }
end

-- A colour taken from one of the game's own tables (chat colours, Blizzard's combat
-- text colours), so a default matches what the game itself uses. `fallback` is
-- Blizzard's stock value, used when the table is not loaded.
local function GameColor(source, key, fallback)
	local info = type(source) == "table" and source[key]
	if type(info) == "table" and type(info.r) == "number" and type(info.g) == "number" and type(info.b) == "number" then
		return { info.r, info.g, info.b }
	end
	return fallback
end

-- Records a colour that used to be the default for an event.
local function Retire(key, color)
	ns.retiredColors[key] = ns.retiredColors[key] or {}
	table.insert(ns.retiredColors[key], color)
end

-- Adds hit, crit, any extra variants, and one event per miss type for a class of hits.
-- Every class owns its own events, so no two classes can share a colour or a format
-- by accident and a white swing can never be drawn as an ability hit.
-- `retired` lists the class's previous default colours. `missColor` replaces the usual
-- dimmed colour for the miss events.
local function AddHitClass(category, prefix, name, color, hitFormat, missFormat, area, extras, retired, missColor)
	Add(category, prefix .. ".HIT", name .. " hit", color, hitFormat, area)
	Add(category, prefix .. ".CRIT", name .. " crit", color, hitFormat, area)
	for _, extra in ipairs(extras or {}) do
		Add(category, prefix .. "." .. extra.variant, extra.name, extra.color, hitFormat, area)
	end
	for _, miss in ipairs(ns.MISS_TYPES) do
		Add(category, prefix .. "." .. miss, name .. " " .. MISS_NAMES[miss], missColor or Dim(color), missFormat, area)
	end
	for _, old in ipairs(retired or {}) do
		Retire(prefix .. ".HIT", old)
		Retire(prefix .. ".CRIT", old)
		for _, miss in ipairs(ns.MISS_TYPES) do
			Retire(prefix .. "." .. miss, Dim(old))
		end
	end
end

-- Outgoing Player ---------------------------------------------------------------

AddHitClass("outgoing", "out.white", "Melee swing", { 1, 1, 1 }, "%a%e", "%r", "Outgoing",
	{ { variant = "GLANCING", name = "Melee swing glancing blow", color = { 0.75, 0.75, 0.75 } } })
AddHitClass("outgoing", "out.yellow", "Ability", { 1, 0.82, 0 }, "%s %a%e", "%s %r", "Outgoing")
-- Ticks of my own bleeds and curses (Garrote, Rupture, Corruption).
AddHitClass("outgoing", "out.dot", "Damage over time", { 0.9, 0.7, 0.25 }, "%s %a%e", "%s %r", "Outgoing")
AddHitClass("outgoing", "out.ranged", "Ranged attack", { 0.45, 0.78, 1 }, "%s %a%e", "%s %r", "Outgoing")
AddHitClass("outgoing", "out.other", "Proc or poison", { 0.55, 0.9, 0.45 }, "%a%e", "%r", "Outgoing")

-- Outgoing Pet ------------------------------------------------------------------

-- The pet's hits on my target. "(Pet)" follows the number so one is never read as a
-- white swing; %s is the pet ability's name when the hit came from one.
AddHitClass("petout", "out.pet", "Pet", { 1, 0.8, 0.6 }, "%s %a (Pet)%e", "%s %r (Pet)", "Outgoing")

-- Incoming Player ---------------------------------------------------------------

-- Damage taken uses the colours of Blizzard's own incoming combat text: red for melee
-- and purple for spells, with misses in the same colour as hits.
local takenMelee = GameColor(COMBAT_TEXT_TYPE_INFO, "DAMAGE", { 1, 0.1, 0.1 })
local takenSpell = GameColor(COMBAT_TEXT_TYPE_INFO, "SPELL_DAMAGE", { 0.79, 0.3, 0.85 })

AddHitClass("incoming", "in.melee", "Melee taken", takenMelee, "-%a%e", "%r!", "Incoming",
	{ { variant = "CRUSHING", name = "Melee taken crushing blow", color = { 1, 0.1, 0.1 } } },
	{ { 1, 0.3, 0.3 }, { 0.8, 0.15, 0.15 } }, takenMelee)
AddHitClass("incoming", "in.spell", "Spell taken", takenSpell, "-%a%e", "%r!", "Incoming", nil,
	{ { 0.85, 0.45, 1 }, { 0.62, 0.32, 0.8 } }, takenSpell)
Add("incoming", "in.heal.HIT", "Heal received", { 0.3, 1, 0.3 }, "+%a", "Incoming")
Add("incoming", "in.heal.CRIT", "Heal received crit", { 0.3, 1, 0.3 }, "+%a", "Incoming")
Add("incoming", "in.power.HIT", "Power gained", { 1, 1, 0.4 }, "+%a", "Incoming")

-- Incoming Pet ------------------------------------------------------------------

AddHitClass("petin", "petin.melee", "Pet melee taken", { 0.7, 0.38, 0.3 }, "Pet -%a%e", "Pet %r!", "Incoming",
	{ { variant = "CRUSHING", name = "Pet melee taken crushing blow", color = { 1, 0.3, 0.2 } } }, { { 0.9, 0.5, 0.4 } })
AddHitClass("petin", "petin.spell", "Pet spell taken", { 0.58, 0.42, 0.72 }, "Pet -%a%e", "Pet %r!", "Incoming", nil, { { 0.75, 0.55, 0.9 } })
Add("petin", "petin.heal.HIT", "Pet heal received", { 0.4, 0.9, 0.4 }, "Pet +%a", "Incoming")
Add("petin", "petin.heal.CRIT", "Pet heal received crit", { 0.4, 0.9, 0.4 }, "Pet +%a", "Incoming")

-- Notification ------------------------------------------------------------------

Add("note", "note.combat_enter", "Entering combat", { 0.7, 0.2, 0.2 }, "+Combat", "Notification")
Add("note", "note.combat_leave", "Leaving combat", { 0.25, 0.6, 0.25 }, "-Combat", "Notification")
Retire("note.combat_enter", { 1, 0.5, 0.5 })
Retire("note.combat_leave", { 0.6, 1, 0.6 })
-- An effect of 30 seconds or less gained by the player (Slice and Dice, Blood Fury), or
-- one of the player's own class or racial abilities lasting up to 60 seconds.
Add("note", "note.buff", "Short ability gained", { 1, 1, 1 }, "+%s", "Notification")
Add("note", "note.combo", "Combo point gained", { 1, 0.65, 0.2 }, "%a CP", "Notification", false)
Add("note", "note.combo_full", "Combo points full", { 1, 0.4, 0.1 }, "%a CP - finish it!", "Notification")
Add("note", "note.low_health", "Low health", { 1, 0.2, 0.2 }, "Low health! (%a)", "Notification")
Add("note", "note.xp", "Experience gained", { 0.65, 0.5, 1 }, "+%a XP", "Notification", false)
Add("note", "note.rep", "Reputation change", GameColor(ChatTypeInfo, "COMBAT_FACTION_CHANGE", { 0.5, 0.5, 1 }), "%e", "Notification")
Add("note", "note.honor", "Honor gained", { 0.6, 0.08, 0.08 }, "%e", "Notification")
Add("note", "note.skill", "Skill increased", GameColor(ChatTypeInfo, "SKILL", { 0.33, 0.33, 1 }), "%e", "Notification")
Retire("note.rep", { 0.5, 0.65, 1 })
Retire("note.honor", { 1, 0.75, 0.3 })
Retire("note.skill", { 0.45, 0.65, 1 })
Add("note", "note.loot_item", "Item looted", { 1, 1, 1 }, "+%a %s", "Notification")
Add("note", "note.loot_money", "Money looted", { 1, 0.85, 0.1 }, "+%e", "Notification")
Add("note", "note.loot_currency", "Currency gained", { 0.9, 0.8, 0.5 }, "%e", "Notification")

--------------------------------------------------------------------------------
-- Formatting and posting
--------------------------------------------------------------------------------

-- Shows an event if the profile has it enabled. `tokens` must hold a, s, n, r and e.
-- Returns true when something was shown.
function ns.Post(key, tokens, crit, icon, color)
	local settings = ns.profile.events[key]
	if not settings or not settings.enabled then return false end
	local text = settings.format:gsub("%%(%a)", tokens)
	text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
	if text == "" then return false end
	color = color or settings.color
	ns.Display.Show(settings.area, text, color[1], color[2], color[3], crit, icon)
	return true
end
