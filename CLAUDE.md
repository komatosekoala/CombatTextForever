# CombatTextForever

Scrolling combat text for World of Warcraft: Forever (client 1.60.1, interface 16001,
install folder `_classic_beta_`, TOC suffix `_Camelot`). Written from scratch; MSBT is
All Rights Reserved and was used only as a list of features.

The owner plays a Rogue and raids. The point of the addon is reading their own melee
output at a glance: white swings and ability hits must never be confused or merged.

## What this client allows (measured in game with a probe addon, October 2026)

- `COMBAT_LOG_EVENT_UNFILTERED` cannot be registered by addons. `RegisterEvent` returns
  normally under pcall, the event is not registered, and the client fires
  `ADDON_ACTION_FORBIDDEN`. `CombatLogGetCurrentEventInfo` does not exist. Do not retry.
- `UNIT_COMBAT` is readable in open-world combat for `target`, `player` and `pet`:
  action (`WOUND`, `MISS`, `DODGE`, `PARRY`, ...), descriptor (`CRITICAL`, `GLANCING`,
  `CRUSHING`, `BLOCK_REDUCED`, or empty), amount, school. It has no source and no spell.
- `UNIT_SPELLCAST_SUCCEEDED` for the player is readable, with the spell ID.
- The hit of an instant ability arrives in the same frame as its cast event, cast first
  (30 of 30 Sinister Strikes, 2 of 2 Eviscerates). Throw lands later.
- `C_DamageMeter` per-spell rows for the player are secret while in combat (spell ID and
  total both) and exact once combat ends. Auto attack is spell 6603; Throw is filed
  under 75.
- Secret values do not error when read, only when compared or used in arithmetic.
  Guard with `issecretvalue`, not pcall.
- `C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.X)` reports
  restrictions; `Combat` is active in any fight. `Encounter` has not been observed.
- The pre-2.4 `CHAT_MSG_COMBAT_*` damage events do not exist. `COMBAT_TEXT_UPDATE`
  delivered nothing for the target and secret payloads for the player.
- The floating combat text CVars use the `_v2` names.

Not yet measured: anything in an instance or a boss encounter. In a group, the owner
reports that ability hits display correctly; no logged data from a group has been read.

## Design rules

- Outgoing classes are derived, not read: yellow = hit in the same frame as one of my
  casts; ranged = first physical hit after a thrown/shot cast; white = any other physical
  hit; other = any other non-physical hit. See the header of `Engine.lua`.
- Events merge only when class, spell, result, crit state and hit type all match. There
  must be no user option that relaxes this.
- Hits on the target carry no source. Outgoing damage is shown in groups anyway: the
  owner decided on 2026-10-12 that white swings must not be hidden in a group, replacing
  the earlier rule of showing nothing there. The cost is that other players' hits on the
  same target appear as white swings. Do not reintroduce the group gate.
- Hits on the player and pet need no attribution and are shown everywhere.
- `/ctf check` compares the last fight's classification with the damage meter. Use it
  to validate any change to the classifier.

## Files

- `Core.lua` helpers, defaults, profiles, export/import, Blizzard CVars, slash commands
- `Events.lua` the event registry and `ns.Post`
- `Display.lua` scroll areas and animation
- `Engine.lua` classification, incoming, notifications, loot, fight log for `/ctf check`
- `Options.lua` the settings page (hand-made widgets, built on first show)

## Working with the owner

Only the owner can run the game. Nothing here has a test harness and there is no Lua
interpreter on the machine. Errors are caught by `ns.Guard` and saved under
`CombatTextForeverDB.debug.errors`; the saved variables file can be read from
`WTF\Account\<account>\SavedVariables\CombatTextForever.lua` after a `/reload`. A change to
the TOC needs a full client restart; a change to a Lua file only needs `/reload`.

## Spells that land late, and pet hits

Added at the owner's request; neither has been seen working in game.

- A cast that hit nothing in its own frame waits up to 2.5 s for a hit of its school if
  it "lands late": it has a cast time and its English description mentions damage, or
  the damage meter has credited it with damage without it ever claiming a same-frame hit
  (`stats.late`, learned after a fight). The school comes from the description text
  ("Fire damage"; plain "damage" is physical). Non-English clients only get the meter
  route.
- Pet hits are the class `pet`, shown with "(Pet)" after the number. A hit in the frame
  of a pet cast is the pet's. A physical hit nothing else accounts for is the pet's when
  the pet is on my target and I cannot be swinging: I am casting, fired a ranged auto
  attack in the last 3.5 s, or my melee auto attack is off. While I melee beside the
  pet the two cannot be separated and the hit is treated as mine.
- A pet's bite and my shot in flight are both physical; a running average of each one's
  size decides which a hit resembles.

## Abilities queued onto the next swing

The owner reported on a Hunter that Raptor Strike showed as "0" with its real damage
as a white swing. No log of it has been read, so the event order is not known. The fix
assumes the client sends an empty `WOUND` (amount 0) beside the real hit:

- a zero-damage `WOUND` on the target is ignored (and logged as "ignored ..."),
- within a frame, a cast with no hit after it claims the nearest unclaimed hit before it.

If Raptor Strike still misbehaves, read the fight log lines around its `cast` entry
before changing anything; a cast and hit in different frames would need another approach.

## Short ability notification (`note.buff`)

Announces an effect gained by the player that lasts 30 seconds or less, or up to 60
seconds when it is one of the player's own class or racial abilities (a spell in their
spellbook). Anything over 60 seconds is ignored; the owner set both limits. Two sources,
see the "Short abilities" section of `Engine.lua`:

- Aura data (`UNIT_AURA` added auras, plus a scan just after combat ends). Exact, and the
  only source that sees procs such as Remorseless Attacks. Whether this client lets
  addons read aura names and durations has not been measured; the one related reading
  (`COMBAT_TEXT_UPDATE` aura events) came back secret.
- The player's own casts: a cast that claimed no hit and whose English description
  mentions at most 30 "sec". This also announces short non-buff abilities (Cheap Shot,
  Vanish) and things like eating.

Neither path has been seen working in game.

## Known gaps

- Damage over time from a spell the player casts is the class `dot` (owner reported
  Garrote ticks showing as white swings). A tick is recognised by being the same size as
  the others and on a fixed beat from the cast; the size and interval are learned the
  first time (two matching ticks) and kept in `db.spells[id].tick`. Changing target
  drops the tracking. Not seen working in game. Ticks from procs with no cast (Deadly
  Poison) are still `other`.
- Any other player or pet hitting the same target, grouped or not, shows as white.
- Partial resist/block/absorb amounts, overkill, pet outgoing damage and outgoing heals
  have no data source.
- The killing blow on a target often produces no `UNIT_COMBAT` event, so it is not shown.
  In six of eight logged solo fights the white total was one hit short of the damage
  meter (12 to 29 damage) and the last logged event was never the kill. A possible fix,
  not built: after the fight, show the difference between the meter and the logged sum.

## In-game history

- 1.0.0 ran solo in the open world for four fights with no errors recorded. Sinister
  Strike and Throw totals matched the damage meter in all four; white matched in one
  and was one killing blow short in three.
- The addon was first installed as CombatTextPlus (`/ctp`, `CombatTextPlusDB`) and renamed
  to CombatTextForever (`/ctf`, `CombatTextForeverDB`) before publication.
