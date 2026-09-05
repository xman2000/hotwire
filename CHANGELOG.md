# Changelog

Versions cover both halves at once. The plugin and the launcher are only
useful together, so "Hotwire 1.0.0" means the same thing whichever one you are
holding.

## 1.1.2 — 2026-09-05

**The RCON password was passed unquoted**, so a password containing a space
became two arguments and the server listened on the first word. It is quoted
now.

**A `!` in the password was destroyed before it was used.** `secrets.bat` is
`call`ed under `EnableDelayedExpansion`, so its own `set` line lost everything
from a `!` onward. The file is read with expansion disabled now and the value
carried back out intact, so `!`, `%`, `^` and spaces are all read exactly as
written. A `"` or a leading `;` still cannot pass, and now fails loudly at
startup with the reason rather than silently changing the password. The
previous advice to avoid `!` and `^` is withdrawn — it was a bug, not a rule
for users to remember. ADR-0024.

## 1.1.1 — 2026-09-05

**The launcher consumed an update flag even when the update failed**, and reset
its own backstop clock at the same time. Both lines ran unconditionally at a
point reachable from the "giving up on steamcmd" path, so:

- A requested update that failed was silently downgraded to a plain restart.
  The documented contract is one flag, one update; what it implemented was one
  flag, one attempt.
- A server that could not reach Steam rewrote its "last updated" stamp on every
  failed try, so the fourteen-day backstop could never fire — in precisely the
  situation it exists to catch.

The flag is now deleted and the stamp written only when steamcmd and the
framework extract both succeeded, and a banner says so when they did not.
ADR-0022.

Also: the elapsed-days check used `[int]`, which rounds, so 13.6 days tripped
the 14-day backstop half a day early; it floors now. A failed timestamp call
during log rotation produced `server_log_.txt` and then overwrote it on every
later failure; it falls back to a unique name. `secrets.example.bat` now says
that `!` and `^` cannot appear in an RCON password, because delayed expansion
eats them and the server would listen on a different password than the one
written in the file.

**A crash loop destroyed the log explaining it.** Rotation culled to `LOG_KEEP`
every pass, and a server dying on boot relaunched every 15 seconds, so about
three and a half minutes in, the log holding the actual failure had been culled
and fourteen identical near-empty ones were left. The launcher now times every
run: shorter than `CRASH_SECONDS` (60) is a crash, the first crash of a streak
keeps its log as `server_crash_*` where the cull cannot reach it, the delay
backs off 15/30/60/120/300, and after `MAX_CRASH_STREAK` (10) it stops and says
why rather than looping forever. Set `MAX_CRASH_STREAK=0` for the old behavior.
ADR-0023.

Read-verified, not executed.

## 1.1.0 — 2026-09-05

**Every string a player can see is now a lang key.** Previously the schedule
descriptions, the validation complaints and most of the in-game panel were
English assembled in code — `"the " + ordinal + " " + day + " of the month"` —
which no translation could reach. They are composed from keys now, with the
parts passed as `{0}` arguments, so a translator can reorder them.

That is a uMod submission requirement, and it also fixed three real bugs on an
English server:

- The status bar label, the kick reason and the words *restart* / *update and
  restart* inside broadcast announcements were resolved once in the server's
  language and then shown to everybody. On a server with a translation
  installed, a player reading another language got a translated sentence with
  an untranslated word inside it. Each is now resolved per recipient.
- Weekday names came from `DayOfWeek.ToString()`, which is English on every
  server whatever its culture. They come from lang keys now.
- English ordinal suffixes (`15th`) were generated in code. That logic is gone;
  the day of the month is an argument to a translatable sentence.

`oxide/lang/en/Hotwire.json` grows from 30 keys to 153. Lang files are written
once and never rewritten, so an existing file keeps its old keys and the new
ones fall back to English — **delete it to pick the new set up.** Wording of
the existing announcements is unchanged.

Not converted: the `hotwire check` diagnostic dump. It is a console tool for
whoever runs the server, never seen in game, and forty column-aligned fragments
would make the lang file worse for nobody's benefit.

Also in this release: a recurrence is parsed once per lookup instead of once
per day, which took the 367-day scan for the next occurrence from 367
allocations to one.

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
rest of the launch. The curated options ship with the game's real defaults
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

`docs/DECISIONS.md` records why the design is the way it is, and
`docs/GAME-API.md` lists what has been verified against a real build rather
than assumed.
