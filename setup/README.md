# hotwire-setup

Installs a Rust server with Oxide, and connects it to [Hotwire Panel](https://hotpanel.on-forge.com)
as well. **Every step asks first.** Installing something that is not there yet defaults to yes; replacing
or removing anything defaults to no.

| file | platform |
|---|---|
| `hotwire-setup.bat` + `hotwire-setup.ps1` | Windows. Double-click the `.bat`; the `.ps1` does the work. |
| `hotwire-setup.sh` | Linux. Connect only — installing on Linux is still [the guide](../docs/INSTALL-LINUX.md). |

## Windows

1. Put **`hotwire-setup.bat`** and **`hotwire-setup.ps1`** in the folder you want the server in, for
   example `C:\rustserver`.
2. **Right-click `hotwire-setup.bat` → Run as administrator.**
3. It checks five things first, and changes nothing while it does:
   - is a Rust server installed in this folder, and which build
   - is the clock right (against Steam's servers, so it never contacts the panel)
   - is Hotwire installed: `hotwire.bat` here, `Hotwire.cs` in `oxide\plugins`
   - is the RCON password in `secrets.bat` one `hotwire.bat` will accept
   - is it connected to Hotwire Panel, and as what
4. Pick from the menu. It suggests the next step from what it found.

Double-clicking works too; without Administrator, install can only *report* on the firewall and the
clock rather than fix them. From a console, name the command: `.\hotwire-setup.bat connect`.

**Why two files.** Windows will not run a PowerShell script when you double-click it, and by default
refuses to run one at all. The `.bat` starts that one script for that one window, changes no Windows
setting, and is short enough to read first.

## Commands

```
install   SteamCMD, Rust, Oxide, the start script, an RCON password, the firewall,
          the Hotwire plugin, and connecting to Hotwire Panel               (Windows)
doctor    check this machine is ready to connect. read-only, changes nothing
connect   connect to the panel. asks for the code; nothing is written until you confirm
status    what this server is connected to
detach    disconnect. the server keeps running
```

Linux: `./hotwire-setup.sh doctor` and so on. It needs bash, curl, openssl, and either jq or python3.

## install

| step | what | changes |
|---|---|---|
| 1 | Windows, PowerShell 5.1, Administrator, memory, **the clock** | only if the clock is out and you say yes (`w32tm /resync`) |
| 2 | Where the server goes: **this folder unless you say otherwise** | nothing yet |
| 3 | SteamCMD into `C:\steamcmd`, where `hotwire.bat` looks for it | reuses one already there |
| 4 | The Rust server, app 258550, about 12 GB. Defaults to yes | the server folder |
| 5 | Oxide, checked to be the Windows build and a real archive before it is unpacked. Defaults to yes; no leaves a vanilla server, and the start script is set up to stay vanilla | the server folder |
| 6 | **Start script**: `hotwire.bat`, with `ROOT` and `STEAMCMD` set for this folder, `INSTALL_FRAMEWORK=0` when there is no Oxide, and Windows line endings. Defaults to yes; no means you use your own start script, and step 8 is skipped | `hotwire.bat`; an existing one is left alone |
| 7 | **Hotwire plugin**, asked separately, defaults to yes. Scheduled, announced restarts. Skipped without Oxide | `oxide\plugins\Hotwire.cs` |
| 8 | **RCON password**, walked through: type your own (hidden, twice, checked against the launcher's rules), or press Enter for 32 random letters and digits, shown once and copied to the clipboard | `secrets.bat`, readable only by Administrators and you; an existing valid one is left alone, an invalid one replaced only if you say yes |
| 9 | **Windows Firewall**: reports what is already open or blocked, then opens UDP 28015 and 28017; TCP 28083 (Rust+) only if asked | rules in the group `Hotwire` |
| 10 | **Hotwire Panel**, asked last, defaults to yes. Yes runs `connect`; no changes nothing | only if yes: the three files under *doctor and connect* |

It never opens RCON (TCP 28016), and warns if something else has. It never touches a Rust server it
did not install: a folder with `RustDedicated.exe` and no `hotwire\install.json` is refused. It does
not start the server. When it finishes, set the server's name in `hotwire.bat` and double-click it.

Stopped halfway? Run it again. `hotwire\install.json` records the finished steps, and SteamCMD
resumes a partial download. `Remove-NetFirewallRule -Group Hotwire` removes the rules it added.

The numbers it uses: ports from `launcher/hotwire.bat` section 4.1; the Rust+ port from
[Rust+ Server](https://wiki.facepunch.com/rust/rust-companion-server); 15 GB disk and 12 GB RAM,
warned about rather than enforced, from [Creating a server](https://wiki.facepunch.com/rust/Creating-a-server).

## doctor and connect

`doctor` writes nothing, and checks what otherwise fails in ways nobody can diagnose: that this
machine signs requests byte-for-byte like the panel, that the panel answers, and **that the clock is
within the panel's 300-second window** — a drifting clock refuses every request with a message that
says nothing about clocks.

`connect` asks for the code rather than taking it as an argument, so it never lands in your shell
history (`-Code` / `--code` exists for unattended runs). It writes only inside the server folder:

| file | what |
|---|---|
| `hotwire/connect.json` | install id, panel URL, server name. No secrets. |
| `hotwire/keys.json` | the launcher's signing key. Readable only by its owner. |
| `oxide/data/Hotwire/panel.json` | the plugin's signing key. Readable only by its owner. |

The plugin's key is in `oxide/data/`, not `oxide/config/Hotwire.json`: the plugin rewrites its config,
and the documented way to reset it is to delete it — which would quietly disconnect the server.
Anything it would replace is backed up first. Running `connect` again from the same machine adopts
the server the panel already has rather than creating a second one.

The panel has no endpoint that accepts a plugin's source or a configuration value. Hashes and
metadata travel; contents do not.
