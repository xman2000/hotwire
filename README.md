# Hotwire

Scheduled restarts and updates for a Rust server. Announces, counts down, kicks with a reason, saves, and quits — and where you want it, separates "restart" from "install a new build".

Windows. MIT.

## What it is for

A busy modded server accumulates memory and wants a daily restart. Most setups get that by having the launcher re-run steamcmd on every exit, which means every restart is also an unattended update — at 5am, over a working install, the day after a Rust update, with nobody watching.

Hotwire holds the schedule and, when a restart is *also* meant to be an update, writes a flag file into the server root before it quits. A launcher that looks for that flag updates; one that does not, does not. The plugin never spawns a process and never shells out — it writes a file and quits.

Without such a launcher the plugin is still a complete restart scheduler. The flag is simply written and ignored.

A matching Windows launcher ships alongside it. See **The launcher** below.

## Six ways to say when

- **Daily**
- **Certain weekdays** — `Mon,Thu`, `weekdays`, `weekends`
- **An ordinal weekday of the month** — `first Thursday`, `last Friday`
- **A date each month** — `day 15`
- **Every N days**, counted from an anchor date
- **Once**, on a date, after which the entry disables itself

Ordinal weekdays exist because Rust force wipes on the first Thursday of the month, which is the update most admins actually want to schedule.

Restarts and updates are two separate lists. If one of each falls on the same minute, the update wins.

## Announcing

The countdown starts an hour out by default and announces at 60, 30, 15, 10, 5, 2 and 1 minutes, then 30, 20 and 10 seconds, then every second to zero. Sparse where nothing is at stake, dense where it is.

Remaining time is rounded up everywhere, and both the chat text and the status bar take their minute count from the same helper, so an announcement that says "3 minutes" stays true for the minute it sits in chat.

The countdown recomputes from the wall clock every tick rather than counting down, so it is immune to timescale, a stalled frame and timer drift. The restart lands when it said it would; the worst a hitch can do is skip an announcement.

Announcements go out under a configurable name — **"Server Manager"** by default, not "Hotwire", because the plugin's name means nothing to a player.

## Status bar (optional)

Where **AdvancedStatus** is installed, the countdown also renders as a HUD bar. It is entirely optional and is not distributed through uMod, so it cannot be listed as a formal dependency — install it or do not. Without it the countdown still runs and is announced in chat, which is the normal case rather than a degraded one, and `hotwire check` reports which state you are in.

## Times and DST

Schedules are local wall-clock time, so `05:00` means five in the morning whatever the clocks have done. Every time the plugin prints carries the zone and whether daylight saving is in effect.

A record of when each entry last fired is persisted, and an entry refuses to run twice inside 20 hours. That suppresses the autumn repeat, where an hour happens twice; the spring skip is logged and waits for the next day.

## Safety

Two things this must never do: leave a server unable to restart, or restart one unannounced. Everything else is cosmetic, and the failure directions are chosen accordingly.

- **Every schedule entry in the shipped config is disabled.** Installing the plugin cannot restart anything by surprise. Turn one on when you mean it.
- A failed flag write downgrades an update to a plain restart rather than canceling it.
- An entry that becomes invalid is switched off and reported, rather than left to fail at three in the morning.
- Disabling an entry cancels a countdown that came from it.

## Installing

Drop `Hotwire.cs` into `oxide/plugins/`. It compiles on the spot and writes `oxide/config/Hotwire.json` with **every schedule disabled**, so installing it cannot restart anything by surprise.

Then grant yourself permission. Nothing works without a grant, and the first command you try will simply refuse.

```
oxide.grant group admin hotwire.status
oxide.grant group admin hotwire.restart
oxide.grant group admin hotwire.cancel
oxide.grant group admin hotwire.edit
```

Then add a schedule — `hotwire menu` in game, or from the console:

```
hotwire add restart 05:00 daily
hotwire add update  20:00 first Thursday
```

## Permissions

- **`hotwire.status`** — see what is scheduled, open the menu, run `check` and `list`
- **`hotwire.restart`** — start a countdown now
- **`hotwire.cancel`** — cancel a running countdown
- **`hotwire.edit`** — add, change, remove, enable and disable entries

## Commands

Chat or console, and `hw` works as a short form. Bare `hotwire` is `status`.

- **`hotwire status`** — `hotwire.status` — what is next, or what is counting down
- **`hotwire menu`** — `hotwire.status` — the in-game panel
- **`hotwire list`** — `hotwire.status` — every entry with its index and next occurrence
- **`hotwire check`** — `hotwire.status` — diagnostics: where the flag goes, whether that is really the server root, the clock, the DST guard, the status bar
- **`hotwire now`** — `hotwire.restart` — start a countdown now
- **`hotwire cancel`** — `hotwire.cancel` — stop the one that is running
- **`hotwire add`** — `hotwire.edit` — add an entry
- **`hotwire set`** — `hotwire.edit` — edit one in place
- **`hotwire remove`** — `hotwire.edit` — remove one
- **`hotwire enable`**, **`hotwire disable`** — `hotwire.edit` — turn one on or off

Full syntax where arguments are involved:

```
hotwire now    [update|validate] [seconds]
hotwire add    <restart|update|validate> <HH:mm> [pattern]
hotwire set    <restart|update> <index> <time|pattern|validate> <value>
hotwire remove <restart|update> <index>

hotwire enable  <restart|update> <index>
hotwire disable <restart|update> <index>
```

`hotwire now` with no seconds uses the configured countdown length, which is an hour by default. Pass a number if you mean sooner.

**An entry added with `hotwire add` is enabled immediately.** You typed the whole rule, so it is taken as meant. An entry added from the menu's `+ Restart` button starts disabled instead — that one is a blank form, not an instruction.

Patterns:

```
hotwire add restart 05:00                     daily
hotwire add restart 05:00 weekdays
hotwire add restart 03:00 Tue                 every Tuesday at 3am
hotwire add restart 05:00 Mon,Thu
hotwire add update  20:00 first Thursday      Rust force wipe day
hotwire add update  04:00 last Friday
hotwire add restart 05:00 day 15
hotwire add restart 05:00 every 2 days
hotwire add update  02:00 once 2026-12-24
```

The pattern words are English on every server. They are typed, not read, and a parser that accepted translated tokens would accept a different language on each install. Everything the plugin *says* back is translatable.

## The in-game panel

`hotwire menu` opens a panel over the same schedule, with no capability the commands lack. Each click edits and saves immediately — there is no draft to lose by disconnecting. Time, day of month, interval and date are stepped with buttons rather than typed, so nothing can end up as `5:0` in a field that has to parse.

## Localization

Every string a player can see is a lang key, and sentences take their parts as `{0}` arguments rather than being concatenated, so word order is the translator's to choose. 153 keys in `oxide/lang/en/Hotwire.json`, including weekday names and ordinals.

Lang files are written once and never rewritten. If you upgrade from a version before 1.1.0, delete the file to pick up the full set.

The `hotwire check` diagnostic dump is deliberately not translated. It is a console tool for whoever runs the server and is never seen in game.

## Configuration

Written on first load with **every entry disabled**. The file stays hand-editable; the commands and the panel are a convenience over the same file, never the only way in.

```json
{
  "Restarts": [
    {
      "Time": "05:00",
      "Repeat": "Daily",
      "Days": [],
      "Ordinal": "First",
      "DayOfMonth": 1,
      "IntervalDays": 2,
      "AnchorDate": "",
      "Date": "",
      "Enabled": false
    }
  ],
  "Updates": [
    {
      "Time": "20:00",
      "Repeat": "MonthlyWeekday",
      "Days": [ "Thursday" ],
      "Ordinal": "First",
      "DayOfMonth": 1,
      "IntervalDays": 2,
      "AnchorDate": "",
      "Date": "",
      "Validate": false,
      "Enabled": false
    }
  ],
  "Countdown": {
    "Start the countdown this many seconds before": 3600,
    "Announce when this many seconds remain": [
      3600, 1800, 900, 600, 300, 120, 60,
      30, 20, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1
    ],
    "Seconds between the last announcement and the kick": 1.0
  },
  "Framework update check": {
    "Enabled": false,
    "Check every this many minutes": 60,
    "Release feed URL": "https://umod.org/games/rust.json",
    "When a new release is found, update at (HH:mm)": "05:00",
    "Validate on a framework update": false
  },
  "General": {
    "Server root (empty = detect)": "",
    "Update flag file name": "UPDATE.flag",
    "Validate flag file name": "VALIDATE.flag",
    "Refuse to fire the same entry twice within this many hours": 20.0,
    "Name shown in chat announcements": "Server Manager",
    "Name color (hex)": "#e0995e"
  },
  "Status bar": {
    "Enabled": true,
    "Category": "Hotwire",
    "Order": 10,
    "Bar color, hex (blank = inherit)": "",
    "Text color, hex": "#FFFFFF",
    "Bar fill color, hex": "#C0392B",
    "Icon: built-in sprite path": "assets/icons/stopwatch.png",
    "Icon: local name in oxide/data/AdvancedStatus/Images": "",
    "Icon: URL (used only when the other two are blank)": "",
    "Icon color, hex (blank = the progress color)": "",
    "Fill style: Full, Fills or Drains": "Full",
    "Text left padding (pixels)": 5,
    "Countdown minimum width (characters)": 5,
    "Count seconds in the final minute": false
  }
}
```

**Repeat** is one of `Daily`, `Weekly`, `MonthlyWeekday`, `MonthlyDay`, `EveryNDays`, `Once`. Only the fields a mode uses are read, and the rest are left alone so switching modes does not lose what you had.

**Server root** is detected and almost never needs setting. `hotwire check` tells you in one line what it resolved to, whether `RustDedicated` is actually there, and whether it is writable — run it before trusting an update entry.

**Framework update check** is off by default. Turned on, it polls the release feed and, on finding a new build, schedules an announced update rather than installing one behind your back.

Every field, with its reasoning, is in [`docs/CONFIG.md`](docs/CONFIG.md).

## The launcher

The other half of the project, and the half that consumes the flag: a Windows batch launcher that starts the server, relaunches it when it exits, and — in `hotwire` mode — updates only when the plugin has asked it to. Every option in it is one independent line you can comment out without breaking the launch, and every default printed beside an option was read out of a real Rust build rather than copied from a guide.

You do not need it. The plugin restarts a server perfectly well on its own, and the launcher runs perfectly well without the plugin.

Full documentation: [`docs/LAUNCHER.md`](docs/LAUNCHER.md).

## What it does not do

Wipe. Manage maps. Restart on a schedule someone else owns — it does not know about your events, and will restart on top of one.

## Layout

```
src/Hotwire.cs                  the plugin
launcher/hotwire.bat            the launcher
launcher/secrets.example.bat    copy to secrets.bat; never committed
CHANGELOG.md                    what is in this release, and what is not
docs/LAUNCHER.md                the launcher in full
docs/CONFIG.md                  every config field, command and permission
docs/DECISIONS.md               every design choice, with its reasoning
docs/GAME-API.md                what has been verified against a real build
tools/convars.py                maintenance tooling; you never need to run it
```

## Credit

The problem space was mapped in part by reading [Smooth Restarter](https://umod.org/plugins/smooth-restarter) by 2CHEVSKII. Hotwire shares no code with it.
