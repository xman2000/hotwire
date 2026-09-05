# tools

`convars.py` reads the `[ServerVar]` convars out of a real
`Assembly-CSharp.dll` with pure Python — no .NET runtime, no Unity, nothing but
the file the server already has. It reports each convar's name and, where the
compiler stored one, its default.

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
configuration sources agree on, gathered in `docs/RESEARCH.md`. `--all` prints
the long tail when you want to search it.

**Re-run it after every Rust update.** Convars come and go, and their defaults
move more often than their names do. A launcher documenting a default that has
quietly changed is worse than one documenting nothing, because someone reads
the comment and believes it. The assembly on your server is the only authority.

**Defaults come back `UNKNOWN` rather than guessed** when a convar is
initialised in a static constructor: the value is in IL, not metadata. Walking
those `.cctor` assignments would close most of the gap, and is the obvious next
step.

**Status: unrun.** Written against the metadata tables `dnfile` exposes —
`TypeDef`, `Field`, `CustomAttribute`, `Constant` — but never executed against
a real assembly. Treat its output as unverified until it has been.
