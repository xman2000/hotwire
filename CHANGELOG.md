# Changelog

Versions cover both halves at once. The plugin and the launcher are only
useful together, so "Hotwire 1.0.0" means the same thing whichever one you are
holding.

## 1.0.0 — 2026-09-05

First public release.

**The launcher** (`launcher/hotwire.bat`) starts a Rust dedicated server and
relaunches it whenever it exits. Two update modes: `always`, which updates on
every start like most Rust launchers, and `hotwire`, which updates only when a
flag file says to — so an automated restart cannot install a new build
unattended. In `hotwire` mode a backstop updates anyway if a fortnight passes
without one, because a Rust server that never updates stops accepting
connections rather than merely going stale.

Every option is one independent line, so commenting one out cannot break the
rest of the launch. 75 curated options ship with the game's real defaults
printed beside them, read out of a real `Assembly-CSharp.dll` rather than
copied from a guide.

**The plugin** (`src/Hotwire.cs`, Oxide) holds the schedule. Six recurrence
modes — daily, certain weekdays, an ordinal weekday such as the first Thursday
of the month, a date each month, every N days, and one-off dates. It announces,
counts down, renders a status bar through AdvancedStatus where that is
installed, kicks players with a reason, saves the world on the way out, and
writes the flag when a restart is also an update. Full chat and console
commands, plus an in-game panel over the same schedule.

Schedules are local wall-clock time with a persisted guard against firing twice
across a daylight-saving change. Every schedule entry ships disabled.

**Tooling** (`tools/convars.py`) reads convars and their defaults out of an
assembly and audits a launcher against a build. It is maintenance tooling —
nothing in `launcher/` refers to it and nobody installing this needs Python.

### Known limitations

- The launcher's `always` mode has not been exercised on a live server;
  `hotwire` mode has.
- The framework-update check has never fired. It is off by default.
- No countdown has yet crossed a daylight-saving boundary.
- Event-aware deferral — not restarting on top of a live event — is not built.
- Windows only. There is no shell port of the launcher.
- No crash-loop protection: if the server dies on boot, the launcher relaunches
  it every 15 seconds indefinitely.

`docs/OPEN-QUESTIONS.md` keeps the current list, including what is assumed
rather than verified.
