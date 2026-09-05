# Brief — Hotwire

**Status:** early. The plugin compiles and loads under Oxide.Compiler
v1.0.32.0; the launcher is drafted. **Neither has been exercised on a live
server** — no countdown has run, and no flag has been handed to a launcher. Read this before writing code, then
`docs/DECISIONS.md` for the choices already made and `docs/OPEN-QUESTIONS.md`
for what is still unproven.

There is a longer internal brief, `HANDOFF.md`, which is deliberately not in
this repository: it describes one specific production server in enough detail
that publishing it would be unwise. Everything in it that a contributor needs
is either here, in the ADRs, or in `docs/RESEARCH.md`.

---

## 1. What Hotwire is

Scheduled restarts and updates for a Rust dedicated server, as a matched pair:

| | |
|---|---|
| `src/Hotwire.cs` | Oxide plugin. Holds the schedule, announces, counts down, decides, quits. **v0.1.0 — compiles and loads, never yet fired.** |
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

0. **Fire the plugin once, end to end.** It compiles and loads, and
   `hotwire check` confirms the flag path is right; it has never run a
   countdown. Wanted: does the flag land where the launcher looks; does
   a countdown announce, kick and quit cleanly; does the launcher act on the
   flag on its next pass. Until that has happened the update/restart split is
   a design, not a proven mechanism.
1. **Run `tools/convars.py` against a real `Assembly-CSharp.dll`.** It has
   never been executed. Everything downstream — real defaults, tier 3, the
   ADR-0010 recount — is blocked on it.
2. Teach it to report `ShowInAdminUI`, which is confirmed to exist on the
   `ServerVar` attribute. That is Facepunch's own list of admin-facing
   convars, and it turns tier 2 from a judgement call into data.
3. Decide where tier 3 lives and write the ADR (ADR-0008 leaves it open).
4. Split `launcher/hotwire.bat` into labelled tiers; 1 and 2 are mixed today.
5. Generate tier 3 and replace every `[default: unknown]` with a verified
   value — or leave it honest.
6. Build `tools/Test-Launcher.ps1`: check every `+convar` in a launcher
   against the installed build and report the ones that no longer exist. It
   turns a Rust update from a mystery outage into a two-line diff, and it is
   probably the most useful thing in the repo.
7. **The admin menu, last** (ADR-0006). Its precondition is met: the chat
   commands it wraps already do everything it will do, so a broken panel can
   never mean a schedule cannot be changed. Read ADR-0006 before starting —
   CUI lifecycle is the most bug-prone part of Oxide plugin work, and that
   lesson has already been paid for once elsewhere.
8. **Event-aware deferral.** Blocked on having anything to ask; see
   `docs/OPEN-QUESTIONS.md`. Must degrade to "restart on schedule, say nothing
   about events" on a server with none of the relevant plugins.

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
