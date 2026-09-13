# A Rust server on a blank Windows machine

From nothing to a running, scheduled, connected server. No prior Rust experience assumed.

Roughly **45 minutes**, most of it waiting for downloads. You need a Windows machine you can
administer, about **20 GB free**, and **8 GB of RAM** as a realistic floor for a modded server.

Every command below is run in **PowerShell as Administrator** unless it says otherwise. You can
stop after step 6 and have a perfectly good server; steps 7-9 add the panel, which is optional.

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
C:\steamcmd\steamcmd.exe +force_install_dir C:\rustserver +login anonymous +app_update 258550 +quit
```

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

Make it long and unique. **This is a root password for your server**, and the launcher refuses to
start if it looks weak or is left at an example value.

```powershell
# Generates one and copies it to your clipboard. Save it in your password manager NOW.
-join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }) | Set-Clipboard
```

Create `C:\rustserver\secrets.bat` containing it, and **never commit this file anywhere**:

```bat
@echo off
set "RCON_PASSWORD=the-long-thing-you-just-generated"
```

## 6. Install Hotwire and start the server

Hotwire is the launcher and the plugin. The launcher restarts your server on a schedule, separates
"restart" from "install an update", and keeps a crash loop from becoming a disk full of logs.

1. Download it: **https://github.com/xman2000/hotwire**
2. Put `hotwire.bat` in `C:\rustserver\`
3. Put `Hotwire.cs` in `C:\rustserver\oxide\plugins\`
4. Open `hotwire.bat` and set your server's name, description and the values you want. The top of
   the file explains every option, and **every schedule ships disabled**, so installing it cannot
   restart anything by surprise.

Then start it:

```powershell
cd C:\rustserver
.\hotwire.bat
```

The first start takes several minutes — it generates the map. When you see the server appear in
Rust's server browser under your hostname, you have a working Rust server.

**Stop here if that is all you wanted.** Everything above is free, open source, and yours.

---

## 7. Check the machine can talk to the panel

```powershell
cd C:\rustserver
.\hotwire-connect.ps1 selftest
.\hotwire-connect.ps1 doctor
```

`selftest` proves this machine signs requests correctly. `doctor` checks it can reach the panel,
that its clock is close enough, and that it can find your server. **Neither writes anything**, so
run them as often as you like.

If `doctor` complains about the clock, fix it before going further — a drifting clock makes every
later request fail with a message that explains nothing:

```powershell
w32tm /resync
```

## 8. Get a code and connect

In the panel: **Servers → Connect a server**. Then:

```powershell
.\hotwire-connect.ps1 connect -Code HW-XXXX-XXXX
```

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
| The panel shows the server but no player counts | the plugin is not loaded — check `oxide\logs\` for a compile error |

**Disconnecting** is one command and leaves everything running:

```powershell
.\hotwire-connect.ps1 detach
```
