# hotwire.cfg

`hotwire.cfg` holds every setting for your server and for Hotwire's launcher. It sits beside the launcher:
`hotwire.bat` and `hotwire.ps1` on Windows, `hotwire.sh` on Linux. The RCON password is not in it: see [The RCON password file](https://afkpanel.com/docs/rcon-password).

## Get the file

| You have | Do this |
| --- | --- |
| A server you already run | Convert your start script at https://afkpanel.com/get-started |
| A new server | Copy `hotwire.example.cfg`, from the Hotwire download, to `hotwire.cfg` |

## The format

One setting per line: a name, a space, then the value.

```
server.hostname      "My Server | Weekly wipes"
server.maxplayers    100
#server.tickrate     10
```

| Rule | Detail |
| --- | --- |
| A value with spaces | In double quotes |
| A double quote inside a value | Not allowed |
| A comment | A line that starts with `#` |
| A setting that is off | `#` before its name. The game's default is used. |
| An empty value, `""` | The game's default is used |
| Longest value | 1024 characters |
| Characters such as `& % ! \| < >` | Allowed as they are. The file is read as data, never run. |

A line that breaks a rule is ignored, and `check` names it. See [Check your settings](https://afkpanel.com/docs/check-your-settings).

## When a change takes effect

The launcher reads `hotwire.cfg` again before every start, so an edit takes effect at the next restart. There is no
need to restart the launcher.

If an edit makes the file unusable while the launcher runs, the launcher says so and starts the server with the
settings from its last start.

## Sections

| Section | What it holds |
| --- | --- |
| 1. Your server | Name, description, tags, player slots, save folder, map |
| 2. Ports | `server.port`, `server.queryport`, `rcon.port` |
| 3. Updates | `hotwire.update_mode` |
| 4. More server settings | Rust's other settings, each off, with its default |
| 5. Launcher settings | How the launcher behaves |
| Other convars | Settings you add that are not in the list above |

Each setting has a comment above it that says what it does and gives its default.

## Settings the launcher checks

A value that fails its check is ignored and the default is used. For the settings marked **Stops the start**, a bad
value stops the launcher instead, because the default would open a different save or map.

| Setting | Rule | Stops the start |
| --- | --- | --- |
| `server.identity` | Letters, digits, `_` and `-`, up to 64 characters | Yes |
| `server.seed` | A whole number from 0 to 2147483647 | Yes |
| `server.worldsize` | A whole number from 1000 to 6000 | Yes |
| `server.port` | A port number from 1 to 65535 | Yes |
| `server.queryport` | A port number from 1 to 65535 | Yes |
| `rcon.port` | A port number from 1 to 65535 | Yes |
| `server.levelurl` | An `http://` or `https://` address | Yes |
| `server.tags` | Tags separated by commas, with no spaces | No |
| `server.maxplayers` | A whole number | No |
| `rcon.web` | 0 or 1 | No |

`rcon.password` in `hotwire.cfg` is ignored. It belongs in `hotwire-secrets.cfg`.

## Update modes

Set with `hotwire.update_mode`.

| Mode | Rust and Oxide update |
| --- | --- |
| `auto` | The default. On every start, until an update schedule is on in the Hotwire plugin; then as `hotwire` |
| `always` | On every start |
| `hotwire` | When an `UPDATE.flag` or `VALIDATE.flag` file is in the server's folder, when Steam has a newer build, when the launcher cannot tell, or after `hotwire.max_days_without_update` days |
| `off` | Never |

To ask for one update in `hotwire` mode, create `UPDATE.flag` in the server's folder and restart the server. The flag
is deleted once the update succeeds.

## Launcher settings

Each is off in the file and shows the value used.

| Setting | Default | What it does |
| --- | --- | --- |
| `hotwire.steamcmd` on Windows | `C:\steamcmd\steamcmd.exe` | The SteamCMD program |
| `hotwire.steamcmd` on Linux | `/usr/games/steamcmd` | The SteamCMD program |
| `hotwire.steam_branch` | `public` | The Steam branch. Empty lets Steam keep the last one. |
| `hotwire.max_days_without_update` | 14 | `hotwire` mode: update after this many days without one. 0 = never. |
| `hotwire.update_on_new_build` | 1 | Update when Steam has a newer build |
| `hotwire.fast_rust_updates` | 0 | 1 = a Rust update on a server with Oxide finishes in one try (launchers 1.1.19, 1.1.7-linux) |
| `hotwire.recover_refused_update` | 1 | When Steam no longer serves the installed build's file list, update without it (launchers 1.1.19, 1.1.7-linux). 0 = start the installed build. |
| `hotwire.build_check_hours` | 6 | Hours to trust a Steam build check. 0 turns the check off. |
| `hotwire.steam_tries` | 5 | SteamCMD attempts before starting what is on disk |
| `hotwire.steam_retry_seconds` | 60 | Seconds between SteamCMD attempts |
| `hotwire.steamcmd_wait_minutes` | 60 | Minutes to wait for another server's SteamCMD run |
| `hotwire.forced_wipe_steam_minutes` | 15 | Launchers 1.1.25 (Windows) and 1.1.6-linux or later: when a forced wipe waits on the update, keep trying SteamCMD this many minutes. 0 = only `hotwire.steam_tries`. |
| `hotwire.install_framework` | 1 | Install and refresh Oxide with the server. 0 = never touch it. |
| `hotwire.skip_unchanged_framework` | 1 | Skip re-extracting Oxide when neither it nor the game changed |
| `hotwire.verify_framework` | 1 | Check Oxide against the SHA-256 GitHub publishes |
| `hotwire.restart_on_exit` | 1 | Start the server again when it exits. 0 = the launcher stops too. |
| `hotwire.restart_delay` | 15 | Seconds before starting again |
| `hotwire.crash_seconds` | 60 | A run shorter than this counts as a crash |
| `hotwire.max_crash_streak` | 10 | Crashes in a row before the launcher stops. 0 = never stop. |
| `hotwire.crash_backoff` | 1 | Wait 30, 60, 120, then 300 seconds after repeated crashes |
| `hotwire.rotate_logs` | 1 | Keep each run's log |
| `hotwire.log_keep` | 14 | How many logs to keep. Cannot be 0. |
| `hotwire.rcon_password_min` | 8 | Shortest RCON password allowed. Cannot be 0. |
| `hotwire.check_options` | 1 | Warn about a setting name the launcher does not know |
| `hotwire.backups` | 1 | Carry out the backups Hotwire asks for. 0 = never back up here. |

A `hotwire.` name that is not in this table is ignored, and `check` names it.

## The log

The launcher always writes the server's log to `logs/server_log.txt`. With `hotwire.rotate_logs 1`, each run's log is
kept beside it. The first log of a crash streak is kept as `logs/server_crash_<time>.txt`.
