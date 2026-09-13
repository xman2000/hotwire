# hotwire-setup

Installs a Rust server with Oxide, and connects it to [Hotwire Panel](https://hotpanel.on-forge.com)
as well. **Every step asks first.** Installing something that is not there yet defaults to yes; replacing
or removing anything defaults to no.

| file | platform |
|---|---|
| `hotwire-setup.bat` + `hotwire-setup.ps1` | Windows. Double-click the `.bat`; the `.ps1` does the work. |
| `hotwire-setup.sh` | Linux. Connect only — installing on Linux is still [the guide](../docs/INSTALL-LINUX.md). |

## Windows

1. **Extract everything first.** If you downloaded a `.zip`, right-click it and choose **Extract All**.
   Double-clicking a file while it is still inside the zip does not work.
2. Put **`hotwire-setup.bat`** and **`hotwire-setup.ps1`** together in a folder. Any folder will do,
   because install asks where the server goes and suggests `C:\rustserver`.
3. **Right-click `hotwire-setup.bat` → Run as administrator.** Windows may ask whether to allow it,
   and a download can also show a blue "Windows protected your PC" box: choose *More info*, then *Run
   anyway*.
4. It checks five things first, and changes nothing while it does:
   - is a Rust server installed in this folder, and which build
   - is the clock right (against Steam's servers, so it never contacts the panel)
   - is Hotwire installed: `hotwire.bat` here, `Hotwire.cs` in `oxide\plugins`
   - is the RCON password in `secrets.bat` one `hotwire.bat` will accept
   - is it connected to Hotwire Panel, and as what
5. Pick from the menu. It suggests the next step from what it found.

Windows usually hides file extensions, so you may see two files both called `hotwire-setup`. The one
to double-click is the one whose type is **Windows Batch File**. Double-clicking the other only opens
it as text, which does no harm.

Double-clicking works too; without Administrator, install can only *report* on the firewall and the
clock rather than fix them. From a console, name the command: `.\hotwire-setup.bat connect`.

**Why two files.** Windows will not run a PowerShell script when you double-click it, and by default
refuses to run one at all. The `.bat` starts that one script for that one window, changes no Windows
setting, and is short enough to read first.

## Safe to stop, safe to run again

Install is built so that stopping at any moment — an error, a closed window, a power cut — leaves
nothing broken, and running it again simply carries on.

- **Nothing is written straight into place.** Every file goes to a temporary `<name>.hotwire-tmp`
  beside its destination and is then renamed over it. A rename is all-or-nothing, so you get the old
  file or the new one, never half of either. Leftover temporary files are deleted on the next run.
  That suffix is used by nothing else.
- **Secrets are locked before they hold anything.** `secrets.bat` and the panel keys are restricted to
  Administrators and you while still empty, and so are their backups.
- **A record, `hotwire\install.json`, says what is finished**, what you said no to, and which files
  install created. The pre-flight reads it, so a second run does only what is left. A folder holding a
  Rust server with no record is somebody else's, and install refuses to touch it.
- **Only one copy runs at a time.** A second window stops with a message; Windows releases the lock if
  the first is closed.
- **Nothing is unpacked over a running server.** If the server in that folder is running, install
  stops and says how to stop it.
- **A download is checked before it is used.** SteamCMD's zip must hold exactly `steamcmd.exe`. Oxide's
  must contain `Oxide.Rust.dll`, every file must sit inside `RustDedicated_Data`, and it must be the
  Windows build. The start script and the plugin must be the files they claim to be.
- **Low disk space is a question, not a warning.** Under 15 GB free, the Rust download defaults to *no*.
- **A mistyped panel code does not end the install.** The rest stays done; connect later from the menu.

## What it will never overwrite

- **A Rust server it did not install.**
- **An existing `hotwire.bat`, `Hotwire.cs` or valid `secrets.bat`.** They are kept as they are. The one
  exception is a `hotwire.bat` that install created: its `INSTALL_FRAMEWORK` line is changed to match
  whether Oxide is installed, after a copy is saved, and never while it is running.
- **The game's own files, without a copy.** Before Oxide first replaces anything, the originals go to
  `hotwire\backups\<time>-before-oxide\`.
- **Anything in a SteamCMD folder that already exists.** Only `steamcmd.exe` is added, and you are asked
  first.
- **Your Downloads, Desktop, Documents, OneDrive or temporary folders.** It will not suggest them for a
  server, and it warns before using one you type.

## Undoing it

Every change is written, as it happens, to **`hotwire\changes.log`** in the server folder, each with the
exact way to undo it. The last screen shows where that file is. In short:

| to undo | do this |
|---|---|
| the firewall rules | `Remove-NetFirewallRule -Group Hotwire` (as Administrator) |
| Oxide | copy the files from `hotwire\backups\*-before-oxide\` back into the server folder |
| the start script, plugin or password | delete `hotwire.bat`, `oxide\plugins\Hotwire.cs` or `secrets.bat` |
| connecting to the panel | `hotwire-setup.bat detach`, then revoke the keys in the panel |
| everything | delete the server folder, and `C:\steamcmd` if nothing else uses it |

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

It runs in four parts, and only the third one changes anything:

1. **Where the server goes**: this folder, unless you say otherwise.
2. **Pre-flight**: a read-only check of everything below. That covers the machine (Administrator,
   memory, disk, the clock against Steam's servers), SteamCMD, Rust, Oxide, the start script, the
   plugin, the RCON password and Hotwire Panel. It also checks Windows Firewall, and there *open*
   means open on the network the machine is actually on: a rule that only covers Private networks
   does not count on a Public connection. A **flight plan** then lists only what is missing. A
   finished server gets an empty plan and nothing happens.
3. **The steps** in that plan, after a five-second countdown you can stop with Ctrl+C. Each step says
   what it will do and asks first.
4. **Post-flight**: the same checks again, so you see the result rather than take it on trust.

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

Stopped halfway? Run it again, from anywhere: it remembers the last install folder and offers to
carry on there. SteamCMD resumes a partial download, and Oxide puts every file in place again.

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
