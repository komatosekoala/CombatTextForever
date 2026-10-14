# CombatTextForever

Scrolling combat text for World of Warcraft: Forever (interface 16001).

It keeps your white swings and ability hits apart, each in its own colour, so you can
read your damage at a glance.

## Features

**Outgoing damage**, each kind with its own colour, format and scroll area:

- White swings
- Ability hits, including abilities queued onto the next swing (Raptor Strike, Heroic
  Strike) and spells that land after their cast (Fireball, Frostbolt, Aimed Shot)
- Damage-over-time ticks (Garrote, Rupture, Corruption), shown with the ability's icon
- Ranged auto attacks
- Pet hits, marked with "(Pet)" after the number
- Procs and poisons, coloured by school

Glancing blows, crits, partial blocks and every miss type (miss, dodge, parry, block,
absorb, resist, immune, evade, deflect, reflect) are called out.

**Incoming damage and heals** for you and your pet. Melee is red; spell damage is
coloured by school (fire orange, shadow purple, nature green).

**Notifications** for entering and leaving combat, short abilities such as Slice and
Dice and Blood Fury, combo points, low health, experience, reputation, honor, skill-ups
and loot (with item quality filters and always-show / never-show lists).

**Display and settings**

- Scroll areas you can create, drag and resize, with four animation styles and sticky crits
- Fonts, sizes, outline, opacity and animation speed
- Ability names and icons can each be switched on or off
- A colour and a format string for every event
- Profiles you can copy, reset, export and import

## Install

Copy the `CombatTextForever` folder into
`World of Warcraft\_classic_beta_\Interface\AddOns`, then restart the game.

Disable other scrolling combat text addons while using this one, or numbers will
appear twice.

## Commands

- `/ctf` opens the options
- `/ctf test` shows sample text in every scroll area
- `/ctf unlock` lets you drag the scroll areas, `/ctf lock` fixes them in place
- `/ctf check` compares your last fight with the game's damage meter

## How it works, and its limits

Forever does not give addons a combat log. The client reports that a hit happened and
how big it was, but not who dealt it or with which spell. CombatTextForever works that
out by matching each hit to your own casts, your pet's casts, and the timing and size
of your damage-over-time effects. Most of the time that is right; it cannot be certain.

- **Groups:** other players' hits on your target can appear as white swings.
- **Pets:** pet abilities are always recognised. Pet melee is recognised while you are
  casting, shooting, or not auto-attacking. While you are swinging in melee beside your
  pet, its melee hits show as white swings.
- **Damage over time:** the first tick or two of an ability you have never used before
  may show as white swings while the addon learns its size and timing. Changing target
  stops the tracking for that application. Effects you do not cast, such as Deadly
  Poison, show as procs.
- **Instant spells that travel** (Arcane Shot) are recognised from the second fight on.
- **Killing blows** are often not reported by the client and may not appear.
- **Not available at all:** the amount removed by a partial resist, block or absorb,
  overkill, and outgoing heals.
- Spell names, schools and durations are read from English spell descriptions, so some
  matching only works on English clients.

See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.
