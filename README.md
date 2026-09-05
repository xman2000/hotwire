# Hotwire

**Scheduled restarts and updates for a Rust dedicated server — as a matched
pair: an Oxide plugin and the launcher script it talks to.**

Windows. MIT.

> **Status: the plugin works, the launcher is unrun.** The plugin has been
> proven end to end on a live server — announce, countdown, kick, save, quit,
> write the flag, and a launcher acting on it — and has a full recurrence
> model and an in-game panel. `launcher/hotwire.bat` itself has never been
> executed. See `BRIEF.md` and `docs/OPEN-QUESTIONS.md`.

---

## The problem

Most Rust launchers are one long `^`-continued command that runs steamcmd,
re-downloads the mod framework, and starts the server — all of it, every
time the server exits.

That is fine when you restart occasionally. It stops being fine when you
restart daily to shed the memory a busy modded server accumulates:

- **A restart costs double.** On a 4250-size map with a heavy plugin load,
  bootstrap alone is ~2.5 minutes and the server is not really ready for
  another two. Add `steamcmd validate` and you have six to eight minutes of
  downtime for what should have been three.
- **Every restart becomes an unattended update.** Force-extracting whatever
  Oxide build is current, at 5am, over a working install. Twenty-nine days a
  month that is harmless. The day after a Rust update it is how a server comes
  back with half its plugins dead and nobody watching.
- **The file is frightening to edit.** Comment out one line in the middle of a
  `^`-continued command and you silently take the rest of the launch with it.

## What Hotwire does

**Separates updates from restarts.** A restart relaunches the server and
nothing else. An update happens when a flag file says so:

| File in the server root | The next launch |
|---|---|
| `UPDATE.flag` | `steamcmd app_update`, then the framework, then launch |
| `VALIDATE.flag` | the same plus `validate`, which re-checksums everything |
| neither | straight to launch |

The flag is deleted once acted on, so one flag buys one update. Anything can
create one — you, a scheduled task, or the plugin when it notices a new
framework release:

```powershell
New-Item -ItemType File C:\rustserver\UPDATE.flag
```

**Schedules the restart, and announces it.** The plugin holds the schedule,
counts down, tells players what is about to happen, kicks them with a reason
rather than a timeout, and quits — which saves the world on the way out. If
the entry was an update, it writes the flag first. It never spawns a process
or shells out; it writes a file and quits, and the launcher does the rest.

```
hotwire status                        what is next, or what is counting down
hotwire menu                          the in-game panel
hotwire now [update|validate] [s]     start a countdown now
hotwire cancel                        stop the one that is running
hotwire add update 20:00 first Thursday   Rust force wipe day
hotwire add restart 05:00 every 2 days
hotwire set restart 0 time 06:00
```

Schedules can say daily, certain weekdays, **the first Thursday of the
month**, a date each month, every N days, or once on a date. Ordinal weekdays
exist because Rust force wipes on the first Thursday, and that is the update
most admins actually want.

Every schedule entry ships **disabled**. A restarter that starts restarting
the moment you install it is a restarter that catches you out. See
`docs/CONFIG.md`.

**Makes the launcher editable.** Every option is one independent line:

```bat
REM  server.maxplayers -- slots.  [default: unknown]
set "ARGS=!ARGS! +server.maxplayers 50"
```

Put `REM` in front to disable it; take it away to enable it. You cannot break
the file by turning one option off, because nothing depends on the line
above it.

**Documents itself against your build.** `tools/convars.py` reads the
`[ServerVar]` attributes out of the `Assembly-CSharp.dll` you actually have
and generates the annotated option list, with real defaults where the compiler
stored them and `UNKNOWN` where it did not. It never guesses a default — a
comment claiming a default that has moved is worse than no comment, because
someone will believe it.

## Layout

```
src/Hotwire.cs                  the plugin
launcher/hotwire.bat            the launcher
launcher/secrets.example.bat    copy to secrets.bat; never committed
tools/convars.py                generate the option list from your build
docs/DECISIONS.md               every design choice, with its reasoning
docs/RESEARCH.md                the evidence behind the option list
docs/OPEN-QUESTIONS.md          what is assumed, unverified or undecided
docs/CONFIG.md                  every config field, command and permission
docs/GAME-API.md                what has been read from a real assembly
BRIEF.md                        the full brief
```

## Getting started

1. Copy `launcher/hotwire.bat` and `launcher/secrets.example.bat` next to your
   server install.
2. Rename `secrets.example.bat` to `secrets.bat` and put your RCON password in
   it. **Change it from the example** — RCON is remote code execution on that
   machine, and the launcher does not check the value.
3. Open `hotwire.bat`, set `ROOT` and `STEAMCMD` at the top, then work down the
   options.
4. Run it.

The plugin is separate and optional: drop `src/Hotwire.cs` into
`oxide/plugins/` and it will write the flags on a schedule. See
`docs/CONFIG.md`.

Optionally, generate the full option reference for your own build:

```
python -m venv venv
venv\Scripts\pip install dnfile
venv\Scripts\python tools\convars.py "<server>\RustDedicated_Data\Managed\Assembly-CSharp.dll" --bat
```

## What it does not do

Wipe. Manage maps. Recover from a crash loop — if the server dies on boot the
launcher will keep relaunching it every 15 seconds. Run on Linux; the launcher
is batch, and a shell port does not exist yet.

## Credit

The problem space was mapped in part by reading
[SmoothRestarter](https://umod.org/plugins/smooth-restarter) by 2CHEVSKII.
Hotwire shares no code with it.
