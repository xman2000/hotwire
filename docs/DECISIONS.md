# Architecture decision records

Newest last. An ADR is added whenever a design choice is made or reversed.
These six were taken during the briefing, before any code existed; the
reasoning is in `HANDOFF.md` and is summarised here.

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
On the reference server, Flashpoint already draws its event timers through
AdvancedStatus (67 references) and PvpTargetCounter draws into Hud (57). A
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

**But `a sibling plugin` chose a CUI panel in its ADR-0001 and superseded it in
ADR-0007**, and that repo's `CLAUDE.md` says plainly that CUI lifecycle is the
most bug-prone part of Oxide plugin work. That lesson is already paid for.
Conditions: strict panel lifecycle, destroy on disconnect, and **chat commands
that do everything the menu does**, written first, so a broken panel never
means a schedule cannot be changed.

## ADR-0007 — Restart-on-new-framework-release is opt-in, default off

**Date:** 2026-09-04 · **Status:** ACCEPTED

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

**Date:** 2026-09-04 · **Status:** PROPOSED

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
   verified working on protocol 2632.287.1. Listed in `HANDOFF.md` §8b.
   **n = 1**: evidence, not a survey. Say so in the docs.

Status stays PROPOSED until source 1 is checked.
