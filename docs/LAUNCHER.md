# The launcher — `launcher/hotwire.bat`

Starts a Rust dedicated server and relaunches it whenever it exits. Windows,
batch, no dependencies. It works on its own; the plugin is optional, and the
two meet at a flag file.

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

## Every behaviour is a setting

Section 1 holds every choice the launcher makes. The defaults are ours, and every one can be changed:

| setting | default | what it does |
|---|---|---|
| `ROOT` | `%~dp0` | the server's folder: by default the folder `hotwire.bat` is in |
| `STEAMCMD` | `C:\steamcmd\steamcmd.exe` | SteamCMD; several servers may share one |
| `STEAMCMD_WAIT_MINUTES` | `60` | how long to wait for another server's SteamCMD run before starting as-is |
| `STEAM_BRANCH` | `public` | the Steam branch; empty lets Steam choose, which keeps an install on whatever branch it was last on |
| `UPDATE_MODE` | `always` | `always` updates every start; `hotwire` for a flag file, a newer build or the backstop; `off` never |
| `UPDATE_FLAG`, `VALIDATE_FLAG` | `UPDATE.flag`, `VALIDATE.flag` | the flag file names, which must match the plugin's |
| `MAX_DAYS_WITHOUT_UPDATE` | `14` | `hotwire` mode's backstop; `0` turns it off |
| `UPDATE_ON_NEW_BUILD` | `1` | `hotwire` mode updates when Steam's build is ahead |
| `BUILD_CHECK_HOURS` | `6` | how long Steam's answer is cached; `0` turns the check off |
| `MAX_STEAM_TRIES` | `5` | steamcmd attempts before launching what is on disk |
| `STEAM_RETRY_SECONDS` | `60` | wait between those attempts |
| `INSTALL_FRAMEWORK` | `1` | `0` is a vanilla server |
| `SKIP_UNCHANGED_FRAMEWORK` | `1` | `0` re-extracts Oxide on every update |
| `FRAMEWORK_URL`, `FRAMEWORK_FEED`, `FRAMEWORK_VERSION_FILE` | uMod's | where Oxide comes from and how its version is read |
| `ROTATE_LOGS` | `1` | keep each run's log; `0` lets the server empty it each start |
| `LOG_KEEP` | `14` | rotated logs kept |
| `RESTART_ON_EXIT` | `1` | `0` stops the launcher when the server exits |
| `RESTART_DELAY` | `15` | seconds before relaunching |
| `CRASH_SECONDS` | `60` | a run shorter than this is a crash |
| `MAX_CRASH_STREAK` | `10` | crashes in a row before stopping; `0` never stops |
| `CRASH_BACKOFF` | `1` | wait 30, 60, 120, then 300 seconds after repeated crashes; `0` always waits `RESTART_DELAY` |
| `RCON_PASSWORD_MIN` | `8` | shortest RCON password it starts with; `0` is refused, because an empty one crashes Rust |
| `CHECK_OPTIONS` | `1` | `0` skips the section 4 check |
| `HOOK_BEFORE`, `HOOK_AFTER` | empty | commands to run around updates |

A value that cannot work stops the launcher at start with the line to fix, rather than failing somewhere
later: a non-number in `MAX_DAYS_WITHOUT_UPDATE`, `MAX_STEAM_TRIES`, `STEAM_RETRY_SECONDS`,
`STEAMCMD_WAIT_MINUTES`, `LOG_KEEP`, `RESTART_DELAY`, `CRASH_SECONDS`, `MAX_CRASH_STREAK` or
`RCON_PASSWORD_MIN`; an `UPDATE_MODE` other than `always`, `hotwire` or `off`; `LOG_KEEP=0`;
`MAX_STEAM_TRIES=0`; `RCON_PASSWORD_MIN=0`; an empty `ROOT` or flag name; or a `ROOT` that is another
folder with a `hotwire.bat` of its own (see *Several servers*). The `0`/`1` switches are not checked: anything
but `0` counts as on.

## Knowing whether you are behind

Every start prints where the install stands against Steam:

```
Rust build: installed 25129933, public 25129933 -- current.
```

The branch named there is `STEAM_BRANCH`. A server on a newer build than that branch is on another branch,
such as staging, and the next update moves it to `STEAM_BRANCH`.

If a newer build exists you get a banner instead, saying so and reminding you
that clients update themselves — so the server will eventually stop accepting
connections whether or not you act.

That costs one steamcmd launch, cached for `BUILD_CHECK_HOURS` (6), so a daily
restart pays for it once a day and a crash loop never pays at all. Set it to
`0` to turn the whole thing off. If another server is using SteamCMD at that
moment, the question is skipped for that start rather than waited for.

`UPDATE_ON_NEW_BUILD` uses that number: in `hotwire` mode, update when the build has actually changed
rather than waiting for `MAX_DAYS_WITHOUT_UPDATE`. The calendar rule stays as a fallback for when Steam
cannot be reached.

Two more settings govern the framework on an update:

- **`INSTALL_FRAMEWORK`** — `1` (the default) installs Oxide with the server and
  puts it back after every update. `0` is a vanilla server: the framework is
  never downloaded or extracted, and an update is complete once steamcmd is.
- **`SKIP_UNCHANGED_FRAMEWORK`** — do not re-extract the framework when
  neither it nor the game has changed. Writing it over a working install is
  the riskiest thing this file does, and doing it for no reason is pure risk.
  `FRAMEWORK_VERSION_FILE` says where to read the installed version and
  `FRAMEWORK_FEED` where to read the published one.

If any of it fails — no steamcmd, no network, a hang, an unreadable manifest —
the launcher reports that and carries on under the ordinary rules. None of it
can stop a server starting.

## Update modes

`UPDATE_MODE` decides whether a restart is also an update.

**`always`** is the default and behaves like every other Rust launcher: it
updates on every start. That is the right policy while you are the one
deciding when the server restarts.

**`hotwire`** separates the two. A restart is only a restart, and an update happens when a flag file is
present in the server folder, when Steam has a newer build (`UPDATE_ON_NEW_BUILD`), or when the backstop
fires. The flag files are named by `UPDATE_FLAG` and `VALIDATE_FLAG`:

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

That mode is opt-in because Rust clients update themselves: a server that
never updates does not go stale, it becomes unjoinable, and it usually happens
on force wipe day. So the default is the safe, slow behavior and the sharp
behavior is a deliberate choice.

**`hotwire` mode carries a backstop.** If `MAX_DAYS_WITHOUT_UPDATE` (14) full
days pass with no *successful* update, one happens anyway and says so loudly
in the console. Fourteen days never fires on a monthly cycle that is working,
and it turns "my server is dead and I do not know why" into a line of log. A missing stamp file
counts as forever, so a fresh install updates on its first start rather than
waiting a fortnight to discover it is out of date. Set it to `0` to disable.

**`off`** never updates: not on start, not for a flag file, not for the backstop or a new build. A flag file
is left where it is and the console says so. It is for a server whose files are managed some other way.

## Several servers on one machine

A production and a dev server side by side, often on different branches, is normal. What each needs:

- **Its own folder, with its own `hotwire.bat` and `secrets.bat`.** `ROOT` defaults to the launcher's own
  folder, so a copied server folder runs *its* server, not the original's. A launcher whose `ROOT` names a
  different folder that has its own `hotwire.bat` refuses to start, because starting it would update and
  run that other server.
- **Its own ports**, in section 4.2 (`server.port`, `server.queryport`, `rcon.port`). Two servers on one
  port crash-loop, and the crash-loop stop says so. `hotwire-setup` suggests a free set for each server.
- **Its own `STEAM_BRANCH`**, if they differ.

They may share one SteamCMD. Only one server runs it at a time: each run holds `hotwire-steamcmd.lock` beside
`steamcmd.exe`, opened unshared, and `hotwire-setup` takes the same lock. Another server waits, and says
so, for up to `STEAMCMD_WAIT_MINUTES`, then gives up on updating this start and runs the server as it is.
Windows releases the lock when the process holding it ends, however it ends, so a crash cannot leave it
stuck. Whether SteamCMD itself is safe to run twice at once is undocumented by Valve; taking turns avoids
the question.

## One option, one line

Every option is one independent line:

```bat
REM   server.saveinterval -- Seconds between world saves.
REM   [int, default 600]
set "ARGS=!ARGS! +server.saveinterval 300"
```

Put `REM` in front to disable it; take it away to enable it. You cannot break
the file by turning one option off, because nothing depends on the line above
it.

**Every default in it is real.** The option list is curated by hand, but the
names and defaults beside each one were read out of a Rust build rather than
copied from a guide, and they are re-checked against a new build after every
Rust update. A comment claiming a default that has quietly moved is worse than
no comment, because someone will believe it.

**Out of the box it sets only what it must.** That is the ports, because they have to match the
firewall, and what the server cannot run without: `-batchmode -nographics`, `server.level`, the RCON
password and `rcon.web`. Everything else — world size, save interval, player count, the save folder — is
the game's own default until you choose otherwise.

**The seed is the exception, and why.** Rust's own default seed is **1337** (read from the build), so a
server left to the default plays the same map as every other one. `SERVER_SEED` in section 4.1 sets it;
empty means the game's 1337. `hotwire-setup` writes a random one there when it builds a new server — once,
so every restart keeps the same map — and leaves it empty for a server that already has a save, because a
new seed on a played server starts a new map. Change it only before the first start, or as a deliberate
wipe. `server.randomize_seed` is not used: it picks a new seed on every start, which on a restart means a
new map.

**The server's name, description, tags and player count have their own settings**, filled in rather than
switched on with `REM`: `SERVER_HOSTNAME` and `SERVER_DESCRIPTION` in section 4.3, `SERVER_TAGS` beside
them, `SERVER_MAXPLAYERS` in 4.2. Left empty, the game's default is used. They are separate because a
`|`, `&`, `<` or `>` typed straight into a `set "ARGS=..."` line splits the line and the server never
starts; in those settings they are safe. `!` and `"` are not safe anywhere, a percent sign is written
`%%`, and a web address containing `&` needs `^&` in its `ARGS` line.

That checking is maintenance work, not yours: nothing here needs Python, and
the launcher never asks you to run anything. See `tools/` if you are curious
how it is done.

## Requirements

Windows, a Rust dedicated server, and steamcmd. PowerShell and curl, both of which ship with Windows 10
and later, are used for dates, downloads, the SteamCMD lock and the checks.

## Setup

`hotwire-setup` does all of this for you; see `setup/README.md`. By hand:

1. Copy `launcher/hotwire.bat` and `launcher/secrets.example.bat` into your server's folder, beside
   `RustDedicated.exe`.
2. Rename `secrets.example.bat` to `secrets.bat` and put your RCON password in it. **Change it from the
   example** — RCON is remote code execution on that machine. The launcher refuses a password that is
   empty, shorter than `RCON_PASSWORD_MIN` (8), still the example value, or has a double quote in it, and
   one that starts with a semicolon does not survive being read. Write a percent sign as `%%`.
3. Open `hotwire.bat`. Check `STEAMCMD` at the top; `ROOT` is already the file's own folder. Fill in
   `SERVER_HOSTNAME` and `SERVER_DESCRIPTION`, then work down the other options.
4. Run `hotwire.bat check`, then run `hotwire.bat`.

To have the plugin drive the updates, set `UPDATE_MODE=hotwire` once the
plugin is installed and you have a schedule you trust.

## Generating the option reference for your own build

Optional, and only if you want the full convar list rather than the curated
one:

```
python -m venv venv
venv\Scripts\pip install dnfile
venv\Scripts\python tools\convars.py "<server>\RustDedicated_Data\Managed\Assembly-CSharp.dll" --bat
```

## Checking it before you run it

```
hotwire.bat check
```

Reads back everything you set, says what is wrong, and exits without updating or starting the server. It
does ask Steam for the current build, and it does not run `HOOK_BEFORE`. Run it after editing section 4.

The same checks run on every start, and refuse to launch if they fail. They
exist because Rust ignores a convar it does not recognize and accepts an empty
value for one it does — both in silence.

**The settings in section 1** are checked for the mistakes listed under *Every behaviour is a setting*. A
trailing backslash on `ROOT` or `STEAMCMD` is removed rather than reported — it would otherwise escape the
closing quote of every path handed to another program.

**The option list** is tokenized and checked, unless `CHECK_OPTIONS=0`, for:

- a convar with no value, or followed immediately by the next convar
- an empty value — this is the one that took a server down for an afternoon
- a value that is still an unexpanded `%VAR%` or `!VAR!`
- the same convar set twice, where whichever line is last silently wins
- a name with no dot in it, which Rust would ignore without a word
- an unbalanced quote anywhere in the list
- a port that is not a number, is outside 1-65535, or collides with another port in this list
- a `server.identity` that cannot be a folder name

If the check cannot run — no PowerShell, or an error inside it — the launcher
says so and starts anyway. Only "the check ran and found problems" refuses to
launch. Losing a diagnostic must not cost a working server, and that includes
the case where the diagnostic itself is the thing that is broken. `check` says which of those happened
rather than reporting "no problems" for a check that did not run.

## When the server will not start

A run shorter than `CRASH_SECONDS` (60) did not start — a Rust server takes
minutes to boot, so a run measured in seconds means a bad convar, a port
already in use, or a corrupt save. The launcher counts consecutive short runs
and treats them differently from restarts:

- **The first crash of a streak keeps its log.** It rotates to
  `logs/server_crash_<stamp>.txt`, which the `LOG_KEEP` cull never matches.
  Later crashes in the same streak rotate normally, since they say the same
  thing and keeping every one is how a crash loop fills a disk.
- **The delay backs off** — `RESTART_DELAY` (15s), then 30, 60, 120 and 300 with `CRASH_BACKOFF=1` — so a
  permanently broken config does not relaunch four times a minute, and does not run `HOOK_BEFORE` that
  often either.
- **After `MAX_CRASH_STREAK` (10) it stops**, prints why, names the crash log
  and waits. Set it to `0` to loop forever instead. On a machine with more than one server, the message
  points at the likeliest cause: two servers on the same port.

A successful run resets the streak. If the timestamp call it uses ever fails,
the run is treated as a long one — that keeps the server running, where the
other direction would stop it over a failed clock read.

Note that the stop is a `pause`: it holds the window open so the message is
readable. Under a scheduled task with no console that means it waits rather
than exits, which is the correct state — stopped and visible — but is worth
knowing before you wrap this in a service.

## What it does not do

Diagnose the crash for you; it only keeps the log that explains it. Start the server when Windows starts.
Run on Linux; it is batch, and a shell port does not exist yet.
