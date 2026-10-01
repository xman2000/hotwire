# The launcher

The launcher starts the Rust server and relaunches it whenever it exits. It updates the server only when the plugin's schedule, a newer Steam build or a backstop says so, and it carries out the wipes the plugin schedules. It works without the plugin.

| Platform | File | Runs under |
| --- | --- | --- |
| Windows | `hotwire.bat` | cmd, with PowerShell and curl, which ship with Windows 10 and later |
| Linux | `hotwire.sh` | bash, on Ubuntu 22.04 or later |

The launcher's own folder is the server folder: the one that holds `RustDedicated` and `oxide/`. A copied server folder runs its own server, never the original's.

## Settings

Every setting is in `hotwire.cfg`, beside the launcher; the launcher holds none. Rust's convars go by their own names (`server.hostname "My Server"`), the launcher's under `hotwire.`, and the RCON password is in `hotwire-secrets.cfg`. See [hotwire.cfg](HOTWIRE-CFG.md) and [The RCON password file](RCON-PASSWORD.md).

| Rule | Value |
| --- | --- |
| The file | Data. It is read one line at a time and never run, so no character in a value can become a command. |
| Read | Before every start, so an edit takes effect at the next restart |
| A line that is not a setting | Ignored, and named by `check` |
| A value that fails its check | The default is used, except for the five below |
| Never defaulted | `server.identity`, `server.seed`, `server.worldsize`, `server.levelurl` and the ports: a bad one stops the first start and names the line. One that goes bad while the server runs keeps the last good value at the next restart, and says so. |
| Values | Reach Rust as separate arguments, so a name can hold `& \| < > % !` and anything but a double quote |

The launcher's settings, and the default when `hotwire.cfg` leaves one out:

| Setting | Default | Meaning |
| --- | --- | --- |
| `hotwire.update_mode` | `auto` | See Update modes |
| `hotwire.steamcmd` | Windows `C:\steamcmd\steamcmd.exe`; Linux `/usr/games/steamcmd` | SteamCMD. Several servers may share one. |
| `hotwire.steamcmd_wait_minutes` | `60` | How long to wait for another server's SteamCMD run before starting as is |
| `hotwire.steam_branch` | `public` | The Steam branch. Empty lets Steam keep the install on its current branch. |
| `hotwire.max_days_without_update` | `14` | `hotwire` mode's backstop. `0` turns it off. |
| `hotwire.update_on_new_build` | `1` | `hotwire` mode updates when Steam's build is ahead |
| `hotwire.build_check_hours` | `6` | How long Steam's answer is cached. `0` turns the check off. |
| `hotwire.steam_tries` | `5` | SteamCMD attempts before starting what is on disk |
| `hotwire.steam_retry_seconds` | `60` | Wait between those attempts |
| `hotwire.install_framework` | `1` | `0` is a vanilla server: Oxide is never downloaded |
| `hotwire.skip_unchanged_framework` | `1` | `0` re-extracts Oxide on every update |
| `hotwire.verify_framework` | `1` | Check Oxide against the SHA-256 GitHub publishes before extracting it |
| `hotwire.rotate_logs` | `1` | Keep each run's log. `0` lets the server empty it each start. |
| `hotwire.log_keep` | `14` | Rotated logs kept |
| `hotwire.restart_on_exit` | `1` | `0` stops the launcher when the server exits |
| `hotwire.restart_delay` | `15` | Seconds before relaunching |
| `hotwire.crash_seconds` | `60` | A run shorter than this is a crash |
| `hotwire.max_crash_streak` | `10` | Crashes in a row before stopping. `0` never stops. |
| `hotwire.crash_backoff` | `1` | Wait 30, 60, 120, then 300 seconds after repeated crashes. `0` always waits `hotwire.restart_delay`. |
| `hotwire.rcon_password_min` | `8` | The shortest RCON password it starts with |
| `hotwire.check_options` | `1` | `0` skips the warning about convar names it does not know |
| `hotwire.backups` | `1` | Carry out the backups the plugin asks for. `0` never backs up here. |

Fixed in the launcher, never settings: where Oxide is downloaded from and checked against, Rust's Steam app id, the flag file names (`UPDATE.flag`, `VALIDATE.flag`, `WIPE.flag`), and the server folder. `hotwire.cfg` is data that other tools may write, and data never says what gets downloaded or run.

## Update modes

`hotwire.update_mode` decides whether a start is also an update.

| Mode | Updates |
| --- | --- |
| `auto` | As `hotwire` while the plugin has an update scheduled, as `always` otherwise. The plugin keeps `UPDATE.schedule` in the server folder while an update entry or its framework check is on, rewritten every 15 minutes; a file that is missing or over 2 hours old counts as no schedule. |
| `always` | On every start |
| `hotwire` | When a flag file is present, when Steam has a newer build (`hotwire.update_on_new_build`), when the launcher cannot find out whether it has, or when the backstop fires |
| `off` | Never. A flag file is left in place and the console says so. |

| Flag in the server folder | The next start |
| --- | --- |
| `UPDATE.flag` | `steamcmd app_update`, then Oxide, then the start |
| `VALIDATE.flag` | The same with `validate`, which checks every game file |
| Neither | The start, unless a newer build or the backstop says otherwise |

| Rule | Value |
| --- | --- |
| A flag is deleted | Once the update has completed. If SteamCMD or the Oxide download fails, the flag stays and the next start tries again. |
| Who may write a flag | Anyone: you, a scheduled task, or the plugin |
| The build check | Every start prints the installed and public builds, from one SteamCMD call cached for `hotwire.build_check_hours`. In `hotwire` mode the cached answer is used only during a crash streak. |
| Doubt | Resolves toward updating: a Rust server that does not update becomes unjoinable, because clients update themselves |
| The backstop | After `hotwire.max_days_without_update` without a successful update, one happens and the console says so. A missing stamp counts as forever, so a fresh install updates on its first start. |
| Oxide | Installed with the server and put back after every update, unless `hotwire.install_framework` is `0`. With `hotwire.skip_unchanged_framework` it is not re-extracted when neither changed: the game's build is the one from before the update, and Oxide's version is the newest release on GitHub, the file that is downloaded and checked. An update that changed the build, or a validate, always puts Oxide back. |
| A failure in any of it | Reported, and the server starts under the ordinary rules |

## Wipes

A wipe comes from the plugin as `WIPE.flag`, one `key value` per line: the new seed, a size if it changes, what to do with blueprints, a cycle id and an expiry. Between runs the launcher:

1. Checks every value: a number where a number belongs, one of the allowed words for blueprints.
2. Writes `server.seed` (and `server.worldsize`) into `hotwire.cfg`.
3. Renames or deletes the `player.blueprints.*.db` files as asked. `player.tokens.db`, the Rust+ pairings, is never touched.
4. Records the cycle id, so the same wipe can never run twice.
5. Clears the flag and starts the server. The old save stays on disk.

| Rule | Value |
| --- | --- |
| The seed cannot be written | The wipe is cancelled and the server starts unchanged |
| An expired flag, or a cycle already recorded | Ignored |
| The outcome | Written to `WIPE.result` for the plugin to read |
| A forced wipe (`forced 1` and the build the plugin armed on) | Applied only if the update changed the installed build. Otherwise the flag stays, the old map starts, and `WIPE.result` says `deferred`, so the plugin tries again. |
| The before-wipe backup (Linux) | Taken only once the build is known to have changed, not on every try |
| A modified launcher | The plugin checks the launcher's code hash before it writes a flag, and offers no wipe for a modified one |

## Several servers on one machine

| Each server needs | |
| --- | --- |
| Its own folder | With its own launcher, `hotwire.cfg` and `hotwire-secrets.cfg` |
| Its own ports | `server.port`, `server.queryport` and `rcon.port` in its `hotwire.cfg`. Two servers on one port crash-loop, and the crash-loop stop says so. `hotwire-setup` suggests a free set. |
| Its own `hotwire.steam_branch` | If they differ |

They may share one SteamCMD. One server runs it at a time: each run holds a lock (`hotwire-steamcmd.lock` beside `steamcmd.exe` on Windows; `~/.hotwire/steamcmd.lock` on Linux), and `hotwire-setup` takes the same lock. Another server waits, and says so, for up to `hotwire.steamcmd_wait_minutes`, then starts as it is. The lock is released when the process holding it ends, however it ends.

## The list in hotwire.example.cfg

Every setting is one line. A setting that is off starts with `#` and shows the game's default:

```
#  Seconds between world saves. [int, default 600]
#server.saveinterval         600
```

| Rule | Value |
| --- | --- |
| To use a setting | Remove the `#` and change the value |
| Turning a setting off | Breaks nothing; no line depends on another |
| A convar not in the list | Goes at the end, under OTHER CONVARS, by its own name. The launcher warns about a name it does not know, and passes it on. |
| The defaults shown | Read out of a Rust build and re-checked after every Rust update |
| Set out of the box | Only the ports and what the server cannot run without: `-batchmode -nographics`, `server.level`, the RCON password and `rcon.web`. Everything else is the game's default until you change it. |
| `server.seed` | Rust's own default is 1337, so a server left to it plays the same map as every other. `hotwire-setup` writes a random seed when it builds a new server, once; for a server that already has a save it leaves the seed alone, because a new seed starts a new map. `server.randomize_seed` is not used. |

## Set it up

`hotwire-setup` does this for you: see [INSTALL-WINDOWS.md](INSTALL-WINDOWS.md), [INSTALL-LINUX.md](INSTALL-LINUX.md) and, for a server you already run, [SWITCH-TO-HOTWIRE.md](SWITCH-TO-HOTWIRE.md). By hand:

1. Copy the launcher, `hotwire.example.cfg` and `hotwire-secrets.example.cfg` into the server folder.
2. Copy `hotwire-secrets.example.cfg` to `hotwire-secrets.cfg` and put your RCON password in it, in double quotes. The launcher refuses a password that is empty, shorter than `hotwire.rcon_password_min`, or still the example.
3. Copy `hotwire.example.cfg` to `hotwire.cfg`. Set `server.hostname` and `server.description` at the top, check the ports, then go through the list.
4. Run the check, then the launcher:

   | Platform | Check | Start |
   | --- | --- | --- |
   | Windows | `hotwire.bat check` | `hotwire.bat` |
   | Linux | `./hotwire.sh check` | `./hotwire.sh` |

Your own commands, such as a backup before every start, go in `hotwire-before` (before every start) and `hotwire-after` (after an update), beside the launcher. See [Run your own commands](HOOKS.md).

## Check

`check` reads `hotwire.cfg` and `hotwire-secrets.cfg`, names every line it did not use and why, asks Steam for the current build, and exits without updating or starting the server. It runs neither hook. Run it after editing a setting. See [Check your settings](CHECK.md).

## When the server will not start

A run shorter than `hotwire.crash_seconds` is a crash: a Rust server takes minutes to start, so a run of seconds means a bad convar, a port in use, or a corrupt save.

| Crash | The launcher |
| --- | --- |
| The first of a streak | Keeps its log as `logs/server_crash_<stamp>.txt`, which log rotation never removes |
| Each one after | Waits longer: `hotwire.restart_delay`, then 30, 60, 120 and 300 seconds, with `hotwire.crash_backoff` on |
| `hotwire.max_crash_streak` in a row | Stops, prints why, names the crash log. On Windows it holds the window open; under a scheduled task with no console it waits rather than exits. On a machine with more than one server, the message points at two servers on one port. |
| A successful run | Resets the streak |

## What it does not do

| Not done | Note |
| --- | --- |
| Diagnose a crash | It keeps the log that explains it |
| Start when the machine starts | On Windows, use a scheduled task; on Linux, `hotwire-setup` creates a `rust-server` service |
