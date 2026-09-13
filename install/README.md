# hotwire-install

Puts a Rust dedicated server with Oxide on a Windows machine, **one confirmed step at a time**. It is
steps 1–4 of the [Windows guide](../docs/INSTALL-WINDOWS.md) done for you, plus the checks people skip.

1. Make a folder for the server, for example `C:\rustserver`.
2. Put **`hotwire-install.bat`** and **`hotwire-install.ps1`** in it.
3. **Right-click `hotwire-install.bat` → Run as administrator.**

Double-clicking works too. Without Administrator, it installs everything but can only *report* on the
firewall and the clock, not fix them.

**Why two files.** The `.ps1` does the work. Windows will not run a PowerShell script when you
double-click it, and by default refuses to run one at all. The `.bat` starts that one script for that
one window, changes no Windows setting, and is short enough to read before you run it.

## What it does

Every step explains itself, links to the documentation it is based on, and waits for a `y`. Enter
on its own is always a no.

| step | what | changes |
|---|---|---|
| 1 | Windows, PowerShell 5.1, Administrator, memory, **the clock** | only if the clock is out and you say yes (`w32tm /resync`) |
| 2 | Where the server goes: **this folder unless you say otherwise** | nothing yet |
| 3 | SteamCMD into `C:\steamcmd`, where `hotwire.bat` looks for it | reuses one already there |
| 4 | The Rust server, app 258550, about 12 GB | the server folder |
| 5 | Oxide, checked to be the Windows build and a real archive before it is unpacked | the server folder |
| 6 | **Windows Firewall**: reports what is already open or blocked, then opens UDP 28015 and 28017; TCP 28083 (Rust+) only if asked | rules in the group `Hotwire` |

## What it never does

- **Open RCON (TCP 28016).** It *warns* if something else already has, including a rule that allows
  `RustDedicated.exe` as a program, which covers RCON if it names no port.
- Touch a Rust server it did not install. A folder with `RustDedicated.exe` and no
  `hotwire-install.json` is refused.
- Start the server, choose a password, or contact Hotwire Panel.
- Configure a home router or a cloud provider's firewall. Those are outside the machine, and it says so.

## Stopping and starting again

It keeps `hotwire-install.json` in the server folder with the steps it finished. Run it again and
it skips those steps. SteamCMD resumes a partial download rather than starting over.

To remove the firewall rules it added: `Remove-NetFirewallRule -Group Hotwire`.

## The numbers it uses, and where they come from

| | value | source |
|---|---|---|
| ports | 28015/udp game, 28017/udp query, 28016/tcp RCON | `launcher/hotwire.bat` section 4.1 |
| Rust+ port | 28083/tcp (the larger of game and RCON port, plus 67) | [Rust+ Server](https://wiki.facepunch.com/rust/rust-companion-server) |
| 15 GB disk, 12 GB RAM | warned about, not enforced | [Creating a server](https://wiki.facepunch.com/rust/Creating-a-server) |
| Oxide | `umod.org/games/rust/download` → `Oxide.Rust.zip` on GitHub | checked 2026-09-13 |

Change the ports in `hotwire.bat` and the firewall rules have to change with them.
