# nard (نرد)

> **Why the name?** *nard* is the Arabic word **نرد**, meaning **dice**, like the dice in backgammon. Corsairs roll dice for every Phantom Roll, so the tracker is named after them.

Floating **Corsair roll tracker** for Ashita v4 — Phoenix (level 75). by Jboor

## Features

- Each Phantom Roll as a floating die with name, total, effect and time left
- Flames on Lucky, gold zoom and smash on 11, frost on Unlucky, red on Bust (penalty shown)
- Bust chance and Double-Up window countdown on your newest roll
- Up to 4 rolls: MELEE row and MAGES row, sorted by the jobs each roll landed on
- Party job bonus included in effect values
- Phantom Roll and Double-Up cooldown pills
- Real buff check: a roll that wears off early is removed
- Separate pieces mode, minimize pill, settings window, debug log
- Rolls kept across reloads

## Install

Copy the `nard` folder (`nard.lua`, `rolls.lua`, `dlog.lua`) into `Ashita/addons/`, then:

```
/addon load nard
```

## Commands

| Command | |
|---|---|
| `/nard` | settings window |
| `/nard test` | preview rolls (cycles presets) |
| `/nard clear` | clear tracked rolls |
| `/nard min` | minimize / restore |
| `/nard lock` / `unlock` | lock position |
| `/nard free` | separate pieces on / off |
| `/nard scale <0.6-2.0>` | size |
| `/nard show` / `hide` | show / hide |
| `/nard reset` | default position |
| `/nard log` | debug log |
| `/nard debug [on\|off]` | verbose tracing |

Logs are saved to `Ashita/logs/nard/`.

— by Jboor
