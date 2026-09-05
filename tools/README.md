# tools

**These are for maintaining Hotwire, not for running it.** Nothing in
`launcher/` refers to them and nobody installing the launcher needs Python.
The launcher ships with its defaults already filled in; this is how they got
there and how they stay right.

`convars.py` reads the `[ServerVar]` convars out of a real
`Assembly-CSharp.dll` with pure Python — no .NET runtime, no Unity, nothing but
the file itself. It reports each convar's name, type and default.

**The workflow after a Rust update**, for whoever maintains this repo: copy
`RustDedicated_Data\\Managed\\Assembly-CSharp.dll` off a server, run `--check`
against `launcher/hotwire.bat`, and fix whatever it reports. Then the launcher
is correct again for everyone who uses it, without any of them running
anything.

```
python -m venv venv
venv\Scripts\pip install dnfile

venv\Scripts\python tools\convars.py <dll>                 curated list
venv\Scripts\python tools\convars.py <dll> --all           everything
venv\Scripts\python tools\convars.py <dll> --bat           launcher lines
venv\Scripts\python tools\convars.py <dll> --check <bat>   audit a launcher
```

**`--check` is the one that earns its keep.** It reads a launcher and reports
every convar in it that no longer exists in the installed build, and every
comment whose claimed default the build disagrees with. Run it after a Rust
update and it turns a mystery outage into a two-line diff.

**The default output is curated, not exhaustive** (ADR-0018). A launcher
holding every convar in the assembly is worse than one holding none: hundreds
of `ai.*`, `debug.*` and `antihack.*` entries are runtime surface nobody sets
at launch, and burying the twenty that matter among them destroys the only
thing that makes the file good. The curation comes from two sources that are
not opinions of ours — `[ServerVar(ShowInAdminUI = true)]`, which is
Facepunch's own list of what an admin should see, and the names independent
configuration sources agree on, recorded in ADR-0009. `--all` prints the long
tail when you want to search it.

**Re-run it after every Rust update.** Convars come and go, and their defaults
move more often than their names do. A launcher documenting a default that has
quietly changed is worse than one documenting nothing, because someone reads
the comment and believes it. The assembly on your server is the only authority.

**Defaults come back `UNKNOWN` rather than guessed** when a convar is
initialised in a static constructor: the value is in IL, not metadata. Walking
those `.cctor` assignments would close most of the gap, and is the obvious next
step.

**Status: run, 2026-09-05.** Against a real `Assembly-CSharp.dll` it finds
**1,623 convars** and reads **1,620 defaults** out of static-constructor IL.
The remaining 17% are properties, which have a getter rather than a constant
and so have nothing to read.

On its first working run, checking `launcher/hotwire.bat`, it found that
`server.combatlog`, `server.chatlog` and `server.globalchat` do not exist —
the real names are `server.combatlogdelay`, `chat.serverlog` and
`chat.globalchat` — and that a comment claiming `server.worldsize` defaults to
4000 was wrong by 500. Three of those had been on a live server's command line
doing nothing.
