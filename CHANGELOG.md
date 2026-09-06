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

Entries are newest first, so the two halves interleave: a plugin `1.1.2` can
sit above a launcher `1.1.7`. Read the label, not the number.

`hotwire check` prints the plugin's version. The launcher's is in the banner
at the top of the file — it is a comment, not something it echoes, so read it
rather than watch for it.

## 1.1.2 — plugin — 2026-09-05

**The in-game panel never refreshed itself.** It is static text, drawn once and
redrawn only when you click something, so a panel left open through a countdown
kept showing whatever was true when it opened. Caught on a live server with the
panel reading *"update and restart in 12 minutes"* beside a status bar reading
`5m` — the bar counts itself down, the panel did not.

That is worse than cosmetic. The banner that goes stale is the one offering
**Cancel the restart**, so the number an admin is deciding on could be minutes
out of date.

Open menus now refresh on a timer: every five seconds while a countdown is
running, every thirty otherwise, and the timer stops itself when the last menu
closes. Only the content is replaced — the root panel, which owns the cursor,
is left alone, because recreating that per redraw is what used to throw the
cursor back to the middle of the screen.

## 1.1.1 — plugin — 2026-09-05

**One red instead of four.** The panel had `ColOff` at `0.42 0.22 0.22`,
`ColDanger` at `0.58 0.24 0.20`, an inline `0.85 0.45 0.40` for broken text, and
a status bar filling `#E74C3C` — four unrelated reds, two of them side by side
on every row.

Worse, `OFF` was one of them. Being switched off is a state, not a hazard, and
it sat four inches from a red `Delete` on the same row with only the label
telling them apart. `OFF` is now a recessed neutral: the toggle column reads as
lit or unlit rather than as safe or dangerous.

What remains is one danger red — `#C0392B`, for `Delete` and the countdown
banner — the same hue lightened into `ColDangerText` where it has to be legible
as text on a dark row, and amber kept deliberately outside the family for
"this will behave in a way you may not expect". Every color literal in the menu
is now a named constant.

**The status bar's default fill changes to `#C0392B`** so the HUD and the panel
agree. An existing config keeps `#E74C3C`; delete the `Status bar` section, or
set `Bar fill color, hex` yourself, to pick it up.

## 1.1.7 — launcher — 2026-09-05

**The launcher now knows which Rust build is current, and says so.** Steam
publishes it and `steamapps\appmanifest_258550.acf` records the installed one,
so the comparison costs nothing but a steamcmd launch — cached for
`BUILD_CHECK_HOURS` (6), which means a daily restart pays for it once a day and
a crash loop never pays at all. Every start now prints one of:

```
Rust build: installed 25129933, public 25129933 -- current.
```

or a banner saying a newer build is available and that clients update
themselves, so the server will eventually stop accepting connections.

Three things follow from having that number:

**`UPDATE_ON_NEW_BUILD` (on) makes the backstop fire on evidence.** A build that
has actually changed is a better reason to update than fourteen days having
passed, and a server that is current is now left alone however long it has been.
The calendar backstop remains as a fallback for when Steam cannot be reached.

**`SKIP_UNCHANGED_FRAMEWORK` (on) stops needless re-extracts.** Writing the
framework over a working install is the riskiest thing this file does. It is now
skipped when the game did not move *and* the framework's own version matches its
feed. The game check matters: a Rust update rewrites the managed assemblies, so
the framework must go back over the top regardless of its version.

**`FRAMEWORK_VERSION_FILE` and `FRAMEWORK_FEED`** are settings rather than
assumptions, so nothing here hard-codes a path that might not be yours.

Every failure path falls through to the old behavior: no steamcmd, no network,
a hang (180s timeout, then the process is killed), an unreadable manifest or a
missing version file all leave the launcher doing exactly what it did before.
None of this can decide not to start the server. ADR-0028.

## 1.1.6 — launcher — 2026-09-05

**The update stamp was written with the redirect last**, so the character
immediately before the arrow was whatever digit the clock happened to end on —
and cmd reads a digit in that position as a file handle number, not as text.
Handle 1 is stdout and worked by luck; handles 3 to 9 created the file and wrote
nothing into it; handle 2 sent the line to stderr. The backstop reads the file's
timestamp rather than its contents, so this survived entirely on the file being
created at all. The redirect comes first now.

**A flag that cannot be deleted, or a stamp that cannot be written, is now
reported.** Neither shows up in the outcome — the update succeeded — but an
undeletable `UPDATE.flag` means every restart from then on updates, forever, in
silence, and an unwritable stamp means the backstop believes no update has ever
happened. Warnings rather than failures, since the update itself worked.

Section 4 was audited against its own annotations: all 75 options have a name,
a type and a default, every comment names the convar its line actually sets,
none is set twice, and all 15 enabled values match their declared types. Three
defaults are honestly recorded as `UNKNOWN`.

## 1.1.5 — launcher — 2026-09-05

Hardening found by reviewing 1.1.4 line by line. Most of these were defects in
1.1.4 itself, written the same day.

**A broken option check can no longer stop a working server.** PowerShell exits
`2` for "ran, found problems" and `0` for "ran, found none"; anything else means
the check did not run — no PowerShell, or an error inside the script — and the
launcher says so and continues. Previously any non-zero exit was read as
"problems found", so a mistake in the check would have refused to start a server
whose settings were fine.

**`timeout` refuses to run when stdin is redirected**, which is how the launcher
behaves under a scheduler. It returned immediately, so the relaunch loop would
have spun with no delay at all and the steamcmd retry would have hammered Steam.
Both now fall back to `ping` when `timeout` fails.

**Two of 1.1.4's own checks could have blocked a working server** and were
softened. A space in `server.identity` is legal in a folder name and is allowed
again; only genuinely illegal path characters are refused. And `rcon.password`
is exempt from the unexpanded-variable heuristic, since a password may
legitimately contain `%word%` — it is validated in full separately.

**The settings check now runs before anything uses `ROOT`.** It strips a
trailing backslash, and it was running after `cd /d "%ROOT%"` had already used
the unstripped value.

**A `logs` directory that cannot be created is now fatal and says so.** The
rotated logs and the update backstop stamp both live there; without it a crash
leaves nothing to read and the backstop never fires.

Also: the server is launched by full path rather than relying on the working
directory; the crash-loop message names "another copy of this launcher already
running" as a cause, since the second one cannot bind the port; and 32 lines had
picked up doubled carriage returns.

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

**Executed on a real server 2026-09-05**, after 1.1.6. Both directions: a
clean option list passes in 0.7s, and a deliberately broken one — the query
port set equal to the game port — is caught, named, and refuses to start.

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

**The flag and stamp half was executed 2026-09-05**, by a scheduled update
firing unattended: the flag was consumed only after both steps succeeded, and
the stamp was written. The crash-loop path still has not run — it needs a
server that genuinely fails to boot.

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
