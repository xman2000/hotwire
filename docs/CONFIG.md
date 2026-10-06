# Configuration

The plugin's settings are in `oxide/config/Hotwire.json`, in the server folder. The file is written on first load with every schedule entry off, and it stays hand-editable: the chat commands, the in-game menu and AFKPanel change the same file.

| Rule | Value |
| --- | --- |
| A key the file lacks | Takes its default; the file is written once and new keys are not added to it. Delete a section to pick up new defaults. |
| A key the plugin does not know | Ignored |
| A schedule entry that cannot be read | Disabled at load and reported in the console; the rest of the schedule runs |
| Changes from chat, the menu or AFKPanel | Saved to the file as they are made |

## Restarts and updates

Two of the three lists. A restart relaunches the server, and with `Install updates if available` (on by default) it also installs a new Rust build or Oxide release when AFKPanel says one is out, or when AFKPanel cannot say. An update entry always leaves the launcher `UPDATE.flag`, so the next start installs the current Rust build and the Oxide that matches it. The third list, wipes, is below.

From 1.1.49 the plugin moves its update entries into the restarts once, set to install updates if available; a validating update entry stays where it is. From 1.1.61 nothing adds an update entry: `hotwire add` and the menu add restarts. An update entry already in the file stays, and can be changed or removed.

```json
"Restarts": [
  { "Time": "05:00", "Repeat": "Daily", "Enabled": true, "Install updates if available": true }
],
"Updates": [
  { "Time": "20:00", "Repeat": "MonthlyWeekday", "Ordinal": "First",
    "Days": [ "Thursday" ], "Validate": false, "Enabled": true }
]
```

The shipped update entry is the first Thursday of the month at 20:00, off.

### Fields

| Field | Read by | Meaning |
| --- | --- | --- |
| `Time` | all | `HH:mm`, 24-hour, on the machine's clock |
| `Repeat` | all | One of the six repeats below |
| `Days` | Weekly, MonthlyWeekday | Day names: `[ "Monday", "Thursday" ]` |
| `Ordinal` | MonthlyWeekday | `First`, `Second`, `Third`, `Fourth` or `Last` |
| `DayOfMonth` | MonthlyDay | 1 to 31 |
| `IntervalDays` | EveryNDays | Days between runs |
| `AnchorDate` | EveryNDays | `yyyy-MM-dd`, the day the count starts from. Empty is filled with today and saved. |
| `Date` | Once | `yyyy-MM-dd` |
| `Enabled` | all | `false` ignores the entry |
| `Validate` | updates | Adds `validate` to the steamcmd update, which checks every game file. Slow on a large install. |
| `Id` | all | Written by the plugin, 12 characters. Leave it. AFKPanel names an entry by it. |

Only the fields the chosen `Repeat` reads are used; the others keep their values, so an entry switched from weekly to monthly and back keeps its days.

### Repeats

| `Repeat` | Means | Chat pattern |
| --- | --- | --- |
| `Daily` | Every day | `daily`, or nothing |
| `Weekly` | The days in `Days` | `Tue`, `Mon,Thu`, `weekdays`, `weekends` |
| `MonthlyWeekday` | The `Ordinal` weekday of the month | `first Thursday`, `last Friday` |
| `MonthlyDay` | `DayOfMonth` each month | `day 15` |
| `EveryNDays` | Every `IntervalDays` from `AnchorDate` | `every 2 days` |
| `Once` | `Date`, then the entry disables itself | `once 2026-12-24` |

| Rule | Value |
| --- | --- |
| `Fifth` | Not offered. `Last` covers it in every month. |
| A `DayOfMonth` the month lacks | Skipped that month, not moved. The plugin warns at load. |
| Two entries on the same minute | A wipe wins over an update; an update wins over a restart |
| `Install updates if available` | Restart entries only. On: the restart installs updates when AFKPanel said in the last ten minutes that a newer Rust build (on the server's own branch) or Oxide is out, or when AFKPanel has said nothing; off, or nothing new: a plain restart. Decided when the countdown starts. |
| `UPDATE.schedule` | While a restart that installs updates, an update entry or the framework check is on, the plugin keeps this file in the server folder and rewrites it every 15 minutes. A launcher on `hotwire.update_mode auto` follows the schedule while the file is under 2 hours old, and updates on every start otherwise. |

### From chat

```
hotwire add restart 05:00                       daily
hotwire add restart 05:00 weekdays
hotwire add restart 03:00 Tue                   every Tuesday
hotwire add restart 05:00 Mon,Thu
hotwire add restart 20:00 first Thursday        Rust's monthly update
hotwire add restart 04:00 last Friday
hotwire add restart 05:00 day 15
hotwire add restart 05:00 every 2 days
hotwire add restart 02:00 once 2026-12-24

hotwire set restart 0 time 06:00
hotwire set restart 0 pattern second Tuesday
hotwire set restart 0 updates off              a plain restart, no updates
hotwire set restart 0 from 2026-10-01          every N days, counted from this day
hotwire set update  0 validate true            an update entry already in the file
```

An entry added with `hotwire add` is on at once. An entry added from the menu's **+** button is off until you turn it on. To add one and keep it off: `hotwire disable restart <index>` after adding it.

## Wipes

Requires the Hotwire launcher: Windows 1.1.17 or later, Linux 1.1.4 or later. On a start script, or an older launcher, a wipe entry is reported with that problem and never fires.

A wipe is a restart that also leaves the launcher `WIPE.flag` with the next map's seed. Every server starts with one forced wipe, switched off, with a random seed and a random size between 3500 and 4500; it is added once, and a deleted one is not added back. The entry has the recurrence fields above and these:

| Field | Meaning | Default |
| --- | --- | --- |
| `Seed` | The next map's seed, 1 to 2147483647. Empty: the plugin draws a random one when the entry is saved, and again after each wipe. | Drawn |
| `Size` | The next map's size, 1000 to 6000. Empty keeps the current size. | Empty |
| `Blueprints` | `keep`, `rename` or `delete`. `rename` keeps each file aside as `player.blueprints.*.db.wiped-<date>`. | `keep` |
| `Backup first` | Back up the stopped server before the wipe: by the launcher where it can, by Rust's `server.backup` otherwise | `true` |
| `Forced wipe (tied to the monthly update)` | Follow Facepunch's monthly update instead of `Time` and `Repeat` | `false` |
| `Wipe anyway when no update arrives` | Forced wipes only: wipe at the end of the window even if no update came | `false` |
| `Wipe as soon as the update is out (before 19:00 London)` | Forced wipes only: start as soon as AFKPanel's release check opens, even before 19:00 London | `false` |
| `Random size after each wipe` | Draw `Size` from the range below when the entry is saved and again after each wipe | `false` |
| `Random size: smallest`, `Random size: largest` | The range, 1000 to 6000, smallest first | 3500, 4500 |
| `Same seed every wipe` | Keep `Seed` after a wipe instead of drawing a new one, so every wipe brings the same map back fresh. Requires launcher 1.1.26 (Windows) or 1.1.11 (Linux) or later. | `false` |
| `Custom map URL` | The `http://` or `https://` address of a custom `.map` file. Set, each wipe loads this map fresh and `Seed` and `Size` are not used. Empty, the map is generated from the seed. Requires launcher 1.1.26 (Windows) or 1.1.11 (Linux) or later. | Empty |
| `Template` | The AFKPanel template the entry was made from. Hotwire does not read it. | Empty |

```json
"Wipes": [
  { "Repeat": "MonthlyWeekday", "Ordinal": "First", "Days": [ "Thursday" ],
    "Seed": "1847362", "Size": "4000", "Blueprints": "keep", "Backup first": true,
    "Forced wipe (tied to the monthly update)": true,
    "Wipe anyway when no update arrives": false,
    "Wipe as soon as the update is out (before 19:00 London)": false, "Enabled": true }
]
```

| Kind | Fires | The launcher |
| --- | --- | --- |
| Scheduled (`Forced wipe` false) | On `Time` and `Repeat` | Writes the seed and size into `hotwire.cfg`, deals with the blueprints, records the wipe's cycle id, starts the server |
| Forced (`Forced wipe` true) | The first Thursday of the month, once AFKPanel's release check is open: the new Rust build is on Steam and an Oxide release was published after it. Never before 19:00 Europe/London, whatever the machine's zone, unless `Wipe as soon as the update is out` is `true`. Once 19:00 has passed, after a 5-minute countdown. The plugin restarts with an update. | Applies the wipe only if the update changed the installed build. Otherwise it starts the old map, writes `WIPE.result` `deferred`, and the plugin tries again. When the new build is already installed, the plugin hands over a plain wipe and the launcher applies it without comparing. |

| Rule | Value |
| --- | --- |
| Retry, forced wipe | With AFKPanel's release check open, a deferral means the update did not install the new build: the plugin tries again after `Forced wipe: after a failed update, retry after these many minutes` (5, 10, 20, then 30), counted from the boot that found it, each a 5-minute announced restart. As soon as the new build is installed it wipes without comparing. Without AFKPanel: every `Forced wipe: try again every this many minutes` (30) from the last restart. |
| Window, forced wipe | `Forced wipe: give up this many hours after the release moment` (6), counted from when AFKPanel's release check opened, or from 19:00 London without it. After it the plugin stops and reports that no update arrived, or wipes once if `Wipe anyway` is `true`. |
| No word from AFKPanel, forced wipe | `Forced wipe: go without AFKPanel's release check after this many minutes of silence` (30) after 19:00 London. The plugin then restarts with an update and the launcher's build comparison decides. |
| Release check | Requires Hotwire 1.1.47 or later, connected to AFKPanel, with `Accept commands from the panel` on. A server that cannot hear it restarts at 19:00 London and the launcher's build comparison decides. |
| `hotwire.update_mode off` | The launcher does not update, so a forced wipe applies only if the new build is already installed; otherwise it gives up at the end of the window |
| A wipe entry | Always updates too |
| Same minute as an update | The wipe wins |
| Rust+ pairings (`player.tokens.db`) | Never touched |
| The old save | Stays on disk |
| A seed the launcher cannot write | The wipe is cancelled and the server starts unchanged |
| Added and changed in | AFKPanel. `hotwire list` shows wipe entries in game. |

## Countdown

```json
"Countdown": {
  "Start the countdown this many seconds before": 3600,
  "On a Pterodactyl or Pelican server, hold a scheduled restart for Oxide (hours)": 2,
  "Announce when this many seconds remain": [
    3600, 1800, 900, 600, 300, 120, 60,
    30, 20, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1
  ],
  "Seconds between the last announcement and the kick": 1.0
}
```

| Key | Meaning |
| --- | --- |
| `Start the countdown this many seconds before` | How long before the entry's time the countdown begins. `hotwire now` with no seconds uses it too. |
| `On a Pterodactyl or Pelican server, hold a scheduled restart for Oxide (hours)` | On these hosts every start installs the newest Rust and Oxide. When AFKPanel says a new Rust build is out and Oxide's release for it is not, a scheduled restart waits for Oxide's release, up to this many hours, then goes ahead. When it goes ahead at its original time, that time stands; later than that, the countdown is ten minutes. `0` never waits. A restart asked for with `hotwire now` or from AFKPanel never waits, and a server with no answer from AFKPanel never waits. |
| `Announce when this many seconds remain` | The moments announced in chat. The status bar, where there is one, updates its text once a minute. |
| `Seconds between the last announcement and the kick` | The pause before players are kicked |

| Rule | Value |
| --- | --- |
| Remaining time | Rounded up, so "3 minutes" stays true for the minute it sits in chat |
| The clock | Read on every tick; a stalled frame or a changed timescale cannot move a restart |
| The announcement text | Lang strings in `oxide/lang/en/Hotwire.json` |

## Times and clock changes

| Rule | Value |
| --- | --- |
| Entry times | The machine's wall-clock time. `05:00` is five in the morning whatever the clocks have done. |
| Printed times | Carry the zone and whether daylight saving is in effect |
| The same entry twice | Refused within `Refuse to fire the same entry twice within this many hours` (20). The autumn change never restarts twice; the spring change skips once and is logged. |
| `hotwire now` | Not subject to that rule and does not feed it |

## Framework update check

```json
"Framework update check": {
  "Enabled": false,
  "Check every this many minutes": 60,
  "Release feed URL": "https://umod.org/games/rust.json",
  "When a new release is found, update at (HH:mm)": "05:00",
  "Validate on a framework update": false
}
```

Off by default. On, the plugin polls the release feed and, when a new Oxide release appears, schedules an announced update at the hour set, which then behaves like any update entry. A feed whose shape has changed logs a warning and schedules nothing.

## General

```json
"General": {
  "Server root (empty = detect)": "",
  "Update flag file name": "UPDATE.flag",
  "Validate flag file name": "VALIDATE.flag",
  "Wipe flag file name": "WIPE.flag",
  "Refuse to fire the same entry twice within this many hours": 20.0,
  "Forced wipe: try again every this many minutes": 30,
  "Forced wipe: after a failed update, retry after these many minutes": [ 5, 10, 20, 30 ],
  "Forced wipe: give up this many hours after the release moment": 6.0,
  "Forced wipe: go without AFKPanel's release check after this many minutes of silence": 30,
  "Default forced wipe added": true,
  "Update entries merged into restarts": true,
  "Name shown in chat announcements": "Server Manager",
  "Name color (hex)": "#e0995e"
}
```

| Key | Meaning |
| --- | --- |
| `Server root` | Where the flag files are written. Empty asks Oxide. `hotwire check` shows what was resolved, whether `RustDedicated` is in it, and whether it is writable. |
| `Update flag file name`, `Validate flag file name`, `Wipe flag file name` | The files the launcher watches for. Change them only if your launcher watches for different names. |
| `Refuse to fire the same entry twice within this many hours` | The clock-change guard. `0` turns it off. Set it below the gap only if you schedule one entry twice a day. |
| `Forced wipe: try again every this many minutes` | See Wipes |
| `Forced wipe: after a failed update, retry after these many minutes` | See Wipes. The last value repeats. |
| `Forced wipe: give up this many hours after the release moment` | See Wipes |
| `Forced wipe: go without AFKPanel's release check after this many minutes of silence` | See Wipes |
| `Default forced wipe added` | Set once the plugin has added the default forced wipe. `false` adds it again on the next load if the server has no forced wipe. |
| `Update entries merged into restarts` | Set once the plugin has turned older update entries into restarts that install updates. Leave it as it is. |
| `Name shown in chat announcements` | The name players see: *Server Manager: Scheduled restart in 4 minutes*. Empty drops the prefix. |
| `Name color (hex)` | The name's colour. Empty drops the markup. |

## Panel

Reporting to AFKPanel. Nothing is sent until the Rust server has been connected with `hotwire-setup connect`, or `hotwire connect <code>` in the server console, which writes `oxide/data/Hotwire/panel.json`; without that file this section does nothing. `hotwire-setup detach` removes it. See [Connect a server](https://afkpanel.com/docs/connect-a-server).

```json
"Panel": {
  "Report to the panel when connected": true,
  "Heartbeat every this many seconds": 30,
  "Accept commands from the panel": true,
  "Check for commands every this many seconds": 30,
  "Shortest restart countdown from the panel (seconds)": 60,
  "Enforce the panel's ban list": true,
  "Check the ban list every this many seconds": 120,
  "Report the map and its markers": true,
  "Send map markers at most every this many seconds": 60,
  "Send the map image": true,
  "Render the map image if Rust+ has not": true,
  "Send the map layout": true,
  "Report the schedule": true,
  "Accept schedule changes from the panel": true,
  "Accept plugin updates from the panel": true,
  "Send the Oxide log": true,
  "Keep unsent reports and log lines for this many days": 7,
  "Send the server console": true,
  "Send the log every this many seconds": 60,
  "Send who is online, and player joins and leaves": true,
  "Send chat": true,
  "Send in-game reports when the panel asks for them": true,
  "Send player joins, leaves and chat every this many seconds": 30,
  "Send player positions for the panel's live map": true,
  "Send player positions every this many seconds": 30,
  "Report each plugin's server time": true,
  "Send plugin server time every this many seconds": 60
}
```

| Key | Meaning | Limit |
| --- | --- | --- |
| `Report to the panel when connected` | `false` stops reporting and keeps the connection | |
| `Heartbeat every this many seconds` | How often the server says it is up. AFKPanel counts a server as silent after 10 minutes without one. | 10 or more |
| `Accept commands from the panel` | `false` means AFKPanel's buttons do nothing on this server; what is queued there expires unanswered. Commands: a message to players, a save, a plugin reload or unload, a kick, an announced restart, update or wipe, and schedule changes. Hotwire never unloads itself. | |
| `Check for commands every this many seconds` | How often queued commands are fetched | |
| `Shortest restart countdown from the panel (seconds)` | A restart from AFKPanel never has less warning than this, whatever was asked | 10 or more |
| `Enforce the panel's ban list` | Writes the account's bans into this server's own ban list, so they hold when AFKPanel is unreachable. A ban AFKPanel lifts is lifted here only if AFKPanel added it; a ban made on this server stays. Mutes are not enforced. What AFKPanel added is recorded in `oxide/data/Hotwire/panel_bans.json`. | |
| `Check the ban list every this many seconds` | How often the ban list is fetched | |
| `Report the map and its markers` | The seed, size, custom map address and when the current save was created, when they change; and the markers other plugins place (radius circles and labels, such as a PVP zone), when they change. Never players, shops or bases. | |
| `Send map markers at most every this many seconds` | | 30 or more |
| `Send the map image` | The picture Rust draws for Rust+, once per map, a few MB. AFKPanel is asked first, so a restart on the same map sends nothing. | |
| `Render the map image if Rust+ has not` | With Rust+ off (`app.port -1`) the plugin asks the game to draw the picture, once per map, 2 minutes after the start | |
| `Send the map layout` | Landmarks, roads, rails, rivers, power lines, the train tunnels and the underwater labs' rooms: what the world generator made, 100 to 200 KB, once per map and again after 7 days. Never players or bases. | |
| `Send the Oxide log` | Oxide's log lines. Card numbers and SSNs are masked first, and Steam IDs are removed below the "identified" sharing level. The log file on this machine stays the full record. | |
| `Keep unsent reports and log lines for this many days` | How long reports and log lines that could not reach AFKPanel are kept on this machine | Up to 90 |
| `Send the server console` | What the game server writes to its console that Oxide does not: saves, joins and leaves, Rust's own warnings and errors. IP addresses, card numbers and SSNs are masked, and Steam IDs below the "identified" level. Chat never goes this way. | |
| `Send the log every this many seconds` | How often log lines are sent. AFKPanel may ask for a longer interval, never a shorter one. | 10 or more |
| `Send who is online, and player joins and leaves` | By Steam ID and name, only at the "identified" sharing level. Below it only the player count leaves this machine. | |
| `Send chat` | What players say, with its channel. Only at the "identified" level, only while the account's plan includes chat, with card numbers and SSNs masked. Chat commands are never sent. | |
| `Send in-game reports when the panel asks for them` | F7 reports: who reported whom, the kind, the subject and the message. Only when the account has them turned on and the level is "identified". `false` keeps them on this server. | |
| `Send player joins, leaves and chat every this many seconds` | How often they are sent. AFKPanel may ask for a longer interval, never a shorter one. | 10 or more |
| `Send player positions for the panel's live map` | Where each awake, living player stands, and whether they are hidden from other players, for AFKPanel's map. Sent only when AFKPanel says the account's plan includes the live map, and never at the "counts only" sharing level. | |
| `Send player positions every this many seconds` | While anyone is playing; once more when the last player leaves | 30 or more |
| `Report each plugin's server time` | How much of the server's time each plugin used, and the memory allocated while it ran: plugin names and numbers only | |
| `Send plugin server time every this many seconds` | AFKPanel may ask for a longer interval, never a shorter one | 30 or more |
| `Report the schedule` | Every restart, update and wipe entry, its next time and any problem, the countdown settings, and the running countdown; sent when any of it changes | |
| `Accept schedule changes from the panel` | Lets AFKPanel add, edit, enable, disable and remove entries. Each change is checked as a chat command is, and refused if the schedule changed in game since AFKPanel last saw it. `false` keeps the schedule editable in game only; a restart, update or wipe now, and cancelling a countdown, follow `Accept commands from the panel`. | |
| `Accept plugin updates from the panel` | Lets AFKPanel update a plugin to uMod's current file, and undo that update. Hotwire downloads the file from umod.org by the plugin's file name and installs it only if its SHA-256 is the one AFKPanel named. It first copies the plugin's file, its config (`oxide/config/<name>.json`) and its data (`oxide/data/<name>.json` and `oxide/data/<name>/`) to `oxide/data/Hotwire/plugin-backups/<name>/`, replacing the previous copy, and puts them back if the new file has not loaded within 3 minutes. Refused while a restart is counting down, while another plugin is being changed, for Hotwire itself, and when the copy would be larger than 50 MB. `false` means plugin files change only by hand. | |

| Rule | Value |
| --- | --- |
| Player data | How much player data the account's servers send is chosen by the account owner in AFKPanel: counts only, anonymous, pseudonymous or identified. The plugin asks every 2 minutes and applies the level before anything is sent. Until AFKPanel has answered, or when an answer cannot be read, the level is counts only. There is no key for it in this file. |
| A command AFKPanel sends twice | Answered from `oxide/data/Hotwire/panel_commands.json`, kept for 2 days, not carried out again |
| An update AFKPanel sends while a countdown is running | The countdown becomes an update, moved earlier if the update asked for less time. A restart sent while a countdown is running is refused. |
| `panel.json` changed | Read without a reload. Connecting, reconnecting and detaching take effect at once. |
| `panel.json` written for another folder | The plugin refuses to report: a copied server folder does not report as the original |
| A failed request | Logged once in the console with what to do, then retried with a growing wait, up to 10 minutes apart |

| Console says | Meaning | Do |
| --- | --- | --- |
| clock is more than five minutes out | The machine's clock is wrong | Set it to synchronise automatically |
| no longer accepts this server's key | The server was retired in AFKPanel, or another machine was connected in its place | Make a connect code in AFKPanel and run `hotwire-setup connect` again, or `hotwire connect <code>` in the server console |
| could not reach the panel | The network or AFKPanel is down | Nothing; it keeps trying and the Rust server is unaffected |
| refused the signature, or malformed | A bug | Report it with the plugin version |

## Backups

Requires Hotwire 1.1.41 or later (1.1.58 on Windows), the Linux launcher 1.1.0 or the Windows launcher 1.1.25 or later, and an AFKPanel plan that includes backups. Off until `Back up this server` is `true`. `hotwire backup` says which of the three is missing.

```json
"Backups": {
  "Back up this server": false,
  "Accept backup settings from the panel": true,
  "Back up every this many hours": 6,
  "Back up the world": true,
  "Keep the map file, once per map": true,
  "Back up the server config": true,
  "Back up Oxide": true,
  "Keep every backup from the last this many hours": 24,
  "Keep one a day for this many days": 7,
  "Keep one a week for this many weeks": 4,
  "Keep one a month for this many months": 3,
  "Keep the last backup before each of this many wipes": 3,
  "Largest total size of the backups in MB (0 = no limit)": 0,
  "Never back up with less than this many MB free": 5120,
  "Back up before an update": true,
  "Back up before a wipe": true,
  "Profile": ""
}
```

| Rule | Value |
| --- | --- |
| Where | `backup/<save folder name>/` in the server folder: `<UTC time>-<why>.tar.zst` on Linux or `<UTC time>-<why>.zip` on Windows, a `.meta` file beside it, `backup.log`. The map file is in `maps/`, once per map. Nothing is sent anywhere. |
| The world | The save and the game's databases, copied through the game's own connection right after Rust's save, a few milliseconds per frame, so the copy is consistent while players play |
| The server config | The save folder's `cfg` (owners, moderators, bans, `serverauto.cfg`) and the launcher's settings |
| Oxide | `oxide/plugins`, `config`, `data` and `lang`. Never `oxide/data/Hotwire`, which holds the AFKPanel keys. |
| Keeping | Everything from the last `Keep every backup from the last this many hours`; then the newest of each day, week and month for as long as set; the last backup before each wipe, kept apart; then the size cap, oldest first. The newest backup is never removed. |
| Free space | A backup that would take the disk below `Never back up with less than this many MB free` is refused and says so |
| Before an update or a wipe | The launcher backs up the stopped server first. A wipe entry's `Backup first` says otherwise for that wipe. |
| `Accept backup settings from the panel` | AFKPanel changes these settings only against the settings it last saw. `false` leaves them editable here only. |
| `Profile` | A name AFKPanel sets with the settings. Shown, not used. |

## Status bar

Requires [AdvancedStatus](https://codefling.com/plugins/advanced-status), which is sold outside uMod. Without it this section does nothing and chat carries the countdown.

```json
"Status bar": {
  "Enabled": true,
  "Category": "Hotwire",
  "Order": 10,
  "Bar color, hex (blank = inherit)": "",
  "Text color, hex": "#FFFFFF",
  "Bar fill color, hex": "#C0392B",
  "Icon: built-in sprite path": "assets/icons/stopwatch.png",
  "Icon: local name in oxide/data/AdvancedStatus/Images": "",
  "Icon: URL (used only when the other two are blank)": "",
  "Icon color, hex (blank = the progress color)": "",
  "Fill style: Full, Fills or Drains": "Full",
  "Text left padding (pixels)": 5,
  "Countdown minimum width (characters)": 5,
  "Count seconds in the final minute": false
}
```

| Key | Meaning |
| --- | --- |
| `Bar color, hex (blank = inherit)` | Blank takes AdvancedStatus's own frame, so the bar matches every other plugin's. A bare hex value without `#` is accepted. |
| `Bar fill color, hex` | The fill. The bar reads *Server Restart* on it; the label is a lang string. |
| `Icon: …` | A built-in sprite, then a file in `oxide/data/AdvancedStatus/Images`, then a URL, the first set winning. A sprite path that does not exist logs `[FileSystem] Not Found` once per draw; [GAME-API.md](GAME-API.md) lists paths known to exist. |
| `Fill style: Full, Fills or Drains` | `Full` is solid for the whole countdown; `Drains` empties toward the restart; `Fills` fills toward it |
| `Count seconds in the final minute` | `true` redraws every bar on screen once a second for the last minute |

The bar is created once; its text is updated about once a minute, and AdvancedStatus removes it when the countdown ends.

## Commands

In chat or in the server console. `hw` is a short form.

| Command | Permission | Does |
| --- | --- | --- |
| `hotwire status` | `hotwire.status` | What is counting down, or what is next |
| `hotwire check` | `hotwire.status` | Diagnose the install without restarting anything |
| `hotwire menu` | `hotwire.status` to open, `hotwire.edit` to change | The in-game menu |
| `hotwire list` | `hotwire.status` | Every entry in all three lists, with its index and next occurrence |
| `hotwire now [update\|validate] [seconds]` | `hotwire.restart` | Start a countdown now |
| `hotwire cancel` | `hotwire.cancel` | Cancel the running countdown |
| `hotwire add restart <HH:mm> [pattern]` | `hotwire.edit` | Add a restart |
| `hotwire set <restart\|update> <index> <time\|pattern\|updates\|from\|validate> <value>` | `hotwire.edit` | Edit one in place |
| `hotwire remove <restart\|update> <index>` | `hotwire.edit` | Remove one |
| `hotwire enable\|disable <restart\|update> <index>` | `hotwire.edit` | Turn one on or off |
| `hotwire backup` | `hotwire.status` | Whether backups can run, and the last one |
| `hotwire backup now` | `hotwire.edit` | Back up now, if the plan and the launcher allow it |
| `hotwire connect <code> [panel address]` | Server console, RCON or an admin | Connect this server to AFKPanel with a connect code, from where `hotwire-setup` cannot run, such as a host panel's console |

| Rule | Value |
| --- | --- |
| Indexes | From `hotwire list`, per list: `restart 0` and `update 0` are different entries |
| `hotwire now` with no seconds | The configured countdown, 1 hour by default. `hotwire now 60` is 1 minute; `hotwire now update 300` is 5 minutes with an update. |
| `hotwire cancel` | Stops the countdown and leaves the schedule alone. It no longer works once players have been kicked. |
| Disabling an entry | Cancels its running countdown too |
| Wipe entries | Added and changed in AFKPanel |

### The in-game menu

`hotwire menu` opens a panel over the same schedule: every entry with its next occurrence, and buttons to add, edit, enable, disable and delete.

| Rule | Value |
| --- | --- |
| Run now | Requires Hotwire 1.1.61 or later. Restart, update and restart, or validate and restart, with a countdown of at least 1 minute. It starts the server's configured countdown length, 1 hour by default. Nothing starts until Start the countdown. |
| Install updates | Requires Hotwire 1.1.61 or later. A restart's `Install updates if available`, on or off. |
| Counting from | Requires Hotwire 1.1.61 or later. The day an every-N-days restart counts from. Any day, past or future. |
| Wipes | Listed with their next map from Hotwire 1.1.61. Added and changed in AFKPanel only. |
| Saving | Every change is saved as you make it. There is no save or cancel button. |
| The edit view | Shows the fields the chosen repeat uses, and leads with when the entry next runs, in words, with the rule and the exact moment beneath |
| A new entry | Off until you turn it on |
| A disabled entry | Says Disabled, and beneath it when it would run |
| A change that makes an enabled entry invalid | Disables it and says so |
| Disabling, deleting or rescheduling an entry | Cancels its running countdown, and says so |
| A running countdown | A banner across the top of the menu, with a button to cancel it |

### `hotwire check`

Changes nothing except a probe file it removes again. Run it after installing, after moving the server, and after an Oxide update.

| Reports | |
| --- | --- |
| The server folder | Where the flag files go, whether that came from the config or from Oxide, whether `RustDedicated` is in it, and whether it is writable |
| Flags present now | A flag already in the folder means the next start updates or wipes |
| The schedule | How many entries, what is next, the countdown settings, how many entries the clock-change guard holds, whether the framework check is on |
| The status bar | Whether AdvancedStatus is present |
| AFKPanel | Whether the server is reporting, and if not, why. `NOT REPORTING` after three missed heartbeats, with the time of the last one; the request in flight and how long it has waited; when the plugin list, commands, the ban list and the map were last sent or checked; the sharing level in force. |

## What the plugin does at zero

1. Records the time in `oxide/data/Hotwire/last_fired.json`.
2. Writes the flag files: `UPDATE.flag` for an update, `WIPE.flag` for a wipe. A flag that cannot be written downgrades the entry to a plain restart.
3. Announces.
4. Kicks every connected player, with the reason.
5. Runs `quit`, which saves the world.

The launcher then sees the process exit, acts on the flags (not on `UPDATE.flag` when `hotwire.update_mode` is `off`), deletes each once it has been carried out, and starts the server again.
