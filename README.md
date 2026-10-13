# CombatTextForever

Scrolling combat text for World of Warcraft: Forever (interface 16001).

It keeps your white swings and ability hits apart, each in its own colour, so you can
read your melee damage at a glance.

## Features

- White swings, ability hits, ranged attacks, procs and pet hits each have their own
  events, colours and format strings
- Glancing blows, crits, partial blocks and every miss type are called out
- Incoming damage coloured by school (fire orange, shadow purple, nature green)
- Notifications for combat, short buffs such as Slice and Dice, loot, reputation and
  skill-ups
- Movable scroll areas with four animation styles and sticky crits
- Custom fonts, sizes and colours
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

## Good to know

Forever does not give addons a combat log, and does not say who dealt a hit or with
which spell. CombatTextForever works that out by matching hits to your own casts:

- In a group, other players' hits on your target can appear as white swings.
- While you melee beside your pet, its hits cannot be told apart from yours.
- The killing blow on a target is often not reported by the client and may not appear.
- The amount removed by a partial resist, block or absorb is not available.
