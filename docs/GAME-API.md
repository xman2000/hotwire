# Game API — what has actually been read from an assembly

This file is the source of truth for Rust and Oxide API used by Hotwire, per
rule 5 in `CLAUDE.md`. **Only entries read out of a real
`Assembly-CSharp.dll` belong here.** Anything else is assumed, is tagged
`// VERIFY:` at its use site, and lives in `docs/OPEN-QUESTIONS.md` until it
has been checked.

## AdvancedStatus 0.1.26 (IIIaKa)

**Verified:** 2026-09-04, read from the plugin installed on the reference
server. Not from documentation, and not from memory.

Called through `[PluginReference] Plugin AdvancedStatus` and `Call(...)`.

```
IsReady()                                              -> true, or null when not ready
CreateBar(string userIdStr, Dictionary<string,object>)  overloads: ulong, BasePlayer, object
UpdateContent(string userIdStr, Dictionary<string,object>)
DeleteBar(ulong userID, string barId, string pluginName)
DeleteBarForAll(string barId, string pluginName)
DeleteAllPluginBars(string pluginName)
BarExists(ulong userID, string barId, string pluginName)
```

Hotwire uses the **string** user-id overloads, so nothing in the integration
needs a `BasePlayer` and ADR-0014 still holds.

Parameter keys used, from the bar's own constructor:

| Key | Type | Note |
|---|---|---|
| `Plugin` | string | **required** — `CreateBar` returns silently without it |
| `Id` | string | **required** — same |
| `Category` | string | defaults to `"Default"` |
| `Order` | int | defaults to 10 |
| `Text` | string | |
| `Progress` | **float** | 0–1 |
| `Main_Color`, `Text_Color`, `Progress_Color` | string | hex; omit to inherit the server's theme |

**Every key is type-checked and a mismatch is silently ignored.** `Progress`
is tested with `obj is float`, so a `double` there renders an empty bar and
logs nothing. `Order`, `Height` and the `*_Size` keys want `int`; the
`TimeStamp*` keys want `double`. This is the single easiest thing to get
wrong.

`OnAdvancedStatusLoaded` is the readiness hook. It never appears as a literal
in the file — it is built as `$"On{AdvancedStatusName}Loaded"` where
`AdvancedStatusName = "AdvancedStatus"`. Every API method checks `_isReady`
first, so bars created before it fires are dropped without a word.

**Licensing.** AdvancedStatus is EULA'd and sold through Codefling and
Lone.Design: it may not be copied, modified or redistributed without the
author's consent. Calling its API is not copying it, and describing that API
here is interoperability documentation. No code from it may enter this
repository — the same rule the project applies to SmoothRestarter. Most
servers will not have it, which is why the integration is optional and chat
carries the countdown by itself.

## Rust assembly: nothing read yet

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
