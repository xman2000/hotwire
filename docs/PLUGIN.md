# Add or update the Hotwire plugin

The Hotwire plugin schedules announced restarts and updates, counts players down, and reports to AFKPanel once
connected. With AFKPanel Pro, it also runs wipes and backups. It needs Oxide. The launcher works without it.

## Add the plugin

1. Get `Hotwire.cs`. It is in the `plugin` folder of the Hotwire download for Windows and Linux, and on its own at
   https://afkpanel.com/get/Hotwire.cs.
2. Put it in the server's `oxide/plugins` folder. If the folder does not exist, start the server once with Oxide
   installed, or create it.
3. Oxide compiles it within a few seconds. To load it at once, run in the server console:

   ```console
   oxide.load Hotwire
   ```

The plugin writes `oxide/config/Hotwire.json` with every schedule turned off, so adding it cannot restart anything.

## Permissions

| Permission | Allows |
| --- | --- |
| `hotwire.status` | See the schedule, open the menu, run `check` and `list` |
| `hotwire.restart` | Start a countdown now |
| `hotwire.cancel` | Cancel a running countdown |
| `hotwire.edit` | Add, change, remove, enable and disable schedule entries |

Oxide's `admin` group, which every server owner joins, gets all four when the plugin first loads. Each is given once,
so one you take away from the group with `oxide.revoke group admin <permission>` stays away. Give them to anyone else
with `oxide.grant`, for example `oxide.grant user <steamid> hotwire.status`.

## Check that it loaded

Run `hotwire status`, or `hw status`, in the server console. A compile error is written to `oxide/logs/`.

## Change what the plugin shares with AFKPanel

The `Panel` section of `oxide/config/Hotwire.json` sets what the plugin sends to AFKPanel and what it accepts from it.
After you edit the file, run `oxide.reload Hotwire` in the server console.

| Setting | Default | `false` means |
| --- | --- | --- |
| `Report to the panel when connected` | `true` | The plugin stops reporting. The server stays connected. |
| `Accept commands from the panel` | `true` | Commands sent from AFKPanel do nothing on this server. |
| `Discord account linking` | `true` | Players cannot use `/link`. |
| `Report the item list` | `true` | AFKPanel cannot offer items by name. |

With `Discord account linking` on, a player types `/link` and the code from your Discord server to link their Discord
account.

## Update the plugin

1. Replace `oxide/plugins/Hotwire.cs` with the new file.
2. Run `oxide.reload Hotwire` in the server console.

The schedule in `oxide/config/Hotwire.json` and the connection to AFKPanel in `oxide/data/Hotwire/` are kept.

## Connect it to AFKPanel

See [Connect a server](https://afkpanel.com/docs/connect-a-server).

## Remove the plugin

1. If the server is connected to AFKPanel, disconnect it: see
   [Reconnect, move or disconnect a Rust server](https://afkpanel.com/docs/connect-a-server#reconnect-move-or-disconnect-a-rust-server).
2. Run `oxide.unload Hotwire` in the server console.
3. Delete `oxide/plugins/Hotwire.cs`.
