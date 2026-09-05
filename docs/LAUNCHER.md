# The launcher — `launcher/hotwire.bat`

Starts a Rust dedicated server and relaunches it whenever it exits. Windows,
batch, no dependencies. It works on its own; the plugin is optional, and the
two meet at a flag file.

## The problem it solves

Most Rust launchers are one long `^`-continued command that runs steamcmd,
re-downloads the mod framework, and starts the server — all of it, every time
the server exits.

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

## Update modes

`UPDATE_MODE` decides whether a restart is also an update.

**`always`** is the default and behaves like every other Rust launcher: it
updates on every start. That is the right policy while you are the one
deciding when the server restarts.

**`hotwire`** separates the two. A restart is only a restart, and an update
happens when a flag file is present in the server root:

| File in the server root | The next launch |
|---|---|
| `UPDATE.flag` | `steamcmd app_update`, then the framework, then launch |
| `VALIDATE.flag` | the same plus `validate`, which re-checksums everything |
| neither | straight to launch |

The flag is deleted **once the update has actually completed**, so one flag
buys one update rather than one attempt. If steamcmd exhausts its retries, or
the framework download fails, the flag is kept and the backstop clock is not
reset — the console says so in a banner, and the next start tries again.
Anything can create a flag — you, a scheduled task, or the plugin:

```powershell
New-Item -ItemType File C:\rustserver\UPDATE.flag
```

That mode is opt-in because Rust clients update themselves: a server that
never updates does not go stale, it becomes unjoinable, and it usually happens
on force wipe day. So the default is the safe, slow behavior and the sharp
behavior is a deliberate choice.

**`hotwire` mode carries a backstop.** If `MAX_DAYS_WITHOUT_UPDATE` (14) full
days pass with no *successful* update, one happens anyway and says so loudly
in the console. Fourteen days never fires on a monthly cycle that is working,
and it turns "my server is dead and I do not know why" into a line of log. A missing stamp file
counts as forever, so a fresh install updates on its first start rather than
waiting a fortnight to discover it is out of date. Set it to `0` to disable.

## One option, one line

Every option is one independent line:

```bat
REM  server.maxplayers -- slots.  [default: unknown]
set "ARGS=!ARGS! +server.maxplayers 50"
```

Put `REM` in front to disable it; take it away to enable it. You cannot break
the file by turning one option off, because nothing depends on the line above
it.

**Every default in it is real.** The option list is curated by hand, but the
names and defaults beside each one were read out of a Rust build rather than
copied from a guide, and they are re-checked against a new build after every
Rust update. A comment claiming a default that has quietly moved is worse than
no comment, because someone will believe it.

That checking is maintenance work, not yours: nothing here needs Python, and
the launcher never asks you to run anything. See `tools/` if you are curious
how it is done.

## Requirements

Windows, a Rust dedicated server, and steamcmd. That is all — it is a batch
file.

## Setup

1. Copy `launcher/hotwire.bat` and `launcher/secrets.example.bat` next to your
   server install.
2. Rename `secrets.example.bat` to `secrets.bat` and put your RCON password in
   it. **Change it from the example** — RCON is remote code execution on that
   machine, and the launcher does not check the value. Avoid `!` and `^` in it:
   the launcher runs under delayed expansion, which eats both, and the server
   would end up listening on a password that is not the one in the file.
3. Open `hotwire.bat`, set `ROOT` and `STEAMCMD` at the top, then work down the
   options.
4. Run it.

To have the plugin drive the updates, set `UPDATE_MODE=hotwire` once the
plugin is installed and you have a schedule you trust.

## Generating the option reference for your own build

Optional, and only if you want the full convar list rather than the curated
one:

```
python -m venv venv
venv\Scripts\pip install dnfile
venv\Scripts\python tools\convars.py "<server>\RustDedicated_Data\Managed\Assembly-CSharp.dll" --bat
```

## What it does not do

Recover from a crash loop. If the server dies on boot the launcher will keep
relaunching it every 15 seconds. Run on Linux; it is batch, and a shell port
does not exist yet.
