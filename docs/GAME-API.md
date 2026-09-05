# Game API — what has actually been read from an assembly

This file is the source of truth for Rust and Oxide API used by Hotwire, per
rule 5 in `CLAUDE.md`. **Only entries read out of a real
`Assembly-CSharp.dll` belong here.** Anything else is assumed, is tagged
`// VERIFY:` at its use site, and lives in `docs/OPEN-QUESTIONS.md` until it
has been checked.

## Status: empty

No assembly has been inspected yet. `tools/convars.py` is written and unrun,
and `src/Hotwire.cs` does not exist, so there is nothing verified to record.

Everything Hotwire currently believes about the game API is assumed — the
shutdown call, the restarting flag, the Covalence kick, and the uMod release
feed. All four are listed in `docs/OPEN-QUESTIONS.md`.

## How to add an entry

Run the inspection tools in `tools/` against the `Assembly-CSharp.dll` of the
build you are targeting, then record what you found in this shape:

```
### ConVar.Global.quit
**Verified:** <date> against protocol <version>
**Signature:** <exact signature as read from metadata>
**Notes:** <behaviour, saving, side effects>
```

Re-run the tools after a Rust update. An entry here is a claim about a
specific build, not a permanent fact — say which build it came from.
