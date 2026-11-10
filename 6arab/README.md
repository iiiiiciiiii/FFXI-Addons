# 6arab (طرب)

Floating **Bard song tracker** for Ashita v4 — Phoenix (level 75). Companion to [nard](../nard/). by Jboor

## Features

- **Draining note tiles** — each song is a tile that fills with the song's colour and drains as it runs out; refills when you sing it again
- **Melee row on top, mages row under it** — sorted by the jobs each song landed on
- **Enemy songs as bars on the side** — Requiem, Elegy, Lullaby, Threnody, with recast READY / countdown
- **Exact timers** read from your buff bar (covers instrument bonus and Troubadour)
- **Your song set** — songs you normally keep up show as ghost tiles when they're not running
- **Ability cooldowns** — Soul Voice, Pianissimo, Nightingale, Troubadour (main BRD)
- Amber pulse when a song is ending, quick grey fade when it finishes
- Works with BRD as main or sub job
- Minimize to a small pill, settings window, debug log

## Install

Copy the `6arab` folder (`6arab.lua`, `songs.lua`, `dlog.lua`) into `Ashita/addons/`, then:

```
/addon load 6arab
```

## Commands

| Command | |
|---|---|
| `/6arab` | settings window |
| `/6arab test` | preview songs (cycles presets) |
| `/6arab clear` | clear tracked songs |
| `/6arab min` | minimize / restore |
| `/6arab lock` | lock / unlock position |
| `/6arab scale <0.6-2.0>` | size |
| `/6arab show` / `hide` | show / hide |
| `/6arab reset` | default position |
| `/6arab log` | debug log |
| `/6arab debug [on\|off]` | verbose tracing |

Logs are saved to `Ashita/logs/6arab/`.

— by Jboor
