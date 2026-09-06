# Changelog

## How the version numbers work

`MAJOR.MINOR.PATCH`, and the first two are a promise about the pair.

**MAJOR and MINOR always agree between the plugin and the launcher.** They are
only useful together, and those two numbers are the contract: a launcher on
1.1 and a plugin on 1.1 are built for each other. When the pair moves, both
move, and both patch numbers go back to 0.

**PATCH belongs to one half at a time.** A fix to the launcher between minor
releases advances the launcher's patch and leaves the plugin's alone, and the
reverse. Shipping a release with no changes in it, purely to keep two numbers
level, would be worse than the numbers differing.

So "Hotwire 1.1" names the pair and is the version worth quoting. A full
`1.1.3` names one half, and every entry below says which. They are expected to
differ; that is the design, not drift.

`hotwire check` prints the plugin's version. The launcher's is in the banner
at the top of the file — it is a comment, not something it echoes, so read it
rather than watch for it.

## 1.1.4 — launcher — 2026-09-05

**The launcher now checks its own settings and its option list, and refuses to
start when they cannot work.** `hotwire.bat check` runs the same checks and
exits without updating or starting anything.

Rust ignores a convar it does not recognize and accepts an empty value for one
it does, both without a word. The option list is tokenized and checked for a
convar with no value, an empty value, a value still holding an unexpanded
`%VAR%` or `!VAR!`, the same convar set twice, a name with no dot in it, an
unbalanced quote, a port that is not a number or is out of range or collides
with another port, and a `server.identity` that cannot be a folder name.

Section 1 is checked too: non-numeric counts and delays, `LOG_KEEP=0` (which
would have made the cull delete every rotated log rather than keep none), a
misspelled `UPDATE_MODE` — anything that is not `always` was silently treated
as `hotwire` — and an empty `ROOT`. A trailing backslash on `ROOT` or
`STEAMCMD` is stripped rather than reported; it would otherwise escape the
closing quote of every path passed to another program.

A missing PowerShell skips the check with a note instead of blocking the
launch. ADR-0027.

## 1.1.3 — launcher — 2026-09-05

**The launcher now refuses to start on a password that cannot be right**, and
says which file to fix. Empty, under 8 characters, still the example value, or
containing a double quote — each gets its own line and the path to the secrets
file.

This exists because a two-character leftover in a secrets file was passed
through as `+rcon.password "xx"` and the server died in `Bootstrap.Init_Tier0`
with `ArgumentException: String cannot be of zero length`. Rust redacts the
password out of its own logged command line, so an implausible value makes that
redaction throw before anything else runs. The message names nothing and points
nowhere, and the launcher — which knows exactly which file the value came from
— had said nothing at all. It only checked that the variable was *defined*.

The check runs in PowerShell rather than with batch string slicing, because the
value is untrusted text and a quote or caret in it would break the comparison
meant to catch a bad password.

Also added: a missing `RustDedicated.exe` under `ROOT` is now refused by name.
That is the same class of failure — every convar correct and the server simply
not there.

## 1.1.2 — launcher — 2026-09-05

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

## 1.1.1 — launcher — 2026-09-05

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

## 1.1.0 — plugin and launcher — 2026-09-05

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

## 1.0.0 — plugin and launcher — 2026-09-05

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
