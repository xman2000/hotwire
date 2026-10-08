# Hotwire

[![Get started at afkpanel.com](https://img.shields.io/badge/Get_started-afkpanel.com-44FF2B?style=for-the-badge)](https://afkpanel.com/get-started) [![AFKPanel](https://img.shields.io/badge/Watch_your_server-AFKPanel-0067A5?style=for-the-badge)](https://afkpanel.com) [![Latest release](https://img.shields.io/github/v/release/xman2000/hotwire?style=for-the-badge&label=latest)](https://github.com/xman2000/hotwire/releases/latest) [![MIT licence](https://img.shields.io/badge/licence-MIT-lightgrey?style=for-the-badge)](LICENSE.md)

**Run your Rust server on a schedule. Watch it from anywhere.**

Hotwire is a set of free tools for Rust server admins. An Oxide plugin restarts and updates your server on a schedule, with a countdown your players can see. A launcher brings the server back and installs updates only when they are due. A setup script builds a server from nothing. Connect it to [AFKPanel](https://afkpanel.com) and see the server, its players, its logs and what each plugin costs, from any browser.

**[Get started at afkpanel.com](https://afkpanel.com/get-started)** · [Features](https://afkpanel.com/features) · [Pricing](https://afkpanel.com/pricing) · [Documentation](https://afkpanel.com/docs)

## What's in it

- **The plugin** (`Hotwire.cs`, for Oxide). Restarts and updates on a schedule. Each one is announced in chat with a countdown; then players are kicked with a reason, the world is saved and the server quits. Set the schedule from chat, the server console or an in-game menu.
- **The launcher** (Windows and Linux). Starts Rust and brings it back when it exits. Installs a new Rust build and the Oxide made for it when the schedule says so, not on every restart. Stops after a run of crashes instead of looping forever.
- **Setup** (Windows and Linux). Installs SteamCMD, Rust, Oxide and Hotwire on a fresh machine, connects the server to AFKPanel, and checks the result. Every step asks first.
- **The start-script converter** (on [afkpanel.com](https://afkpanel.com/get-started#existing)). Turns the start script you use today into Hotwire's settings file, with your settings carried over.
- **[AFKPanel](https://afkpanel.com)**. Your servers in a browser: status, alerts, players, logs and each plugin's cost. Free for one server.

## Get started

- **A new server on Windows:** [Install a Rust server on Windows](https://afkpanel.com/docs/install-windows)
- **A new server on Ubuntu:** [Install a Rust server on Ubuntu](https://afkpanel.com/docs/install-linux)
- **A server you already run:** [Switch to Hotwire](https://afkpanel.com/docs/switch-to-hotwire)
- **A Pterodactyl or Pelican host:** [Add Hotwire on a host panel](https://afkpanel.com/docs/install-pterodactyl)
- **The plugin only:** [Add the plugin](docs/PLUGIN.md)

Downloads: [Windows](https://afkpanel.com/get/windows) · [Linux](https://afkpanel.com/get/linux) · [the plugin](https://afkpanel.com/get/Hotwire.cs) · [every release](https://github.com/xman2000/hotwire/releases)

## Your server never depends on AFKPanel

- If AFKPanel is slow, down or wrong, your server starts, restarts and updates exactly as it would without it. Nothing on the restart path waits for it.
- Hotwire opens no port and needs no RCON access. Every connection it makes is outbound.
- Plugin files stay on your server. AFKPanel receives each plugin's name, version, file hash and size, never the file.
- Every request is signed, and AFKPanel's replies are signed too. Hotwire acts only on a reply it has verified.
- Without an account, Hotwire is a complete restart and update scheduler. Connecting to AFKPanel adds to it.

## AFKPanel

[AFKPanel](https://afkpanel.com) shows every connected server in one place and tells you when one goes down.

- **Free, for one server:** every health check and every alert, live status, players and performance, restarts and updates on your schedule, a public status page, and warnings and errors from your logs for 7 days, other lines for 1 day.
- **Pro, coming soon:** restart, update, reload plugins, message players and change settings from the panel; kicks and bans on every server at once; every F7 report in one inbox; every chat, searchable; wiping the map; automatic backups, kept and rotated on your server; every log level with search; and 90 days of player counts and performance. $5 a month for the first server and $2.50 for each one after. See [Pricing](https://afkpanel.com/pricing).

To connect a server, see [Connect a server](https://afkpanel.com/docs/connect-a-server). On a host panel's console, `hotwire connect <code>` does the same.

## The plugin

Requires Oxide on any current Rust build. Put `Hotwire.cs` in `oxide/plugins`; every schedule entry starts off, so installing it cannot restart anything. Then grant the permissions and add a schedule, in the server console:

```
oxide.grant group admin hotwire.status
oxide.grant group admin hotwire.restart
oxide.grant group admin hotwire.cancel
oxide.grant group admin hotwire.edit
hotwire add restart 05:00 daily
hotwire add restart 20:00 first Thursday
```

- **Updates:** with `Install updates if available` (on by default) and the launcher, a restart also installs a new Rust build or Oxide release when one is out, so one schedule covers both.
- **Repeats:** daily, chosen weekdays (`Mon,Thu`, `weekdays`), an ordinal weekday (`first Thursday`, `last Friday`), a date (`day 15`), every N days, or once.
- **Countdown:** starts an hour before and is announced at 60, 30, 15, 10, 5, 2 and 1 minutes, then the last seconds. Where [AdvancedStatus](https://codefling.com/plugins/advanced-status) is installed, it also shows as a status bar.
- **Clock changes:** times are wall-clock time, and an entry never fires twice within 20 hours, so the autumn change never restarts twice.
- **Commands:** `hotwire status`, `menu`, `list`, `check`, `now`, `cancel`, `add`, `set`, `remove`, `enable`, `disable`, `backup`, `connect`. `hw` is a short form.
- **The in-game menu** (`hotwire menu`): the same schedule, saved as you change it, with Run now for a restart, an update or a validate. Wipes are listed there and changed in AFKPanel.

Every key, command and permission: [docs/CONFIG.md](docs/CONFIG.md). Adding, updating and removing the plugin: [docs/PLUGIN.md](docs/PLUGIN.md).

## Wipes, with AFKPanel Pro

Wipes are part of [AFKPanel Pro](https://afkpanel.com/pricing). A wipe is a restart that starts a new map. The next seed is chosen when the wipe is saved, so the next map is known in advance. Blueprints are kept, set aside or deleted, as the wipe says. The old save stays on disk.

- **Scheduled wipe:** on its own time and repeat.
- **Forced wipe:** when Facepunch's monthly update arrives on the first Thursday, once AFKPanel sees the new Rust build and the Oxide made for it, and not before 19:00 London time unless you allow it.

Wipes are added and changed in AFKPanel, and need the Hotwire launcher. The launcher records each wipe, so a map is never wiped twice or half wiped: if the new seed cannot be written, the server starts on the old map unchanged.

## The launcher

- **Windows:** `hotwire.bat` starts `hotwire.ps1`. Windows 10 or later.
- **Linux:** `hotwire.sh`. Ubuntu 22.04 or later.

Every setting lives in `hotwire.cfg` beside the launcher: Rust's own settings by their own names, the launcher's under `hotwire.`. The launcher and the plugin each work without the other: the plugin restarts a server on its own, and the launcher runs a server without the plugin. See [docs/LAUNCHER.md](docs/LAUNCHER.md) and [docs/HOTWIRE-CFG.md](docs/HOTWIRE-CFG.md).

## What Hotwire sends to AFKPanel

Nothing, until you connect the server. Then:

- Every 30 seconds: players, FPS, CPU, memory, entities, network, queue, uptime, the Oxide and Rust versions, and whether RCON is on (never its password).
- When they change: the plugin list (name, author, version, file hash and size, and Oxide's error if one failed), the schedule, and the map.
- Every minute: each plugin's server time and memory.
- Once each start: the SHA-256 of each file in `RustDedicated_Data/Managed`, so AFKPanel can say whether Oxide's files are that release's.
- Players' names, joins, chat and positions only at the sharing level you set in AFKPanel, and only what your plan includes.

Each kind can be switched off in the plugin's config. `hotwire check` shows what is being sent and, if something is not, why.

## Safety

- **A server that cannot restart:** nothing on the restart path waits on AFKPanel or reads from it.
- **A restart without warning:** every restart, scheduled or sent from AFKPanel, goes through the countdown.
- **An update that leaves the server down:** a flag that cannot be written turns the update into a plain restart.
- **A restart at 03:00 from an entry that stopped making sense:** the entry is turned off and reported when the plugin loads.

## Layout

```
plugin/Hotwire.cs               the plugin
launcher/hotwire.bat            starts the Windows launcher; the same in every release
launcher/hotwire.ps1            the launcher for Windows
launcher/hotwire.sh             the launcher for Linux
examples/                       hotwire.cfg, the secrets file and your own commands, to copy
setup/                          install a server, connect it, check it (Windows and Linux)
docs/                           every guide and reference page
tools/                          maintenance tooling; you never need to run it
tests/                          checks the plugin's and the launchers' signing, and the wipe permission, outside the game
CHANGELOG.md                    what is in each release
```

## Licence and credit

MIT. See [LICENSE.md](LICENSE.md). The problem space was mapped in part by reading [Smooth Restarter](https://umod.org/plugins/smooth-restarter) by 2CHEVSKII; Hotwire shares no code with it.
