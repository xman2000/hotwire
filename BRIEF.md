# Brief — Hotwire

**Status:** the plugin works, and has run on a live server — announced,
counted down, kicked, saved, quit, wrote an update flag, and had a launcher
act on it. It also has a full recurrence model and an in-game panel.
**`launcher/hotwire.bat` is still unrun**: the flag contract was proven
against the reference server's own launcher, not against the one in this
repository, and those are different claims.

Read this before writing code, then `docs/DECISIONS.md` for the choices
already made and `docs/OPEN-QUESTIONS.md` for what is still unproven.

There is a longer internal brief, `HANDOFF.md`, which is deliberately not in
this repository: it describes one specific production server in enough detail
that publishing it would be unwise. Everything in it that a contributor needs
is either here, in the ADRs, or in `docs/RESEARCH.md`.

---

## 1. What Hotwire is

Scheduled restarts and updates for a Rust dedicated server, as a matched pair:

| | |
|---|---|
| `src/Hotwire.cs` | Oxide plugin. Holds the schedule, announces, counts down, decides, quits. **Working.** |
| `launcher/hotwire.bat` | Windows launcher. Restarts the server, and updates it only when told. **Drafted, never executed.** |

They ship together because neither is much use alone. The plugin can shut a
server down but cannot bring it back; the launcher can bring it back but has
no idea when it should go down.

## 2. The flag file is the whole interface

```
  Hotwire (plugin)                        hotwire.bat (launcher)
  ─────────────────                       ──────────────────────
  holds the schedule
  announces + counts down
  at zero:
    if this is an update  ──────────────►  writes UPDATE.flag
    kicks players
    Global.quit()         ──────────────►  process exits
                                              ↓
                                           flag present?
                                             yes → steamcmd + framework,
                                                   delete flag
                                             no  → straight to launch
                                              ↓
                                           relaunch, loop
```

The plugin never spawns a process, writes a scheduled task, or shells out. It
writes a file and quits. Keeping the contract that narrow is what makes both
halves testable and either half replaceable — and it means the plugin never
needs permission to start processes on a stranger's machine.

| File in the server root | Effect on the next launch |
|---|---|
| `UPDATE.flag` | `steamcmd +app_update 258550`, then the framework, then launch |
| `VALIDATE.flag` | the same plus `validate`, which re-checksums the whole install |
| neither | straight to launch — no steamcmd, no framework download |

The flag is deleted once acted on, so **one flag buys one update**.

## 3. Why the update/restart split exists

Measured on the reference server — a 4250-size procedural map with 43 plugins
loaded, on 2026-09-03:

- `[Bootstrap] completed in 153.04s`. Navmesh ≈58s. Process start to "Server
  startup complete" ≈3 minutes, with content still generating at +5.
- Add `steamcmd validate` against a ~20 GB install and the same restart is
  6–8 minutes.

So a restart that also updates costs roughly double. Worse, the launcher it
replaced re-downloaded and force-extracted the mod framework over a working
install **on every exit**. Twenty-nine days a month that is harmless; the day
after a Rust force wipe it is how a server comes back at 5am with broken
plugins and nobody watching.

That is the argument the README makes, and the thing Hotwire does that a
plain restarter does not.

## 4. The launcher: three tiers of options

The framing: *the start.bat that Facepunch never created* — one that lists
every option, lets you comment them in and out, documents the defaults, and
hands you the tools to maintain it yourself.

| Tier | What | How many | Where it comes from |
|---|---|---|---|
| **1. Boilerplate** | Edit five values, get a working server | ~10 | Hand-written, hand-verified, stable for years |
| **2. Common** | What admins actually change | ~20-30 | Curated, seeded from evidence — `docs/RESEARCH.md` |
| **3. Reference** | Everything discoverable | hundreds | Generated from the installed assembly |

The tiers have different truth requirements, which is the whole point.
`server.hostname`, `server.port`, `server.identity` and friends have not moved
in years, so tier 1 and 2 can be hand-written and given real prose. Tier 3
churns with content updates.

And **defaults churn faster than names.** Facepunch tunes numbers far more
often than it renames anything, so the specific danger is not "this convar
vanished", it is "*this comment says the default is 600 and it has quietly
been 900 for six months*". That is the failure `tools/convars.py` exists to
prevent, and it is why `UNKNOWN` beats a guess. See ADR-0008.

Two mechanics make the launcher editable, and both are load-bearing:

- **One option per line, appended to a variable** — `set "ARGS=!ARGS!
  +server.maxplayers 50"` — rather than one `^`-continued command. That is
  what makes `REM` on a single line safe. Commenting out a line inside a
  continued command breaks the continuation chain and silently takes the rest
  of the launch with it, which is exactly why hand-edited launchers are so
  frightening.
- **Delayed expansion for values.** `!ARGS!`, never `%ARGS%`. Delayed
  expansion substitutes after cmd has parsed the line, so `| & > < ^` inside a
  value are never seen by the parser. A hostname like `My Server | Monthly |
  NA` breaks a launcher written with `%ARGS%` and works here.

## 5. What is left to do, in order

0. **Run `launcher/hotwire.bat` as shipped.** Its structure has now booted a
   real server — a launcher generated from it, carrying one site's settings,
   started the reference server on protocol 2633.288.1. What has not run is
   this file with its own defaults, and in particular `UPDATE_MODE=always`,
   which is the default and was not the mode that ran.
1. **Fire the framework-update check once.** It is off by default and has
   never run, so the path from detecting a new release through to an announced
   update is untested — as are the two assumptions only reachable through it,
   the feed's shape and the extension's name.
2. **Watch a countdown cross a DST boundary.** ADR-0013's guard is written,
   persisted and reasoned about, but the autumn repeat it exists for has not
   happened yet.
3. **Event-aware deferral.** Blocked on having anything to ask; see
   `docs/OPEN-QUESTIONS.md`. Must degrade to "restart on schedule, say nothing
   about events" on a server with none of the relevant plugins.

The plugin is done for v1: schedule, six recurrence modes, countdown,
announcements, status bar, kick, save, quit, flag, chat commands and the
in-game panel (ADR-0006, built last as it was meant to be).

The launcher is done too, and so is its option list — 75 curated options whose
names and defaults were read out of a real build, with `convars.py --check`
keeping them honest after a Rust update. The tier scheme this brief used to
describe is gone: ADR-0018 replaced it with one curated list, and ADR-0010,
which chose how to split the tiers across files, went with it.

## 6. Do not

- Write a convar or a default from memory. Generate it, or mark it `UNKNOWN`.
- Put the plugin on a daily schedule before the update/restart split is
  proven on a real server.
- Ship anything that assumes a particular third-party plugin is installed.
  Event-aware deferral in particular must degrade to "restart on schedule,
  say nothing about events" on a server that has none of them.
- Present assumed game API as verified. `docs/GAME-API.md` holds what was
  read out of a real assembly; everything else is tagged `// VERIFY:` and
  listed in `docs/OPEN-QUESTIONS.md`.
