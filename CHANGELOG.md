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

## 1.1.17 — plugin — 2026-09-17

**A sharper map, and Raidable Bases zones named on it.**

- **The map image is rendered sharper.** The plugin renders it to about 4096 px on a side instead of the game's own 0.5
  scale, so the panel's map holds up when you zoom in. It is preferred over the Rust+ cached image when rendering is on
  (the `Panel` config's map-image switch); Rust+'s image is the fallback. Off any path a server waits on, once per map.
- **Raidable Bases zones are reported and named.** The plugin latches onto Raidable Bases' own `OnRaidableBaseStarted` and
  `OnRaidableBaseEnded` hooks and sends each active raid's position, difficulty, radius and name (`kind: raid_zones`). The
  panel labels Raidable Bases' own coloured dot with it — "Raidable Base — Hard" — instead of leaving it unnamed. Sent when
  the set changes, at most once a minute, and gated by the same `Report the map` config as the markers.

## 1.1.16 — plugin — 2026-09-16

**The map's layout, for a connected server's map layers.**

- **The map layout** is sent once per map: the landmarks the game shows on its map, the roads, rails, rivers and power lines,
  the train tunnel grid and its entrances, and the underwater labs' rooms. It is what the world generator made, never
  players, bases or anything that moves. A restart sends nothing; it is sent again after a week.
- **A new config switch** under `Panel`: `Send the map layout`. `hotwire check` shows the last send under "map layout".

## 1.1.15 — plugin — 2026-09-16

**Far less memory: a plugin file's text is read only when the file changes.**

- The plugin list check ran every minute and read the full text of every plugin in the plugins folder to find its `[Info]`
  line. On a server with 10 MB of plugins that allocated tens of megabytes a minute. The `[Info]` line is now read once with
  the file's hash, and again only when the file changes. The plugin list it sends is the same.

## 1.1.14 — plugin — 2026-09-16

**Each plugin's server time, for a connected server.**

- **Each plugin's server time** is reported every minute: the seconds Oxide timed each plugin's hooks, timers, commands and
  web request callbacks, and the memory allocated while they ran, the figures `oxide.plugins` shows, sent as the change.
  Plugin names and numbers only.
- **A new config switch** under `Panel`: `Report each plugin's server time`, and how often. `hotwire check` shows the last
  send under "plugin time".
- An early build of 1.1.13 carried this too; this version exists so a server running it can be told apart.

## 1.1.13 — plugin — 2026-09-16

**Performance figures, who is online, player joins and leaves, and chat, for a connected server.**

- **The heartbeat carries performance figures:** the game process's share of the machine's CPU, and entities, memory,
  network and the join queue as Rust's own `serverinfo` reports them. They are read from the game by name while it runs,
  so a Rust update that moves them drops these figures with a warning, never the rest of the plugin.
- **Who is online, when players join and leave, and chat** are sent only while the panel's player data level is
  "identified". Below it, only the player count leaves the machine, and anything gathered is let go when the level drops.
  Names, disconnect reasons and chat have card numbers and SSNs masked first. Chat commands are never sent as chat.
- **New config switches** under `Panel`: `Send who is online, and player joins and leaves`, `Send chat`, and how often
  joins, leaves and chat are sent. `hotwire check` shows what each has sent.

## 1.1.12 — plugin — 2026-09-13

**Unload a plugin from the panel, and the plugin list names each file.**

- **A new panel command unloads a plugin.** The file stays where it is and nothing is deleted or moved; Oxide loads
  the plugin again when the server restarts, or when the panel reloads it. Hotwire refuses to unload itself from the
  panel, because it would stop hearing the panel; unload it on the server instead.
- **The plugin list sends each plugin's file name** beside the name in its `[Info]` line. Oxide reloads and unloads
  by file name, which often differs from the title (`ImageLibrary` for "Image Library"), so the panel can now reload
  or unload any plugin it lists. The plugin list hash is unchanged.

## 1.1.11 — plugin — 2026-09-13

**Log lines are readable, and the panel's health rows fill in.**

- **Every log line's text is sent.** Card numbers keep only their last four digits and hyphenated US SSNs are masked
  at every sharing level; Steam IDs are removed below the "identified" level. Nothing else is held back. 1.1.10 held
  back every line's text below that level, which made the panel's log useless.
- **The heartbeat reports the query port** (`server.queryport`, or the game port when it is 0), so the panel can
  check the game port without anyone typing it in, and **which Steam branch is installed**, so the installed build is
  compared with the right one.
- **Each boot is reported:** how long it took, how many plugins loaded and which failed, and, at the next boot,
  whether the run before ended with a clean shutdown or not (a crash, a kill or a power loss). A plugin loaded into a
  server that is already running does not time a boot it did not see.
- `hotwire check` shows the session state.

## 1.1.10 — plugin — 2026-09-13

**Oxide's log, sent to the panel.**

- Reads `oxide/logs/oxide_<date>.txt` as Oxide writes it and sends new lines every minute: time, level, plugin
  and, where allowed, the text. A stack trace stays with the line it belongs to.
- **Below the "identified" player data level no line's text is sent**, because a line can hold a player's name.
  Each line still arrives with its time, level, plugin, length, what it might contain, and a fingerprint of its
  shape, so a gap is visible rather than silent. Your log file stays the full record.
- Card numbers keep only their last four digits, and hyphenated US SSNs are masked, before anything is sent.
- Where it has read up to is kept in `oxide/data/Hotwire/panel_log.json`, so a reload or an outage never sends
  a line twice or skips one. A batch too large for the panel is split, never dropped.
- Times are read in 24-hour or AM/PM form. A time that cannot be read, or that falls in the hour a clock change
  repeats or skips, is left out rather than guessed.
- New `Panel` settings: `Send the Oxide log` (on) and `Send the log every this many seconds` (60).
  `hotwire check` shows what has been sent and whether text is included.

## 1.1.9 — plugin — 2026-09-13

**Player data sharing, applied on the server.**

- Asks the panel every two minutes for the account's sharing level: counts only, anonymous, pseudonymous or
  identified. Applied here, before anything is sent.
- Fails closed. No answer yet, an unreadable answer, an unknown level, or pseudonymous without its salt all
  mean counts only. A request that simply fails keeps the level in force.
- The last answer is kept in `oxide/data/Hotwire/panel_sharing.json` with the key it came from. A different
  key starts again at counts only.
- `hotwire check` shows the level in force and where it came from.
- Nothing sent today carries a player's identity. This is in place before the log and event senders that
  will use it.

## 1.1.8 — plugin — 2026-09-13

**The schedule can be run from the panel.**

- **Reported:** every restart and update entry, with its description, when it next fires, and any problem.
  Also the countdown settings, the framework check, and a countdown running now. Sent when it changes.
- **Changed from the panel:** add, edit, enable, disable and remove entries. Checked exactly like the chat
  commands. A change made against a schedule that has since changed in game is refused, never applied over
  it.
- **Run now:** an announced restart can also be an update or a validate, and a running countdown can be
  canceled from the panel.
- Every schedule entry gets a stable `Id` in the config, so the panel can name it after entries move.
- New `Panel` settings: `Report the schedule` and `Accept schedule changes from the panel`, both on.
  `hotwire check` shows the schedule report's state.

## 1.1.12 — launcher — 2026-09-13

**Its own map, not everyone's.**

- **`SERVER_SEED`** in section 4.1. Empty means the game's own seed, and Rust's own default is **1337**, so
  every server left to it plays the same map. `hotwire-setup` now writes a random seed there when it builds
  a new server. It picks once, so restarts keep the map. A server that already has a save gets no seed,
  because a new seed on a played server starts a new map.
- The option check refuses a `server.seed` that is not a whole number from 0 to 2147483647.
- `server.randomize_seed` is deliberately not used: it picks a new seed on every start, and so a new map on
  every restart.

## 1.1.7 — plugin — 2026-09-13

**The map image arrives by itself.** No console command, no upload.

- The picture Rust draws of the map for the Rust+ app at startup is sent to the panel once per map.
  The panel is asked first, so a restart on the same map sends nothing.
- With Rust+ off, the plugin asks the game to draw the same picture, once per map, two minutes after
  startup. It takes the game a few seconds.
- Read by name like the rest of the map. If the game's renderer changes shape, the image is not sent,
  with a warning, and everything else carries on.
- A panel whose web server refuses a large upload is told plainly in the console, and the image is
  tried again in an hour. Heartbeats are never held up.
- New `Panel` settings: `Send the map image` and `Render the map image if Rust+ has not`, both on.
  `hotwire check` shows the map image state.

## 1.1.6 — plugin — 2026-09-13

**The panel can show the map.**

- **Map details:** seed, world size, whether it is procedural, the custom map address, the map name, and
  when the current save was created (the last wipe). Sent when they change.
- **Map markers other plugins place:** radius circles (position, radius, fill and outline colour, opacity)
  and their text labels, such as Flashpoint's PVP zones. Sent when they change, at most once a minute. A
  player's vending machine is never sent, since it marks their base, and players are never sent.
- **Read by name while running.** The game's map types are looked up by reflection instead of being
  named in the code, so a Rust update that moves one cannot stop the plugin compiling. Map reporting
  switches itself off with a warning, and everything else carries on.
- New `Panel` settings: `Report the map and its markers` (true) and `Send map markers at most every this
  many seconds` (60). `hotwire check` shows the map state.

## 1.1.5 — plugin — 2026-09-13

**The panel can see what is installed, act on the server, and enforce bans.**

- **Plugin list.** Every `.cs` file in the plugins folder, sent when the list changes: name, author and
  version as written in its `[Info]` line, the file's SHA-256 and size, whether it loaded, and Oxide's
  compile error if it did not. The heartbeat carries the list's hash. The files are never sent.
- **Commands.** Checked every 30 seconds. Carried out: message players, save, reload a plugin, kick, and
  restart. A restart always runs the announced countdown, never shorter than 60 seconds (configurable,
  minimum 10). Anything else is refused with a reason. Each command is recorded on disk before it runs and
  acknowledged twice, received and then done, failed or refused, so one the panel resends is answered, not
  repeated.
- **Ban list.** Checked every two minutes and written into the server's own ban list, so bans hold without
  the panel. A player who is online is kicked when banned. Only bans the panel added are changed or lifted.
  Mutes are not enforced. An account without ban sync gets nothing added, and earlier bans stay.
- **Heartbeat FPS**: frames actually run since the last heartbeat, averaged over the time between them.
- **One request at a time**, with a rejected report let go rather than retried forever, so a bad answer
  can never hold up the heartbeat.
- New `Panel` settings: `Accept commands from the panel`, `Check for commands every this many seconds`,
  `Shortest restart countdown from the panel (seconds)`, `Enforce the panel's ban list`, `Check the ban
  list every this many seconds`. `hotwire check` shows each one's state.
- `tests/plugin-signing` now also checks the plugin list hash against the panel's fixture, and GET signing.

Not yet: player events and log lines (they wait on the admin's choice of how much player data leaves the
machine), and the launcher's reports.

## 1.1.4 — plugin — 2026-09-13

**Reports to a Hotwire panel.** A server connected with `hotwire-setup connect` now shows up as live.

- **A signed heartbeat every 30 seconds:** player count, max players, uptime, Oxide version, network
  protocol, and the installed Rust build (read from Steam's app manifest). A value that cannot be read is
  left out, never guessed.
- **Only when connected.** The key is read from `oxide/data/Hotwire/panel.json`, which connect writes. No
  file, nothing sent. The file is re-read when it changes, so connect and detach need no reload.
- **Not from a copy.** If `panel.json` was written for another folder, the plugin refuses to report and says
  which folder it was written for.
- **Never in the server's way.** Requests are queued; failures are caught, logged once with what to do, and
  retried with a wait that doubles up to ten minutes.
- New config section `Panel`: `Report to the panel when connected` (true) and `Heartbeat every this many
  seconds` (30).
- `hotwire check` shows the panel state.
- `tests/plugin-signing/run.sh` checks the signing code, taken straight out of the plugin, against the
  panel's published signature vector.

Not yet: `fps` and the plugin inventory hash in the heartbeat, session and inventory reports, and collecting
commands from the panel.

## 1.1.11 — launcher — 2026-09-13

**Safe with several servers on one machine.** Admins often run a production and a dev server side by
side, on different branches.

- **ROOT is this file's own folder** (`%~dp0`) unless set otherwise. Before, a copied server folder
  kept the original's `ROOT`. Started from the copy, it updated and ran the *original* server. A `ROOT`
  that is not this file's folder, and has a `hotwire.bat` of its own, is now refused at start.
- **SteamCMD takes turns.** Every run holds `hotwire-steamcmd.lock` beside `steamcmd.exe`, opened
  unshared, and `hotwire-setup` takes the same lock. Another server waits, and says so, for up to
  `STEAMCMD_WAIT_MINUTES` (60), then gives up on updating this pass and starts the server as it is.
  The lock is released when the process ends however it ends, so it cannot be left stuck. The build
  check does not wait: if SteamCMD is busy it skips the question for that start.
- **The crash-loop stop names two servers on one port** as a likely cause, and points at section 4.2.

Also: `hotwire.bat check` no longer runs `HOOK_BEFORE`. It no longer says "No problems" when the
option check was skipped (`CHECK_OPTIONS=0`) or could not run. Stale comments were corrected: update
modes, flag file names, the crash back-off, the password rules and the branch the build check reads.

## 1.1.3 — plugin — 2026-09-13

`hotwire check` warned about a flag file by its default name, `UPDATE.flag` or `VALIDATE.flag`, even
when the config names it something else. It now uses the configured names. The note written with a
flag no longer promises the launcher "will act on it, then delete it": it deletes the flag once an
update completes, and not at all when its `UPDATE_MODE` is `off`.

## 1.1.10 — launcher — 2026-09-13

**Every behaviour is a setting, and updates can be switched off.** What the launcher does was partly
settings and partly fixed in the code. All of it is in section 1 now, with the same values as before,
except `STEAM_BRANCH` (below):

| setting | default | what it does |
|---|---|---|
| `UPDATE_MODE` | `always` | now also `off`: never update, not even for a flag file, which is left in place |
| `STEAM_BRANCH` | `public` | the Steam branch installed and updated; empty lets Steam choose |
| `UPDATE_FLAG`, `VALIDATE_FLAG` | `UPDATE.flag`, `VALIDATE.flag` | the flag file names, to match the plugin's |
| `STEAM_RETRY_SECONDS` | `60` | wait between steamcmd tries |
| `ROTATE_LOGS` | `1` | keep each run's log; `0` lets the server empty it every start |
| `RESTART_ON_EXIT` | `1` | `0` stops the launcher when the server exits |
| `CRASH_BACKOFF` | `1` | `0` always waits `RESTART_DELAY`, however many crashes |
| `RCON_PASSWORD_MIN` | `8` | the shortest password it starts with; never `0` |
| `CHECK_OPTIONS` | `1` | `0` skips the section 4 check |
| `FRAMEWORK_URL` | umod.org's download | where Oxide is downloaded from |

**The branch is named on every update.** Steam keeps using whatever branch an install was last on. A
test install built by `hotwire-setup` turned out to be on `staging`, with nothing in either script asking
for it, and SteamCMD kept it there. The update line now passes `-beta public` unless `STEAM_BRANCH` says
otherwise, and the build check compares against that branch rather than always public. **A server on a
test branch moves to public on its next update**, which is a downgrade of the game build. Set
`STEAM_BRANCH` first if that server is meant to stay where it is.

**`server.identity` is the game's default.** Setting it to `my_server` was our choice. **If a server has
already run under 1.1.9 or earlier, its saves are in `server\my_server`.** Put `+server.identity
my_server` back in section 4.1, or it starts a new map in the game's default folder and the old one
looks lost. Nothing is deleted.

## 1.1.9 — launcher — 2026-09-13

**The server never started with the shipped settings.** The default server
name, `My Rust Server | Monthly | NA`, was typed straight into a
`set "ARGS=..."` line. The quotes around the name leave it outside the line's
own quotes, so cmd split the line at each `|`, tried to run a program called
`Monthly`, and stopped. The file's own comments said pipes were safe there.
Found on the first real run on Windows. The name, description, tags and player
count now have their own settings, `SERVER_HOSTNAME`, `SERVER_DESCRIPTION`,
`SERVER_TAGS` and `SERVER_MAXPLAYERS`, where `| & < >` are safe. `!` and `"`
still are not.

**Out of the box, the game's own defaults.** The launcher shipped with values
chosen for one server: a name and tags including a region (`NA`), 50 players,
seed 1234567, a 4000 map, five-minute saves and player reports in the console.
Now it sets only what has to agree with something outside the game (the ports,
which match the firewall). The name, description, tags and player count are
empty, which means the game's defaults. Seed, world size, save interval and
`printReportsToConsole` are left to the game.

**Oxide was never updated while the game stayed the same.** Since 1.1.7 the
framework comparison has printed its own code instead of running it: a missing
`;` made the statement that sets its exit code into text for `Write-Output`.
It always reported "unchanged", so a new Oxide release was skipped until the
next Rust update.

**"A newer build is available" appeared when this server was ahead.** Any
difference between the installed and public builds counted as behind. A
server on a newer build than public, as a test branch is, was told to update,
and with `UPDATE_ON_NEW_BUILD` it would have run steamcmd on every start. Only
a public build higher than the installed one counts now.

## 1.1.8 — launcher — 2026-09-13

**A vanilla server can now stay vanilla.** The launcher installed Oxide on
every update, and the only way to stop it was commenting out a block by hand.
`INSTALL_FRAMEWORK` in section 1 now decides: `1`, the default, behaves exactly
as before; `0` never downloads or extracts the framework, and an update counts
as complete once steamcmd is. `hotwire-setup` writes `0` when it installs a
server without Oxide.

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
None of this can decide not to start the server.

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
launch.

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
for users to remember.

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

`docs/GAME-API.md` lists what has been verified against a real build rather
than assumed.
