# Hotwire

Hotwire schedules restarts, updates and wipes for a Rust dedicated server. It announces each one to players, counts down, kicks with a reason, saves and quits; a matching launcher brings the server back, updated or on a new map when the schedule says so. Windows and Linux. MIT.

| Term | Meaning in this document |
| --- | --- |
| Rust server | The game, `RustDedicated`, that players connect to |
| Machine | The computer the Rust server runs on |
| Server folder | The folder that holds `RustDedicated`, `oxide/` and the launcher |
| Hotwire | The plugin (`Hotwire.cs`) and the launcher (`hotwire.bat` or `hotwire.sh`) |
| AFKPanel | The web panel at https://afkpanel.com that a Hotwire server can report to |

## What it does

| Area | What |
| --- | --- |
| Restarts | On a schedule, with an announced countdown. A restart is only a restart. |
| Updates | A restart that also installs a new Rust build and the Oxide that matches it, carried out by the launcher |
| Wipes | A restart that also starts a new map, on a schedule or when Facepunch's monthly update arrives |
| Announcements | In chat under a name you choose, and as a status bar where AdvancedStatus is installed |
| In-game menu | Add, edit, enable, disable and delete entries without leaving the game |
| AFKPanel | Reports the server's state and carries out commands queued there. Optional. |

## Requirements

| Requirement | Value |
| --- | --- |
| Rust server | Any current build, with Oxide (uMod) |
| Machine | Windows 10 or later, or Ubuntu 22.04 or later |
| Updates and wipes | The Hotwire launcher. The plugin alone restarts only. |

## Install the plugin

1. Put `Hotwire.cs` in the server folder's `oxide/plugins`. Oxide compiles it within a few seconds and writes `oxide/config/Hotwire.json` with every schedule entry off.
2. Grant the permissions to your admin group, in the server console:

   ```
   oxide.grant group admin hotwire.status
   oxide.grant group admin hotwire.restart
   oxide.grant group admin hotwire.cancel
   oxide.grant group admin hotwire.edit
   ```

3. Add a schedule, in the server console or in chat:

   ```
   hotwire add restart 05:00 daily
   hotwire add update  20:00 first Thursday
   ```

To update or remove the plugin, see [docs/PLUGIN.md](docs/PLUGIN.md). To install a Rust server from nothing, see [docs/INSTALL-WINDOWS.md](docs/INSTALL-WINDOWS.md) or [docs/INSTALL-LINUX.md](docs/INSTALL-LINUX.md).

## Permissions

| Permission | Allows |
| --- | --- |
| `hotwire.status` | See the schedule, open the menu, run `check` and `list` |
| `hotwire.restart` | Start a countdown now |
| `hotwire.cancel` | Cancel a running countdown |
| `hotwire.edit` | Add, change, remove, enable and disable entries |

## Schedule

Three lists: restarts, updates and wipes. Each entry has a time, on the machine's clock, and one of six repeats.

| Repeat | Means | Example |
| --- | --- | --- |
| Daily | Every day | `05:00 daily` |
| Weekly | The listed weekdays | `03:00 Tue`, `05:00 Mon,Thu`, `05:00 weekdays` |
| Monthly, a weekday | An ordinal weekday | `20:00 first Thursday`, `04:00 last Friday` |
| Monthly, a date | A day of the month | `05:00 day 15` |
| Every N days | A fixed interval from an anchor date | `05:00 every 2 days` |
| Once | One date; the entry disables itself afterwards | `02:00 once 2026-12-24` |

| Rule | Value |
| --- | --- |
| Two entries on the same minute | A wipe wins over an update; an update wins over a restart |
| A date of the month the month lacks | Skipped that month, not moved |
| An entry that cannot be read | Disabled and reported; the rest of the schedule runs |
| Clock changes | Times are wall-clock time; an entry never fires twice within 20 hours, so the autumn change never restarts twice |
| Shipped config | Every entry off. Installing the plugin cannot restart anything. |

## Wipes

A wipe starts a new map: the plugin hands the launcher the next seed (and size), the launcher writes them into `hotwire.cfg` before the start, and the old save stays on disk. Blueprints are kept, kept aside on disk, or deleted, as the entry says. Rust+ pairings are never touched. The seed is chosen when the entry is saved, so the next map is known in advance; a fresh one is drawn after each wipe.

| Kind | Fires |
| --- | --- |
| Scheduled wipe | On the entry's own time and repeat |
| Forced wipe | When Facepunch's monthly update arrives on the first Thursday of the month: once AFKPanel sees the new Rust build and the Oxide made for it, and not before 19:00 London time unless the entry says so. The launcher applies the new seed only in a start whose update changed the installed build. Until then the old map stays and the plugin tries again every 30 minutes, for 6 hours, then stops and says so. Without AFKPanel, it restarts at 19:00 London and the launcher's build comparison decides. |

Wipe entries are added and changed in AFKPanel. `hotwire list` shows them in game. A wipe requires the Hotwire launcher, unmodified; on a start script the entry reports that and never fires.

## Commands

In chat or in the server console. `hw` is a short form. Bare `hotwire` is `status`.

| Command | Permission | Does |
| --- | --- | --- |
| `hotwire status` | `hotwire.status` | What is counting down, or what is next |
| `hotwire menu` | `hotwire.status` | The in-game menu |
| `hotwire list` | `hotwire.status` | Every entry in all three lists, with its index and next occurrence |
| `hotwire check` | `hotwire.status` | Diagnostics: the server folder, the flag files, the clock, the status bar |
| `hotwire now [update\|validate] [seconds]` | `hotwire.restart` | Start a countdown now |
| `hotwire cancel` | `hotwire.cancel` | Cancel the running countdown |
| `hotwire add <restart\|update\|validate> <HH:mm> [pattern]` | `hotwire.edit` | Add an entry |
| `hotwire set <restart\|update> <index> <time\|pattern\|validate> <value>` | `hotwire.edit` | Edit one in place |
| `hotwire remove <restart\|update> <index>` | `hotwire.edit` | Remove one |
| `hotwire enable\|disable <restart\|update> <index>` | `hotwire.edit` | Turn one on or off |

| Rule | Value |
| --- | --- |
| `hotwire now` with no seconds | The configured countdown, 1 hour by default |
| An entry added with `hotwire add` | On at once |
| An entry added from the menu's + button | Off until you turn it on |
| Pattern words | English on every server; what the plugin says back is translated |
| Wipe entries | Added and changed in AFKPanel, not from chat |

## The in-game menu

`hotwire menu` opens a panel over the same schedule. Every change is saved as you make it. The edit view shows the fields the chosen repeat uses and leads with when the entry next runs, in words: *tomorrow at 05:00*, *Tuesday at 03:00*.

## Announcements

| Setting | Default |
| --- | --- |
| Countdown starts | 1 hour before |
| Announced at | 60, 30, 15, 10, 5, 2 and 1 minutes; 30, 20 and 10 seconds; then every second |
| Name shown in chat | Server Manager |
| Remaining time | Rounded up, so "3 minutes" stays true for the minute it sits in chat |

The countdown is read from the clock on every tick, so a stalled frame or a changed timescale cannot move a restart.

Where [AdvancedStatus](https://codefling.com/plugins/advanced-status) is installed, the countdown also shows as a status bar. It is optional: without it the countdown runs in chat, and `hotwire check` says which is the case. AdvancedStatus is not on uMod, so it cannot be listed as a dependency.

## Reporting to AFKPanel

Optional. Nothing is sent until the Rust server is connected with `hotwire-setup connect`, which writes `oxide/data/Hotwire/panel.json`. See [Connect a server](https://afkpanel.com/docs/connect-a-server).

| Sent | When |
| --- | --- |
| Heartbeat: players, FPS, CPU, memory, entities, network, queue, uptime, Oxide and Rust versions | Every 30 seconds |
| The plugin list: name, author, version, file hash and size, whether it loaded, Oxide's error if not | When it changes |
| Each plugin's server time and memory | Every minute |
| The schedule: restarts, updates, wipes, the running countdown | When it changes |
| The map: seed, size, custom map address, last wipe, the map image, markers other plugins place | When they change |
| Who is online, joins and leaves, chat, and where players stand | Only at the sharing level the account owner set in AFKPanel, and only what the account's plan includes |

| Carried out from AFKPanel | Rule |
| --- | --- |
| A message, a save, a kick, a plugin reload or unload | As queued |
| A restart, update or wipe | Always with the countdown, never with less than 1 minute's warning |
| Schedule changes | Checked exactly as a chat command is; refused if the schedule changed in game since |
| The account's ban list | Written into the Rust server's own ban list, so bans hold when AFKPanel is unreachable. A ban made on the server is never lifted by AFKPanel. |

| Never | Why |
| --- | --- |
| A plugin's file or source | Only its hash and size travel |
| A password | Every request is signed with the server's key; the key never leaves the machine |
| A report from a copied server folder | The plugin reports only from the folder that was connected |
| A change to what the server does because AFKPanel is slow, down or wrong | Reporting runs beside the schedule, never in front of it |

Each switch is in the config's `Panel` section. `hotwire check` shows what is being sent and, if something is not, why.

## Safety

| Must never happen | How it is prevented |
| --- | --- |
| A server left unable to restart | Nothing on the restart path waits on AFKPanel or reads from it |
| An unannounced restart | Every restart, scheduled or sent from AFKPanel, goes through the countdown |
| An update that does not start | A flag that cannot be written downgrades the update to a plain restart |
| A map wiped twice, or half wiped | The launcher records each wipe's cycle id, and cancels toward starting unchanged if the seed cannot be written |
| A restart at 03:00 from an entry that stopped parsing | The entry is disabled and reported at load |

## Configuration

`oxide/config/Hotwire.json`, written on first load. Every key is in [docs/CONFIG.md](docs/CONFIG.md). The file stays hand-editable; the commands and the menu change the same file.

## The launcher

| Platform | File | Settings |
| --- | --- | --- |
| Windows | `hotwire.bat` | `hotwire.cfg` beside it |
| Linux | `hotwire.sh` | `hotwire.cfg` beside it |

The launcher starts the Rust server, relaunches it when it exits, and updates it only when the plugin's schedule, a newer Steam build or a backstop says so. It carries out the wipes the plugin schedules. Neither half needs the other: the plugin restarts a server on its own, and the launcher runs without the plugin. See [docs/LAUNCHER.md](docs/LAUNCHER.md) and [docs/HOTWIRE-CFG.md](docs/HOTWIRE-CFG.md).

## What it does not do

| Not done | Note |
| --- | --- |
| Wipe a custom (`levelurl`) map | A wipe changes the seed; a custom map has none |
| Remove old saves after a wipe | They stay on disk |
| Hold a restart for a live event | It does not know about your events |

## Layout

```
src/Hotwire.cs                  the plugin
launcher/hotwire.bat            the launcher for Windows
launcher/hotwire.sh             the launcher for Linux
launcher/hotwire.example.cfg    every setting both launchers read; copy to hotwire.cfg
launcher/hotwire-secrets.example.cfg   copy to hotwire-secrets.cfg for the RCON password; never committed
launcher/hotwire-*.example.*    your own commands before a start and after an update
setup/hotwire-setup.ps1         Windows: install a server, connect it, check it
setup/hotwire-setup.sh          Linux: the same
CHANGELOG.md                    what is in each release
docs/INSTALL-WINDOWS.md         a server from nothing, on Windows
docs/INSTALL-LINUX.md           a server from nothing, on Ubuntu
docs/SWITCH-TO-HOTWIRE.md       a server you already run
docs/PLUGIN.md                  add, update or remove the plugin
docs/LAUNCHER.md                the launcher
docs/HOTWIRE-CFG.md             the settings file
docs/RCON-PASSWORD.md           the secrets file
docs/CHECK.md                   what check says and what to do about it
docs/HOOKS.md                   your own scripts before a start and after an update
docs/CONFIG.md                  every config key, command and permission
docs/GAME-API.md                what has been verified against a real build
tools/                          maintenance tooling; you never need to run it
tests/plugin-signing/           checks the plugin's request signing outside the game
```

## Licence and credit

MIT. The problem space was mapped in part by reading [Smooth Restarter](https://umod.org/plugins/smooth-restarter) by 2CHEVSKII; Hotwire shares no code with it.
