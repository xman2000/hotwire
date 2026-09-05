# Configuration — `oxide/config/Hotwire.json`

Written on first load with **every schedule entry disabled**. Nothing
restarts until you enable one. That is deliberate: a restarter that starts
restarting the moment it is installed is a restarter that catches you out.

The config stays hand-editable and always will. Chat commands are a
convenience over the same file, never the only way in (ADR-0006).

> **Upgrading to 1.0.0?** Five config keys were spelled the British way and are
> now American: the four `... color, hex` keys under `Status bar` and
> `Name color (hex)` under `General`. An existing config keeps the old keys,
> which are now ignored, so those five settings fall back to their defaults —
> delete those sections to pick the new keys up. Two lang keys changed the same
> way; delete `oxide/lang/en/Hotwire.json` if you want the corrected wording.
>
> **Upgrading to 0.9.4?** The countdown now starts an hour out instead of ten
> minutes, with a fuller set of announcements. Existing configs keep their old
> values — delete the `Countdown` section to pick the new ones up. Note that
> `hotwire now` with no seconds argument uses this value too, so a bare
> `hotwire now` is an hour-long countdown unless you pass a number.
>
> **Upgrading to 0.9.0?** `Bar drains as the countdown runs` is replaced by
> `Fill style`, and the fill color key was renamed and given a real default.
> Delete the `Status bar` section to pick them up.
>
> **Upgrading to 0.8.0?** The `Status bar` section gained several keys and the
> icon default changed to a sprite that exists. Delete the section from your
> config, or the whole file, to pick the new defaults up.
>
> **Upgrading to 0.6.0?** The `Chat prefix` key is replaced by
> `Name shown in chat announcements` and `Name color (hex)`, so an existing
> config picks up the new default of "Server Manager" rather than keeping
> "Hotwire".
>
> **Upgrading to 0.3.0?** Schedule entries changed shape: `Days` is now a list
> and there is a `Repeat` mode, so an entry written by 0.2.x is not read. The
> old keys are ignored rather than throwing, so the plugin loads and your other
> settings survive — but any schedule you had is gone and must be re-added.
> `hotwire list` shows what you have.
>
> **Upgrading to 0.2.1?** Two announcement strings changed. Lang files are
> only written once, so `oxide/lang/en/Hotwire.json` keeps whatever it already
> had — delete it to pick up the new wording, or edit it in place. It is meant
> to be edited; that is the point of ADR-0004.
>
> **Upgrading to 0.2.0?** The `Render the countdown through AdvancedStatus`
> key under `General` has been replaced by a `Status bar` section. The old key
> is ignored; the new section is written with defaults on first load.
>
> **Upgrading from 0.1.0?** 0.1.0 duplicated its default schedule entries on
> every load — a config written with two entries had four after one reload and
> six after two, all of them disabled copies of the defaults. `AnnounceAt` grew
> the same way, though a de-duplication at load hid it. 0.1.1 fixes the cause.
> It does not clean up what 0.1.0 wrote, so delete the surplus entries by hand,
> or just delete `oxide/config/Hotwire.json` and let it regenerate — nothing is
> lost if you had not enabled anything yet.

---

## Restarts and Updates

Two lists (ADR-0012). A restart relaunches the server; an update also writes a
flag file the launcher acts on.

```json
"Restarts": [
  { "Time": "05:00", "Repeat": "Daily", "Enabled": true }
],
"Updates": [
  { "Time": "20:00", "Repeat": "MonthlyWeekday", "Ordinal": "First",
    "Days": [ "Thursday" ], "Validate": false, "Enabled": true }
]
```

That second entry is **the first Thursday of the month at 20:00** — Rust's
force wipe day, and the reason monthly recurrence exists at all. It ships as
the default update entry, disabled like everything else.

### Fields

| Field | Used by | Meaning |
|---|---|---|
| `Time` | all | `HH:mm`, 24-hour, **server local time** |
| `Repeat` | all | one of the six modes below |
| `Days` | Weekly, MonthlyWeekday | list of day names: `[ "Monday", "Thursday" ]` |
| `Ordinal` | MonthlyWeekday | `First`, `Second`, `Third`, `Fourth`, `Last` |
| `DayOfMonth` | MonthlyDay | 1–31 |
| `IntervalDays` | EveryNDays | how many days between runs |
| `AnchorDate` | EveryNDays | `yyyy-MM-dd`, the day the count starts from |
| `Date` | Once | `yyyy-MM-dd` |
| `Enabled` | all | off means the entry is ignored entirely |
| `Validate` | Updates only | adds `validate` to steamcmd — slow, weekly at most |

Only the fields the chosen `Repeat` needs are read. The others keep whatever
they held, which is what lets you switch an entry from weekly to monthly and
back without retyping it.

### Repeat modes

| Mode | Means | Example |
|---|---|---|
| `Daily` | every day | 05:00 daily |
| `Weekly` | the listed weekdays | every Tuesday; Mon and Thu |
| `MonthlyWeekday` | an ordinal weekday | the **first Thursday**; the last Friday |
| `MonthlyDay` | a date in the month | day 1; day 15 |
| `EveryNDays` | a fixed interval from an anchor | every other day |
| `Once` | one specific date, then it disables itself | 2026-12-24 |

**`Fifth` is deliberately not offered.** Not every month has a fifth Tuesday,
so `Last` covers what people mean by it without the edge case.

**A `DayOfMonth` above 28 is skipped in months that are too short**, not moved
to the last day. A restart that silently shifts is worse than one that does not
happen, and the plugin warns at load if you set one.

**`EveryNDays` needs an anchor.** If `AnchorDate` is empty it is filled in with
today's date and saved, so "every 2 days" means a fixed set of days rather than
one that re-anchors every time the plugin reloads.

### Creating them from chat

Everything above is reachable from the console or in game, so you never have to
hand-edit JSON unless you want to:

```
hotwire add restart 05:00                       daily
hotwire add restart 05:00 weekdays
hotwire add restart 03:00 Tue                   every Tuesday at 3am
hotwire add restart 05:00 Mon,Thu
hotwire add update  20:00 first Thursday        Rust force wipe day
hotwire add update  04:00 last Friday
hotwire add restart 05:00 day 15
hotwire add restart 05:00 every 2 days
hotwire add update  02:00 once 2026-12-24
```

`hotwire set` edits an entry in place, taking the same words:

```
hotwire set restart 0 time 06:00
hotwire set update  0 pattern second Tuesday
hotwire set update  0 validate true
```

**An entry that will not parse is disabled and reported, not guessed at.** A
bad entry disables itself and leaves the rest of the schedule running.

**If a restart and an update fall at the same minute, the update wins.** An
update entry is a restart entry that also writes a flag, so running it
satisfies both. Validate beats update for the same reason.

## Countdown

```json
"Countdown": {
  "Start the countdown this many seconds before": 3600,
  "Announce when this many seconds remain": [
    3600, 1800, 900, 600, 300, 120, 60,
    30, 20, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1
  ],
  "Seconds between the last announcement and the kick": 1.0
}
```

**An hour of warning by default.** The status bar is unobtrusive enough to
carry a long runway, and an hour is enough to finish a raid, bank a run, or log
off deliberately rather than be thrown out of a fight. The bar is the warning;
chat is the punctuation.

Announcements land at 60, 30, 15, 10, 5, 2 and 1 minutes, then 30, 20 and 10
seconds, then every second to zero — sparse where nothing is at stake and dense
where it is. The last ten seconds are when somebody is deciding whether to open
one more door.

The bar itself changes text about once a minute over that hour, which is one
push each. If that ever reads as flicker on a busy HUD, coarsening the bar's
wording at long range is the lever — the announcements are independent of it.

Announcements are plain lang strings (ADR-0004) and are editable in
`oxide/lang/en/Hotwire.json`.

**Remaining time is rounded up, everywhere.** An announcement is written once
and then sits in chat for a minute while the bar keeps counting, so "3 minutes"
has to stay true for that minute. Truncating instead made the bar read `2m` one
second after chat said three minutes — both doing the same arithmetic, and the
arithmetic being wrong for a phrase about time remaining. The chat text and the
bar take their minute count from the same helper, so they cannot drift apart.

The remaining time is recomputed from the wall clock every tick rather than
counted down, so the countdown is immune to timescale, to a stalled frame and
to timer drift. The restart lands when it said it would; the worst a hitch can
do is skip an announcement.

## Times, zones and DST

Every time this plugin prints carries the zone it means and whether daylight
saving is in effect — `Thu 02 Oct 2026 20:00 Central Daylight Time (UTC-05:00,
DST)`. That is not decoration. Schedules are local wall-clock time (ADR-0013),
so `05:00` is a different absolute moment either side of a clock change, and
"next Sunday at 05:00" is ambiguous without it.

The zone shown is computed **for the moment being displayed**, not for now: a
date in November reads as standard time while today is still daylight time.
When a clock change falls between now and the next occurrence, the line says
so — in the panel, in `hotwire list`, and in `hotwire status`.

`hotwire check` reports the server's current clock, zone and DST state on one
line, and says when the zone has no daylight saving at all.

The panel is a convenience and never the only way in. Everything it does,
`hotwire add`, `set`, `remove`, `enable` and `disable` also do — which is what
lets the panel be deleted outright if a Rust update ever breaks it (ADR-0016).

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
  "Name shown in chat announcements": "Server Manager",
  "Name color (hex)": "#e0995e"
}
```

- **Server root** — where the flag files are written. Empty asks Oxide. Set it
  only if that turns out to be wrong on your install; the plugin says so in
  console at boot if it cannot work it out.
- **Refuse to fire the same entry twice** — the DST guard (ADR-0013). Leave it
  at 20 hours unless you genuinely schedule the same entry twice a day, in
  which case set it below the gap between them. `0` disables it.
- **Name shown in chat announcements** — **"Hotwire" means nothing to a
  player.** Announcements go out under this name, not the plugin's, so what a
  player reads is *"Server Manager: Scheduled restart in 4 minutes"*. Set it to
  whatever your server calls itself. An empty name drops the prefix entirely;
  an empty color drops the markup.

Sentences are capitalised when they are sent rather than in the lang file, so
correcting one reaches servers that already have a lang file — lang files are
written once and never rewritten.

The `Render the countdown through AdvancedStatus` key from 0.1.x is gone,
replaced by the `Status bar` section below.

## Status bar

```json
"Status bar": {
  "Enabled": true,
  "Category": "Hotwire",
  "Order": 10,
  "Bar color, hex (blank = inherit)": "",
  "Text color, hex": "#FFFFFF",
  "Bar fill color, hex": "#E74C3C",
  "Icon: built-in sprite path": "assets/icons/stopwatch.png",
  "Icon: local name in oxide/data/AdvancedStatus/Images": "",
  "Icon: URL (used only when the other two are blank)": "",
  "Icon color, hex (blank = the progress color)": "",
  "Fill style: Full, Fills or Drains": "Full",
  "Text left padding (pixels)": 5,
  "Countdown minimum width (characters)": 5,
  "Count seconds in the final minute": false
}
```

Renders the countdown as a status bar through **AdvancedStatus**, which is a
paid plugin most servers will not have. Without it this section does nothing
and chat carries the countdown on its own — that is the normal case, not a
degraded one.

**Hotwire creates the bar once and pushes almost nothing.** The fill and the
bar's removal are handled by AdvancedStatus from the timestamps it was given,
on its own tick. Only the countdown text is pushed, and only when it changes —
once a minute by default. Every push redraws the whole stack, which is why a
per-second countdown made every bar on screen blink.

`Count seconds in the final minute` turns the last minute into a per-second
countdown. It is off because that is sixty redraws of every bar on the screen,
and the chat announcements already carry the last minute.

**The bar reads `Server Restart` on a solid block of alert red**, with the
countdown on the right. It is a glance surface: a player needs to know the
server is going down, not which flavour of going down it is — the chat
announcements carry that. The label is a lang string, so change it in
`oxide/lang/en/Hotwire.json`.

**Fill style** is `Full` by default because the bar exists to be noticed.
`Drains` is loudest at the start and quietest at the moment the restart
actually lands, which is backwards. `Fills` is invisible for the first nine
minutes of a ten-minute countdown. `Full` is solid the whole way and lets the
countdown text carry the time.

`Full` uses bar type `Timed` rather than `TimeProgress`: manual control of the
fill, but it still deletes itself when the timestamp passes, which `Default`
does not — and a stuck bar on every player's screen is the worst failure this
integration has available to it.

**Leave the frame color blank unless you mean it.** Blank inherits AdvancedStatus's
own frame, so the bar matches every other plugin's by construction — including
after AdvancedStatus is retuned. Hex is normalized for you: bare hex without a
`#` reaches CUI unparseable and renders the bar white.

**The icon** is a built-in sprite, then a local file in
`oxide/data/AdvancedStatus/Images`, then a URL, in that order. With none set
you get AdvancedStatus's tinted placeholder, which is a solid colored square.
Built-in sprite paths cannot be validated server-side: a wrong one logs
`[FileSystem] Not Found` once per draw and shows nothing. `docs/GAME-API.md`
lists the paths known to exist.

## Commands

All under `hotwire` (alias `hw`), in chat or on the server console.

| Command | Permission | Does |
|---|---|---|
| `hotwire status` | `hotwire.status` | What is counting down, or what is next |
| `hotwire check` | `hotwire.status` | Diagnose the install without restarting anything |
| `hotwire menu` | `hotwire.status` to open, `hotwire.edit` to change | The in-game panel |
| `hotwire list` | `hotwire.status` | Every entry, with what it resolves to next |
| `hotwire now [update\|validate] [seconds]` | `hotwire.restart` | Start a countdown now |
| `hotwire cancel` | `hotwire.cancel` | Cancel the running countdown |
| `hotwire add <restart\|update\|validate> <HH:mm> [pattern]` | `hotwire.edit` | Add an entry |
| `hotwire set <restart\|update> <index> <time\|pattern\|validate> <value>` | `hotwire.edit` | Edit one in place |
| `hotwire remove <restart\|update> <index>` | `hotwire.edit` | Remove one |
| `hotwire enable\|disable <restart\|update> <index>` | `hotwire.edit` | Turn one on or off |

Indexes come from `hotwire list` and are per-list, so `restart 0` and
`update 0` are different entries.

**`hotwire now` with no number lasts as long as a scheduled countdown** — an
hour, by default, because it uses the same `Start the countdown this many
seconds before` setting. That is deliberate: a manual restart gets players the
same warning a scheduled one does. Pass a number when you want it sooner:

```
hotwire now 60          a minute, plain restart
hotwire now update 300  five minutes, and update on the way back
```

A manual `hotwire now` is not subject to the fired-recently guard and does not
feed it. An admin asking for a restart means it.

`hotwire cancel` stops the countdown and leaves the schedule alone. Disabling
the entry stops both (ADR-0017).

**Cancel stops working once the shutdown has begun** — players have been
kicked by then, and pretending the restart can still be called off would leave
the server up with everyone thrown off it.

### `hotwire menu`

An in-game panel over the same schedule. It opens on `hotwire menu`, lists
every entry with what it resolves to next, and lets you add, edit, toggle and
delete without leaving the game.

The edit view shows only the fields the chosen repeat mode uses, and carries a
summary that leads with the answer:

```
Tomorrow at 05:00
Restart daily. Sunday 6 September 2026 at 05:00, Central Daylight Time (UTC-05:00, DST).
```

That summary is the point of the panel: an ordinal schedule is hard to be
confident about until something tells you when it lands. "When does this
happen" is the only question the edit view is really asked, so the answer is
the largest text on it, phrased the way a person would say it — *in 4
minutes*, *today at 11:10*, *tomorrow at 05:00*, *Tuesday at 03:00*. An
absolute date answers a question nobody asked: "next Saturday 5 September
2026" for something four minutes away is technically true and actively
misleading. The rule and the exact moment go underneath, for when *they* are
the question.

**A disabled entry says `Disabled`, not when it would run.** Showing a next
occurrence under a switch reading OFF is the same false reassurance that once
let a disabled entry restart a server (ADR-0017). The line underneath still
says when it *would* run, which is what you want while setting one up.

Things worth knowing:

- **Every click saves immediately.** There is no save or cancel button, so an
  edit cannot be lost by disconnecting halfway through.
- **New entries start disabled**, so a half-configured one cannot fire. Turn it
  on when the summary line says what you meant.
- **A change that makes an enabled entry invalid disables it** and says so,
  rather than leaving it to fail at three in the morning.
- **Disabling, deleting or rescheduling an entry cancels its running
  countdown**, if it has one, and tells you it did (ADR-0017). Switching an
  entry off used to stop it happening *again* while the countdown already
  under way carried on to a restart — which is not what "disabled" reads as.
- **A running countdown appears as a banner** across the top of the panel, with
  a button to cancel it outright. It is the most important thing on the screen
  and it used to be the one thing the panel did not show.
- **Time and numbers are stepped with buttons**, not typed. Fewer ways to end
  up with something that will not parse. Click as fast as you like — the panel
  is built so redrawing never drops the cursor.
- **Time steps by 5, 15, 60 and 360 minutes**, so any hour is at most four
  clicks away. Every stepper button carries its unit — `-15m`, `+1h`, `+7d`,
  `-1mo`, `+1y` — because a button reading `-15` does not say of what. The
  units are all lower case, including `mo` for months: capital `M` is a
  date-format convention that exists only because lower-case `m` was already
  taken by minutes in a machine-readable string, and nothing on a button
  should ask someone to know that.
- **A one-off date has day, month and year steppers**, and shows the weekday it
  lands on. Month steps move whole months and clamp the day, so stepping a
  month on from 31 January gives 28 February rather than 3 March.

### `hotwire check`

Answers the questions you would otherwise spend a real restart to answer:

- **Where the flag will be written**, and whether that came from your config
  or from Oxide.
- **Whether that directory is actually the server root.** A directory that
  exists is not necessarily the one your launcher watches; one containing
  `RustDedicated` is. This is the check worth running first on a new install.
- **Whether it is writable**, tested by writing and deleting a probe file
  rather than by inspecting permissions.
- **Whether a flag is sitting there right now** — which means the next
  restart will update whether or not anyone meant it to.
- Schedule counts, what is next, the countdown shape, how many entries the
  DST guard is holding, whether a status plugin is present, and whether the
  framework check is on.

It changes nothing except the probe file it cleans up after itself. Run it
after installing, after moving the server, and after any Oxide update.

## What the plugin does at zero

1. Records the fire time to `oxide/data/Hotwire/last_fired.json`.
2. Writes the flag file, if this is an update. A failure here is reported and
   downgrades the update to a plain restart — the safe direction to fail in.
3. Announces.
4. Kicks every connected player, so they get a reason rather than a timeout.
5. Runs `quit`, which saves the world on the way out.

Then the launcher takes over: it sees the process exit, acts on the flag if
there is one, and starts the server again.
