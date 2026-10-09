# Add or update the Hotwire plugin

The Hotwire plugin schedules announced restarts, updates and wipes, counts players down, and reports to AFKPanel once
connected. It needs Oxide. The launcher works without it.

## Add the plugin

1. Get `Hotwire.cs`. It is in the `plugin` folder of the Hotwire download for Windows and Linux, and on its own at
   https://afkpanel.com/get/Hotwire.cs.
2. Put it in the server's `oxide/plugins` folder. If the folder does not exist, start the server once with Oxide
   installed, or create it.
3. Oxide compiles it within a few seconds. To load it at once, run in the server console:

   ```console
   oxide.load Hotwire
   ```

4. Grant the permissions to your admin group:

   ```console
   oxide.grant group admin hotwire.status
   oxide.grant group admin hotwire.restart
   oxide.grant group admin hotwire.cancel
   oxide.grant group admin hotwire.edit
   ```

The plugin writes `oxide/config/Hotwire.json` with every schedule turned off, so adding it cannot restart anything.

## Permissions

| Permission | Allows |
| --- | --- |
| `hotwire.status` | See the schedule, open the menu, run `check` and `list` |
| `hotwire.restart` | Start a countdown now |
| `hotwire.cancel` | Cancel a running countdown |
| `hotwire.edit` | Add, change, remove, enable and disable schedule entries |

## Check that it loaded

Run `hotwire status` in the server console. A compile error is written to `oxide/logs/`.

## Update the plugin

1. Replace `oxide/plugins/Hotwire.cs` with the new file.
2. Run `oxide.reload Hotwire` in the server console.

The schedule in `oxide/config/Hotwire.json` and the connection to AFKPanel in `oxide/data/Hotwire/` are kept.

## Connect it to AFKPanel

See [Connect a server](https://afkpanel.com/docs/connect-a-server).

## Remove the plugin

1. If the server is connected to AFKPanel, disconnect it: see
   [Connect a server](https://afkpanel.com/docs/connect-a-server).
2. Run `oxide.unload Hotwire` in the server console.
3. Delete `oxide/plugins/Hotwire.cs`.
