# tools

`convars.py` reads the `[ServerVar]` convars out of a real
`Assembly-CSharp.dll` with pure Python — no .NET runtime, no Unity, nothing but
the file the server already has. It reports each convar's name and, where the
compiler stored one, its default.

```
python -m venv venv
venv\Scripts\pip install dnfile
venv\Scripts\python tools\convars.py <Assembly-CSharp.dll>          # TSV reference
venv\Scripts\python tools\convars.py <Assembly-CSharp.dll> --bat    # launcher lines
```

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
