# A Rust server on a blank Windows machine

From nothing to a running, scheduled, connected server. No prior Rust experience assumed.

Roughly **45 minutes**, most of it waiting for downloads. You need a Windows machine you can
administer, about **20 GB free**, and **8 GB of RAM** as a realistic floor for a modded server.

Every command below is run in **PowerShell as Administrator** unless it says otherwise. You can
stop after step 6 and have a perfectly good server; steps 7-9 add the panel, which is optional.

> **Rather not type steps 1–6?** [`setup/hotwire-setup.bat`](../setup/README.md) does them one
> confirmed step at a time: the clock, SteamCMD, Rust on the branch you choose, Oxide, the start script
> with its ports, an RCON password and the firewall, then the Hotwire plugin and connecting to the panel.
> Put `hotwire-setup.bat` and `hotwire-setup.ps1` together in any folder, right-click the `.bat`, choose
> **Run as administrator** and pick **Install**. When it finishes, fill in your server's name in
> `hotwire.bat` (step 6, item 4) and start it.

> **A second server on the same machine?** Use setup: it gives each server its own ports and firewall
> rules, and never mixes the two up. By hand, see *Running a second server* at the end.

> **What this never does:** nothing here, and nothing Hotwire does later, can stop your server
> starting. If the panel is slow, unreachable or gone, your server still boots, restarts and
> updates. That is a design rule, not a hope.

---

## 1. Open the ports

Rust needs three, and **one of them must not be public**.

| port | protocol | who needs it |
|---|---|---|
| 28015 | UDP | players |
| 28017 | UDP | the server browser |
| 28016 | TCP | **RCON — you, and nobody else** |

```powershell
New-NetFirewallRule -DisplayName "Rust game"  -Direction Inbound -Protocol UDP -LocalPort 28015 -Action Allow
New-NetFirewallRule -DisplayName "Rust query" -Direction Inbound -Protocol UDP -LocalPort 28017 -Action Allow
```

**Do not open 28016 to the internet.** RCON is remote control of the machine: anyone who reaches it
with the password runs commands on your server. Leave it closed and reach it over a VPN, or from the
machine itself. If you must open it, restrict it to your own address:

```powershell
New-NetFirewallRule -DisplayName "Rust RCON (me only)" -Direction Inbound -Protocol TCP `
  -LocalPort 28016 -RemoteAddress "YOUR.IP.HERE" -Action Allow
```

## 2. Install SteamCMD

This is Valve's downloader. Rust's server files come through it.

```powershell
New-Item -ItemType Directory -Force C:\steamcmd | Out-Null
Invoke-WebRequest https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip -OutFile C:\steamcmd\steamcmd.zip
Expand-Archive C:\steamcmd\steamcmd.zip -DestinationPath C:\steamcmd -Force
Remove-Item C:\steamcmd\steamcmd.zip
```

Run it once so it can update itself — it will print a lot and end at a `Steam>` prompt:

```powershell
C:\steamcmd\steamcmd.exe +quit
```

## 3. Download the Rust server

App **258550** is the dedicated server. It is free and needs no Steam account — `anonymous` is a
real login, not a placeholder.

```powershell
C:\steamcmd\steamcmd.exe +force_install_dir C:\rustserver +login anonymous +app_update 258550 -beta public +quit
```

`-beta public` names the normal game. Steam keeps an install on whatever branch that machine used last, so
naming it matters if this machine has ever run a test branch. For Facepunch's test build, write
`-beta staging` instead — and then set `STEAM_BRANCH=staging` in `hotwire.bat` in step 6.

About 12 GB. Go and make a coffee. When it finishes you should have `C:\rustserver\RustDedicated.exe`.

## 4. Install Oxide

Oxide (uMod) is what lets the server run plugins. Hotwire is a plugin, so this is required if you
want to connect to the panel later.

```powershell
Invoke-WebRequest "https://umod.org/games/rust/download" -UserAgent "Mozilla/5.0" -OutFile C:\rustserver\OxideMod.zip
Expand-Archive C:\rustserver\OxideMod.zip -DestinationPath C:\rustserver -Force
Remove-Item C:\rustserver\OxideMod.zip
```

You will not see much yet — Oxide creates its folders the first time the server starts.

## 5. Pick an RCON password

Make it long and unique. **This is a root password for your server.** The launcher refuses to start
if it is shorter than 8 characters, still the example value, or has a double quote in it.

```powershell
# Generates one and copies it to your clipboard. Save it in your password manager NOW.
-join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }) | Set-Clipboard
```

Create `C:\rustserver\secrets.bat` containing it, and **never commit this file anywhere**:

```bat
@echo off
set "RCON_PASSWORD=the-long-thing-you-just-generated"
```

If you type your own rather than generating one: no double quote, do not start it with a semicolon, and
write a percent sign as `%%`.

## 6. Install Hotwire and start the server

Hotwire is the launcher and the plugin. The plugin schedules announced restarts; the launcher starts the
server again when it exits, separates "restart" from "install an update", and keeps a crash loop from
becoming a disk full of logs.

1. Download it: **https://github.com/xman2000/hotwire**
2. Put `hotwire.bat` in `C:\rustserver\`, beside `RustDedicated.exe`. It uses its own folder as the
   server's folder, so there is no path to set.
3. Put `Hotwire.cs` in `C:\rustserver\oxide\plugins\`. Create the `plugins` folder if it is not there
   yet — Oxide makes it on the first start.
4. Open `hotwire.bat` in Notepad. In section 4.3 fill in `SERVER_HOSTNAME` and `SERVER_DESCRIPTION`; in
   section 4.2, `SERVER_MAXPLAYERS` if you want a number other than the game's. `SERVER_TAGS` is optional.
   `SERVER_SEED` in section 4.1 is the map: install picked a random one. Change it now if you want a
   particular map — after the server has been played, a new seed is a new map.
   Each option is explained beside it. Anything left empty is the game's own default. The plugin's
   **schedules all ship disabled**, so installing it cannot restart anything by surprise.

Check it, then start it:

```powershell
cd C:\rustserver
.\hotwire.bat check
.\hotwire.bat
```

The first start takes several minutes — it generates the map. When you see the server appear in
Rust's server browser under the name you set (or "My Untitled Rust Server" if you left it empty), you
have a working Rust server.

**Stop here if that is all you wanted.** Everything above is free, open source, and yours.

---

## 7. Check the machine can talk to the panel

```powershell
cd C:\rustserver
.\hotwire-setup.bat doctor
```

`doctor` checks everything in one go: that this machine signs requests correctly, that it can reach
the panel, that its clock is close enough, and that it can find your server. **It writes nothing**,
so run it as often as you like.

If `doctor` complains about the clock, fix it before going further — a drifting clock makes every
later request fail with a message that explains nothing:

```powershell
w32tm /resync
```

## 8. Connect it

```powershell
.\hotwire-setup.bat connect
```

It tells you where to get a code and waits while you fetch it — **Servers → Connect a server** in
the panel — then asks you to paste it. You never type the code as part of a command, so it does not
end up in your PowerShell history.

It re-checks everything `doctor` checks, shows you exactly which files it will write, and asks
before writing any of them.

## 9. Restart the server

```powershell
# stop hotwire.bat with Ctrl-C, then
.\hotwire.bat
```

The plugin picks up its key on load and starts reporting. Within a minute or two your server appears
in the panel with a live status.

---

## If something goes wrong

| what you see | what it means |
|---|---|
| `doctor` says the clock is too far out | `w32tm /resync`, then try again |
| `connect` says the code is invalid or expired | codes last 60 minutes and work once — make another |
| The server browser never shows your server | port 28017/UDP is not open, or your host blocks it |
| The server stops after "consecutive crashes" on a machine with another server | both servers are on the same ports — give one different ports in section 4.2 |
| The panel shows the server but no player counts | the plugin is not loaded — check `oxide\logs\` for a compile error |

**Disconnecting** is one command and leaves everything running:

```powershell
.\hotwire-setup.bat detach
```

## Running a second server

Setup does this for you. By hand, the second server needs:

1. **Its own folder**, for example `C:\rust-dev`, with its own `hotwire.bat` and `secrets.bat`. Copying
   the whole first server's folder is fine: `hotwire.bat` follows its own folder, so the copy runs the
   copy. Do not copy `hotwire\connect.json` and the keys if you plan to connect it — or run connect in the
   copy and answer yes to connecting it as a new server.
2. **Its own ports.** In the second `hotwire.bat`, section 4.2, use for example `28115`, `28117` and `28116`
   for `server.port`, `server.queryport` and `rcon.port`, and open UDP 28115 and 28117 as in step 1.
3. **Its own branch**, if it differs: `STEAM_BRANCH` in section 1.

Both may share `C:\steamcmd`: the launchers take turns using it.
