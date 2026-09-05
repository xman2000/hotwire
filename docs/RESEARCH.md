# Research — what admins actually configure

Gathered 2026-09-04. The question this answers: **which convars belong in
tier 2**, without inventing a claim about a population of admins (ADR-0009).

Method: collect independent samples of real configuration surfaces, count how
many name each convar. A convar that three unrelated sources all expose is
evidence; one that appears once is a lead.

## Sources

| # | Source | Kind | Convars named |
|---|---|---|---|
| A | The reference server's live command line | one real server, protocol 2632.287.1 | 23 |
| B | [XGamingServer server.cfg generator](https://xgamingserver.com/tools/rust/server-config) | hosting tool, has vanilla/2x/5x/PvE presets | 17 |
| C | [low.ms server settings guide](https://low.ms/knowledgebase/rust-server-settings-guide) | hosting-provider documentation | 25 |

41 distinct convars across the three.

## Result

**7 named by all three** — the irreducible core:

`server.hostname` `server.description` `server.headerimage` `server.tags`
`server.maxplayers` `server.worldsize` `server.seed`

**10 more named by two of three:**

`server.identity` `server.level` `server.url` `server.logoimage`
`server.saveinterval` `server.pve` `decay.scale` `rcon.password` `rcon.port`
`rcon.web`

**17 convars appear in two or more independent sources.** That is tier 2's
evidence base, and it lands almost exactly on the "top 20ish" the user
predicted before any of this was gathered.

24 more appear in exactly one source. Those are leads, not consensus.

## Two artifacts in the method, worth knowing

**Ports look unimportant and are not.** `server.port` and `server.queryport`
appear only in source A. B and C generate `server.cfg`, and ports are
conventionally passed on the command line rather than set in that file. Their
low count measures where a setting is written, not how much it matters — a
wrong `queryport` makes a server invisible in the browser.

**Source A under-represents rate tuning.** `gather.*`, `crafting.*` and
`heli.enabled` appear only in B, which ships 2x and 5x presets. The reference
server is PVE and does its loot tuning through plugins instead. A launcher
aimed at modded servers needs the rate convars that one real PVE server never
touches. This is the clearest thing the outside sources added.

## Scale of tier 3

[Corrosion Hour's command list](https://www.corrosionhour.com/rust-admin-commands/)
covers, by rough class: `ai.*` ~150, `server.*` ~150, `antihack.*` ~100,
`global.*` ~100, `debug.*` ~80, `decay.*` ~40, `player.*` ~40, `physics.*`
~20, `entity.*` ~15, "plus dozens more". That is ~700 in the classes counted,
so **the total is plausibly 800-1200**.

But most of that is not launcher material. `ai.*`, `debug.*` and `antihack.*`
are runtime and diagnostic surface. The number that matters for tier 3 is
**how many carry `[ServerVar]`**, which is what `tools/convars.py` counts.
Expect that to be far smaller than the total console surface. Do not quote the
800-1200 figure as the size of tier 3.

## Confirmed: `ShowInAdminUI` is real

Search surfaced the declaration form directly:

```csharp
[ServerVar(ShowInAdminUI = true)]
public static string hostname = "My Untitled Rust Server";
```

This closes the highest-value open question. `ServerVar` carries
`ShowInAdminUI`, so Facepunch's own list of admin-facing convars is
machine-readable, and `tools/convars.py` should report it as a column.
ADR-0009 moves to ACCEPTED.

It also gives one real default — `server.hostname` is `"My Untitled Rust
Server"` — from a source that is the declaration itself rather than prose
about it.

## Why the generator still exists

Source C states `rcon.port` default **28017**. The reference server runs RCON
on 28016, and 28017 is the conventional *queryport* default. One of those is
wrong, and reading more community pages cannot settle which.

That is the case for ADR-0008 in one line: **community documentation disagrees
about defaults, and the assembly does not.** Generate defaults; never copy
them from a page, including this one.
