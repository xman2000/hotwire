# Architecture decision records

Newest last. An ADR is added whenever a design choice is made or reversed.
These six were taken during the briefing, before any code existed; the
reasoning is in `BRIEF.md` and is summarised here.

---

## ADR-0001 — The plugin quits; the launcher restarts

**Date:** 2026-09-04 · **Status:** ACCEPTED

Alternatives: the plugin manages the server process itself; an external
scheduler drives both.

Chosen: **the plugin makes the process exit cleanly and nothing else.** The
launcher already relaunches on exit, so the restart half is free. Keeping the
interface to "write a flag, then quit" means either half can be replaced
without touching the other, and the plugin never needs permission to spawn
processes on someone's server.

## ADR-0002 — Kick players, then `Global.quit`

**Date:** 2026-09-04 · **Status:** ACCEPTED

`quit` saves the world; a hard kill does not. On a server running
`server.saveinterval 300` that is up to five minutes of everyone's progress.
Kicking first gives players a real disconnect reason instead of a timeout.

## ADR-0003 — The countdown renders through an existing status plugin

**Date:** 2026-09-04 · **Status:** ACCEPTED — implemented against
AdvancedStatus 0.1.26; see `docs/GAME-API.md`. Absent that plugin the bar does
nothing and chat carries the countdown, which is the case on most servers.

Alternatives: a bespoke CUI panel, as SmoothRestarter does.

Chosen: **render through AdvancedStatus where it is present, chat otherwise.**
On the reference server, the event plugin already draws its timers through
AdvancedStatus (67 references) and the PVP-target plugin draws into Hud (57). A
bespoke panel would be a fifth thing competing for a screen corner and would
duplicate a bar players already read. Must degrade to chat-only, since no
status plugin is guaranteed on a public install.

Does not apply to the admin menu — see ADR-0006.

## ADR-0004 — Plain lang strings, no format mini-language

**Date:** 2026-09-04 · **Status:** ACCEPTED

SmoothRestarter ships a custom `IFormatProvider` driven by a regex template
language (`<hr?+ hours ><min?+ minutes >`). That is a large, testable-only-by-
hand surface for rendering "5 minutes left". Plain lang strings instead.

## ADR-0005 — No reflection into Facepunch internals

**Date:** 2026-09-04 · **Status:** ACCEPTED

SmoothRestarter reaches into `ServerMgr`'s private `restartCoroutine` field to
cancel a native `global.restart`. That breaks silently whenever Facepunch
renames a field, and the failure would land on other people's servers. The
whole native-restart interop feature is dropped.

## ADR-0006 — The admin menu is a CUI panel, with a chat fallback

**Date:** 2026-09-04 · **Status:** ACCEPTED — implemented in v0.4.0, after the
chat commands could do everything it does. See ADR-0016 for where it lives.

The user asked specifically for an in-game surface to add, edit, delete and
view scheduled restarts and updates.

This does not contradict ADR-0003: that governs the countdown, which every
player sees constantly. The menu is admin-only, permission-gated, opened
deliberately and occasionally by one person.

**But a sibling plugin in the same house chose a CUI panel and later
superseded that decision**, and its `CLAUDE.md` says plainly that CUI
lifecycle is the most bug-prone part of Oxide plugin work. That lesson has
already been paid for once.
Conditions: strict panel lifecycle, destroy on disconnect, and **chat commands
that do everything the menu does**, written first, so a broken panel never
means a schedule cannot be changed.

## ADR-0007 — Restart-on-new-framework-release is opt-in, default off

**Date:** 2026-09-04 · **Status:** ACCEPTED — implemented in v0.1.0, still
default off. The release feed's response shape remains unverified, so a
changed feed logs a warning and schedules nothing.

Detecting a new Oxide release and restarting to pick it up is the best idea in
the upstream plugin, and the one most able to restart a server at a bad
moment. With the update/restart split (ADR-0001) it becomes genuinely good:
detect, schedule, announce, restart *with the update flag*. Ship it off by
default and document it well.

## ADR-0008 — Three tiers of options, with different truth requirements

**Date:** 2026-09-04 · **Status:** ACCEPTED, third tier **superseded by
ADR-0018**. Tiers 1 and 2 stand. Tier 3 is not generated into a file; the list
is curated and the generator checks it.

Alternatives: one hand-written launcher (unmaintainable, and its comments go
stale silently); one fully generated launcher (unreadable, and generated prose
is bad prose).

Chosen: **three tiers.** Boilerplate (~10 options, edit five values and you
have a server), Common (~20-30, what admins actually change), Reference
(everything discoverable).

The tiers exist because they have different truth requirements. Tiers 1 and 2
are stable across years — `server.hostname`, `server.port`, `server.identity`
and friends do not move — so they can be hand-written, hand-verified, and
given real explanatory prose. Tier 3 churns with content updates and must be
generated from the installed assembly.

An earlier draft justified generating everything by claiming convars change
frequently. That was too broad. What actually churns fastest is **defaults**,
not names: Facepunch tunes numbers constantly. So the danger a generator
guards against is not "this convar vanished" but "this comment says the
default is 600 and it has quietly been 900 for six months". Hence: never write
a default from memory, and prefer `UNKNOWN` to a guess.

Open sub-decision: whether tier 3 lands in a generated `docs/CONVARS.md`, a
generated `launcher/options-full.bat`, or inline. Inline is not recommended —
several hundred commented lines would destroy the readability that is the
launcher's whole point.

## ADR-0009 — Tier 2 is seeded from evidence, not from intuition

**Date:** 2026-09-04 · **Status:** ACCEPTED — `ShowInAdminUI` confirmed real,
and cross-source counting done. See `docs/RESEARCH.md`.

"The top 20 settings admins change" is a claim about a population of admins,
and inventing it would undermine the one thing this project sells: that the
annotations can be trusted.

Two real sources, in order:

1. **`[ServerVar(ShowInAdminUI = true)]`** — *assumed, unverified, check
   first.* Rust's in-game admin UI shows a curated subset of convars. If that
   selection is an attribute property, it is Facepunch's own opinion about
   which settings admins touch, it is machine-readable, and tier 2 stops being
   a judgement call. Teach `tools/convars.py` to report it.
2. **The reference server's live command line** — 23 convars, one real admin,
   verified working on protocol 2632.287.1. Listed as source A in
   `docs/RESEARCH.md`. **n = 1**: evidence, not a survey. Say so in the
   docs.

**Resolved 2026-09-04.** `ShowInAdminUI` is real; the declaration form is
`[ServerVar(ShowInAdminUI = true)] public static string hostname = "My
Untitled Rust Server";`. `convars.py` reports it as a column.

**Amended 2026-09-05, having read it.** It is real, and it is **not** the
oracle this ADR claimed. Of the 71 convars it marks, many are live tuning
knobs — `waterWheelWorkBudgetMs`, `hopperAnimationBudgetMs`,
`farmChickenLocalAvoidance` — while it does not mark `server.port`,
`server.seed`, `server.worldsize`, `server.identity` or `server.level`. It
answers "what does the in-game admin panel expose at runtime", which is a
different question from "what do you set at launch". It is useful input to
curation. It is not a substitute for it.

Source 2 was also widened from n=1 to three independent samples. 17 convars
are named by two or more of them — see `docs/RESEARCH.md` for the list and for
two methodological artifacts that would otherwise mislead (ports look
unimportant because they live on the command line rather than in server.cfg;
rate tuning is missing from the reference server because it uses plugins).

## ADR-0010 — Config file layout: by tier, not by topic (for now)

**Date:** 2026-09-04 · **Status:** PROPOSED — revisit once `convars.py` runs

Batch supports this cleanly: `call "%~dp0conf\network.bat"` runs in the same
environment, so `set` in the child persists in the parent. Rules: the child
must not use `setlocal`, `%~dp0` carries a trailing backslash, `exit /b`
returns while bare `exit` kills the window, and the parent's
`EnableDelayedExpansion` is inherited — *assumed, verify on first run*, because
the whole per-line `!ARGS!` model depends on it.

An earlier draft recommended **tier 1 inline in `hotwire.bat`, topics split
into `conf/`**. Counting the reference server's 23 live convars against that
layout shows why it does not work:

| conf/ file | tier 1 | tier 2 |
|---|---|---|
| network | 3 | **0** |
| world | 4 | **0** |
| listing | 2 | 3 |
| admin | 1 | 1 |
| logs | 0 | 4 |
| gameplay | 0 | 5 |

Tier 1 and the topic split cut across each other. Every network and world
convar is tier 1, so pulling tier 1 inline leaves two empty files and one
holding a single line. The two schemes are not composable at this size.

Chosen: **split by tier.** `hotwire.bat` holds logic plus 10 boilerplate
options; `conf/common.bat` holds tier 2 (13 confirmed, target 20-30);
tier 3 is generated. Two files a human edits, and 30 options is 60 readable
lines — the topic split solves a problem that does not exist yet.

Revisit when `convars.py` has run. If `ShowInAdminUI` yields ~40 admin-facing
convars weighted toward gameplay tuning, `conf/common.bat` gets unwieldy and
splitting *it* by topic — not the whole launcher — becomes right. The trigger
is roughly **gameplay passing 15 options**.

Distribution note supporting this: of the 23 in use, **17 are `server.*`**.
The tail is 3 convars across 3 classes, one each (`decay`, `rideablehorse`,
`hackablelockedcrate`). A heavy head and a long thin tail is the shape to
design for: tier 2 is mostly one class, tier 3 is where the many one-off
classes live — and it is generated and grouped by class automatically, so it
never needs hand-splitting at all.

## ADR-0011 — The public repo carries a sanitized brief; the internal one stays untracked

**Date:** 2026-09-04 · **Status:** ACCEPTED

The original brief, `HANDOFF.md`, describes one production server in enough
detail to be worth not publishing: install path, identity, map seed, host
hardware, the plugin roster, and pointers to two private repositories. It is
also the most useful document in the project, so deleting it was never an
option.

Alternatives: sanitize it in place, keeping one file; leave it and gate the
decision until the repo is flipped public.

Chosen: **`HANDOFF.md` is gitignored and stays on the author's disk. A shorter
`BRIEF.md` is the public version** — same architecture, same measured numbers,
same ordering of the work, with the identifying detail removed. `CLAUDE.md`
points contributors at `BRIEF.md`.

Consequences, and one of them is a job still to do:

- Public docs may no longer cite the private repositories. References to a
  sibling plugin's tooling and ADRs are now described by what they assert
  rather than by where they live. `HANDOFF.md` keeps the concrete pointers,
  because its only reader has access to them.
- Named plugins that are not public — the reference server's event plugin and
  its PVP-target plugin — are now referred to by role in `docs/`. Plugins
  Hotwire might integrate with (AdvancedStatus, Hud, ZoneManager) keep their
  names, because a stranger needs them.
- Evidence that lived only in `HANDOFF.md` moved into `docs/RESEARCH.md`, so
  no public document points at a private one. Source A's 23 convars are there
  in full.
- **`HANDOFF.md` remains in this repository's git history**, in commits
  `3e54724` and `3f0dc61`. Untracking a file does not remove it from history.
  That must be resolved before the repository is made public — see
  `docs/OPEN-QUESTIONS.md`.

## ADR-0012 — Two schedule lists, not one typed list

**Date:** 2026-09-04 · **Status:** ACCEPTED

Alternatives: a single `Schedule` array where each entry carries a type.

Chosen: **separate `Restarts` and `Updates` lists.** The typed single list is
the smaller implementation — one code path, one set of commands — but the two
lists read more obviously at a glance, and "this server never updates
unattended" becomes a visibly empty list rather than a property you have to
check on every entry. For a file whose whole value is that a stranger can read
it and be right about what it does, that legibility is worth the duplication.

The duplication is contained: entries share a base type, the scanner iterates
both lists through one method, and the edit commands address either list
through a small view so they cannot silently edit a copy.

One ambiguity the single list would not have had, and the answer:
**if a restart and an update fall at the same minute, the update wins.** An
update entry is a restart entry that also writes a flag, so running it
satisfies both. Validate beats update for the same reason. Documented in
`docs/CONFIG.md`.

## ADR-0013 — Entries are local wall-clock time, guarded by a persisted last-fired record

**Date:** 2026-09-04 · **Status:** ACCEPTED

`"HH:mm"` plus local date arithmetic misfires across a DST boundary: a 02:30
entry happens twice in autumn and not at all in spring.

Alternatives: interpret entries as UTC (unambiguous, but the admin who typed
05:00 gets a restart that walks an hour twice a year relative to their
players); local time with no guard (simplest, accepts one double restart a
year).

Chosen: **local wall-clock time, plus a record of when each entry last fired.**
An entry refuses to fire again within 20 hours, configurable. Local time is
what an admin means when they type 05:00. The autumn repeat is suppressed by
the guard; the spring skip is logged and simply waits for the next day.

**The guard has to be on disk, and that is the whole reason it works.** The
autumn repeat does not arrive in the same process: the first 02:30 restarts
the server, the launcher brings it back, and the second 02:30 arrives an hour
later in a fresh process with an empty memory. So the record lives in
`oxide/data/Hotwire/last_fired.json`, keyed by type, time and days rather than
by list index, so reordering the config does not reset it.

A negative interval — the clock moved backwards under us, from an NTP
correction or the DST shift itself — counts as "recently" rather than firing
again immediately.

Manual restarts are exempt from the guard and do not feed it. An admin asking
for a restart means it.

**Amended 2026-09-05.** Local wall-clock time is only honest if the plugin says
which clock. Every time it prints now carries its zone and DST state, computed
for the moment being displayed rather than for now, and any line showing a next
occurrence says when a clock change falls between now and then. The guard
handles the ambiguity; this makes it visible.

## ADR-0014 — The plugin has no compile-time dependency on Assembly-CSharp

**Date:** 2026-09-04 · **Status:** ACCEPTED, then **partially superseded by
ADR-0016** on 2026-09-05. It still holds for everything that schedules,
announces or shuts down. The admin menu breaks it, deliberately and in one
isolated region.

This started as a way to handle the four unverified API calls and turned into
the most load-bearing decision in the plugin, so it gets its own ADR.

Three of the four assumed calls were needed only for shutdown and kicking:
`ConVar.Global.quit(new ConsoleSystem.Arg(...))`, `ServerMgr.Instance.Restarting`,
and the Covalence kick. Each is reachable a second way that touches no
Facepunch type:

| Wanted | Assumed Facepunch call | Used instead |
|---|---|---|
| Clean shutdown that saves | `ConVar.Global.quit(new ConsoleSystem.Arg(...))` | `server.Command("quit")` — runs the same console command |
| "Is a restart already running" | `ServerMgr.Instance.Restarting` | the plugin's own flag |
| Kick with a reason | — | `IPlayer.Kick(string)`, a Covalence interface |

**The argument is the safety envelope, not tidiness.** A wrong guess at a
Facepunch signature is a *compile* error. A plugin that does not compile is a
plugin that never restarts the server — the exact failure the envelope
forbids — and `try`/`catch` cannot save you from it, because the code never
runs. Every remaining assumption in the plugin is a *runtime* one, wrapped, so
being wrong costs one optional feature and not the schedule.

Consequence: three entries in `docs/OPEN-QUESTIONS.md` close by not being
needed, and the plugin keeps compiling across Rust updates that rename things.
The cost is that `server.Command` is a string, so a typo is not caught by the
compiler either — but a typo in a four-letter word in one place is a smaller
risk than a moving signature in a hot path.

## ADR-0015 — Recurrence is stored as structured fields, not cron and not a phrase

**Date:** 2026-09-05 · **Status:** ACCEPTED

Schedules have to express more than "a time and some weekdays": daily, weekly,
every Tuesday at 3am, the second Tuesday of the month, and — the one that
actually matters for Rust — **the first Thursday of the month**, which is force
wipe day and the most valuable update schedule this plugin can hold.

Alternatives: a cron expression, or a richer human-readable string.

**Cron** is compact and universal, and cannot express an ordinal weekday at
all. Standard five-field cron has no syntax for "second Tuesday"; that requires
Quartz's non-standard `#`. It is also opaque to a non-technical admin and
awkward to render as an editable panel.

**A richer string** (`"first Thursday"`, `"day 15"`, `"every 2 days"`) is the
nicest thing to hand-edit and was a close call. It lost on the menu: a panel
must parse the string and write it back, so somebody's hand-written phrasing
gets silently rewritten on save, and error messages degrade to "I could not
read that" rather than naming the field.

Chosen: **explicit fields, with `Repeat` selecting which of them are read.**
Every value validates on its own, an error names the exact field, and each
field maps to one control in the menu.

The string form is not lost — `ApplyPattern` accepts the same words on the
console (`hotwire add update 20:00 first Thursday`) and writes the structured
form. The terse input stays; the ambiguous storage does not.

Three details settled rather than left to emerge:

- **No `Fifth` ordinal.** Not every month has one. `Last` is what people mean.
- **A `DayOfMonth` above 28 is skipped in short months, not clamped.** A
  restart that silently moves is worse than one that does not happen. The
  plugin warns at load when an entry can do this.
- **`EveryNDays` stores an anchor date**, filled in on first validation, so
  "every 2 days" is a fixed set of days rather than one that re-anchors on
  every reload.

The next-occurrence search walks forward a day at a time for up to 366 days and
asks one predicate whether each date matches. Slower than per-mode arithmetic
and much harder to get wrong: one predicate covers all six modes, a month
without a 31st simply never matches, and there is no month- or year-boundary
arithmetic to misplace.

## ADR-0016 — The admin menu lives in Hotwire.cs, and knowingly breaks ADR-0014

**Date:** 2026-09-05 · **Status:** ACCEPTED — partially supersedes ADR-0014

Rust's UI has no Covalence route. `CuiHelper.AddUi` takes a `BasePlayer`, and
building a panel means naming `BasePlayer`, `CuiElementContainer`, `CuiPanel`,
`CuiButton` and `CuiLabel`. So a menu cannot be written without reintroducing
the compile-time Facepunch dependency ADR-0014 removed.

Alternatives: a companion `HotwireMenu.cs` plugin talking to Hotwire through a
plugin API, which would keep the scheduler free of Facepunch types entirely and
let the menu fail to compile without consequence.

Chosen: **the menu lives in `Hotwire.cs`.** The trade, stated honestly rather
than argued one way:

- *Against:* if a Rust update breaks the CUI surface, the whole plugin stops
  compiling, and scheduled restarts stop with it. That risk is real — two
  plugins on the reference server are dead right now from a `StringView`/`Span`
  change, waiting on their authors — though `BasePlayer` and `CuiHelper` are
  among the most stable things in the game and rarely move.
- *For:* splitting adds a cross-plugin `Call()` surface, and those fail
  **silently** when they fail. That is not theoretical either: this project has
  already been bitten by a silent typed-argument mismatch in a plugin API. It
  also means two files to install and keep in version step.

What makes the risk survivable is ADR-0006's condition, which is already met:
**every single thing the menu does, the chat commands do.** If this region ever
stops compiling, the fix is to delete it. The schedule remains fully editable
from chat and console, and no data lives only in the panel.

Containment, so that deletion stays a real option:
- All of it in one `#region Admin menu`, with no CUI type used anywhere else.
- One root element name, destroyed before every redraw, on close, on
  disconnect, and on unload.
- `BasePlayer` re-fetched at each use and never held across a frame (rule 4).
- A draw failure is caught, logged, and closes the menu rather than escaping.

Two implementation choices worth recording:

- **No draft state.** Each click edits the entry and saves immediately, then
  redraws. Fewer moving parts than save/cancel, and an edit cannot be lost by
  disconnecting mid-change. New entries start disabled, so a half-configured
  one cannot fire, and a change that invalidates a live entry disables it.
- **No input fields.** Time, day-of-month, interval and date are stepped with
  buttons. `CuiInputFieldComponent` is one more unverified component and one
  more way to end up with `5:0` in a field that has to parse.

## ADR-0017 — Editing the entry a countdown came from cancels that countdown

**Date:** 2026-09-05 · **Status:** ACCEPTED

Found in use: an admin disabled a scheduled restart in the panel while its
countdown was already running. The button flipped to `OFF`, the entry read as
disabled, and the server restarted a couple of minutes later anyway.

Nothing was malfunctioning. A countdown runs from state captured when it
started, so switching the entry off only stopped it happening *again*. But the
panel showed "disabled" and nothing else, and "disabled" reads as "called off".

Chosen: **disabling, deleting or rescheduling the entry a live countdown came
from cancels that countdown**, from the panel and from chat alike, and says so.
Re-enabling does not cancel, and unrelated entries are untouched.

Cancelling is the safe direction. The envelope forbids restarting a server
unannounced, and a restart the admin believes they called off is worse than
unannounced — they have stopped watching for it. The opposite error, a restart
that does not happen, is loud, recoverable, and one `hotwire now` away.

The second half of the fix is that the panel now shows a running countdown at
all, as a banner with a cancel button. The state was invisible, and an
interface that hides the most important thing on the screen will keep producing
this mistake whatever the semantics underneath are.

## ADR-0018 — Tier 3 is a curated list the machine checks, not a generated dump

**Date:** 2026-09-05 · **Status:** ACCEPTED — supersedes ADR-0008's third tier
and closes its open sub-decision

ADR-0008 said tier 3 should be generated because it is large and moves. That
was half right and the wrong half was acted on.

A launcher containing every convar in the assembly is **worse** than one
containing none. Several hundred of them are `ai.*`, `debug.*` and `antihack.*`
— runtime and diagnostic surface nobody sets at launch — and burying the twenty
that matter among them destroys the only thing that makes the file good, which
is that a person can read it. ADR-0008 even said so about inlining, then
proposed generating the same content into a file next door.

The generator's value was never the list. ADR-0008's own argument was that
**defaults churn faster than names**, and that the danger is a comment claiming
a default that has quietly moved. That danger is unchanged by curation.

Chosen: **the option list is curated by hand; the machine checks it.**

- `tools/convars.py` gains `--check <launcher>`, which reads a launcher and
  reports every convar in it that no longer exists in the installed build, and
  every comment whose claimed default the build disagrees with. That is the
  job that mattered, and it turns a Rust update from a mystery outage into a
  two-line diff.
- Its default output is curated rather than exhaustive, from two sources that
  are not opinions of ours: `[ServerVar(ShowInAdminUI = true)]`, which is
  **Facepunch's own list of the convars worth showing an admin** and ships
  inside the game; and the seed of names independent configuration sources
  agree on, gathered in `docs/RESEARCH.md`. `--all` still prints the long tail
  for searching.
- The curated names go into the launcher with real prose, the way tiers 1 and
  2 already do. There is no longer a meaningful line between tier 2 and tier 3
  — there is one hand-written list, and a checker that keeps it honest.

Consequence: **`tools/Test-Launcher.ps1` is not needed and will not be built.**
`--check` does its job in the tool that already exists, in Python rather than
PowerShell, and works wherever the assembly can be copied.

What this does not change: never write a convar or a default from memory. The
curated list is only as good as its sources, and the checker exists precisely
because a list nobody verifies rots.
