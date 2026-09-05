# Open questions

Things that are assumed, unverified, or undecided. Nothing here should be
presented as fact. Close an item by verifying it and moving what you learned
into `GAME-API.md` or an ADR.

## Unverified game API

All four were read from SmoothRestarter's source, not from a real
`Assembly-CSharp.dll`. Tag every use `// VERIFY:` until checked.

- [ ] `ConVar.Global.quit(new ConsoleSystem.Arg(ConsoleSystem.Option.Server, ""))`
      as the clean-shutdown call
- [ ] `ServerMgr.Instance.Restarting`
- [ ] `IPlayer.Kick(string)` via Covalence
- [ ] the `https://umod.org/games/rust.json` response shape, specifically
      `latest_release_version`

## Unverified tooling

- [ ] **`tools/convars.py` has never been run against a real
      `Assembly-CSharp.dll`.** It is written against the metadata layout
      `a sibling plugin/tools/dump.py` already depends on, but that is an argument
      that it should work, not evidence that it does.
- [ ] Defaults assigned in a static constructor come back `UNKNOWN`, because
      they live in IL rather than metadata. `a sibling plugin/tools/il.py` can read
      that IL; teaching `convars.py` to walk `.cctor` assignments would close
      most of the gap.
- [ ] `launcher/hotwire.bat` has not been executed. Labels and quoting were
      checked by reading, not by running.

## Unverified launcher defaults

Several options in `launcher/hotwire.bat` carry `[default: unknown]` or a
`VERIFY` note. They stay that way until generated from a real assembly. Do not
fill them in from memory.

## The tier-2 question — highest value item open

- [ ] **Does `ServerVar` carry a `ShowInAdminUI` property?** If yes, it is
      Facepunch's own list of admin-facing convars and tier 2 becomes data
      rather than judgement. Assumed to exist; unverified. Check it before
      curating anything by hand. See ADR-0009.
- [ ] **Confirm `call`ed scripts inherit `EnableDelayedExpansion`** from the
      parent's `setlocal`. ADR-0010 depends on it and it is unverified. One
      minute to test: a child doing `set "X=!ARGS!"` either sees the value or
      sees the literal `!ARGS!`.
- [ ] **Re-run the ADR-0010 count once `convars.py` works.** The layout choice
      was made against n=1 (23 convars). If `ShowInAdminUI` returns ~40
      weighted to gameplay, split `conf/common.bat` by topic.
- [ ] **Where does tier 3 live** — generated `docs/CONVARS.md`, generated
      `launcher/options-full.bat`, or inline? Inline is not recommended.
      See ADR-0008.

## Undecided design

- [ ] **One schedule list with a type, or two lists?** An update entry is a
      restart entry that also writes a flag. Probably one list; decide and
      write the ADR.
- [ ] **Restart hour.** Needs player-count-by-hour data, not a guess.
- [ ] **Is daily even right?** Measure process memory at boot, +24h, +48h.
      Flat at 48h means every other day halves the disruption.
- [ ] **DST.** `"HH:mm"` plus `DateTime.Today` arithmetic misfires across a
      DST boundary. Decide the behaviour rather than inherit a bug.
- [ ] **Scope against wipe-schedule plugins.** Hotwire restarts; it does not
      wipe. Where does a wipe-day restart belong?
- [ ] **Crash-loop protection.** If the server dies on boot the launcher
      relaunches every 15 seconds forever. Out of scope for v1, but the README
      says so and that should stay true.

## Not built yet

- [ ] `tools/Test-Launcher.ps1` — check every `+convar` in a launcher against
      the installed build and report the ones that no longer exist. Probably
      the most useful thing in the repo; turns a Rust update from a mystery
      outage into a two-line diff.
- [ ] `src/Hotwire.cs` — the plugin itself.
- [ ] Event-aware deferral. Blocked on the reference server's Flashpoint
      exposing no public API at all; see `HANDOFF.md` §6.
