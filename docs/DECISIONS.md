# Architecture decision records

Newest last. An ADR is added whenever a design choice is made or reversed.
These six were taken during the briefing, before any code existed; the
reasoning is recorded in each one.

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
superseded that decision**, having concluded that CUI lifecycle is the most
bug-prone part of Oxide plugin work. That lesson has already been paid for
once.
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

**Date:** 2026-09-04 · **Status:** ACCEPTED, then amended twice by what the
evidence turned out to say.

"The top 20 settings admins change" is a claim about a population of admins,
and inventing it would undermine the one thing this project sells: that the
annotations can be trusted.

Two real sources, in order:

1. **`[ServerVar(ShowInAdminUI = true)]`** — *assumed, unverified, check
   first.* Rust's in-game admin UI shows a curated subset of convars. If that
   selection is an attribute property, it is Facepunch's own opinion about
   which settings admins touch, it is machine-readable, and tier 2 stops being
   a judgement call. Teach `tools/convars.py` to report it.
2. **A real server's live command line** — 23 convars, one real admin,
   verified working. **n = 1**: evidence, not a survey.

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

Source 2 was widened from n=1 to three independent samples: one production
server's command line, and two hosting providers' configuration surfaces. 41
distinct convars across the three, of which 7 appear in all three
(`hostname`, `description`, `headerimage`, `tags`, `maxplayers`, `worldsize`,
`seed`) and 10 more in two. Those 17 became the seed.

Two artifacts in that method are worth knowing, because both would mislead
anyone repeating it:

- **Ports look unimportant and are not.** `server.port` and `server.queryport`
  appear in only one source, because the other two generate `server.cfg` and
  ports are conventionally passed on the command line instead. The count
  measures where a setting is written, not how much it matters.
- **A hosting panel's form is not a list of convars.** Two sources offered
  gather-rate settings; the assembly has no `gather` class at all. A panel
  lists what that panel can change, some of which it implements itself.
  Cross-referencing documentation tells you what people want to configure.
  Only the assembly tells you what exists.

## ADR-0010 — Config file layout: by tier, not by topic (for now)

**Date:** 2026-09-04 · **Status:** SUPERSEDED by ADR-0018 on 2026-09-05.

Its trigger fired and the answer was that the question had dissolved. This ADR
chose between two ways of splitting the options across files, and asked to be
revisited once `convars.py` ran. It ran, and ADR-0018 curated a small
hand-written list out of the roughly sixteen hundred convars a build contains.
The tier boundary this ADR was reasoning about no longer exists: there is one
file, and no split to choose.

The counting in it is still worth reading. It is a good demonstration that two
plausible ways of organizing the same thing can cut across each other so badly
that neither survives contact with the data.

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

Consequence: three of the four assumed Facepunch calls stop being assumptions
by not being needed at all, and the plugin keeps compiling across Rust updates
that rename things.
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

**Verified 2026-09-05, and it was not true when first written.** Checking which
names the region defines and who uses them found four references reaching in
from outside. Three are unavoidable — a command registration in `Init`, a
cleanup call in `Unload`, and a `case` in the command switch — and each now
carries an `// ADR-0016: goes with the menu` marker, so deleting the region is
a mechanical four-step rather than a hunt through compiler errors.

The fourth was `Ordinalise`, which turns 15 into "15th" for schedule
descriptions and had drifted into the menu region because that is where it was
first needed. Nothing about it is menu-related, and while it lived there this
ADR's central promise was simply false: deleting the region would have broken
`DescribeRecurrence`, which every `hotwire list` depends on. It was moved out,
and in 1.1.0 it was deleted outright: ADR-0020 replaced English ordinal
suffixes with a translatable sentence, so nothing generates "15th" any more.

**Re-verified 2026-09-05 after ADR-0020**, which touched most of the region.
The three markers still stand and no new reference reaches in. `RepeatLabel`
was made an instance method to read from lang; it lives inside the region and
is used only there, so it goes when the region goes. `DayNameShort` lives
outside and is used only inside — the mirror of the `Ordinalise` case, and
harmless in a way that one was not: deleting the region leaves an unused
private method, not a broken caller.

**To delete this region:** remove `#region Admin menu` through its `#endregion`,
then the three lines marked `ADR-0016`. Nothing else refers to it.

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
  agree on, recorded in ADR-0009. `--all` still prints the long tail for
  searching.
- The curated names go into the launcher with real prose, the way tiers 1 and
  2 already do. There is no longer a meaningful line between tier 2 and tier 3
  — there is one hand-written list, and a checker that keeps it honest.

Consequence: **`tools/Test-Launcher.ps1` is not needed and will not be built.**
`--check` does its job in the tool that already exists, in Python rather than
PowerShell, and works wherever the assembly can be copied.

What this does not change: never write a convar or a default from memory. The
curated list is only as good as its sources, and the checker exists precisely
because a list nobody verifies rots.

## ADR-0019 — Updating on every restart is the default; flag-gating is opt-in

**Date:** 2026-09-05 · **Status:** ACCEPTED

The launcher shipped with flag-gated updates as its only behavior. That is the
right policy for a server whose restarts are automated and the wrong default
for a stranger who has just downloaded it.

**Rust clients update themselves.** A server that never updates does not fall
behind gracefully — the protocol stops matching and nobody can connect at all.
So the failure mode of flags-only is not a stale server, it is a dead one, and
it lands on force wipe day, and it lands hardest on the person who did not read
far enough to learn what a flag was. A default should not punish the reader who
stopped early.

Chosen: **`UPDATE_MODE=always` by default, `hotwire` opt-in.**

This is not a retreat from the project's argument. That argument was never
"updating on restart is bad" — it is that *unattended, frequent, automatic*
restarts should not drag updates along with them. Someone restarting by hand
once a week and picking up an update is fine, and is what they expect. A plugin
restarting at 5am daily and pulling whatever build is current is the thing
worth preventing. The policy should match who is deciding when the server
restarts, and the two modes say exactly that.

`UPDATE_ON_LAUNCH` is removed. It was a half-measure aimed at the same gap and
is subsumed by the modes.

**hotwire mode carries a backstop**: if `MAX_DAYS_WITHOUT_UPDATE` (14) passes
with no update, one happens anyway and says so loudly in the console. Fourteen
days never fires on a monthly cycle that is working, and turns "my server is
dead and I do not know why" into a line of log. A missing stamp file counts as
forever, so a fresh install updates on its first start rather than waiting a
fortnight to discover it is out of date. Set it to 0 to disable.

The backstop is the one place the launcher acts against an explicit
instruction. It is justified by the safety envelope's own asymmetry: the
project's whole premise is that a server which cannot come back is worse than
one that comes back at an awkward moment.

## ADR-0020 — Sentences are composed from lang keys, not concatenated in code

**Date:** 2026-09-05 · **Status:** ACCEPTED

Announcements were lang strings from the start (ADR-0004), but the schedule
*descriptions* were not. `"the " + ordinal + " " + DayList(e) + " of the
month"` produces correct English and untranslatable anything-else: word order
differs between languages, and a key that only covers the frame around a
hard-coded middle cannot be repaired by a translator.

Chosen: **every string a player can see is a key, and every sentence takes its
parts as `{0}` arguments.** Ordinals, weekday names, the kind of restart, the
recurrence and the validation complaints are all keys in their own right. The
weekday names in particular no longer come from `DayOfWeek.ToString()`, which
is English on every server regardless of its culture.

Two consequences worth stating, because both were bugs rather than
inconveniences:

**Arguments must be resolved per recipient, not once.** `Broadcast` translated
its template for each player and then interpolated a word that had been
resolved once in the server's language. A second `Broadcast` overload takes a
factory that runs per recipient. The status bar's label and the kick reason had
the same shape and are fixed the same way; the bar's parameter dictionary is
now rebuilt per player rather than shared.

**Code that finds a fault usually cannot translate it.** `ValidationError` and
`ApplyPattern` are static and have no viewer. They return a `Problem` — a key
and its arguments — and whoever displays it calls `Text()` with the reader's
id. This is also what lets the same fault reach the console in the server's
language and the panel in the player's.

**Not converted: the `hotwire check` diagnostic dump.** It is a console tool
for whoever runs the server, never seen in game, and its forty column-aligned
fragments would make the lang file worse for nobody's benefit. The line is
between prose a player reads and diagnostics an admin reads, and it is drawn
deliberately rather than by exhaustion.

The command grammar stays English on both sides of that line. `weekdays`,
`first Thursday`, `once 2026-12-24` are things a person types, not things they
read, and a parser that accepted translated tokens would accept a different
language on every server. Only the complaint about a bad token is translated,
and where a message lists the accepted words they arrive as an argument so the
list cannot drift out of step with the parser.

The lang file goes from 30 keys to 153. Lang files are written once and never
rewritten, so upgrading servers keep their old file and fall back to English
until they delete it — `docs/CONFIG.md` says so.

## ADR-0021 — `README.md` is the uMod listing, unwrapped and without tables

**Date:** 2026-09-05 · **Status:** ACCEPTED

uMod builds a GitHub-hosted plugin's page from **`README.md` in the repo
root** — the paths are convention, not configuration, which is why the
Repository tab offers only a repo name and a sync trigger. `LICENSE.md` gives
the license the same way, and a GitHub *release* pushes the plugin itself.

So `README.md` is the listing. It cannot be the repo's own front page as well
without one audience reading the other's document, so the launcher moved to
`docs/LAUNCHER.md` and the README leads with the plugin. The launcher is half
this project and the more novel half, which is the cost of the arrangement and
worth naming: whoever arrives from GitHub now meets a plugin first.

**The README is not wrapped at 76 columns and contains no markdown tables.**
Alone in this repo, and deliberately.

The listing renderer deletes a newline inside a paragraph without putting a
space in its place, so a wrap between "counts down," and "kicks" arrives as
`counts down,kicks`. Nine of those shipped in the first draft and every one
read as a typo in something nobody had mistyped. A table's row breaks are
newlines inside a block, so they go the same way: the whole table arrives as
one run-on paragraph with `|---|---|---|` in the middle of it. Escaping the
pipes in the cells does not help, because the problem was never the pipes.
Lists, headings, fenced code blocks and blank-line paragraph breaks all
survive, so anything tabular is a list.

**That evidence comes from pasting into the Documentation tab's editor, not
from a repository sync**, and the two may not behave alike. The format is
chosen for the renderer that breaks rather than the one that does not care:
GitHub renders a single-line paragraph and a wrapped one identically, so
writing for the stricter reader costs nothing and cannot be wrong. If a sync
turns out to render wrapped markdown correctly, that is a reason to relax this
and not a reason to have waited.

`docs/LAUNCHER.md`, `docs/CONFIG.md` and the rest are GitHub-only and keep the
repo's normal style — wrapped, tables where a table helps.

## ADR-0022 — Only a completed update consumes the flag or resets the backstop

**Date:** 2026-09-05 · **Status:** ACCEPTED

The launcher deleted `UPDATE.flag` and wrote the backstop stamp
unconditionally, at a point reachable from the "giving up on steamcmd" path
and from a failed framework download. Both were found in review, and both
inverted a documented promise.

**"One flag buys one update" was really "one flag buys one attempt."** An
operator or the plugin asks for an update, steamcmd fails five times, the flag
is eaten, one line scrolls past, and the next restart is a plain restart that
nobody knows was supposed to be an update. Rule 2 says a bug must never leave a
server unable to restart and never restart one unannounced; this is neither,
but it is the same category of silent wrong outcome, and the flag is the entire
interface between the two halves (rule 3). It has to mean what it says.

**The backstop could never fire in the one case it exists for.** A server that
cannot reach Steam rewrote its own "last updated" stamp on every failed try, so
the clock measuring how long since a successful update reset every fifteen
seconds. The backstop is there to catch a server drifting silently out of date
until it stops being joinable. A server that cannot reach Steam is exactly that
server.

Chosen: **track success explicitly** — `STEAM_OK` on the steamcmd path,
`FRAMEWORK_OK` on the extract, and consume the flag and write the stamp only
when both are set. When they are not, a banner says the update did not happen,
that the flag is being kept, and that the clock was not reset.

Failing this way means a server that cannot reach Steam retries on every
restart forever. That is the correct direction: it is loud, it is visible in
the console every time, and it errs toward updating rather than toward quietly
believing it is current.

Also fixed here: the elapsed-days check used PowerShell `[int]`, which rounds,
so 13.6 days tripped a 14-day backstop half a day early. It is `[math]::Floor`
now, which is what "full days since" meant.

**None of this has been executed.** It is read-verified only.

## ADR-0023 — A crash loop is not a restart loop, and its first log is kept

**Date:** 2026-09-05 · **Status:** ACCEPTED

The launcher rotated the server log once per pass and culled to `LOG_KEEP`
(14) unconditionally, then relaunched after a flat 15 seconds. A server dying
on boot therefore destroyed the evidence of why in about three and a half
minutes, leaving fourteen identical near-empty logs. The block's own comment
says it exists so "a restart destroys the log of whatever went wrong before
it" cannot happen; under the one failure where that log is the only thing
anyone wants, it did exactly that.

Chosen: **time every run.** Shorter than `CRASH_SECONDS` (60) is a crash, not a
restart — a Rust server takes minutes to boot, so seconds means it never
started. Consecutive crashes are counted, and:

- The **first** crash of a streak rotates to `server_crash_*`, which the cull
  glob does not match. Later ones rotate normally; they repeat the first and
  keeping all of them is how a crash loop fills a disk.
- The delay **backs off** 15/30/60/120/300. This also throttles `HOOK_BEFORE`,
  which for anyone hooking a backup into it is the expensive part.
- After `MAX_CRASH_STREAK` (10) the launcher **stops**, says why, and names the
  preserved log. `0` restores the old loop-forever behavior.

This reverses a documented non-goal — "recover from a crash loop" was listed
under what the launcher does not do. It still does not *recover*; it fails
visibly instead of silently, which is the difference worth having.

Rule 2 says a bug must never leave a server unable to restart, and stopping
after ten crashes is the closest thing in this project to doing that
deliberately. It is justified by what the tenth relaunch actually is: the
server has not started once, the config has not changed, and the next attempt
cannot succeed either. What stopping costs is nothing; what it buys is a person
noticing.

**If the timestamp call fails, the run counts as long.** Erring that way keeps
the server running. Erring the other way would stop a working server over a
failed clock read, which is the failure this project exists to prevent.

**Not executed when written.** The crash path still is not — it needs a
genuine boot failure to exercise.

## ADR-0024 — The RCON password is read with delayed expansion off, and quoted

**Date:** 2026-09-05 · **Status:** ACCEPTED

Three separate faults on one value, found together.

**The shipped launcher never quoted it.** `+rcon.password !RCON_PASSWORD!`
passes an unquoted argument, so a password containing a space arrives as two
arguments and the server listens on the first word. Passwords with spaces are
good practice; this punished them silently.

**A `!` in the password was eaten before it was ever used.** `secrets.bat` is
`call`ed from a script running under `EnableDelayedExpansion`, so the
`set "RCON_PASSWORD=..."` line *inside secrets.bat* is parsed with expansion
on and loses everything from a `!` onward. The earlier advice — "avoid `!` and
`^`" — treated a fixable bug as a rule for the user to remember, which is the
wrong trade for a password.

Chosen: **read the secret with `setlocal DisableDelayedExpansion` around the
`call`**, then carry the value out through a `for /f` whose block was parsed
while expansion was still off, which is what makes the `!` survive. Then quote
it at the point of use, with `!VAR!` rather than `%VAR%`: a percent-expanded
value is rescanned for `!`, an exclamation-expanded one is not.

`!`, `%`, `^` and spaces are now read exactly as written. A `"` or a leading
`;` still cannot pass, because `for /f "delims="` uses the first for quoting
and treats the second as end-of-line. Those two fail **loudly** at startup with
a message naming the cause, rather than starting the server on a password that
is not the one in the file. A silent wrong password is the failure worth
engineering against; a refusal to start with a reason is not.

**The third fault was mine, twice over, and is worth recording as a method
failure rather than a code one.** A three-quote `+rcon.password "%PW%"` turned
up in the reference server's configuration repository, and I reported it as a
live defect on that server: an unterminated quote swallowing every later
option, including `-logfile`. I was wrong. The launcher on that server has
always been correct. What I had found was a *generated mirror* of it — that
repo regenerates the file on every backup, scrubbing the password out — and the
missing quote came from the scrubber's own regex, where an ERE alternation is
leftmost-longest and the bare-token branch beat the quoted one by exactly the
closing quote of the `set`.

Two things went wrong and neither was a typo. I read a file without
establishing whether it was a source or an artifact, and I asserted a live
failure from a diff rather than from the running system — a check that took one
`grep` on the actual server and immediately disproved it. The real defects
above are real, and were found by comparing the two launchers against each
other; the invented one came from trusting a derived file. Verify against the
thing that runs.

**Executed 2026-09-05**, on the reference server, after being written blind.
A clean option list passes; a query port set equal to the game port is caught
by name and refuses the launch. The negative path was tested deliberately —
a validator that has only ever returned "no problems" has not been tested at
all, and the two paths are different code.

## ADR-0025 — Validate what fails opaquely, at the layer that knows the answer

**Date:** 2026-09-05 · **Status:** ACCEPTED

The launcher checked that `RCON_PASSWORD` was *defined*. A two-character
leftover in a secrets file satisfied that, went onto the command line as
`+rcon.password "xx"`, and the server died in `Bootstrap.Init_Tier0` with
`ArgumentException: String cannot be of zero length` — because Rust redacts the
password out of its own logged command line, and an implausible value makes
that redaction throw before anything else initializes.

The engine's message names no file, no convar and no cause. The launcher knew
exactly which file the value came from and said nothing, because "defined" was
the only question it asked.

Chosen: **check the values that produce opaque failures, and name the file.**
Empty, shorter than eight characters, still the example, or containing a double
quote — each refuses to start with its own line and the path to the secrets
file. A missing `RustDedicated.exe` under `ROOT` is refused the same way.

The test runs in PowerShell, not with batch string slicing. The value is
untrusted text, and `if "!PW:~7,1!"==""` breaks on a password containing a
quote — the comparison meant to catch a bad password would itself be the
syntax error. Asking a language with real strings costs one process at startup.

**This is deliberately not a general "scan ARGS for empty values" check.** That
needs quote-substitution on a string full of quotes, which is exactly the kind
of clever batch that this file already got wrong once. Every value in `ARGS`
that comes from a variable rather than a literal is checked individually
instead; today that is the password, and a new one is three lines.

Refusing to start is the right failure here even under rule 2. The alternative
is not a running server, it is the same dead server with a worse message.

## ADR-0026 — MAJOR.MINOR is shared; PATCH belongs to one half

**Date:** 2026-09-05 · **Status:** ACCEPTED · **Supersedes part of the 1.0.0
changelog preamble**

The changelog promised that a version "means the same thing whichever half you
are holding." Three launcher-only fixes in one afternoon broke that promise,
and keeping it would have meant publishing a plugin release containing no
changes.

Chosen: **`MAJOR.MINOR` always agrees between the plugin and the launcher;
`PATCH` advances for whichever half was edited.** A minor release moves the
pair together and resets both patch numbers to 0.

The first two numbers are the part that carries meaning across the flag file,
which is the entire interface between the halves (rule 3). If the launcher is
on 1.1 and the plugin is on 1.1, they were built for each other. A third number
that differs says only that one of them has been fixed since, which is true and
useful, where a synchronized number bought by an empty release would be neither.

The cost is that "Hotwire 1.1.3" is ambiguous about which half. That is paid
by naming the half in every changelog heading, and by the two artifacts
carrying their own version — `hotwire check` prints the plugin's; the
launcher's is a comment in its banner, which is weaker and is worth revisiting
if support ever needs it echoed at startup. The version worth quoting in a bug report is
"Hotwire 1.1", plus whichever full number the half in question prints.

Rejected: strict lockstep, which forces empty releases; and fully independent
versioning, which loses the one guarantee a user actually needs, that the two
halves in front of them are a matched pair.

## ADR-0027 — The launcher validates the option list before the engine sees it

**Date:** 2026-09-05 · **Status:** ACCEPTED · **Extends ADR-0025**

ADR-0025 checked one value, the RCON password, because that was the one that
had just cost an afternoon. The same failure exists for every other option:
Rust ignores a convar it does not recognize, and accepts an empty value for one
it does. Both are silent. A typo in section 4 produces a server that starts
happily with the setting absent, and nothing anywhere says so.

Chosen: **tokenize the composed `ARGS` and check it before launch**, and check
the section 1 settings before that. Every problem is reported, not just the
first, and the launcher refuses to start.

Three decisions inside that are worth recording.

**The check is written in PowerShell, and the script contains no double quote,
percent sign or exclamation mark.** Those are the three characters cmd would
rewrite on the way through; where the script needs them it builds them with
`[char]`. The script is assembled one readable line at a time into a variable
rather than written as one enormous line. This file has been bitten twice by
clever quoting, and the answer is to make the clever part unreachable by the
parser rather than to escape it correctly.

**`ARGS` reaches PowerShell through the environment, not a file and not the
command line.** The command line is out because `ARGS` is full of quotes and
pipes by design. A file is out because `ARGS` carries the RCON password, and a
file puts it on disk where a backup running at that moment can capture it —
which is exactly how a scrubbed mirror of this project's own launcher ended up
in a git repository. `RCON_PASSWORD` is already in the process environment, so
the environment adds no exposure that did not exist.

**A missing PowerShell skips the check rather than blocking the launch.** The
check is a diagnostic. Losing a diagnostic must not cost a working server —
rule 2 points one way here and it is not the strict one.

Deliberately not attempted: type and range checking against the game's own
convar metadata. That needs a real `Assembly-CSharp.dll`, which is what
`tools/convars.py --check` is for and what it already reads. The launcher
checks what can be known from the option list alone — structure, emptiness,
duplication, ports, and a name that cannot be a convar. Guessing a range for a
convar whose bounds nobody has read out of a build would be rule 6 all over
again.
