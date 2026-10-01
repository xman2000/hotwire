# The launcher — `launcher/hotwire.bat` and `launcher/hotwire.sh`

Starts a Rust dedicated server and relaunches it whenever it exits: `hotwire.bat` on Windows, `hotwire.sh` on
Linux. Both read their settings from `hotwire.cfg`, beside them, and hold none themselves. They work on their own;
the plugin is optional, and the two meet at a flag file. This page describes the Windows launcher; the Linux one
follows the same rules.

## The problem it solves

Most Rust launchers are one long `^`-continued command that runs steamcmd,
re-downloads the mod framework, and starts the server — all of it, every time
the server exits.

That is fine when you restart occasionally. It stops being fine when you
restart daily to shed the memory a busy modded server accumulates:

- **A restart costs double.** On a 4250-size map with a heavy plugin load,
  bootstrap alone is ~2.5 minutes and the server is not really ready for
  another two. Add `steamcmd validate` and you have six to eight minutes of
  downtime for what should have been three.
- **Every restart becomes an unattended update.** Force-extracting whatever
  Oxide build is current, at 5am, over a working install. Twenty-nine days a
  month that is harmless. The day after a Rust update it is how a server comes
  back with half its plugins dead and nobody watching.
- **The file is frightening to edit.** Comment out one line in the middle of a
  `^`-continued command and you silently take the rest of the launch with it.

## Your settings are in hotwire.cfg

`hotwire.cfg` holds every setting, in the style of Rust's own `server.cfg`: a name, a space, then the value, in double
quotes when it has spaces. Rust's convars go by their own names (`server.hostname "My Server"`), the launcher's
under `hotwire.` (`hotwire.update_mode auto`), and the RCON password is in `hotwire-secrets.cfg`. Copy
`hotwire.example.cfg` to begin: it lists the settings people change, each off (`#`) with the game's default.

The file is data. It is read, one line at a time, and never run, so no character in a value can become a command,
and replacing `hotwire.bat` with a newer release changes nothing of yours. It is read again before every restart,
so an edit takes effect at the next one.

The launcher's own settings, and what each does when `hotwire.cfg` leaves it out:

| setting | default | what it does |
|---|---|---|
| `hotwire.update_mode` | `auto` | `auto` follows the plugin's update schedule, and updates every start without one; `always` updates every start; `hotwire` for a flag file, a newer build, an unknown build or the backstop; `off` never |
| `hotwire.steamcmd` | `C:\steamcmd\steamcmd.exe` | SteamCMD; several servers may share one |
| `hotwire.steamcmd_wait_minutes` | `60` | how long to wait for another server's SteamCMD run before starting as-is |
| `hotwire.steam_branch` | `public` | the Steam branch; empty lets Steam choose, which keeps an install on whatever branch it was last on |
| `hotwire.max_days_without_update` | `14` | `hotwire` mode's backstop; `0` turns it off |
| `hotwire.update_on_new_build` | `1` | `hotwire` mode updates when Steam's build is ahead |
| `hotwire.build_check_hours` | `6` | how long Steam's answer is cached; `0` turns the check off |
| `hotwire.steam_tries` | `5` | steamcmd attempts before launching what is on disk |
| `hotwire.steam_retry_seconds` | `60` | wait between those attempts |
| `hotwire.install_framework` | `1` | `0` is a vanilla server |
| `hotwire.skip_unchanged_framework` | `1` | `0` re-extracts Oxide on every update |
| `hotwire.verify_framework` | `1` | check Oxide against the SHA-256 GitHub publishes before extracting it |
| `hotwire.rotate_logs` | `1` | keep each run's log; `0` lets the server empty it each start |
| `hotwire.log_keep` | `14` | rotated logs kept |
| `hotwire.restart_on_exit` | `1` | `0` stops the launcher when the server exits |
| `hotwire.restart_delay` | `15` | seconds before relaunching |
| `hotwire.crash_seconds` | `60` | a run shorter than this is a crash |
| `hotwire.max_crash_streak` | `10` | crashes in a row before stopping; `0` never stops |
| `hotwire.crash_backoff` | `1` | wait 30, 60, 120, then 300 seconds after repeated crashes; `0` always waits `hotwire.restart_delay` |
| `hotwire.rcon_password_min` | `8` | shortest RCON password it starts with |
| `hotwire.check_options` | `1` | `0` skips the warning about convar names it does not know |

Fixed in the launcher, never settings: where Oxide is downloaded from and checked against, Rust's Steam app id,
the flag file names (`UPDATE.flag`, `VALIDATE.flag`, `WIPE.flag`), and the server's folder, which is always the
launcher's own. `hotwire.cfg` is data that other tools may write, and data must never be able to say what gets
downloaded or run.

**Every line is checked before it is used.** A line that is not a setting is ignored, and `hotwire.bat check`
names it. A value that fails its check (a word where a number belongs) falls back to the default. Five settings
are never defaulted, because the default would be a different server: the save folder (`server.identity`), the
map (`server.seed`, `server.worldsize`, `server.levelurl`) and the ports. A bad one stops the first start with the
line to fix. If one goes bad in an edit while the server is running, the next restart keeps the last good settings
and says so.

**Values reach Rust as separate arguments.** On Windows, PowerShell reads the file and starts the server with an
argument list it builds itself, so cmd never sees a value: a server name can hold `& | < > % !` and anything but a
double quote.

## Knowing whether you are behind

Every start prints where the install stands against Steam:

```
Rust build: installed 25129933, public 25129933 -- current.
```

The branch named there is `hotwire.steam_branch`. A server on a newer build than that branch is on another
branch, such as staging, and the next update moves it to `hotwire.steam_branch`.

If a newer build exists you get a banner instead, saying so and reminding you
that clients update themselves — so the server will eventually stop accepting
connections whether or not you act.

That costs one steamcmd launch, cached for `hotwire.build_check_hours` (6), so a daily
restart pays for it once a day and a crash loop never pays at all. Set it to
`0` to turn the whole thing off. If another server is using SteamCMD at that
moment, the question is skipped for that start rather than waited for.

`hotwire.update_on_new_build` uses that number: in `hotwire` mode, update when the build has actually changed
rather than waiting for `hotwire.max_days_without_update`. The calendar rule stays as a fallback for when Steam
cannot be reached.

Two more settings govern the framework on an update:

- **`hotwire.install_framework`** — `1` (the default) installs Oxide with the server and
  puts it back after every update. `0` is a vanilla server: the framework is
  never downloaded or extracted, and an update is complete once steamcmd is.
- **`hotwire.skip_unchanged_framework`** — do not re-extract the framework when
  neither it nor the game has changed. Writing it over a working install is
  the riskiest thing this file does, and doing it for no reason is pure risk.

If any of it fails — no steamcmd, no network, a hang, an unreadable manifest —
the launcher reports that and carries on under the ordinary rules. None of it
can stop a server starting.

## Update modes

`hotwire.update_mode` decides whether a restart is also an update.

**`auto`** is the default. It behaves as `hotwire` while the plugin has an update scheduled, and as `always`
otherwise. The plugin keeps `UPDATE.schedule` in the server folder while an update entry or its framework check
is on, and rewrites it every 15 minutes; a file that is missing or over two hours old counts as no schedule. So a
server with no schedule updates on every start, and turning a schedule on in the plugin is all it takes to hand
updates to it.

**`always`** behaves like every other Rust launcher: it updates on every start.

**`hotwire`** separates the two. A restart is only a restart, and an update happens when a flag file is
present in the server folder, when Steam has a newer build (`hotwire.update_on_new_build`), when the launcher cannot
find out whether Steam has one, or when the backstop fires. It asks Steam afresh on every start and uses its
cached answer only during a crash streak, because a cached "current" from before a Rust release would start the
old build. The flag files:

| File in the server folder | The next launch |
|---|---|
| `UPDATE.flag` | `steamcmd app_update`, then the framework, then launch |
| `VALIDATE.flag` | the same plus `validate`, which re-checksums everything |
| neither | straight to launch, unless a newer build or the backstop says otherwise |

The flag is deleted **once the update has actually completed**, so one flag
buys one update rather than one attempt. If steamcmd exhausts its retries, or
the framework download fails, the flag is kept and the backstop clock is not
reset — the console says so in a banner, and the next start tries again.
Anything can create a flag — you, a scheduled task, or the plugin:

```powershell
New-Item -ItemType File UPDATE.flag     # in the server's folder
```

Every doubt in that mode resolves toward updating, because Rust clients update themselves: a server that
never updates does not go stale, it becomes unjoinable, and it usually happens on force wipe day.

**`hotwire` mode carries a backstop.** If `hotwire.max_days_without_update` (14) full
days pass with no *successful* update, one happens anyway and says so loudly
in the console. Fourteen days never fires on a monthly cycle that is working,
and it turns "my server is dead and I do not know why" into a line of log. A missing stamp file
counts as forever, so a fresh install updates on its first start rather than
waiting a fortnight to discover it is out of date. Set it to `0` to disable.

**`off`** never updates: not on start, not for a flag file, not for the backstop or a new build. A flag file
is left where it is and the console says so. It is for a server whose files are managed some other way.

## Several servers on one machine

A production and a dev server side by side, often on different branches, is normal. What each needs:

- **Its own folder, with its own `hotwire.bat`, `hotwire.cfg` and `hotwire-secrets.cfg`.** The server's folder
  is the launcher's own, so a copied server folder runs *its* server, not the original's.
- **Its own ports**, in its `hotwire.cfg` (`server.port`, `server.queryport`, `rcon.port`). Two servers on one
  port crash-loop, and the crash-loop stop says so. `hotwire-setup` suggests a free set for each server.
- **Its own `hotwire.steam_branch`**, if they differ.

They may share one SteamCMD. Only one server runs it at a time: each run holds `hotwire-steamcmd.lock` beside
`steamcmd.exe`, opened unshared, and `hotwire-setup` takes the same lock. Another server waits, and says
so, for up to `hotwire.steamcmd_wait_minutes`, then gives up on updating this start and runs the server as it is.
Windows releases the lock when the process holding it ends, however it ends, so a crash cannot leave it
stuck. Whether SteamCMD itself is safe to run twice at once is undocumented by Valve; taking turns avoids
the question.

## The list in hotwire.example.cfg

Every setting is one independent line. A setting that is off starts with `#` and shows the game's default:

```
#  Seconds between world saves. [int, default 600]
#server.saveinterval         600
```

Take the `#` away and change the value to use it. You cannot break the file by turning one setting off, because
nothing depends on the line above it. A convar that is not in the list goes at the end, under OTHER CONVARS, by
its own name; the launcher warns about a name its list does not have, in case it is misspelled, and passes it on.

**Every default in it is real.** The list is curated by hand, but the names and defaults beside each one were read
out of a Rust build rather than copied from a guide, and they are re-checked against a new build after every Rust
update. A comment claiming a default that has quietly moved is worse than no comment, because someone will
believe it.

**Out of the box it sets only what it must.** That is the ports, because they have to match the firewall, and what
the server cannot run without: `-batchmode -nographics`, `server.level`, the RCON password and `rcon.web`.
Everything else — world size, save interval, player count, the save folder — is the game's own default until you
choose otherwise.

**The seed is the exception, and why.** Rust's own default seed is **1337** (read from the build), so a server left
to the default plays the same map as every other one. `server.seed` sets it; empty means the game's 1337.
`hotwire-setup` writes a random one when it builds a new server — once, so every restart keeps the same map — and
leaves it empty for a server that already has a save, because a new seed on a played server starts a new map.
Change it only before the first start, or as a deliberate wipe. `server.randomize_seed` is not used: it picks a new
seed on every start, which on a restart means a new map.

That checking is maintenance work, not yours: nothing here needs Python, and
the launcher never asks you to run anything. See `tools/` if you are curious
how it is done.

## Requirements

Windows, a Rust dedicated server, and steamcmd. PowerShell and curl, both of which ship with Windows 10
and later, are used for reading the settings, starting the server, dates, downloads, the SteamCMD lock and the
checks.

## Setup

`hotwire-setup` does all of this for you; see `setup/README.md`. For a server you already run, the start-script
converter at https://afkpanel.com/get-started makes `hotwire.cfg` from your old start script. By hand:

1. Copy `hotwire.bat`, `hotwire.example.cfg` and `hotwire-secrets.example.cfg` into your server's folder, beside
   `RustDedicated.exe`.
2. Copy `hotwire-secrets.example.cfg` to `hotwire-secrets.cfg` and put your RCON password in it, in double
   quotes. **Change it from the example** — RCON is remote code execution on that machine. The launcher refuses
   a password that is empty, shorter than `hotwire.rcon_password_min` (8), or still the example value.
3. Copy `hotwire.example.cfg` to `hotwire.cfg`. Fill in `server.hostname` and `server.description` at the top and
   check the ports, then go through the rest of the list.
4. Run `hotwire.bat check`, then run `hotwire.bat`.

Your own commands, such as a backup before every start, go in `hotwire-before.bat` (run before every start) and
`hotwire-after.bat` (run after an update), beside the launcher; copy the `.example` files. Each runs in a cmd of its
own, and one that fails is logged and the server starts anyway. `check` runs neither.

The plugin drives the updates with no change here: on `hotwire.update_mode auto`, turning on an update schedule in
the plugin is enough. While one is on, the plugin keeps `UPDATE.schedule` in the server's folder and rewrites it
every 15 minutes. The launcher follows the schedule while that file is under two hours old, and updates on every
start when it is missing or older, so a plugin that has stopped running cannot leave the server behind.

When the schedule decides, the launcher still updates on its own when Steam has a newer build, and when it cannot
find out whether Steam has one: it asks Steam afresh on every start, using its cached answer only during a crash
streak. Not knowing costs an update, never the server.

## Checking it before you run it

```
hotwire.bat check
```

Reads `hotwire.cfg` and `hotwire-secrets.cfg`, names every line it did not use and why, and exits without
updating or starting the server. It does ask Steam for the current build, and it runs neither hook. Run it after
editing any setting.

A start reads the same way. A line that fails is left out and the default used, except for the five settings above
that are never defaulted: a bad one stops the first start. A convar name that is not in the file's own list is
warned about, never refused: Rust ignores a name it does not know, and the list is not every convar Rust has.
`hotwire.check_options 0` turns that warning off.

## When the server will not start

A run shorter than `hotwire.crash_seconds` (60) did not start — a Rust server takes
minutes to boot, so a run measured in seconds means a bad convar, a port
already in use, or a corrupt save. The launcher counts consecutive short runs
and treats them differently from restarts:

- **The first crash of a streak keeps its log.** It rotates to
  `logs/server_crash_<stamp>.txt`, which the `hotwire.log_keep` cull never matches.
  Later crashes in the same streak rotate normally, since they say the same
  thing and keeping every one is how a crash loop fills a disk.
- **The delay backs off** — `hotwire.restart_delay` (15s), then 30, 60, 120 and 300 with `hotwire.crash_backoff 1`
  — so a permanently broken config does not relaunch four times a minute, and does not run `hotwire-before.bat`
  that often either.
- **After `hotwire.max_crash_streak` (10) it stops**, prints why, names the crash log
  and waits. Set it to `0` to loop forever instead. On a machine with more than one server, the message
  points at the likeliest cause: two servers on the same port.

A successful run resets the streak. If the timestamp call it uses ever fails,
the run is treated as a long one — that keeps the server running, where the
other direction would stop it over a failed clock read.

Note that the stop is a `pause`: it holds the window open so the message is
readable. Under a scheduled task with no console that means it waits rather
than exits, which is the correct state — stopped and visible — but is worth
knowing before you wrap this in a service.

## Wipes

A wipe comes from the plugin as `WIPE.flag`, one `key value` per line: the new seed, a size if it changes, what to do
with blueprints, a cycle id and an expiry. Between runs the launcher validates every value as a plain number or one of
the allowed words, writes `server.seed` (and `server.worldsize`) into `hotwire.cfg`, renames or deletes the
`player.blueprints.*.db` files as asked (never `player.tokens.db`, the Rust+ pairings), records the cycle id so the same
wipe can never run twice, and clears the flag. If the seed cannot be written, the wipe is cancelled and the server starts
unchanged: a half-wipe is worse than none. The outcome is written to `WIPE.result` for the plugin to read.

A **forced wipe** carries `forced 1` and the build that was installed when it was armed. After its update the launcher
compares the installed build with that one: changed, the wipe is applied; unchanged, the flag is left in place, the old
world starts, and `WIPE.result` says `deferred`, so the plugin tries again later. On Linux the before-wipe backup is
taken only once the build is known to have changed, not on every try. The launcher only applies a wipe when it is the
unmodified Hotwire launcher: the plugin checks its code hash before it writes the flag.

## What it does not do

Diagnose the crash for you; it only keeps the log that explains it. Start the server when Windows starts.
