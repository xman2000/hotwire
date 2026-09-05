# Open questions

Things that are assumed, unverified, or undecided. Nothing here should be
presented as fact. Close an item by verifying it and moving what you learned
into `GAME-API.md` or an ADR.

## Unverified game API

Three of the original four closed by not being needed. ADR-0014 routes the
plugin entirely through Covalence and Oxide.Core, so no Facepunch signature is
referenced at compile time and a wrong guess can no longer stop the plugin
from compiling.

- [x] ~~`ConVar.Global.quit(new ConsoleSystem.Arg(...))`~~ **Not used.**
      `server.Command("quit")` runs the same console command through
      Covalence.
- [x] ~~`ServerMgr.Instance.Restarting`~~ **Not used.** The plugin tracks its
      own shutdown state.
- [x] ~~`IPlayer.Kick(string)` via Covalence~~ **Used, and low risk.** It is a
      Covalence interface method, not a Facepunch one, so it moves with Oxide
      rather than with Rust. Still unexercised until the plugin has run.

What is left is all *runtime* assumption, wrapped so that being wrong disables
one optional feature rather than the schedule. Each is tagged `// VERIFY:` at
its use site.

- [ ] **The `https://umod.org/games/rust.json` response shape**, specifically
      `latest_release_version`. Guarded: a changed feed logs a warning and
      schedules nothing.
- [x] ~~**The AdvancedStatus call shape.**~~ **Read from the installed plugin
      2026-09-04** and written up in `docs/GAME-API.md`. Every part of the
      original guess was wrong — `SetStatus(userId, id, text, seconds)` versus
      the real `CreateBar(userId, Dictionary<string,object>)` — which is the
      case for having shipped it disabled rather than enabled.
- [x] ~~**A game sprite path for the status bar icon.**~~ **Closed the way it
      should have been opened.** `assets/icons/clock.png` does not exist and
      logged `[FileSystem] Not Found` once per draw — a guessed default,
      exactly what rule 6 forbids, and it cost a round trip to find out.
      `assets/icons/stopwatch.png` comes from a list already verified against
      the Rust UI asset list by a sibling plugin. The verified set is in
      `docs/GAME-API.md`.
- [x] ~~**The `TimeStamp` keys.**~~ **Read from the plugin, 2026-09-05.** They
      do exactly that: `BarType: TimeProgressCounter` makes AdvancedStatus
      count the bar down itself and delete it when the time arrives. One
      `CreateBar`, nothing pushed after it. Written up in `docs/GAME-API.md`.
- [ ] **That `Network.TimeEx.currentTimestamp` is Unix epoch seconds.**
      Hotwire computes the same value from `DateTime.UtcNow` rather than
      calling the Facepunch property, so the status code stays free of
      Facepunch types. If the epoch differs, the bar shows nonsense or
      disappears immediately — loud and harmless, but unverified.
- [ ] **AdvancedStatus's own version drift.** The integration is written
      against 0.1.26. It is wrapped and self-disabling, so a changed API costs
      a cosmetic bar rather than a restart, but nothing tells us it changed
      except the warning in console.
- [x] ~~**`Interface.Oxide.RootDirectory` is the server root**~~ **Confirmed
      2026-09-04** by `hotwire check` on the reference server: it resolves to
      the install root, `RustDedicated` is present in it, it is writable, and
      the flag paths are the ones the launcher watches. One data point on one
      Windows install — the `Server root` override exists for anyone it is
      wrong for, and `hotwire check` tells them in one line.
- [ ] **The Oxide extension carrying the framework version is named `Rust`.**
      Used only by the framework-update check.
- [ ] **Oxide's `timer` is real time, not scaled time.** Not depended on:
      the countdown recomputes remaining from `DateTime.Now` every tick, so a
      scaled or drifting timer costs a skipped announcement, never a moved
      restart. Worth confirming anyway.

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

- [x] ~~**One schedule list with a type, or two lists?**~~ **Two lists.**
      ADR-0012. A restart and an update at the same minute resolve in favour
      of the update.
- [ ] **Restart hour.** Needs player-count-by-hour data, not a guess.
- [ ] **Is daily even right?** Measure process memory at boot, +24h, +48h.
      Flat at 48h means every other day halves the disruption.
- [x] ~~**DST.**~~ **Local wall-clock time, plus a last-fired record
      persisted to disk that refuses a repeat inside 20 hours.** ADR-0013.
      The autumn double is suppressed; the spring skip is logged and waits
      for the next day.
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

## The plugin — settled

Kept short deliberately; the reasoning lives in `docs/DECISIONS.md` and the
detail in `docs/CONFIG.md`.

Built and proven on a live server: the schedule with six recurrence modes,
countdown and announcements, the AdvancedStatus bar, kick-then-save-then-quit,
the update flag, the full chat command set, and the in-game panel (ADR-0006,
built last, after the commands could already do everything it does).

Confirmed along the way, each of which had been a guess: `Oxide.Plugins.Timer`
is what `timer.Every()` returns; `Interface.Oxide.RootDirectory` is the server
root; the launcher consumes the flag, so one flag buys one update; a `CuiButton`
command routes to a Covalence-registered command; and
`CuiHelper.AddUi(BasePlayer, CuiElementContainer)` is the right overload.

## Still open on the plugin

- [ ] **Whether the panel is actually readable.** It renders and the buttons
      work, but the anchors, font sizes and row heights were chosen without
      ever seeing it. Nine rows before it overflows is a guess too, and the
      time row is now ten elements wide.
- [ ] **Event-aware deferral** — do not restart on top of a live event.
      Blocked: the reference server's event plugin exposes no `[HookMethod]`
      and no public API, so there is nothing to ask. The options are to add a
      read-only API to it, to query a zone-manager plugin for active zones, or
      to ask a raid-base plugin about occupied bases. Pick one and write the
      ADR. Whatever it is, it must degrade to "restart on schedule, say
      nothing about events" when none of those plugins are installed.
- [ ] **The framework-update check has never fired.** It is off by default and
      nothing has exercised the path from detection through to an announced
      update. Two of its assumptions — the feed shape and the extension name —
      are listed above and are only reachable through it.
- [ ] **Nothing has run across a DST boundary.** ADR-0013's guard is written,
      persisted and unit-reasoned, but the autumn repeat it exists for has not
      happened yet.

## Not built yet

- [ ] `tools/Test-Launcher.ps1` — check every `+convar` in a launcher against
      the installed build and report the ones that no longer exist. Probably
      the most useful thing in the repo; turns a Rust update from a mystery
      outage into a two-line diff.
- [ ] **`launcher/hotwire.bat` has never been executed.** The flag *contract*
      is proven, but against the reference server's own launcher, not against
      the one in this repository. Those are different claims and the second is
      untested. This is now the largest untested thing in the project.
