# Configuration — `oxide/config/Hotwire.json`

Written on first load with **every schedule entry disabled**. Nothing
restarts until you enable one. That is deliberate: a restarter that starts
restarting the moment it is installed is a restarter that catches you out.

The config stays hand-editable and always will. Chat commands are a
convenience over the same file, never the only way in (ADR-0006).

---

## Restarts and Updates

Two lists (ADR-0012). A restart relaunches the server; an update also writes
a flag file the launcher acts on.

```json
"Restarts": [
  { "Time (HH:mm, server local time)": "05:00", "Days": "Daily", "Enabled": true }
],
"Updates": [
  { "Time (HH:mm, server local time)": "05:00", "Days": "Thursday",
    "Validate": false, "Enabled": true }
]
```

| Field | Meaning |
|---|---|
| `Time` | `HH:mm`, 24-hour, **server local time**. |
| `Days` | `Daily`, `Weekdays`, `Weekends`, or a comma list: `Monday,Thursday`. Short forms work: `Mon,Thu`. |
| `Enabled` | Off means the entry is ignored entirely. |
| `Validate` | Updates only. Adds `validate` to the steamcmd call, which re-checksums the whole install. Slow — six to eight minutes on a large one. Weekly at most, or after a crash. |

**An entry that will not parse is disabled and reported, not guessed at.** A
bad `Days` string disables that one entry and leaves the rest of the schedule
running.

**If a restart and an update fall at the same minute, the update wins.** An
update entry is a restart entry that also writes a flag, so running it
satisfies both. Validate beats update for the same reason.

## Countdown

```json
"Countdown": {
  "Start the countdown this many seconds before": 600,
  "Announce when this many seconds remain": [600, 300, 180, 60, 30, 10, 5, 4, 3, 2, 1],
  "Seconds between the last announcement and the kick": 1.0
}
```

Announcements are plain lang strings (ADR-0004) and are editable in
`oxide/lang/en/Hotwire.json`.

The remaining time is recomputed from the wall clock every tick rather than
counted down, so the countdown is immune to timescale, to a stalled frame and
to timer drift. The restart lands when it said it would; the worst a hitch can
do is skip an announcement.

## Framework update check

```json
"Framework update check": {
  "Enabled": false,
  "Check every this many minutes": 60,
  "Release feed URL": "https://umod.org/games/rust.json",
  "When a new release is found, update at (HH:mm)": "05:00",
  "Validate on a framework update": false
}
```

**Off by default and it should stay off until you trust it** (ADR-0007). When
a new framework release appears it does not restart; it schedules an announced
update at the hour you chose, which then behaves like any other update entry.

The feed's response shape is assumed, not verified. If it changes, the check
logs a warning and does nothing — it cannot schedule a restart it did not mean
to.

## General

```json
"General": {
  "Server root (empty = detect)": "",
  "Update flag file name": "UPDATE.flag",
  "Validate flag file name": "VALIDATE.flag",
  "Refuse to fire the same entry twice within this many hours": 20.0,
  "Render the countdown through AdvancedStatus (unverified -- see docs)": false,
  "Chat prefix": "<color=#e0995e>Hotwire</color>: "
}
```

- **Server root** — where the flag files are written. Empty asks Oxide. Set it
  only if that turns out to be wrong on your install; the plugin says so in
  console at boot if it cannot work it out.
- **Refuse to fire the same entry twice** — the DST guard (ADR-0013). Leave it
  at 20 hours unless you genuinely schedule the same entry twice a day, in
  which case set it below the gap between them. `0` disables it.
- **Render through AdvancedStatus** — off because the call shape is
  unverified. If you turn it on and it is wrong, it disables itself for the
  session and falls back to chat; the countdown is unaffected either way.

## Commands

All under `hotwire` (alias `hw`), in chat or on the server console.

| Command | Permission | Does |
|---|---|---|
| `hotwire status` | `hotwire.status` | What is counting down, or what is next |
| `hotwire list` | `hotwire.status` | Every entry with its index |
| `hotwire now [update\|validate] [seconds]` | `hotwire.restart` | Start a countdown now |
| `hotwire cancel` | `hotwire.cancel` | Cancel the running countdown |
| `hotwire add <restart\|update\|validate> <HH:mm> [days]` | `hotwire.edit` | Add an entry |
| `hotwire remove <restart\|update> <index>` | `hotwire.edit` | Remove one |
| `hotwire enable\|disable <restart\|update> <index>` | `hotwire.edit` | Toggle one |

Indexes come from `hotwire list` and are per-list, so `restart 0` and
`update 0` are different entries.

A manual `hotwire now` is not subject to the fired-recently guard and does not
feed it. An admin asking for a restart means it.

**Cancel stops working once the shutdown has begun** — players have been
kicked by then, and pretending the restart can still be called off would leave
the server up with everyone thrown off it.

## What the plugin does at zero

1. Records the fire time to `oxide/data/Hotwire/last_fired.json`.
2. Writes the flag file, if this is an update. A failure here is reported and
   downgrades the update to a plain restart — the safe direction to fail in.
3. Announces.
4. Kicks every connected player, so they get a reason rather than a timeout.
5. Runs `quit`, which saves the world on the way out.

Then the launcher takes over. See `BRIEF.md` §2.
