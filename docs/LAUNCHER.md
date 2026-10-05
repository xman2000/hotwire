# The launcher

The launcher starts the Rust server and relaunches it whenever it exits. It updates the server only when the plugin's schedule, a newer Steam build or a backstop says so, and it carries out the wipes the plugin schedules. It works without the plugin.

| Platform | File | Runs under |
| --- | --- | --- |
| Windows | `hotwire.bat` and `hotwire.ps1` | cmd, with PowerShell and curl, which ship with Windows 10 and later |
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
| `hotwire.forced_wipe_steam_minutes` | `15` | Launchers 1.1.20 (Windows) and 1.1.6-linux or later: when a forced wipe waits on the update, keep trying SteamCMD this long before starting what is on disk. `0` = only `hotwire.steam_tries` |
| `hotwire.steam_branch` | `public` | The Steam branch. Empty lets Steam keep the install on its current branch. |
| `hotwire.max_days_without_update` | `14` | `hotwire` mode's backstop. `0` turns it off. |
| `hotwire.update_on_new_build` | `1` | `hotwire` mode updates when Steam's build is ahead |
| `hotwire.fast_rust_updates` | `0` | Launchers 1.1.19 and 1.1.7-linux. `1` = a Rust update on a server with Oxide finishes in one try. See [Fast Rust updates](#fast-rust-updates). |
| `hotwire.recover_refused_update` | `1` | Launchers 1.1.19 and 1.1.7-linux. When Steam no longer serves the installed build's file list, update without it. See [A refused update](#a-refused-update). `0` = start the installed build. |
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

### Fast Rust updates

Requires launcher 1.1.19 (Windows) or 1.1.7-linux. Off by default: `hotwire.fast_rust_updates 1` turns it on.

SteamCMD updates Rust by patching the game files on disk. Oxide replaces 11 of them, so on a server with Oxide the
first SteamCMD run for a new Rust build stops with "Corrupt game files" (state `0x486`). SteamCMD then records the
install as Files Corrupt, and its next run checks every file, downloads the ones that differ and finishes the update.

| Step | What the launcher does |
| --- | --- |
| Before an update to a newer Rust build, with Oxide installed | Records the install as Files Corrupt itself, so SteamCMD checks every file and finishes in one run |
| Where | `steamapps/appmanifest_258550.acf`, the line `"StateFlags" "4"`, changed to `"132"` |
| A copy | `hotwire/appmanifest-before-update.acf`, the record as it was |
| When the record is not in the expected form | Nothing is changed and the console says so |
| After any SteamCMD run that left the install marked Files Corrupt | The next attempt starts at once, once per update, instead of after `hotwire.steam_retry_seconds` |
| `hotwire.fast_rust_updates 0` (the default) | The record is not changed. The quick retry still applies. |

The record is Steam's own file, and Valve does not document it. If Steam stops reading the mark, updates go back to
taking two runs.

Either way, an update on a server with Oxide replaces every game file that differs from Steam's copy, including files
you changed by hand. Oxide is put back after the update. Files that are not part of Steam's install, such as saves and
Oxide's plugins and configs, are not touched: Valve's SteamCMD documentation says "Any files that are not part of the
default installation will not be affected."

### A refused update

Requires launcher 1.1.19 (Windows) or 1.1.7-linux.

To update, SteamCMD needs the file list of the Rust build installed. It keeps these lists in a cache shared by every
server that uses the same SteamCMD, and asks Steam only for one it does not have. Steam does not serve an old Rust
build's list. So once the cache has lost it, for example after another server on the machine updated, every SteamCMD
run stops with "Access Denied" and "No connection", and the server would start on the old build.

| Step | What the launcher does |
| --- | --- |
| After a failed SteamCMD run | Reads what that run added to SteamCMD's own log (`content_log.txt`) |
| When Steam refused a file list of the build installed | Moves `steamapps/appmanifest_258550.acf` to `hotwire/appmanifest-refused.acf` and runs the update again at once, once per update |
| The update that follows | SteamCMD checks the files on disk against the new build and downloads what differs |
| When it finishes | Steam writes a new record. The old one stays in `hotwire/`. |
| When it fails and Steam left no record it can use | The old record is put back |
| `hotwire.recover_refused_update 0` | Nothing is moved, and the server starts on the installed build after the usual tries |

Measured on one Linux server: about 0.8 GB downloaded, 133 seconds.

| Console line | Meaning |
| --- | --- |
| `Fast Rust updates: Steam will check every game file before this update, so it finishes in one try.` | The mark is written |
| `Fast Rust updates: Steam's install record is not in the expected form; leaving it to Steam.` | Nothing is changed |
| `Fast Rust updates: Steam's install record could not be changed; leaving it to Steam.` | Nothing is changed |
| `Steam marked the game files for a full check; trying again now.` | The quick retry |
| `Steam no longer serves the installed Rust build's file list, so this update cannot patch it.` | A refused update was found |
| `The update finished without the old file list.` | The recovery worked |
| `The update did not finish. Steam's install record is put back as it was.` | The recovery failed, and the server starts on the installed build |

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
| A forced wipe waiting on the update | SteamCMD is tried for up to `hotwire.forced_wipe_steam_minutes` (15) before the server starts on what is on disk |
| A forced wipe (`forced 1` and the build the plugin armed on) | Applied only if the update changed the installed build. Otherwise the flag stays, the old map starts, and `WIPE.result` says `deferred`, so the plugin tries again. |
| The before-wipe backup | Taken only once the build is known to have changed, not on every try |
| Which launchers wipe | One that lists `wipe` among its capabilities. A changed launcher still wipes; AFKPanel shows that it is not the released file. |

## Backups

The plugin decides when a backup runs and, right after Rust's save, copies what only the game can copy safely. The
launcher does the rest, at the lowest priority. Requires launcher 1.1.20 on Windows or 1.1.0-linux.

| Step | What the launcher does |
| --- | --- |
| While the server runs | Adds the save, checked unchanged while it is copied, the plugins and the map, then archives the backup |
| Between runs | Backs up the stopped server before an update or a wipe, when the settings ask for it |
| The archive | `backup/<save folder name>/<UTC time>-<why>`: `.tar.zst` on Linux, `.zip` on Windows. A `MANIFEST` inside lists every file's SHA-256. Before the archive is kept it is checked: on Linux `zstd` tests the whole archive; on Windows every file is read back and compared with the `MANIFEST`. |
| Free space | A backup that would leave less than the plugin's floor free on that drive (5 GB unless changed) is refused and says so |
| Keeping | The plugin's rotation: recent, daily, weekly, monthly and before-wipe backups, then the size cap |
| The record | `backup.log` beside the archives, and a result Hotwire reports to AFKPanel |

`hotwire-secrets.cfg` and `oxide/data/Hotwire`, which hold this server's secrets, are never in a backup.

## Reports to AFKPanel

Once the server is connected, the launcher reports what only it knows, signed with its own key from `hotwire/keys.json`.
Requires launcher 1.1.20 on Windows; every Linux launcher that reads `hotwire.cfg` does it.

| Report | Sent |
| --- | --- |
| How a run ended: when, the exit code, whether it was a crash, and what its update did | After every run |
| The launcher stopped after a crash streak, and the crash log it kept | When it stops |

| Rule | Value |
| --- | --- |
| When it is sent | In the background. The server never waits for it. |
| No answer, or AFKPanel busy | The report waits in `hotwire/launcher-spool` and is sent at a later start, for up to 7 days |
| Refused for another reason | Dropped, because the same report would be refused again |
| Connected to another panel or as another server | What was held for the old connection is dropped |

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

## Update the launcher

On Windows, replace the launcher only while it is stopped: cmd reads `hotwire.bat` while it runs, and a file replaced under it runs part of each version.

1. Close the launcher's window. The server stops with it.
2. Replace `hotwire.bat` and `hotwire.ps1` with the two files from one release.
3. Run `hotwire.bat check`, then `hotwire.bat`.

Launcher 1.1.22 and later keep the PowerShell in `hotwire.ps1`: some antivirus software blocks PowerShell that a script reads out of itself and runs. The launcher refuses to start when `hotwire.ps1` is missing or from another release, and says which. The code hash covers both files.

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
