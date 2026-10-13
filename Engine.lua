-- CombatTextForever engine: turns what this client lets addons read into classified events.
--
-- There is no combat log here. Readable in combat are UNIT_COMBAT (amount, hit type and
-- school for a unit; no source, no spell) and UNIT_SPELLCAST_SUCCEEDED for the player.
-- Outgoing classes are therefore derived, in this order:
--   yellow  a hit on the target in the same frame as one of my casts, or the first hit
--           of the right school after a cast whose hit lands late (Fireball, Aimed Shot)
--   ranged  the first physical hit after one of my thrown or shot auto attacks
--   pet     a hit in the same frame as one of my pet's casts, or a physical hit nothing
--           else accounts for while my pet is on the target and I cannot be swinging
--   white   any other physical hit
--   other   any other non-physical hit (poison and weapon procs)
-- Hits on the target carry no source. Outgoing damage is shown in groups all the same,
-- by the owner's decision, so another player's hit on the same target appears as a
-- white swing (or as "other" if it is not physical). Hits on the player and pet are
-- unambiguous.

local ADDON, ns = ...

local Engine = {}
ns.Engine = Engine

local issecret = ns.issecret

local SCHOOL_PHYSICAL = 1
local AUTO_ATTACK = 6603
local AUTO_SHOT = 75
local MAX_COMBO_POINTS = 5
local LOW_HEALTH, LOW_HEALTH_RESET = 0.35, 0.5
local RANGED_WINDOW = 2      -- seconds a thrown or shot attack may take to land after its cast event
local LATE_WINDOW = 2.5      -- seconds a cast-time or projectile spell may take to land
local AUTO_SHOT_GRACE = 3.5  -- seconds after a ranged auto attack in which I cannot be in melee
local MIN_CASTS_TO_JUDGE = 4 -- casts seen before a spell can be ruled out as non-damaging
local STREAM_ALIVE = 5       -- seconds since the last readable hit for an unclaimed cast to count
local SECRET_LIMIT = 20      -- unreadable events in a row before a context is switched off
local MAX_FIGHTS = 20
local MAX_LINES = 300

-- Seconds each outgoing class waits to merge identical events. Only "other" merges by
-- default, so two poison procs landing together read as one line.
local MERGE_WINDOW = { white = 0, yellow = 0, ranged = 0, pet = 0, other = 0.3 }

-- School masks by the word a spell description uses for them.
local SCHOOL_WORDS = { holy = 2, fire = 4, nature = 8, frost = 16, shadow = 32, arcane = 64 }

-- Ranged auto attacks. Their hit lands after the cast event, and firing one means I am
-- not in melee.
local RANGED_SPELLS = {
	[75] = true,   -- Auto Shot
	[2764] = true, -- Throw
	[2480] = true, -- Shoot Bow
	[7918] = true, -- Shoot Gun
	[7919] = true, -- Shoot Crossbow
	[5019] = true, -- Shoot (wand)
}

local MISS_RESULTS = {}
for _, result in ipairs(ns.MISS_TYPES) do
	MISS_RESULTS[result] = true
end
local FULL_AVOID_DESCRIPTORS = { ABSORB = true, BLOCK = true, RESIST = true }
local PARTIAL_KINDS = { BLOCK = "blocked", ABSORB = "absorbed", RESIST = "resisted" }

local frame = CreateFrame("Frame")
local driver = CreateFrame("Frame")
driver:Hide()
local unitFrames = {}
local enabled = false

local tokens = { a = "", s = "", n = "", r = "", e = "" }

local function SetTokens(amount, spell, name, result, extra)
	tokens.a, tokens.s, tokens.n, tokens.r, tokens.e = amount or "", spell or "", name or "", result or "", extra or ""
	return tokens
end

--------------------------------------------------------------------------------
-- Context and capability
--------------------------------------------------------------------------------

local encounterActive = false
local restricted = {} -- [context] = true once its events proved unreadable this session
local secretStreak = {}
local counters = {}   -- [context] = { received, readable, shown }
local lastReadable = 0

local function Context()
	local base = "open world"
	if encounterActive or (IsEncounterInProgress and IsEncounterInProgress()) then
		base = "boss encounter"
	elseif IsInInstance() then
		base = "instance"
	end
	return IsInGroup() and (base .. ", grouped") or base
end
Engine.Context = Context

local function Counters(ctx)
	local c = counters[ctx]
	if not c then
		c = { received = 0, readable = 0, shown = 0 }
		counters[ctx] = c
	end
	return c
end

-- True while outgoing damage on the target is being shown by this addon.
function Engine.OutgoingLive()
	return enabled and not restricted[Context()]
end

-- Counts one UNIT_COMBAT event and reports whether its fields can be read.
local function Readable(ctx, ...)
	local c = Counters(ctx)
	c.received = c.received + 1
	for i = 1, select("#", ...) do
		if issecret((select(i, ...))) then
			secretStreak[ctx] = (secretStreak[ctx] or 0) + 1
			if secretStreak[ctx] >= SECRET_LIMIT and not restricted[ctx] then
				restricted[ctx] = true
				ns.ApplyBlizzardText()
			end
			return false
		end
	end
	secretStreak[ctx] = 0
	c.readable = c.readable + 1
	return true
end

--------------------------------------------------------------------------------
-- Building events
--------------------------------------------------------------------------------

-- Builds an event from UNIT_COMBAT's fields, or nil for things that are not hits.
local function ParseHit(action, descriptor, amount, school)
	local e = { amount = 0, hits = 1, school = school }
	if action == "WOUND" then
		if amount == 0 and FULL_AVOID_DESCRIPTORS[descriptor] then
			e.result = descriptor
			return e
		end
		e.result, e.amount = "HIT", amount
		if descriptor == "CRITICAL" then
			e.crit = true
		elseif descriptor == "GLANCING" then
			e.glancing = true
		elseif descriptor == "CRUSHING" then
			e.crushing = true
		elseif descriptor ~= "" then
			e.partial = descriptor:match("^(%u+)_REDUCED$")
			if not e.partial then
				-- An unrecognised hit type is shown as-is rather than dropped.
				e.tag = descriptor
				local unknown = ns.db.debug.unknownDescriptors
				unknown[descriptor] = (unknown[descriptor] or 0) + 1
			end
		end
		return e
	end
	if MISS_RESULTS[action] then
		e.result = action
		return e
	end
end

local function Trailer(kind, label)
	local settings = ns.profile.partial[kind]
	if settings and not settings.enabled then return "" end
	local c = settings and settings.color or { 0.8, 0.8, 0.8 }
	return format(" |cff%02x%02x%02x(%s)|r", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5), label)
end

local function Extras(e)
	local text = ""
	if e.glancing then text = text .. Trailer("glancing", "glancing") end
	if e.crushing then text = text .. Trailer("crushing", "crushing") end
	if e.partial then
		local kind = PARTIAL_KINDS[e.partial]
		text = text .. Trailer(kind, kind or e.partial:lower())
	end
	if e.tag then text = text .. " (" .. e.tag:lower() .. ")" end
	if e.hits > 1 then text = text .. format(" (%d hits)", e.hits) end
	return text
end

local function ResultLabel(result)
	local label = _G[result] -- Blizzard's localized "Miss", "Dodge", ...
	return type(label) == "string" and label or result
end

-- hit, crit, glancing (white swings only), crushing (melee taken only), or the miss type.
local function Variant(e, special)
	if e.result ~= "HIT" then return e.result end
	if e.crit then return "CRIT" end
	if special == "GLANCING" and e.glancing then return "GLANCING" end
	if special == "CRUSHING" and e.crushing then return "CRUSHING" end
	return "HIT"
end

-- `side` is "outgoing" or "incoming": each can be coloured by school independently.
local function SchoolColor(school, side)
	local schools = ns.profile.schoolColors
	return schools[side] and schools.colors[school] or nil
end

local function SpellIcon(spellID)
	local icon
	if C_Spell and C_Spell.GetSpellTexture then
		icon = C_Spell.GetSpellTexture(spellID)
	elseif GetSpellTexture then
		icon = GetSpellTexture(spellID)
	end
	if issecret(icon) then return nil end
	return icon
end

local function TargetName()
	local name = UnitName("target")
	if issecret(name) or type(name) ~= "string" then return "" end
	local isPlayer = UnitIsPlayer("target")
	if ns.profile.classColors and not issecret(isPlayer) and isPlayer then
		local _, class = UnitClass("target")
		local color = not issecret(class) and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
		if color then
			return format("|cff%02x%02x%02x%s|r", math.floor(color.r * 255 + 0.5), math.floor(color.g * 255 + 0.5), math.floor(color.b * 255 + 0.5), name)
		end
	end
	return name
end

--------------------------------------------------------------------------------
-- Fight log and damage meter check. After combat the client's own damage meter gives
-- exact per-spell totals for the player; "/ctf check" uses them to verify the
-- classification above. Nothing here is shown on screen.
--------------------------------------------------------------------------------

local fight = { lines = {}, sums = {}, casts = {} }

local function Log(stamp, text)
	fight.start = fight.start or stamp
	if #fight.lines < MAX_LINES then
		fight.lines[#fight.lines + 1] = format("%.2f %s", stamp - fight.start, text)
	end
end

-- [spellID] = total for the player in the current damage meter session, or nil if unreadable.
local function MeterTotals()
	local getSource = C_DamageMeter and C_DamageMeter.GetCombatSessionSourceFromType
	local sessionType = Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Current
	local meterType = Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageDone
	if not getSource or sessionType == nil or meterType == nil then return nil end
	local ok, source = pcall(getSource, sessionType, meterType, UnitGUID("player"))
	if not ok or issecret(source) or type(source) ~= "table" then return nil end
	local spells = source.combatSpells
	if issecret(spells) or type(spells) ~= "table" then return nil end
	local totals = {}
	for i = 1, #spells do
		local row = spells[i]
		local id, total, creature = row.spellID, row.totalAmount, row.creatureName
		if issecret(id) or issecret(total) or issecret(creature) or type(id) ~= "number" or type(total) ~= "number" then return nil end
		-- A row with a creature name is a pet's; only my own rows are wanted.
		if creature == nil or creature == "" then
			totals[id] = (totals[id] or 0) + total
		end
	end
	return totals
end

local function CloseFight()
	if InCombatLockdown() then
		fight.spansFights = true
		return
	end
	local record, meter = fight, MeterTotals()
	fight = { lines = {}, sums = {}, casts = {} }
	-- A spell of mine that the meter credits with damage, but that has never once had a
	-- hit in the same frame as its cast, is one whose hit lands late (Arcane Shot).
	for spellID, total in pairs(meter or {}) do
		local stats = ns.db.spells[spellID]
		if stats and total > 0 and stats.claims == 0 and record.casts[spellID] and not RANGED_SPELLS[spellID] then
			stats.late = true
		end
	end
	if #record.lines == 0 then return end
	record.ctx, record.meter = Context(), meter
	local fights = ns.db.debug.fights
	fights[#fights + 1] = record
	while #fights > MAX_FIGHTS do
		table.remove(fights, 1)
	end
end

local function CheckLine(name, classified, truth)
	return format("  %s: classified %d, damage meter %d - %s", name, classified, truth, classified == truth and "match" or "MISMATCH")
end

-- Compares the last solo fight's classification with the damage meter.
function Engine.CheckLines()
	local fights = ns.db.debug.fights
	local record = fights[#fights]
	if not record then return { "No finished fight yet." } end
	if not record.meter then return { "Last fight: the damage meter was not readable, nothing to compare against." } end
	local lines, ranged = { "Last fight (" .. tostring(record.ctx) .. "), classification against the damage meter:" }, 0
	for label, sum in pairs(record.sums) do
		local class, id = label:match("^(%a+):(%d+)$")
		if class == "yellow" then
			lines[#lines + 1] = CheckLine(ns.SpellName(tonumber(id)), sum, record.meter[tonumber(id)] or 0)
		elseif class == "ranged" then
			ranged = ranged + sum
		end
	end
	lines[#lines + 1] = CheckLine("White swings", record.sums.white or 0, record.meter[AUTO_ATTACK] or 0)
	if ranged > 0 or record.meter[AUTO_SHOT] then
		lines[#lines + 1] = CheckLine("Ranged", ranged, record.meter[AUTO_SHOT] or 0)
	end
	if record.sums.other then
		lines[#lines + 1] = format("  Procs and poisons: classified %d", record.sums.other)
	end
	return lines
end

--------------------------------------------------------------------------------
-- Outgoing: throttle. Events wait for their class's merge window and merge only with
-- events whose key is identical: same class, spell, result, crit state and hit type.
-- There is no setting that relaxes this.
--------------------------------------------------------------------------------

local held = {}

local function ThrottleKey(e)
	return format("%s|%d|%s|%d%d%d|%s|%s", e.class, e.spellID or 0, e.result,
		e.crit and 1 or 0, e.glancing and 1 or 0, e.crushing and 1 or 0, e.partial or "", e.tag or "")
end

local function EmitOutgoing(e)
	if restricted[e.ctx] then return end
	local key = "out." .. e.class .. "." .. Variant(e, e.class == "white" and "GLANCING")
	local color = e.class == "other" and SchoolColor(e.school, "outgoing") or nil
	local icon = e.spellID and SpellIcon(e.spellID) or nil
	local name = ns.profile.names and e.spellName or nil
	local t = SetTokens(tostring(e.amount), name, TargetName(), ResultLabel(e.result), Extras(e))
	if ns.Post(key, t, e.crit, icon, color) then
		local c = Counters(e.ctx)
		c.shown = c.shown + e.hits
	end
end

local function Submit(e)
	local window = MERGE_WINDOW[e.class]
	if window <= 0 then
		EmitOutgoing(e)
		return
	end
	local key = ThrottleKey(e)
	local waiting = held[key]
	if waiting then
		waiting.amount = waiting.amount + e.amount
		waiting.hits = waiting.hits + 1
	else
		e.releaseAt = GetTime() + window
		held[key] = e
	end
end

local function FlushHeld(now)
	for key, e in pairs(held) do
		if now >= e.releaseAt then
			held[key] = nil
			EmitOutgoing(e)
		end
	end
end

--------------------------------------------------------------------------------
-- Short abilities: an effect gained by the player that lasts
--   30 seconds or less, whatever it is (Slice and Dice, Blood Fury, Remorseless Attacks);
--   up to 60 seconds, if it is one of the player's own class or racial abilities.
-- Anything longer than 60 seconds is ignored.
-- Aura data is the exact source and covers procs, but this client may hide it from
-- addons. When it does, a cast of mine that hit nothing and whose description gives a
-- qualifying duration is announced instead.
--------------------------------------------------------------------------------

local SHORT_ABILITY_LIMIT = 30
local OWN_ABILITY_LIMIT = 60
local ABILITY_REPEAT = 1     -- seconds within which the same ability is not announced twice
local RECENT_ABILITY = 3     -- seconds: how fresh an effect must be to be announced after combat
local lastAbilityNotice = {} -- [name] = time
local describedDuration = {} -- [spellID] = seconds, or false when the text gives none
local describedSchool = {}   -- [spellID] = school mask, or false when the text mentions no damage
local auraReadFailed = false

local function PostAbility(name, icon)
	local now = GetTime()
	if name == "?" or (lastAbilityNotice[name] and now - lastAbilityNotice[name] < ABILITY_REPEAT) then return end
	lastAbilityNotice[name] = now
	ns.Post("note.buff", SetTokens(nil, name), false, icon)
end

-- True for a spell in the player's own spellbook: a class or racial ability, as opposed
-- to an effect from an item, a consumable or another player.
local function IsOwnAbility(spellID)
	if issecret(spellID) or type(spellID) ~= "number" then return false end
	local check = IsPlayerSpell or (C_SpellBook and C_SpellBook.IsSpellKnown) or IsSpellKnown
	if not check then return false end
	local ok, known = pcall(check, spellID)
	return ok and not issecret(known) and known and true or false
end

-- Whether an effect of this duration is announced: up to 30 seconds always, up to 60
-- for the player's own abilities, never beyond that.
local function Qualifies(seconds, spellID)
	if seconds <= 0 or seconds > OWN_ABILITY_LIMIT then return false end
	return seconds <= SHORT_ABILITY_LIMIT or IsOwnAbility(spellID)
end

-- Announces `aura` if it is a readable helpful effect that qualifies. `maxAge` limits it
-- to effects that began that many seconds ago or less.
local function CheckAura(aura, maxAge)
	if issecret(aura) or type(aura) ~= "table" then return end
	if issecrettable and issecrettable(aura) then return end
	local name, duration, helpful = aura.name, aura.duration, aura.isHelpful
	if issecret(name) or issecret(duration) or issecret(helpful) then return end
	if type(name) ~= "string" or type(duration) ~= "number" or not helpful then return end
	if not Qualifies(duration, aura.spellId) then return end
	if maxAge then
		local expires = aura.expirationTime
		if issecret(expires) or type(expires) ~= "number" or expires - duration < GetTime() - maxAge then return end
	end
	local icon = aura.icon
	PostAbility(name, not issecret(icon) and icon or nil)
end

local function ScanAddedAuras(updateInfo)
	local added = updateInfo.addedAuras
	if issecret(added) or type(added) ~= "table" then return end
	for index = 1, #added do
		CheckAura(added[index])
	end
end

-- Catches procs gained in the last moments of a fight, once aura data is readable again.
local function ScanRecentAuras()
	local getAura = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
	if not getAura then return end
	for index = 1, 40 do
		local aura = getAura("player", index, "HELPFUL")
		if issecret(aura) or not aura then return end
		CheckAura(aura, RECENT_ABILITY)
	end
end

-- Runs one of the aura readers. If the client refuses, aura reading stops for the
-- session and the cast-based path below carries on alone.
local function ReadAuras(reader, ...)
	if auraReadFailed then return end
	local ok, err = pcall(reader, ...)
	if not ok then
		auraReadFailed = true
		ns.db.debug.auraError = tostring(err)
	end
end

local DURATION_UNITS = {
	{ word = "sec", seconds = 1 },
	{ word = "min", seconds = 60 },
	{ word = "hour", seconds = 3600 },
}

-- A spell's description in lower case, or nil while the client has not loaded it.
-- What is read from it only works on English clients; other languages do not match.
local function Description(spellID)
	local getText = (C_Spell and C_Spell.GetSpellDescription) or GetSpellDescription
	local text = getText and getText(spellID)
	if issecret(text) or type(text) ~= "string" or text == "" then return nil end
	return text:lower()
end

-- The school mask of the damage a spell's description says it deals, or nil when it
-- mentions no damage. "Fire damage" is fire; plain "damage" is physical.
local function DescribedSchool(spellID)
	local cached = describedSchool[spellID]
	if cached ~= nil then return cached or nil end
	local text = Description(spellID)
	if not text then return nil end
	local school = false
	for word in text:gmatch("(%a+) damage") do
		if SCHOOL_WORDS[word] then
			school = SCHOOL_WORDS[word]
			break
		end
	end
	if not school and text:find("damage", 1, true) then school = SCHOOL_PHYSICAL end
	describedSchool[spellID] = school
	return school or nil
end

-- Longest duration, in seconds, that a spell's description mentions, or nil.
local function DescribedDuration(spellID)
	local cached = describedDuration[spellID]
	if cached ~= nil then return cached or nil end
	local text = Description(spellID)
	if not text then return nil end
	local longest = false
	for _, unit in ipairs(DURATION_UNITS) do
		for number in text:gmatch("(%d+%.?%d*)%s*" .. unit.word) do
			local seconds = (tonumber(number) or 0) * unit.seconds
			if not longest or seconds > longest then longest = seconds end
		end
	end
	describedDuration[spellID] = longest
	return longest or nil
end

-- A cast of mine that hit nothing. Spells that normally do hit are left to the damage
-- text; the rest are announced when their duration qualifies.
local function OnUnclaimedCast(cast)
	local stats = cast.stats
	if stats.claims * 2 >= math.max(stats.casts, 1) then return end
	local seconds = DescribedDuration(cast.spellID)
	if seconds and Qualifies(seconds, cast.spellID) then
		PostAbility(cast.name, SpellIcon(cast.spellID))
	end
end

--------------------------------------------------------------------------------
-- Outgoing: classification. Casts and target hits are buffered in arrival order and
-- resolved on the following frame, so "same frame" is exact whichever arrived first.
--------------------------------------------------------------------------------

local buffer = {}
local pendingLate = {} -- casts whose hit has not landed yet, oldest first: { expires, class, school, spellID, name }
local meleeFlag, castingUntil, lastRangedShot = false, 0, 0

-- A cast may claim a hit until enough casts have gone by without one to show the spell
-- does no damage (Slice and Dice, Sprint). Otherwise such a cast would occasionally
-- steal a white swing that happened to land in the same frame.
local function CanClaim(stats)
	return stats.casts < MIN_CASTS_TO_JUDGE or stats.claims * 2 >= stats.casts
end

local function CastTime(spellID)
	local castTime
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(spellID)
		castTime = not issecret(info) and type(info) == "table" and info.castTime or nil
	elseif GetSpellInfo then
		castTime = select(4, GetSpellInfo(spellID))
	end
	if issecret(castTime) or type(castTime) ~= "number" then return 0 end
	return castTime
end

-- True for a spell whose hit lands some time after its cast event: one with a cast
-- time that deals damage (Fireball, Aimed Shot), or one the damage meter has shown to
-- deal damage without ever hitting in the frame of its cast (Arcane Shot).
local function LandsLate(spellID, stats)
	return stats.late or (CastTime(spellID) > 0 and DescribedSchool(spellID) ~= nil) or false
end

-- Whether `cast` may claim `hit`. A cast with a known school only takes hits of that
-- school, so a Fireball does not pick up a pet's bite that lands with it.
local function Fits(cast, hit)
	return cast.school == nil or cast.school == hit.school
end

-- The oldest waiting cast that this hit can belong to, removed from the queue.
local function TakeLate(e)
	local index = 1
	while index <= #pendingLate do
		local waiting = pendingLate[index]
		if waiting.expires < e.stamp then
			table.remove(pendingLate, index)
		elseif waiting.school == e.school or (waiting.school == nil and e.school ~= SCHOOL_PHYSICAL) then
			return table.remove(pendingLate, index)
		else
			index = index + 1
		end
	end
end

-- Whether my melee auto attack is switched on, by the client's events or by asking it.
local function MeleeActive()
	if meleeFlag then return true end
	local isCurrent = (C_Spell and C_Spell.IsCurrentSpell) or IsCurrentSpell
	if not isCurrent then return false end
	local ok, active = pcall(isCurrent, AUTO_ATTACK)
	return ok and not issecret(active) and active and true or false
end

-- True when a physical hit that no cast accounts for cannot be my own swing and my pet
-- is fighting my target: I am casting, shooting, or not auto-attacking at all. While I
-- am swinging in melee beside the pet the two cannot be told apart, and the hit is
-- treated as mine.
local function IsPetSwing()
	local exists = UnitExists("pet")
	if issecret(exists) or not exists then return false end
	local onTarget = UnitIsUnit("pettarget", "target")
	if not issecret(onTarget) and not onTarget then return false end
	local now = GetTime()
	return now < castingUntil or now - lastRangedShot <= AUTO_SHOT_GRACE or not MeleeActive()
end

-- A pet's bite can land while one of my shots is still in the air, and both are physical.
-- The usual size of each is tracked so the hit can go to whichever it resembles.
local typical = {} -- [class] = running average of that class's normal hits

local function NormalSize(e)
	return e.crit and e.amount / 2 or e.amount
end

local function Learn(e)
	if e.result ~= "HIT" or e.amount <= 0 then return end
	local size = NormalSize(e)
	typical[e.class] = typical[e.class] and (typical[e.class] * 0.8 + size * 0.2) or size
end

local function ResemblesPet(e)
	if e.result ~= "HIT" or not (typical.pet and typical.ranged) then return false end
	local size = NormalSize(e)
	return math.abs(size - typical.pet) < math.abs(size - typical.ranged)
end

-- Gives a hit its class. `cast` is the cast that claimed it in its own frame, if one did.
local function Classify(e, cast)
	local petSwing = not cast and e.school == SCHOOL_PHYSICAL and IsPetSwing()
	if not cast and not (petSwing and ResemblesPet(e)) then cast = TakeLate(e) end
	if cast then
		e.class, e.spellID, e.spellName = cast.class, cast.spellID, cast.name
		if cast.class == "ranged" then Learn(e) end
	elseif e.school ~= SCHOOL_PHYSICAL then
		e.class = "other"
	elseif petSwing then
		e.class = "pet"
		Learn(e)
	else
		e.class = "white"
	end

	local label = e.spellID and (e.class .. ":" .. e.spellID) or e.class
	Log(e.stamp, format("%s %s %d school=%d", label, e.raw, e.amount, e.school))
	if e.result == "HIT" then fight.sums[label] = (fight.sums[label] or 0) + e.amount end
	Submit(e)
end

local function SettleCast(cast)
	local stats = cast.stats
	if cast.claimed then
		stats.casts, stats.claims = stats.casts + 1, stats.claims + 1
		return
	end
	if cast.late then
		-- Its hit is still on the way: wait for it rather than treat the cast as a miss.
		cast.expires = cast.stamp + LATE_WINDOW
		pendingLate[#pendingLate + 1] = cast
		return
	end
	if cast.stamp - lastReadable <= STREAM_ALIVE then
		-- Only an unclaimed cast made while hits were demonstrably readable is evidence
		-- that the spell does no damage.
		stats.casts = stats.casts + 1
	end
	if cast.class == "yellow" then OnUnclaimedCast(cast) end
end

-- Resolves one frame: buffer[first..last], which all carry the same stamp.
local function ResolveFrame(first, last)
	-- A cast claims the first hit that follows it, up to the next cast. Instant abilities
	-- arrive in this order.
	local cast
	for i = first, last do
		local entry = buffer[i]
		if entry.isCast then
			cast = CanClaim(entry.stats) and entry or nil
		elseif cast and Fits(cast, entry) then
			entry.claimedBy, cast.claimed = cast, true
			cast = nil
		end
	end
	-- A cast still without a hit takes the nearest unclaimed hit before it. Abilities
	-- queued onto the next swing (Raptor Strike, Heroic Strike, Cleave, Maul) can arrive
	-- with the hit first.
	for i = first, last do
		local entry = buffer[i]
		if entry.isCast and not entry.claimed and CanClaim(entry.stats) then
			for j = i - 1, first, -1 do
				local earlier = buffer[j]
				if not earlier.isCast and not earlier.claimedBy and Fits(entry, earlier) then
					earlier.claimedBy, entry.claimed = entry, true
					break
				end
			end
		end
	end
	for i = first, last do
		local entry = buffer[i]
		if entry.isCast then
			SettleCast(entry)
		else
			Classify(entry, entry.claimedBy)
		end
	end
end

-- Resolves every buffered entry from frames before `now`, one frame at a time.
local function ResolveBuffer(now)
	local first, count = 1, #buffer
	while first <= count and buffer[first].stamp < now do
		local last = first
		while last < count and buffer[last + 1].stamp == buffer[first].stamp do
			last = last + 1
		end
		ResolveFrame(first, last)
		first = last + 1
	end
	local done = first - 1
	if done > 0 then
		for i = 1, count do
			buffer[i] = buffer[i + done]
		end
	end
end

local function OnUpdate()
	local now = GetTime()
	ResolveBuffer(now)
	FlushHeld(now)
	if #buffer == 0 and next(held) == nil then driver:Hide() end
end

driver:SetScript("OnUpdate", function()
	if not ns.Guard("engine update", OnUpdate) then
		-- A failing entry must not be retried every frame.
		wipe(buffer)
		wipe(held)
		driver:Hide()
	end
end)

local function OnTargetCombat(ctx, action, descriptor, amount, school)
	lastReadable = GetTime()
	-- A wound for nothing is not a hit. An ability queued onto a swing produces one
	-- beside its real hit, and its cast would otherwise claim the empty one.
	if action == "WOUND" and amount == 0 and not FULL_AVOID_DESCRIPTORS[descriptor] then
		Log(lastReadable, format("ignored %s/%s 0 school=%d", action, descriptor, school))
		return
	end
	local e = ParseHit(action, descriptor, amount, school)
	if not e then return end
	e.stamp, e.ctx = lastReadable, ctx
	e.raw = action .. "/" .. descriptor
	buffer[#buffer + 1] = e
	driver:Show()
end

--------------------------------------------------------------------------------
-- Incoming: hits and heals on the player and the pet need no attribution.
-- UNIT_COMBAT carries no spell, so these events have no ability name or icon to show;
-- the "names" and "icons" settings only have something to act on for outgoing damage.
--------------------------------------------------------------------------------

local function OnOwnUnitCombat(prefix, ctx, action, descriptor, amount, school)
	local key, crit, color, t
	if action == "HEAL" then
		crit = descriptor == "CRITICAL"
		key = prefix .. ".heal." .. (crit and "CRIT" or "HIT")
		t = SetTokens(tostring(amount))
	elseif action == "ENERGIZE" then
		if prefix ~= "in" then return end
		key = "in.power.HIT"
		t = SetTokens(tostring(amount))
	else
		local e = ParseHit(action, descriptor, amount, school)
		if not e then return end
		local class = (school == SCHOOL_PHYSICAL or school == 0) and "melee" or "spell"
		key = prefix .. "." .. class .. "." .. Variant(e, class == "melee" and "CRUSHING")
		crit = e.crit
		color = class == "spell" and e.result == "HIT" and SchoolColor(school, "incoming") or nil
		t = SetTokens(tostring(e.amount), nil, nil, ResultLabel(e.result), Extras(e))
	end
	if ns.Post(key, t, crit, nil, color) then
		local c = Counters(ctx)
		c.shown = c.shown + 1
	end
end

local function OnUnitCombat(unit, action, descriptor, amount, school)
	if issecret(unit) then return end
	local ctx = Context()
	if restricted[ctx] then return end
	if not Readable(ctx, action, descriptor, amount, school) then return end
	if type(action) ~= "string" then return end
	descriptor = type(descriptor) == "string" and descriptor or ""
	amount = type(amount) == "number" and amount or 0
	school = type(school) == "number" and school or 0
	if unit == "target" then
		OnTargetCombat(ctx, action, descriptor, amount, school)
	elseif unit == "player" then
		OnOwnUnitCombat("in", ctx, action, descriptor, amount, school)
	elseif unit == "pet" then
		OnOwnUnitCombat("petin", ctx, action, descriptor, amount, school)
	end
end

--------------------------------------------------------------------------------
-- Loot
--------------------------------------------------------------------------------

-- Turns a Blizzard format string such as "You receive loot: %sx%d." into a Lua pattern.
local function ChatPattern(globalString)
	if type(globalString) ~= "string" then return nil end
	-- Placeholders stand in for %s and %d while everything else is escaped.
	local pattern = globalString:gsub("%%%d?%$?s", "\1"):gsub("%%%d?%$?d", "\2")
	pattern = pattern:gsub("[%^%$%(%)%.%[%]%*%+%-%?%%]", "%%%0")
	pattern = pattern:gsub("\1", "(.+)"):gsub("\2", "(%%d+)")
	return "^" .. pattern .. "$"
end

local function Patterns(...)
	local list = {}
	for i = 1, select("#", ...) do
		list[#list + 1] = ChatPattern(_G[(select(i, ...))])
	end
	return list
end

-- Counted forms first: the plain forms would also match them.
local LOOT_PATTERNS = Patterns("LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF_MULTIPLE",
	"LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_CREATED_SELF")
local MONEY_PATTERNS = Patterns("YOU_LOOT_MONEY", "LOOT_MONEY_SPLIT")
local CURRENCY_PATTERNS = Patterns("CURRENCY_GAINED_MULTIPLE", "CURRENCY_GAINED")

local function MatchAny(patterns, text)
	for _, pattern in ipairs(patterns) do
		local first, second = text:match(pattern)
		if first then return first, second end
	end
end

-- True when `name` contains any entry of a comma-separated list.
local function Listed(list, name)
	for entry in list:gmatch("[^,]+") do
		entry = entry:lower():match("^%s*(.-)%s*$")
		if entry ~= "" and name:find(entry, 1, true) then return true end
	end
	return false
end

local function ItemQuality(link, itemID)
	local quality = tonumber(link:match("|cnIQ(%d+):"))
	if quality then return quality end
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if getInfo and itemID then
		local _, _, infoQuality = getInfo(itemID)
		if type(infoQuality) == "number" then return infoQuality end
	end
	return 1
end

local function OnLoot(text)
	local settings = ns.profile.loot
	if not settings.items then return end
	local link, count = MatchAny(LOOT_PATTERNS, text)
	if not link then return end
	local name = link:match("|h%[(.-)%]|h")
	if not name then return end
	local itemID = tonumber(link:match("|Hitem:(%d+)"))
	local quality = ItemQuality(link, itemID)
	local lower = name:lower()
	if not Listed(settings.allow, lower) then
		if Listed(settings.exclude, lower) or not settings.quality[quality] then return end
	end
	local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	local getIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
	local icon = itemID and getIcon and getIcon(itemID) or nil
	ns.Post("note.loot_item", SetTokens(count or "1", "[" .. name .. "]"), false, icon, color and { color.r, color.g, color.b } or nil)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local handlers = {}
local lastComboPoints, lastXP, lastXPMax, lowHealth = 0, nil, nil, false

function handlers.UNIT_SPELLCAST_SUCCEEDED(unit, _, spellID)
	if issecret(unit) or (unit ~= "player" and unit ~= "pet") then return end
	if issecret(spellID) or type(spellID) ~= "number" then return end
	local mine = unit == "player"
	local now, name = GetTime(), ns.SpellName(spellID)
	Log(now, format("%s %d %s", mine and "cast" or "pet cast", spellID, name))
	if mine then
		fight.casts[spellID] = (fight.casts[spellID] or 0) + 1
		if RANGED_SPELLS[spellID] then
			lastRangedShot = now
			pendingLate[#pendingLate + 1] = {
				expires = now + RANGED_WINDOW, class = "ranged", school = SCHOOL_PHYSICAL, spellID = spellID, name = name,
			}
			return
		end
	end
	local stats = ns.db.spells[spellID]
	if not stats then
		stats = { casts = 0, claims = 0 }
		ns.db.spells[spellID] = stats
	end
	local late = LandsLate(spellID, stats)
	buffer[#buffer + 1] = {
		isCast = true, stamp = now, spellID = spellID, name = name, stats = stats,
		class = mine and "yellow" or "pet",
		late = late,
		school = late and DescribedSchool(spellID) or nil,
	}
	driver:Show()
end

-- My melee auto attack starting and stopping, and my casts and channels: while I am
-- casting, or not attacking at all, a stray physical hit is not my swing.
function handlers.PLAYER_ENTER_COMBAT() meleeFlag = true end
function handlers.PLAYER_LEAVE_COMBAT() meleeFlag = false end

local function CastBegan(unit)
	if not issecret(unit) and unit == "player" then castingUntil = GetTime() + 15 end
end
local function CastEnded(unit)
	if not issecret(unit) and unit == "player" then castingUntil = 0 end
end
handlers.UNIT_SPELLCAST_START = CastBegan
handlers.UNIT_SPELLCAST_CHANNEL_START = CastBegan
handlers.UNIT_SPELLCAST_STOP = CastEnded
handlers.UNIT_SPELLCAST_FAILED = CastEnded
handlers.UNIT_SPELLCAST_INTERRUPTED = CastEnded
handlers.UNIT_SPELLCAST_CHANNEL_STOP = CastEnded

function handlers.PLAYER_REGEN_DISABLED()
	ns.Post("note.combat_enter", SetTokens())
end

function handlers.PLAYER_REGEN_ENABLED()
	ns.Post("note.combat_leave", SetTokens())
	C_Timer.After(0.3, function() ReadAuras(ScanRecentAuras) end)
	C_Timer.After(1.5, function() ns.Guard("fight log", CloseFight) end)
end

function handlers.UNIT_AURA(unit, updateInfo)
	if issecret(unit) or unit ~= "player" then return end
	if issecret(updateInfo) or type(updateInfo) ~= "table" then return end
	ReadAuras(ScanAddedAuras, updateInfo)
end

function handlers.ENCOUNTER_START()
	encounterActive = true
	ns.ApplyBlizzardText()
end

function handlers.ENCOUNTER_END()
	encounterActive = false
	ns.ApplyBlizzardText()
end

local function ComboPoints()
	local points
	if GetComboPoints then
		points = GetComboPoints("player", "target")
	else
		points = UnitPower("player", 4)
	end
	if issecret(points) or type(points) ~= "number" then return nil end
	return points
end

function handlers.UNIT_POWER_UPDATE(unit, powerType)
	if issecret(unit) or unit ~= "player" or issecret(powerType) or powerType ~= "COMBO_POINTS" then return end
	local points = ComboPoints()
	if not points then return end
	if points > lastComboPoints then
		ns.Post(points >= MAX_COMBO_POINTS and "note.combo_full" or "note.combo", SetTokens(tostring(points)))
	end
	lastComboPoints = points
end

function handlers.PLAYER_TARGET_CHANGED()
	lastComboPoints = ComboPoints() or 0
end

function handlers.PLAYER_XP_UPDATE(unit)
	if unit and (issecret(unit) or unit ~= "player") then return end
	local xp, xpMax = UnitXP("player"), UnitXPMax("player")
	if issecret(xp) or issecret(xpMax) or type(xp) ~= "number" then return end
	if lastXP then
		local gained = xp - lastXP
		if gained < 0 then gained = (lastXPMax or 0) - lastXP + xp end -- levelled up
		if gained > 0 then ns.Post("note.xp", SetTokens(tostring(gained))) end
	end
	lastXP, lastXPMax = xp, xpMax
end

function handlers.UNIT_HEALTH(unit)
	if issecret(unit) or unit ~= "player" then return end
	local health, healthMax = UnitHealth("player"), UnitHealthMax("player")
	if issecret(health) or issecret(healthMax) or type(health) ~= "number" or type(healthMax) ~= "number" or healthMax <= 0 then return end
	local fraction = health / healthMax
	if fraction < LOW_HEALTH and health > 0 and not lowHealth then
		lowHealth = true
		ns.Post("note.low_health", SetTokens(tostring(health)))
	elseif fraction > LOW_HEALTH_RESET then
		lowHealth = false
	end
end

local function ChatNotice(key)
	return function(text)
		if issecret(text) or type(text) ~= "string" then return end
		ns.Post(key, SetTokens(nil, nil, nil, nil, text))
	end
end
handlers.CHAT_MSG_COMBAT_FACTION_CHANGE = ChatNotice("note.rep")
handlers.CHAT_MSG_COMBAT_HONOR_GAIN = ChatNotice("note.honor")
handlers.CHAT_MSG_SKILL = ChatNotice("note.skill")

function handlers.CHAT_MSG_LOOT(text)
	if issecret(text) or type(text) ~= "string" then return end
	OnLoot(text)
end

function handlers.CHAT_MSG_MONEY(text)
	if issecret(text) or type(text) ~= "string" or not ns.profile.loot.money then return end
	ns.Post("note.loot_money", SetTokens(nil, nil, nil, nil, MatchAny(MONEY_PATTERNS, text) or text))
end

function handlers.CHAT_MSG_CURRENCY(text)
	if issecret(text) or type(text) ~= "string" or not ns.profile.loot.currency then return end
	local currency, count = MatchAny(CURRENCY_PATTERNS, text)
	ns.Post("note.loot_currency", SetTokens(count, nil, nil, nil, currency and ("+" .. currency .. (count and (" x" .. count) or "")) or text))
end

frame:SetScript("OnEvent", function(_, event, ...)
	local handler = handlers[event]
	if handler then ns.Guard(event, handler, ...) end
end)

-- Events registered for particular units only: true means the player, a string a second unit.
local UNIT_EVENTS = {
	UNIT_SPELLCAST_SUCCEEDED = "pet",
	UNIT_SPELLCAST_START = true,
	UNIT_SPELLCAST_STOP = true,
	UNIT_SPELLCAST_FAILED = true,
	UNIT_SPELLCAST_INTERRUPTED = true,
	UNIT_SPELLCAST_CHANNEL_START = true,
	UNIT_SPELLCAST_CHANNEL_STOP = true,
	UNIT_POWER_UPDATE = true,
	UNIT_HEALTH = true,
	UNIT_AURA = true,
}
local IsEventValid = C_EventUtils and C_EventUtils.IsEventValid

function Engine.Enable()
	if enabled then return end
	enabled = true
	for event in pairs(handlers) do
		if not IsEventValid or IsEventValid(event) then
			local units = UNIT_EVENTS[event]
			if units == true then
				pcall(frame.RegisterUnitEvent, frame, event, "player")
			elseif units then
				pcall(frame.RegisterUnitEvent, frame, event, "player", units)
			else
				pcall(frame.RegisterEvent, frame, event)
			end
		end
	end
	-- One frame per unit: UNIT_COMBAT otherwise fires for every unit in a raid.
	for _, unit in ipairs({ "target", "player", "pet" }) do
		local unitFrame = unitFrames[unit]
		if not unitFrame then
			unitFrame = CreateFrame("Frame")
			unitFrame:SetScript("OnEvent", function(_, _, ...) ns.Guard("UNIT_COMBAT", OnUnitCombat, ...) end)
			unitFrames[unit] = unitFrame
		end
		unitFrame:RegisterUnitEvent("UNIT_COMBAT", unit)
	end
	lastXP, lastXPMax = nil, nil
	ns.Guard("PLAYER_XP_UPDATE", handlers.PLAYER_XP_UPDATE)
end

function Engine.Disable()
	if not enabled then return end
	enabled = false
	frame:UnregisterAllEvents()
	for _, unitFrame in pairs(unitFrames) do
		unitFrame:UnregisterAllEvents()
	end
	wipe(buffer)
	wipe(held)
	wipe(pendingLate)
	driver:Hide()
end

-- Lines for /ctf status and the options panel's status page.
function Engine.StatusLines()
	local ctx = Context()
	local outgoing
	if not enabled then
		outgoing = "off (addon disabled)"
	elseif restricted[ctx] then
		outgoing = "off - combat data is unreadable in this context, Blizzard's numbers are used"
	elseif IsInGroup() then
		outgoing = "live - in a group, other players' hits on your target are shown as well as your own"
	else
		outgoing = "live"
	end
	local lines = {
		format("Context: %s", ctx),
		format("Outgoing damage: %s", outgoing),
		format("Incoming, notifications and loot: %s", enabled and not restricted[ctx] and "live" or "off"),
		"Events this session (received / readable / shown):",
	}
	local any = false
	for name, c in pairs(counters) do
		any = true
		lines[#lines + 1] = format("  %s: %d / %d / %d%s", name, c.received, c.readable, c.shown, restricted[name] and "  - switched off, unreadable" or "")
	end
	if not any then lines[#lines + 1] = "  none yet" end
	return lines
end
