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
      `Assembly-CSharp.dll`.** It is written against the metadata tables
      `dnfile` exposes, but that is an argument that it should work, not
      evidence that it does.
- [ ] Defaults assigned in a static constructor come back `UNKNOWN`, because
      they live in IL rather than metadata. Teaching `convars.py` to walk
      `.cctor` assignments in IL would close most of the gap.
- [ ] `launcher/hotwire.bat` has not been executed. Labels and quoting were
      checked by reading, not by running.

## Unverified launcher defaults

Several options in `launcher/hotwire.bat` carry `[default: unknown]` or a
`VERIFY` note. They stay that way until generated from a real assembly. Do not
fill them in from memory.

## The tier-2 question — highest value item open

- [x] ~~**Does `ServerVar` carry a `ShowInAdminUI` property?**~~ **Yes.**
      Confirmed 2026-09-04, see `docs/RESEARCH.md`. Teach `convars.py` to
      report it as a column; that is Facepunch's own list of admin-facing
      convars.
- [ ] **How many convars actually carry `[ServerVar]`?** Community sources
      suggest 800-1200 total console entries, but most are `ai.*`, `debug.*`
      and `antihack.*` runtime surface. The launcher-relevant number is
      unknown until the generator runs. Do not quote 800-1200 as tier 3's
      size.
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

## Before this repo is made public

- [ ] **`HANDOFF.md` is still in git history.** It was untracked and
      gitignored under ADR-0011, but it remains in commits `3e54724` and
      `3f0dc61`, where anyone can read the reference server's paths, seed,
      identity and hardware. Untracking is not scrubbing. Either rewrite
      history (`git filter-repo --path HANDOFF.md --invert-paths`) or squash
      to a single initial commit before flipping the repo public. Decide
      which; both discard the existing commit hashes.
- [ ] **Check nothing else identifying is in history.** The launcher's
      earlier revisions were written from a site-specific original.

## Not built yet

- [ ] `tools/Test-Launcher.ps1` — check every `+convar` in a launcher against
      the installed build and report the ones that no longer exist. Probably
      the most useful thing in the repo; turns a Rust update from a mystery
      outage into a two-line diff.
- [ ] `src/Hotwire.cs` — the plugin itself.
- [ ] Event-aware deferral — do not restart on top of a live event. Blocked:
      the reference server's event plugin exposes no `[HookMethod]` and no
      public API, so there is currently nothing to ask. The options are to
      add a read-only API to it, to query a zone-manager plugin for active
      zones, or to ask a raid-base plugin about occupied bases. Pick one and
      write the ADR. Whatever it is, it must degrade to "restart on schedule,
      say nothing about events" when none of those plugins are installed.
