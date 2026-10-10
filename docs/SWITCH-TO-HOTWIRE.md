# Switch a server you already run to Hotwire

This guide moves a Rust server that runs Oxide from its own start script to Hotwire's launcher. The save, map, plugins
and players stay as they are.

| Requirement | Value |
| --- | --- |
| Time | About 15 minutes, plus one server restart |
| The server | Runs Oxide, on Windows or Linux |
| Your start script | The `.bat` or `.sh` that starts the server now |

## 1. Convert your start script

1. Open https://afkpanel.com/get-started and choose your start script. A file that holds a password, a Discord webhook,
   a Steam login or a key is refused in your browser and not sent.
2. Read the report. A problem listed under **Needs you** stops the conversion: fix it in your script and choose the
   file again.
3. Select **Download hotwire-settings.zip**. It holds `hotwire.cfg`, with your settings, and `hotwire-secrets.cfg`.
4. Note the rows under **Not carried**. Each one names the line in your script and what to do with it.

![The converter's result: the settings download, the settings carried, those not carried, and what the launcher does](https://afkpanel.com/images/docs/converter.webp)

## 2. Stop the server

Stop the server and your old start script. Keep the old script: to go back, run it again.

## 3. Install the launcher

1. Download Hotwire:
   - Windows: https://afkpanel.com/get/windows
   - Linux: https://afkpanel.com/get/linux
2. Extract it into the server's folder, the one that holds `RustDedicated.exe` or `RustDedicated`. The launcher treats
   its own folder as the server's.

## 4. Add your settings

1. Extract `hotwire-settings.zip` into the same folder.
2. If the folder already had a `hotwire-secrets.cfg`, keep that one.

See [hotwire.cfg](https://afkpanel.com/docs/hotwire-cfg) for the file's format.

## 5. Set the RCON password, if you use RCON

If you use an RCON tool, put its password in `hotwire-secrets.cfg`. Without one, RCON is off. See
[The RCON password file](https://afkpanel.com/docs/rcon-password).

## 6. Move your own commands

If your old script ran commands of its own before starting the server, such as a backup, or after updating it, move
them to `hotwire-before` or `hotwire-after`. See
[Run your own commands](https://afkpanel.com/docs/your-own-commands). Skip this step if it ran none.

## 7. Check the settings

| Platform | Command |
| --- | --- |
| Windows | `.\hotwire.bat check` |
| Linux | `./hotwire.sh check` |

Fix each problem it lists and run it again. See [Check your settings](https://afkpanel.com/docs/check-your-settings).

## 8. Start the server

| Platform | Command |
| --- | --- |
| Windows | `.\hotwire.bat` |
| Linux | `./hotwire.sh` |

Leave the window or terminal open: the launcher starts the server again whenever it stops. On Linux, a systemd service
keeps it running after you log out; see [Install a Rust server on Ubuntu](https://afkpanel.com/docs/install-linux).

## 9. Add the plugin

Optional. See [Add or update the Hotwire plugin](https://afkpanel.com/docs/hotwire-plugin).

## Go back to your old script

1. Close the launcher's window, or stop `hotwire.sh`.
2. Run your old start script.

The launcher's files can stay in the folder: nothing runs them unless you do.
