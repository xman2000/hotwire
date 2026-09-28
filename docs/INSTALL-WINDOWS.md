# Install a Rust server on Windows

This guide installs a Rust server with Oxide and Hotwire on a Windows machine, then connects it to AFKPanel. It assumes
no Rust experience.

| Requirement | Value |
| --- | --- |
| Time | About 45 minutes, most of it downloading |
| Free disk space | About 20 GB |
| Memory | 8 GB for a server with plugins |
| Access | An administrator account on the machine |

Run every command in **PowerShell as Administrator** unless the step says otherwise.

Steps 1 to 6 give you a working server. Steps 7 to 9 connect it to AFKPanel and are optional.

## Let the setup script do steps 1 to 6

`hotwire-setup.bat` runs steps 1 to 6 for you and asks before each one: the clock, SteamCMD, Rust on the branch you
choose, Oxide, the start script with its ports, an RCON password and the firewall, then the Hotwire plugin. It can also
connect the server to AFKPanel.

1. Put `hotwire-setup.bat` and `hotwire-setup.ps1` in the same folder.
2. Right-click `hotwire-setup.bat` and select **Run as administrator**.
3. Select **Install**.
4. When it finishes, fill in your server's name in `hotwire.bat` (step 6, item 4) and start the server.

For a second server on the same machine, use the setup script. It gives each server its own ports and firewall rules.
To do it by hand, see [Run a second server](#run-a-second-server).

Nothing in this guide, and nothing Hotwire does later, can stop your server starting. If AFKPanel is slow, unreachable
or gone, the server still boots, restarts and updates.

## 1. Open the ports

Rust uses three ports. Open two of them. Keep RCON closed to the internet.

| Port | Protocol | Used by | Open to the internet |
| --- | --- | --- | --- |
| 28015 | UDP | Players | Yes |
| 28017 | UDP | The Steam server browser | Yes |
| 28016 | TCP | RCON | No |

```powershell
New-NetFirewallRule -DisplayName "Rust game"  -Direction Inbound -Protocol UDP -LocalPort 28015 -Action Allow
New-NetFirewallRule -DisplayName "Rust query" -Direction Inbound -Protocol UDP -LocalPort 28017 -Action Allow
```

RCON controls the server: anyone who reaches it with the password can run commands on it. Reach it from the machine
itself or over a VPN. If you must open it, allow only your own address:

```powershell
New-NetFirewallRule -DisplayName "Rust RCON (me only)" -Direction Inbound -Protocol TCP `
  -LocalPort 28016 -RemoteAddress "YOUR.IP.HERE" -Action Allow
```

## 2. Install SteamCMD

SteamCMD is Valve's command-line downloader. Rust's server files come through it.

```powershell
New-Item -ItemType Directory -Force C:\steamcmd | Out-Null
Invoke-WebRequest https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip -OutFile C:\steamcmd\steamcmd.zip
Expand-Archive C:\steamcmd\steamcmd.zip -DestinationPath C:\steamcmd -Force
Remove-Item C:\steamcmd\steamcmd.zip
```

Run it once so it updates itself. It ends at a `Steam>` prompt.

```powershell
C:\steamcmd\steamcmd.exe +quit
```

## 3. Download the Rust server

The dedicated server is Steam app 258550. It is free, and `anonymous` is a real login: no Steam account is needed.

```powershell
C:\steamcmd\steamcmd.exe +force_install_dir C:\rustserver +login anonymous +app_update 258550 -beta public +quit
```

`-beta public` selects the normal game. Steam keeps an install on the branch the machine used last, so name it if the
machine has ever run a test branch. For Facepunch's test build, use `-beta staging` instead, and set
`STEAM_BRANCH=staging` in `hotwire.bat` in step 6.

The download is about 12 GB. When it finishes, `C:\rustserver\RustDedicated.exe` exists.

## 4. Install Oxide

Oxide (uMod) lets the server run plugins. Hotwire is a plugin, so you need Oxide to connect to AFKPanel.

```powershell
Invoke-WebRequest "https://umod.org/games/rust/download" -UserAgent "Mozilla/5.0" -OutFile C:\rustserver\OxideMod.zip
Expand-Archive C:\rustserver\OxideMod.zip -DestinationPath C:\rustserver -Force
Remove-Item C:\rustserver\OxideMod.zip
```

Oxide creates its folders the first time the server starts.

## 5. Set an RCON password

The RCON password gives full control of the server. Make it long and unique. The launcher does not start if the
password is shorter than 8 characters, is still the example value, or contains a double quote.

1. Generate a password. This copies it to your clipboard:

   ```powershell
   -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }) | Set-Clipboard
   ```

2. Save it in your password manager.
3. Create `C:\rustserver\secrets.bat` with the password in it. Never commit this file anywhere.

   ```bat
   @echo off
   set "RCON_PASSWORD=the-long-thing-you-just-generated"
   ```

If you type your own password: do not use a double quote, do not start it with a semicolon, and write a percent sign
as `%%`.

## 6. Install Hotwire and start the server

Hotwire has two parts. The plugin schedules announced restarts. The launcher starts the server again when it exits,
tells a restart apart from an update, and stops a crash loop from filling the disk with logs.

1. Download Hotwire from https://github.com/xman2000/hotwire.
2. Put `hotwire.bat` in `C:\rustserver\`, next to `RustDedicated.exe`. It treats its own folder as the server folder,
   so there is no path to set.
3. Put `Hotwire.cs` in `C:\rustserver\oxide\plugins\`. If the `plugins` folder does not exist yet, create it.
4. Open `hotwire.bat` in Notepad. The settings most servers change are at the top, in section 1:

   | Setting | What it sets |
   | --- | --- |
   | `SERVER_HOSTNAME` | The server's name in the browser |
   | `SERVER_DESCRIPTION` | The server's description |
   | `SERVER_TAGS` | Browser tags (optional) |
   | `SERVER_MAXPLAYERS` | Player limit, if not the game's |
   | `SERVER_IDENTITY` | The save folder's name |
   | `SERVER_SEED` | The map |
   | `SERVER_WORLDSIZE` | The map's size |
   | `SERVER_PORT`, `SERVER_QUERYPORT`, `RCON_PORT` | The three ports from step 1 |

   If you used the setup script, it picked a random `SERVER_SEED`. To play a particular map, change it now: after the
   server has been played, a new seed is a new map. Each option is explained next to it in the file, and an empty
   option uses the game's default. The plugin's schedules are all off when it is installed, so it cannot restart
   anything until you turn one on.
5. Check the settings, then start the server:

   ```powershell
   cd C:\rustserver
   .\hotwire.bat check
   .\hotwire.bat
   ```

The first start takes several minutes while the server generates the map. When the server appears in Rust's server
browser under your name (or "My Untitled Rust Server" if you left it empty), it is working.

This is a complete server. Everything so far is free and open source. The next steps connect it to AFKPanel.

## 7. Check that the machine can reach AFKPanel

```powershell
cd C:\rustserver
.\hotwire-setup.bat doctor
```

`doctor` checks that the machine signs requests correctly, that it can reach AFKPanel, that its clock is accurate
enough, and that it can find your server. It changes nothing, so you can run it at any time.

If `doctor` reports the clock, fix it before you continue. A wrong clock makes every later request fail with an error
that does not mention the clock.

```powershell
w32tm /resync
```

## 8. Connect the server

1. Run `connect`:

   ```powershell
   .\hotwire-setup.bat connect
   ```

2. In AFKPanel, select **Connect a server** and copy the connect code.
3. Paste the code when `connect` asks for it. The code is not part of the command, so it stays out of your PowerShell
   history.

`connect` repeats the `doctor` checks, lists the files it will write, and asks before writing them.

## 9. Restart the server

Stop `hotwire.bat` with Ctrl+C, then start it again:

```powershell
.\hotwire.bat
```

The plugin loads its key and starts reporting. The server appears in AFKPanel within about 2 minutes.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `doctor` says the clock is too far out | The clock has drifted | Run `w32tm /resync`, then run `doctor` again |
| `connect` says the code is invalid or expired | A code works for 60 minutes, once | Make a new code |
| The server never appears in the server browser | Port 28017/UDP is closed, or your host blocks it | Open the port, or ask your host |
| The server stops after "consecutive crashes", on a machine with another server | Both servers use the same ports | Give one of them different ports in section 1 |
| The server is in AFKPanel but shows no player counts | The plugin is not loaded | Look in `oxide\logs\` for a compile error |

## Disconnect the server

```powershell
.\hotwire-setup.bat detach
```

The server keeps running.

## Run a second server

The setup script does this for you. By hand, the second server needs:

1. Its own folder, for example `C:\rust-dev`, with its own `hotwire.bat` and `secrets.bat`. You can copy the
   first server's folder: `hotwire.bat` follows its own folder, so the copy runs the copy. If you plan to connect the
   copy, do not copy `hotwire\connect.json` and the keys, or run `connect` in the copy and choose to connect it as a
   new server.
2. Its own ports. In the second `hotwire.bat`, section 1, set `SERVER_PORT`, `SERVER_QUERYPORT` and `RCON_PORT`,
   for example to 28115, 28117 and 28116. Open UDP 28115 and 28117 as in step 1.
3. Its own branch, if it differs: `STEAM_BRANCH` in section 2.

Both servers can share `C:\steamcmd`. The launchers take turns using it.
