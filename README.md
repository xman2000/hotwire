# Hotwire

**Scheduled restarts and updates for a Rust dedicated server — as a matched
pair: an Oxide plugin and the launcher script it talks to.**

Windows. MIT.

> **Version 1.0.0.** Both halves have run on a live server. What has not been
> exercised is listed plainly in `CHANGELOG.md` under Known limitations.

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

**Separates updates from restarts — when you ask it to.** Out of the box it
updates on every start, like every other Rust launcher, which is right while
you are the one deciding when to restart. Set `UPDATE_MODE=hotwire` and a
restart becomes only a restart, while updates happen when a flag file says so:

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

That mode is opt-in because Rust clients update themselves: a server that never
updates does not go stale, it becomes unjoinable, and it usually happens on
force wipe day. So the default is the safe, slow behaviour, and the sharp
behaviour is a deliberate choice — with a backstop that updates anyway if a
fortnight passes without one.

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

**Every default in it is real.** The option list is curated by hand, but the
names and defaults beside each one were read out of a Rust build rather than
copied from a guide, and they are re-checked against a new build after every
Rust update. A comment claiming a default that has quietly moved is worse than
no comment, because someone will believe it.

That checking is maintenance work, not yours: nothing here needs Python, and
the launcher never asks you to run anything. See `tools/` if you are curious
how it is done.

## Layout

```
src/Hotwire.cs                  the plugin
launcher/hotwire.bat            the launcher
launcher/secrets.example.bat    copy to secrets.bat; never committed
CHANGELOG.md                    what is in this release, and what is not
docs/CONFIG.md                  every config field, command and permission
docs/DECISIONS.md               every design choice, with its reasoning
docs/GAME-API.md                what has been verified against a real build
tools/convars.py                maintenance tooling; you never need to run it
```

## Requirements

The launcher needs Windows, a Rust dedicated server, and steamcmd. That is all
— it is a batch file.

The plugin is optional and needs [Oxide/uMod](https://umod.org). Nothing about
the launcher requires it, and nothing about the plugin requires the launcher;
they meet at a flag file.

The plugin's countdown bar is drawn through **AdvancedStatus**, which is a paid
plugin most servers will not have. Without it the countdown still runs and is
announced in chat — that is the normal case, not a degraded one.

## Getting started

1. Copy `launcher/hotwire.bat` and `launcher/secrets.example.bat` next to your
   server install.
2. Rename `secrets.example.bat` to `secrets.bat` and put your RCON password in
   it. **Change it from the example** — RCON is remote code execution on that
   machine, and the launcher does not check the value.
3. Open `hotwire.bat`, set `ROOT` and `STEAMCMD` at the top, then work down the
   options.
4. Run it.

### Adding the plugin

1. Drop `src/Hotwire.cs` into `oxide/plugins/`. It compiles on the spot and
   writes `oxide/config/Hotwire.json` with **every schedule disabled**, so
   installing it cannot restart anything by surprise.

2. Give yourself permission. Nothing works without this, and the first command
   you try will simply refuse:

   ```
   oxide.grant user <your name> hotwire.status
   oxide.grant user <your name> hotwire.restart
   oxide.grant user <your name> hotwire.cancel
   oxide.grant user <your name> hotwire.edit
   ```

   Or grant them to a group, which is easier to maintain:

   ```
   oxide.grant group admin hotwire.status
   ```

   | Permission | Lets you |
   |---|---|
   | `hotwire.status` | See what is scheduled, and open the menu |
   | `hotwire.restart` | Start a countdown now |
   | `hotwire.cancel` | Cancel a running countdown |
   | `hotwire.edit` | Add, change and remove schedule entries |

3. Set `UPDATE_MODE=hotwire` in the launcher, so scheduled updates are the
   plugin's decision rather than something that happens on every restart.

4. Add a schedule — `hotwire menu` in game, or from the console:

   ```
   hotwire add restart 05:00 daily
   hotwire add update 20:00 first Thursday
   ```

Full reference in `docs/CONFIG.md`.

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
