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

**Date:** 2026-09-04 · **Status:** ACCEPTED

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

**Date:** 2026-09-04 · **Status:** ACCEPTED

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

**Date:** 2026-09-04 · **Status:** ACCEPTED

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
Untitled Rust Server";`. `convars.py` should report it as a column.

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

## ADR-0014 — The plugin has no compile-time dependency on Assembly-CSharp

**Date:** 2026-09-04 · **Status:** ACCEPTED

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
