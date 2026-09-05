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

### Bar types and the countdown

`BarType` is a string parsed into `Default | Timed | TimeCounter | TimeProgress
| TimeProgressCounter`. The last of those is the one worth having:

| Key | Type | Note |
|---|---|---|
| `BarType` | string | `"TimeProgressCounter"` |
| `TimeStampStart` | **double** | when the countdown began |
| `TimeStamp` | **double** | when it ends |
| `TimeStampDestroy` | double | optional, removes the bar early |
| `Progress_Reverse` | bool | true drains, false fills |

Both `TimeProgress` and `TimeProgressCounter` compute `Progress` as
`(now - TimeStampStart) / (TimeStamp - TimeStampStart)` on AdvancedStatus's own
tick, and **delete the bar when `TimeStamp` passes**. So neither the fill nor
the removal ever needs pushing.

**Hotwire uses `TimeProgress`, not `TimeProgressCounter`.** The Counter variants
additionally build their own countdown string, in code, with no format
parameter — you get seconds on the bar for the whole countdown and no way to
change it. Rendering `SubText` yourself is the only way to control the format,
which also matters for the rect bug below.

The timestamps are compared against `Network.TimeEx.currentTimestamp`, i.e.
Unix epoch seconds. Hotwire computes that from `DateTime.UtcNow` rather than
calling the Facepunch property, to keep its status code free of Facepunch
types — **assumed to be the same epoch, not verified.**

### Three things that will bite you

These were paid for once already, by a sibling plugin on the same server that
drives its event timers through AdvancedStatus. Repeated here so the next
person does not rediscover them.

- **Colours must be `#RRGGBB`.** AdvancedStatus passes an un-prefixed hex
  string straight through to CUI, where it is unparseable — and every bar
  renders white. `#RGB` shorthand is not understood either. Normalise before
  sending.
- **Short `SubText` gets clipped.** The rect is sized from a character-count
  estimate and under-allocates for short strings; Unity wraps the overflow to a
  second line the rect is too short to show, so `"24m"` renders as `"24"`.
  Pad the countdown to a minimum width, trailing, so the spaces wrap away
  rather than the unit.
- **`Text_Offset_Horizontal` is not optional.** Absent, it falls back to
  AdvancedStatus's own config value, which is zero — so your text sits flush
  against the icon while every other plugin's bar is inset.

Leave `Main_Color` and `Main_Transparency` unset unless you mean it: the frame
then inherits AdvancedStatus's own and matches the rest of the stack by
construction, including after AdvancedStatus itself is retuned.

### Icons

`Image_Sprite` (a built-in game sprite), then `Image_Local` (a file in
`oxide/data/AdvancedStatus/Images`), then `Image` (a URL, rendered as a
RawImage with the address directly, so no ImageLibrary round trip). With none
of them set you get AdvancedStatus's tinted placeholder, which renders as a
solid coloured square.

**Built-in sprite paths cannot be validated server-side** — a wrong one logs
`[FileSystem] Not Found: <path> (UnityEngine.Sprite)` once per draw and shows
nothing. `assets/icons/clock.png` does **not** exist. These do, verified
against the Rust UI asset list:

```
assets/icons/stopwatch.png   assets/icons/warning.png
assets/icons/explosion.png   assets/icons/grenade.png
assets/icons/peace.png       assets/icons/radiation.png
assets/icons/target.png      assets/icons/weapon.png
```

Hotwire uses `stopwatch.png`. Note that `warning.png` is the generic alert
glyph, so several plugins reach for it and their bars end up
indistinguishable except by colour.

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
