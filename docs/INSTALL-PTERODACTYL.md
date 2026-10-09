# Add Hotwire to a Rust server on Pterodactyl or Pelican

This guide adds Hotwire to a Rust server that your host runs on Pterodactyl or Pelican, then connects it to AFKPanel.
You need only the host panel in your browser: no shell, no SSH and no change on the host's side.

This page uses these terms:

| Term | Meaning |
| --- | --- |
| Host panel | The Pterodactyl or Pelican website where you start, stop and configure your Rust server |
| Rust server | The game server: `RustDedicated`, its save and its plugins |
| Hotwire | The plugin, `Hotwire.cs`, which runs inside the Rust server and reports to AFKPanel |
| AFKPanel | The service at afkpanel.com |

| Requirement | Value |
| --- | --- |
| Time | About 10 minutes |
| Host panel | Pterodactyl or Pelican, with the Rust egg |
| Access in the host panel | Console, Files and Startup |
| Modding framework | Oxide |
| Hotwire | 1.1.55 or later |

Tested on Pterodactyl 1.15.1 with Wings 1.13.3 and the Rust egg that ships with Pterodactyl. Pelican uses the same
Wings and the same environment, so Hotwire sees no difference; Pelican has not been tested.

Nothing Hotwire does can stop your Rust server starting. If AFKPanel is slow, unreachable or gone, the Rust server still
boots and restarts.

## 1. Turn on Oxide

Hotwire is an Oxide plugin. Skip this step if your Rust server already loads Oxide plugins.

1. In the host panel, open **Startup**.
2. Set **Modding Framework** to `oxide`.
3. Restart the Rust server.

The Rust egg installs Oxide when the Rust server starts. When it has started, **Files** shows an `oxide` folder.

## 2. Add the plugin

1. Download `Hotwire.cs` from https://afkpanel.com/get/Hotwire.cs.
2. In the host panel, open **Files**, then `oxide`, then `plugins`.
3. Select **Upload** and choose `Hotwire.cs`.

Oxide compiles and loads the plugin within a few seconds, with no restart. The **Console** shows a line that starts
with `Loaded plugin Hotwire`.

## 3. Connect the server

1. In AFKPanel, open **Servers** and select **Connect a server**. Copy the code.
2. In the host panel, open **Console**, type this command with your code, and press Enter:

   ```console
   hotwire connect HW-4K2P-9XQR
   ```

A code works once, for 60 minutes. The Console shows `This server is reporting.` The Rust server appears in AFKPanel
within a minute, named after its **Server Name**.

## What changes on a host panel

The host panel starts and updates the Rust server, not Hotwire's launcher. AFKPanel knows the Rust server runs on
Pterodactyl or Pelican and shows **Host: Pterodactyl or Pelican** on its Info tab.

Each plan includes the same features as on any other host; see [Plans](https://afkpanel.com/docs/plans). What the host
changes:

| Feature | On Pterodactyl or Pelican |
| --- | --- |
| Monitoring, alerts, logs, players, plugins, map | Yes |
| Restarts and the restart schedule | Yes. Every start also updates Rust and Oxide. |
| Plugin updates from AFKPanel | Yes |
| Memory limit check | Yes: a warning at 90% of the memory limit the host set |
| Backups | No. Use **Backups** in the host panel. |
| Wipes from AFKPanel | No |
| Permanent convar changes | No. Use **Startup** in the host panel. |

### Every start is an update

The Rust egg installs the newest Rust and the newest Oxide every time the Rust server starts. So every restart, from
Hotwire, AFKPanel or the host panel, is also an update.

On the first Thursday of the month, Rust's update reaches Steam before Oxide's update for it. A Rust server restarted
in between gets the new Rust with the old Oxide, which can fail to load; without Oxide, Hotwire does not run until the
next restart. So on that day, a restart from Hotwire's schedule waits until Oxide's release is out, for up to 2 hours.
A restart you start yourself never waits.

To change the wait, set `On a Pterodactyl or Pelican server, hold a scheduled restart for Oxide (hours)` in
`oxide/config/Hotwire.json`. `0` turns it off.

### Restarts

When Hotwire or AFKPanel restarts the Rust server, the Rust server stops and Wings starts it again. Wings does this
because it counts a stop it did not ask for as a crash. If your host has turned off restarting crashed servers, a
restart from Hotwire leaves the Rust server stopped, and AFKPanel shows it as down.

A restart from the host panel, with its restart button or a schedule, is not one AFKPanel asked for:

| How long the Rust server is stopped | What AFKPanel shows | E-mail |
| --- | --- | --- |
| Under about a minute | Nothing | No |
| Longer | **Unreachable**, until it reports again | No |
| More than 10 minutes since its last report | Down | Yes, the Down e-mail |

On the tested host, a restart from the host panel with no update due took about 50 seconds.

### Use one schedule

The host panel's **Schedules** can restart the Rust server too. AFKPanel cannot see those schedules. Use one of the
two: Hotwire's schedule warns players in game before a restart and waits for Oxide on update day.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| No `oxide` folder in **Files** | **Modding Framework** is `vanilla`, or the Rust server has not started since you changed it | Repeat step 1 |
| The Console says the code is invalid or expired | A code works for 60 minutes, once | Make a new code |
| The Console says the panel no longer accepts this server's key | The Rust server was retired in AFKPanel, or another Rust server was connected in its place | Make a new code and run `hotwire connect` again |
| The Rust server stays stopped after a restart from Hotwire | The host does not restart a server that stops | Start it in the host panel, and restart it from the host panel instead |
| After the first Thursday's update, AFKPanel says the Rust server is running without Oxide or Carbon | Oxide's release for the new Rust was not out when it started | Restart it when Oxide's release is out |

## Remove Hotwire

1. In the host panel, open **Files**, then `oxide`, then `plugins`, and delete `Hotwire.cs`.
2. In AFKPanel, open the Rust server's **Server settings** and retire it.

The Rust server keeps running.
