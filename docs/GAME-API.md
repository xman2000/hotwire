# Game API — what has actually been read from an assembly

This file is the source of truth for Rust and Oxide API used by Hotwire, per
rule 5 in `CLAUDE.md`. **Only entries read out of a real
`Assembly-CSharp.dll` belong here.** Anything else is assumed, is tagged
`// VERIFY:` at its use site, and lives in `docs/OPEN-QUESTIONS.md` until it
has been checked.

## Status: empty, and mostly not needed

No assembly has been inspected yet — `tools/convars.py` is written and unrun.

More usefully: **`src/Hotwire.cs` does not reference a single Facepunch type.**
ADR-0014 routes the whole plugin through Covalence and `Oxide.Core`, because a
wrong guess at a Facepunch signature is a compile error, and a plugin that
does not compile is a plugin that never restarts the server. So this file
being empty currently costs the plugin nothing.

What remains assumed is all runtime, all wrapped, and all listed in
`docs/OPEN-QUESTIONS.md`: the uMod release-feed shape, the AdvancedStatus call
shape, `Interface.Oxide.RootDirectory` as the server root, and the name of the
extension carrying the framework version.

This file becomes load-bearing the moment something here needs a game type —
event-aware deferral is the likely first case.

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
