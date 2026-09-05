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

**Source A in full** — the 23 convars one real modded server passes on its
command line, verified working on protocol 2632.287.1:

`server.port` `server.queryport` `server.identity` `server.level`
`server.seed` `server.worldsize` `server.maxplayers` `server.tags`
`server.hostname` `server.description` `server.headerimage`
`server.saveinterval` `server.globalchat` `server.itemdespawn`
`server.combatlog` `server.chatlog` `server.printReportsToConsole`
`rcon.port` `rcon.password` `rcon.web` `decay.scale`
`rideablehorse.population` `hackablelockedcrate.requiredhackseconds`

Of those 23, **17 are `server.*`**. The tail is three convars across three
classes, one each. A heavy head and a long thin tail is the shape to design
for: tier 2 is mostly one class, and tier 3 is where the many one-off classes
live — where the generator groups them by class automatically, so it never
needs hand-splitting at all.

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

## Field finding: query ports and the Steam client range

The reference server had used `server.queryport 27015` for years, copied from
a guide, alongside years of intermittent invisibility in the server browser.

**27015 is inside the Steam client's own port range** — Steam uses UDP
27000-27015 for game client traffic and 27015-27030 for matchmaking and HLTV.
On a machine that runs both the dedicated server and the Steam client, the
client can take the port; the server then stops answering A2S queries and
vanishes from the browser until something releases it. Intermittent, hard to
attribute, survives every reinstall.

27015 is Source-engine convention and a great deal of Rust documentation
copies it. **Rust is not Source.** Its own derivation is `1 + max(server.port,
rcon.port)`, which lands on 28017 for a standard layout and is safely outside
Steam's range. The launcher now ships 28017 and says why.

Diagnostic worth keeping: an A2S query from outside the network settles
visibility in seconds, where testing from inside cannot — many routers do not
hairpin, so a perfectly visible server looks dead from your own LAN.

```python
sock.sendto(b"\xFF\xFF\xFF\xFF\x54Source Engine Query\x00", (ip, queryport))
```

A reply beginning `\xFF\xFF\xFF\xFFI` carries the hostname, map and player
count. Anything else, including silence, means the browser cannot see it
either.

**Second cause found in the same session:** every forward pointed at a fixed
LAN address with no evidence of a DHCP reservation. If that lease ever moves,
*all* forwards break at once and the server disappears completely rather than
intermittently. Any launcher documentation that tells people to forward ports
should tell them to reserve the address in the same breath.
