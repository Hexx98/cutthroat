# Cutthroat

Combo point pips and a Slice and Dice timer for rogues on **WoW Forever** (client 1.60.1, interface 16001).

## Features

- Combo point pips that appear one at a time as you earn them; the fourth and fifth change color so a full bar stands out.
- Five pip shapes: square, circle, diamond, triangle, star.
- Slice and Dice countdown bar above the pips. It starts the moment you cast, counts down in combat, and turns red and pulses for the last 5 seconds.
- Move it anywhere, then lock it. Scale 0.5–3.
- Settings panel: `/cut` or `/cutthroat`. Typed commands: `/cut lock | unlock | reset | scale <n> | shape <name>`.

## How it works on this client

WoW Forever hides combat data from addons ("secret values"):

- **Combo points are secret.** Addons may display them but not read, compare or do math on them. Each pip is a pair of StatusBars (outline and fill) ranged `[i-1, i]` that are handed the raw count; the engine clamps it, drawing pips 1..cp completely and the rest not at all, without the addon ever seeing the number.
- **Buffs cannot be read at all in combat.** So the Slice and Dice timer is built from the cast instead: the cast events still report the spell ID, and on each cast Cutthroat starts five countdowns, one per possible combo point count. Five invisible "gate" bars get the secret combo point count (the pip trick again) and each countdown is clipped to its gate's fill, so the highest visible countdown is the right one.
- **Out of combat** buffs are readable again, so the timer re-syncs to the real buff and learns the Improved Slice and Dice talent bonus from it.

Settings are saved per character: this beta currently does not load account-wide saved variables back in.

## Install

Copy the `Cutthroat` folder into `World of Warcraft\_classic_beta_\Interface\AddOns\`.
