using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using Oxide.Core;
using Oxide.Core.Libraries.Covalence;
using Oxide.Core.Plugins;
using Oxide.Game.Rust.Cui;
using UnityEngine;

namespace Oxide.Plugins
{
    [Info("Hotwire", "xman2000", "1.1.0")]
    [Description("Scheduled restarts and updates. Announces, counts down, writes a flag, quits.")]
    internal class Hotwire : CovalencePlugin
    {
        // =================================================================
        //  WHAT THIS PLUGIN DELIBERATELY DOES NOT DO
        //
        //  It does not spawn processes, write scheduled tasks or shell out.
        //  It writes a flag file and quits; the launcher does the rest
        //  (ADR-0001).
        //
        //  Everything that schedules, announces or shuts the server down goes
        //  through Covalence, which is a stable Oxide interface rather than a
        //  moving Facepunch one. That is a safety decision, not a style one
        //  (ADR-0014): a wrong guess at a Facepunch signature is a COMPILE
        //  error, and a plugin that does not compile is a plugin that never
        //  restarts the server. try/catch cannot save you from code that never
        //  runs. server.Command("quit") runs the same console command as
        //  ConVar.Global.quit with none of that exposure.
        //
        //  The ONE exception is the admin menu, which cannot exist without
        //  Facepunch types -- CuiHelper.AddUi takes a BasePlayer, and Rust's
        //  UI has no Covalence route. It is confined to a single region so
        //  that deleting it stays a real option, and everything it does the
        //  chat commands also do (ADR-0016).
        //
        //  What is left is runtime assumption, tagged VERIFY at each use and
        //  wrapped so that being wrong costs one optional feature rather than
        //  the schedule: the AdvancedStatus call shape, the uMod release-feed
        //  response shape, and the epoch its timestamps are measured from.
        // =================================================================

        #region Configuration

        private HotwireConfig _config;

        private class HotwireConfig
        {
            // ObjectCreationHandling.Replace on every collection, and it is
            // not optional. The default is Auto, which REUSES the list the
            // field initializer already built and ADDS the file's entries to
            // it. The default entry below is therefore re-appended on every
            // single load, and a config that starts with two entries has four
            // after one reload and six after two. That was shipped in 0.1.0.
            [JsonProperty("Restarts", ObjectCreationHandling = ObjectCreationHandling.Replace)]
            public List<ScheduleEntry> Restarts = new List<ScheduleEntry>
            {
                new ScheduleEntry { Time = "05:00", Repeat = "Daily", Enabled = false }
            };

            // The default update entry is the first Thursday of the month at
            // 20:00, because that is Rust's force wipe day and the single most
            // likely thing an admin wants an announced update for. Disabled,
            // like everything else, but it is the shape of the answer.
            [JsonProperty("Updates", ObjectCreationHandling = ObjectCreationHandling.Replace)]
            public List<UpdateEntry> Updates = new List<UpdateEntry>
            {
                new UpdateEntry
                {
                    Time = "20:00",
                    Repeat = "MonthlyWeekday",
                    Ordinal = "First",
                    Days = new List<string> { "Thursday" },
                    Validate = false,
                    Enabled = false
                }
            };

            [JsonProperty("Countdown")]
            public CountdownSettings Countdown = new CountdownSettings();

            [JsonProperty("Framework update check")]
            public FrameworkSettings Framework = new FrameworkSettings();

            [JsonProperty("General")]
            public GeneralSettings General = new GeneralSettings();

            [JsonProperty("Status bar")]
            public StatusBarSettings StatusBar = new StatusBarSettings();
        }

        // Recurrence is stored as explicit fields rather than as a cron
        // string or a phrase to be parsed (ADR-0015). Every value validates on
        // its own, an error can name the exact field that is wrong, and the
        // menu maps one control per field instead of round-tripping somebody's
        // hand-written wording through a serializer.
        //
        // Only the fields the chosen Repeat mode needs are read. The rest sit
        // there holding whatever they held, which is what lets you switch a
        // schedule from weekly to monthly and back without retyping it.
        private class ScheduleEntry
        {
            [JsonProperty("Time")]
            public string Time = "05:00";

            // Daily | Weekly | MonthlyWeekday | MonthlyDay | EveryNDays | Once
            [JsonProperty("Repeat")]
            public string Repeat = RepeatDaily;

            // Weekly: every day it runs on.
            // MonthlyWeekday: the weekday the ordinal applies to.
            [JsonProperty("Days", ObjectCreationHandling = ObjectCreationHandling.Replace)]
            public List<string> Days = new List<string>();

            // MonthlyWeekday: First | Second | Third | Fourth | Last.
            // Fifth is deliberately absent: it does not exist in every month,
            // and Last is what people mean when they reach for it.
            [JsonProperty("Ordinal")]
            public string Ordinal = "First";

            // MonthlyDay: 1-31. A day that does not exist in a given month is
            // skipped that month rather than moved, because a restart that
            // silently shifts is worse than one that does not happen.
            [JsonProperty("DayOfMonth")]
            public int DayOfMonth = 1;

            [JsonProperty("IntervalDays")]
            public int IntervalDays = 2;

            // EveryNDays counts from here. Filled in with today the first time
            // the entry is validated, so "every 2 days" is a fixed set of days
            // rather than one that re-anchors on every reload.
            [JsonProperty("AnchorDate")]
            public string AnchorDate = "";

            // Once: yyyy-MM-dd. The entry disables itself after it fires.
            [JsonProperty("Date")]
            public string Date = "";

            [JsonProperty("Enabled")]
            public bool Enabled = true;

            [JsonIgnore] public virtual bool IsUpdate => false;
            [JsonIgnore] public virtual bool IsValidate => false;

            // Stable across reordering, so the fired-recently guard survives
            // someone rearranging the config. It deliberately includes the
            // recurrence: editing an entry's schedule should clear its history
            // rather than have yesterday's fire suppress today's new time.
            [JsonIgnore]
            public string Key => string.Join("|", new[]
            {
                IsValidate ? "validate" : IsUpdate ? "update" : "restart",
                Time ?? "", Repeat ?? "",
                Days == null ? "" : string.Join(",", Days.ToArray()),
                Ordinal ?? "", DayOfMonth.ToString(), IntervalDays.ToString(), Date ?? ""
            });
        }

        private class UpdateEntry : ScheduleEntry
        {
            // Validate re-checksums the whole install. Slow -- six to eight
            // minutes on a large one. Weekly at most, or after a crash.
            [JsonProperty("Validate")]
            public bool Validate = false;

            [JsonIgnore] public override bool IsUpdate => true;
            [JsonIgnore] public override bool IsValidate => Validate;
        }

        private class CountdownSettings
        {
            // An hour. The status bar is unobtrusive enough to carry a long
            // runway, and an hour is enough warning to finish a raid, bank a
            // run, or log off deliberately rather than be thrown out of a
            // fight. The bar is the warning; chat is the punctuation.
            [JsonProperty("Start the countdown this many seconds before")]
            public int StartSeconds = 3600;

            // 60, 30, 15, 10, 5, 2 and 1 minutes, then 30, 20 and 10 seconds,
            // then every second to zero. Sparse where nothing is at stake and
            // dense where it is -- the last ten seconds are when somebody is
            // deciding whether to open one more door.
            [JsonProperty("Announce when this many seconds remain",
                ObjectCreationHandling = ObjectCreationHandling.Replace)]
            public List<int> AnnounceAt = new List<int>
            {
                3600, 1800, 900, 600, 300, 120, 60,
                30, 20, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1
            };

            [JsonProperty("Seconds between the last announcement and the kick")]
            public float KickDelaySeconds = 1.0f;
        }

        private class FrameworkSettings
        {
            // ADR-0007: the best idea upstream has, and the one most able to
            // restart a server at a bad moment. Off by default, always.
            [JsonProperty("Enabled")]
            public bool Enabled = false;

            [JsonProperty("Check every this many minutes")]
            public int CheckIntervalMinutes = 60;

            [JsonProperty("Release feed URL")]
            public string Url = "https://umod.org/games/rust.json";

            [JsonProperty("When a new release is found, update at (HH:mm)")]
            public string UpdateAt = "05:00";

            [JsonProperty("Validate on a framework update")]
            public bool Validate = false;
        }

        // ADR-0003: render the countdown through a status surface players
        // already read. Verified against AdvancedStatus 0.1.26 by IIIaKa --
        // see docs/GAME-API.md. Absent that plugin this does nothing at all
        // and chat carries the countdown, which is the case on most servers.
        // Settings and conventions here follow a sibling plugin on the same
        // server that has already been through several rounds of this against
        // AdvancedStatus. Where its changelog records a reason, that reason is
        // repeated at the use site rather than rediscovered later.
        private class StatusBarSettings
        {
            [JsonProperty("Enabled")]
            public bool Enabled = true;

            [JsonProperty("Category")]
            public string Category = "Hotwire";

            [JsonProperty("Order")]
            public int Order = 10;

            // Blank means inherit AdvancedStatus's own frame, which is what
            // makes the bar match every other plugin's by construction rather
            // than by us picking a value that happens to agree today.
            [JsonProperty("Bar color, hex (blank = inherit)")]
            public string MainColor = "";

            [JsonProperty("Text color, hex")]
            public string TextColor = "#FFFFFF";

            // Alert red, and the same red the server's other urgent bars
            // already use, so it reads as part of the set rather than as a
            // stray color.
            [JsonProperty("Bar fill color, hex")]
            public string ProgressColor = "#E74C3C";

            // A verified built-in path. assets/icons/clock.png does NOT exist
            // and logs "[FileSystem] Not Found" once per draw.
            [JsonProperty("Icon: built-in sprite path")]
            public string ImageSprite = "assets/icons/stopwatch.png";

            [JsonProperty("Icon: local name in oxide/data/AdvancedStatus/Images")]
            public string ImageLocal = "";

            [JsonProperty("Icon: URL (used only when the other two are blank)")]
            public string ImageUrl = "";

            [JsonProperty("Icon color, hex (blank = the progress color)")]
            public string IconColor = "";

            // "Full" | "Fills" | "Drains".
            //
            // Full is the default because the bar exists to be noticed. A
            // draining fill is loudest at the start and quietest at the moment
            // the restart actually lands, which is backwards; a filling one is
            // invisible for the first nine minutes of a ten-minute countdown.
            // Full is a solid block of alert red the whole way, and the
            // countdown text carries the time, which is what it is there for.
            //
            // Full uses bar type Timed: manual control of the fill, but it
            // still self-deletes at TimeStamp, which Default does not, and a
            // stuck bar on every player's screen is the worst failure here.
            [JsonProperty("Fill style: Full, Fills or Drains")]
            public string FillStyle = "Full";

            // AdvancedStatus positions bar text at Text_Offset_Horizontal and
            // falls back to its own config value when the key is absent, which
            // is zero -- so text sits flush against the icon while other
            // plugins' bars are inset.
            [JsonProperty("Text left padding (pixels)")]
            public int TextIndent = 5;

            // AdvancedStatus sizes the SubText rect from a character count and
            // under-allocates for short strings; Unity then wraps the overflow
            // onto a second line the rect is too short to show, which is how
            // "24m" renders as "24". Padding buys the rect proportionally more
            // room. Trailing, so in the worst case the spaces wrap away rather
            // than the unit.
            [JsonProperty("Countdown minimum width (characters)")]
            public int CountdownMinWidth = 5;

            // Every push redraws the stack, so a per-second final minute blinks
            // every bar on screen. Off by default: the chat announcements carry
            // the last minute, which is what they are for.
            [JsonProperty("Count seconds in the final minute")]
            public bool SecondsInFinalMinute = false;
        }

        private class GeneralSettings
        {
            // Empty means "ask Oxide where the server root is". Set it only
            // if that turns out to be wrong on your install.
            [JsonProperty("Server root (empty = detect)")]
            public string ServerRoot = "";

            [JsonProperty("Update flag file name")]
            public string UpdateFlag = "UPDATE.flag";

            [JsonProperty("Validate flag file name")]
            public string ValidateFlag = "VALIDATE.flag";

            // The autumn DST repeat: 02:30 happens twice, and the second one
            // arrives in a fresh process after the first restart, so the
            // guard has to be on disk rather than in memory. ADR-0013.
            [JsonProperty("Refuse to fire the same entry twice within this many hours")]
            public double MinimumHoursBetweenSameEntry = 20.0;

            // "Hotwire" means nothing to a player. This is the name they see
            // in chat, and it should be something they can act on. The old
            // "Chat prefix" key is gone rather than renamed, so servers that
            // already had one pick up the better default.
            [JsonProperty("Name shown in chat announcements")]
            public string AnnouncementName = "Server Manager";

            // Empty for no color markup at all.
            [JsonProperty("Name color (hex)")]
            public string AnnouncementColor = "#e0995e";
        }

        protected override void LoadDefaultConfig()
        {
            _config = new HotwireConfig();
            PrintWarning("No configuration found. Writing defaults with every schedule DISABLED. " +
                         "Nothing will restart until you enable an entry.");
        }

        protected override void LoadConfig()
        {
            base.LoadConfig();
            try
            {
                _config = Config.ReadObject<HotwireConfig>();
                if (_config == null) throw new JsonException("configuration deserialized to null");
                RepairConfig();
            }
            catch (Exception ex)
            {
                // Fail soft, in the safe direction: a broken config must not
                // leave the plugin half-loaded holding a schedule it cannot
                // read. Defaults are all-disabled, so this restarts nothing.
                PrintError($"Configuration is unreadable, falling back to disabled defaults: {ex.Message}");
                PrintError("Your file has NOT been overwritten. Fix it and reload.");
                _config = new HotwireConfig();
                return;
            }
            SaveConfig();
        }

        // A null in the file is not the same as a missing key. Delete a key and
        // the field initializer's default survives; write "Restarts": null and
        // Newtonsoft faithfully replaces the list with null. Every use then
        // dereferences it -- and Scan() runs on a ten-second timer, so a single
        // null would either throw forever or kill the timer, and in both cases
        // the server never restarts again. That is the one failure the safety
        // envelope rules out, so it is repaired rather than reported.
        private void RepairConfig()
        {
            var repaired = new List<string>();

            if (_config.Restarts == null) { _config.Restarts = new List<ScheduleEntry>(); repaired.Add("Restarts"); }
            if (_config.Updates == null) { _config.Updates = new List<UpdateEntry>(); repaired.Add("Updates"); }
            if (_config.Countdown == null) { _config.Countdown = new CountdownSettings(); repaired.Add("Countdown"); }
            if (_config.Framework == null) { _config.Framework = new FrameworkSettings(); repaired.Add("Framework update check"); }
            if (_config.General == null) { _config.General = new GeneralSettings(); repaired.Add("General"); }
            if (_config.StatusBar == null) { _config.StatusBar = new StatusBarSettings(); repaired.Add("Status bar"); }

            if (_config.Countdown.AnnounceAt == null)
            {
                _config.Countdown.AnnounceAt = new List<int>();
                repaired.Add("Announce when this many seconds remain");
            }

            // A null entry inside a list -- a stray comma, usually.
            if (_config.Restarts.RemoveAll(e => e == null) > 0) repaired.Add("an empty entry in Restarts");
            if (_config.Updates.RemoveAll(e => e == null) > 0) repaired.Add("an empty entry in Updates");

            foreach (var entry in AllEntries())
                if (entry.Days == null) entry.Days = new List<string>();

            if (repaired.Count > 0)
                PrintWarning("Repaired empty values in the config: " + string.Join(", ", repaired.ToArray()) +
                             ". A null there would have stopped the schedule entirely, so defaults were " +
                             "put back. Check the file is what you meant.");
        }

        protected override void SaveConfig() => Config.WriteObject(_config, true);

        #endregion

        #region State

        private const string PermStatus = "hotwire.status";
        private const string PermRestart = "hotwire.restart";
        private const string PermCancel = "hotwire.cancel";
        private const string PermEdit = "hotwire.edit";

        private const string LastFiredFile = "Hotwire/last_fired";

        // Oxide.Plugins.Timer, injected by the plugin compiler -- NOT
        // Oxide.Core.Libraries.Timer, which is the library that hands these
        // out. timer.Every() returns the former.
        private Timer _scanTimer;
        private Timer _countdownTimer;
        private Timer _frameworkTimer;

        private bool _countdownActive;
        private DateTime _countdownTarget;
        private ScheduleEntry _countdownEntry;   // null for a manual countdown
        private bool _countdownIsUpdate;
        private bool _countdownIsValidate;
        private string _countdownKey = "";
        private readonly HashSet<int> _announced = new HashSet<int>();

        // Set once the shutdown sequence has begun. Nothing cancels after
        // this point -- players have been kicked, and pretending otherwise
        // would leave the server up with everyone thrown off it.
        private bool _shuttingDown;

        private Dictionary<string, DateTime> _lastFired = new Dictionary<string, DateTime>();

        // A single pending one-shot, used by the framework-update check.
        private DateTime? _oneShotTarget;
        private bool _oneShotValidate;
        private string _oneShotReason = "";

        [PluginReference] private Plugin AdvancedStatus;
        private bool _statusDisabled;
        private DateTime _countdownStarted;
        private string _lastSubText;

        private string _knownFrameworkVersion;

        #endregion

        #region Lifecycle

        private void Init()
        {
            permission.RegisterPermission(PermStatus, this);
            permission.RegisterPermission(PermRestart, this);
            permission.RegisterPermission(PermCancel, this);
            permission.RegisterPermission(PermEdit, this);

            AddCovalenceCommand(new[] { "hotwire", "hw" }, nameof(CmdHotwire));
            AddCovalenceCommand("hotwire.ui", nameof(CmdMenuAction));   // ADR-0016: goes with the menu

            try
            {
                _lastFired = Interface.Oxide.DataFileSystem.ReadObject<Dictionary<string, DateTime>>(LastFiredFile)
                             ?? new Dictionary<string, DateTime>();
            }
            catch (Exception ex)
            {
                PrintWarning($"Could not read {LastFiredFile} ({ex.Message}). Starting with an empty guard.");
                _lastFired = new Dictionary<string, DateTime>();
            }
        }

        private void OnServerInitialized()
        {
            var root = ServerRoot();
            if (root == null)
                PrintError("Cannot determine the server root, so update flags cannot be written. " +
                           "Set \"Server root\" in the config. Restarts still work; updates will not.");

            ValidateSchedule();

            // Descending, so the tick can stop at the first point it crosses.
            _config.Countdown.AnnounceAt = _config.Countdown.AnnounceAt
                .Where(x => x > 0).Distinct().OrderByDescending(x => x).ToList();

            // Ten seconds is plenty: the countdown works off the wall clock
            // rather than off tick accumulation, so a late start shortens the
            // countdown by a few seconds instead of moving the restart.
            _scanTimer = timer.Every(10f, Scan);

            if (_config.Framework.Enabled)
            {
                var minutes = Math.Max(5, _config.Framework.CheckIntervalMinutes);
                _frameworkTimer = timer.Every(minutes * 60f, CheckFrameworkRelease);
                timer.Once(60f, CheckFrameworkRelease);
                Puts($"Framework update checks are ON, every {minutes} minutes. " +
                     $"A new release schedules an announced update at {_config.Framework.UpdateAt}.");
            }

            var next = DescribeNext(null);
            Puts(next == null ? "No schedule is enabled. Nothing will restart." : $"Next: {next}");
        }

        private void Unload()
        {
            _scanTimer?.Destroy();
            _countdownTimer?.Destroy();
            _frameworkTimer?.Destroy();

            CloseAllMenus();   // ADR-0016: goes with the menu

            // Belt and braces: removes every bar this plugin ever created,
            // whatever state we think we are in. A bar left on someone's
            // screen after an unload has no way to remove itself.
            if (AdvancedStatus != null && !_statusDisabled)
            {
                try { AdvancedStatus.Call("DeleteAllPluginBars", Name); }
                catch (Exception ex) { PrintWarning($"Could not clear status bars: {ex.Message}"); }
            }

            if (_countdownActive && !_shuttingDown)
            {
                // Say so. A countdown that vanishes silently is the "restarts
                // unannounced" half of the safety envelope in reverse: players
                // brace for a restart that never comes.
                Broadcast("Canceled");
                RemoveBars();
                Puts("Unloaded mid-countdown. The restart was canceled.");
            }
        }

        #endregion

        #region Schedule scanning

        private const string RepeatDaily = "Daily";
        private const string RepeatWeekly = "Weekly";
        private const string RepeatMonthlyWeekday = "MonthlyWeekday";
        private const string RepeatMonthlyDay = "MonthlyDay";
        private const string RepeatEveryNDays = "EveryNDays";
        private const string RepeatOnce = "Once";

        private static readonly string[] RepeatModes =
        {
            RepeatDaily, RepeatWeekly, RepeatMonthlyWeekday,
            RepeatMonthlyDay, RepeatEveryNDays, RepeatOnce
        };

        private static readonly string[] Ordinals = { "First", "Second", "Third", "Fourth", "Last" };

        private static string Normalize(string repeat)
        {
            foreach (var mode in RepeatModes)
                if (string.Equals(mode, repeat, StringComparison.OrdinalIgnoreCase)) return mode;
            return repeat ?? "";
        }

        // What is wrong with an entry, carried as a lang key plus its
        // arguments rather than as a finished sentence: the code that finds
        // the fault is static and has no viewer to translate for, and the
        // console, the chat commands and the panel all show the same fault to
        // different audiences. Whoever displays it calls Text().
        private sealed class Problem
        {
            public readonly string Key;
            public readonly object[] Args;

            public Problem(string key, params object[] args)
            {
                Key = key;
                Args = args;
            }
        }

        private string Text(Problem problem, string user)
        {
            return problem == null ? null : T(problem.Key, user, problem.Args);
        }

        // Returns null when the entry is usable.
        private static Problem ValidationError(ScheduleEntry e)
        {
            if (ParseTime(e.Time) == null)
                return new Problem("ErrBadTime", e.Time);

            switch (Normalize(e.Repeat))
            {
                case RepeatDaily:
                    return null;

                case RepeatWeekly:
                    return ParsedDays(e).Count == 0 ? new Problem("ErrNoDays") : null;

                case RepeatMonthlyWeekday:
                    if (ParsedDays(e).Count == 0) return new Problem("ErrNoWeekday");
                    foreach (var o in Ordinals)
                        if (string.Equals(o, e.Ordinal, StringComparison.OrdinalIgnoreCase)) return null;
                    return new Problem("ErrBadOrdinal", e.Ordinal, string.Join(", ", Ordinals));

                case RepeatMonthlyDay:
                    return e.DayOfMonth < 1 || e.DayOfMonth > 31
                        ? new Problem("ErrDayOfMonth")
                        : null;

                case RepeatEveryNDays:
                    return e.IntervalDays < 1 ? new Problem("ErrInterval") : null;

                case RepeatOnce:
                    return ParseDate(e.Date) == null ? new Problem("ErrBadDate", e.Date) : null;

                default:
                    return new Problem("ErrBadRepeat", e.Repeat, string.Join(", ", RepeatModes));
            }
        }

        private void ValidateSchedule()
        {
            var changed = false;
            foreach (var e in AllEntries())
            {
                if (!e.Enabled) continue;

                var problem = ValidationError(e);
                if (problem != null)
                {
                    e.Enabled = false;
                    changed = true;
                    PrintError($"Schedule entry at {e.Time}: {Text(problem, null)} Entry DISABLED.");
                    continue;
                }

                var mode = Normalize(e.Repeat);

                if (mode == RepeatEveryNDays && ParseDate(e.AnchorDate) == null)
                {
                    e.AnchorDate = DateTime.Now.ToString("yyyy-MM-dd");
                    changed = true;
                    Puts($"The entry at {e.Time} repeats every {e.IntervalDays} days and had no anchor " +
                         $"date. Anchored to {e.AnchorDate}; edit it if you meant a different day.");
                }

                if (mode == RepeatMonthlyDay && e.DayOfMonth > 28)
                    PrintWarning($"The entry at {e.Time} runs on day {e.DayOfMonth}, which does not exist " +
                                 "in every month. Those months are skipped, not moved.");
            }
            if (changed) SaveConfig();
        }

        private IEnumerable<ScheduleEntry> AllEntries()
        {
            foreach (var e in _config.Restarts) yield return e;
            foreach (var e in _config.Updates) yield return e;
        }

        private void Scan()
        {
            if (_countdownActive || _shuttingDown) return;

            var now = DateTime.Now;
            var start = Math.Max(10, _config.Countdown.StartSeconds);

            ScheduleEntry best = null;
            DateTime bestTarget = DateTime.MaxValue;

            foreach (var e in AllEntries())
            {
                if (!e.Enabled) continue;
                var next = NextOccurrence(e, now);
                if (next == null) continue;
                if ((next.Value - now).TotalSeconds > start) continue;
                if (FiredRecently(e.Key, now)) continue;

                // Earliest wins. On a tie an update beats a plain restart --
                // an update entry is a restart entry that also writes a flag,
                // so running it satisfies both. Validate beats update for the
                // same reason.
                if (next.Value < bestTarget ||
                    (next.Value == bestTarget && Rank(e) > Rank(best)))
                {
                    best = e;
                    bestTarget = next.Value;
                }
            }

            if (_oneShotTarget != null && _oneShotTarget.Value > now &&
                (_oneShotTarget.Value - now).TotalSeconds <= start)
            {
                if (best == null || _oneShotTarget.Value <= bestTarget)
                {
                    BeginCountdown(_oneShotTarget.Value, true, _oneShotValidate, null, "oneshot:" + _oneShotReason);
                    _oneShotTarget = null;
                    return;
                }
            }

            if (best != null)
                BeginCountdown(bestTarget, best.IsUpdate, best.IsValidate, best, best.Key);
        }

        private static int Rank(ScheduleEntry e)
        {
            if (e == null) return -1;
            return e.IsValidate ? 2 : e.IsUpdate ? 1 : 0;
        }

        private bool FiredRecently(string key, DateTime now)
        {
            if (!_lastFired.TryGetValue(key, out var last)) return false;
            var hours = _config.General.MinimumHoursBetweenSameEntry;
            if (hours <= 0) return false;
            var since = (now - last).TotalHours;
            // A negative value means the clock moved backwards under us --
            // spring-forward's mirror, or an NTP correction. Treat it as
            // "recently" rather than firing again immediately.
            return since < hours && since > -hours;
        }

        // An entry's recurrence, parsed once.
        //
        // This exists for one reason: NextOccurrence tests up to 367 dates, and
        // Scan calls it for every enabled entry every ten seconds. Parsing the
        // entry inside that loop meant a HashSet allocation and a string Trim
        // per day per entry -- on the order of eighteen hundred short-lived
        // objects every ten seconds on a five-entry schedule, for a plugin that
        // is doing nothing at all. Parsed once, it is a handful.
        private struct Recurrence
        {
            public string Mode;
            public HashSet<DayOfWeek> Days;
            public string Ordinal;
            public int DayOfMonth;
            public int IntervalDays;
            public DateTime? Anchor;
            public DateTime? Once;
        }

        private static Recurrence Parse(ScheduleEntry e)
        {
            return new Recurrence
            {
                Mode = Normalize(e.Repeat),
                Days = ParsedDays(e),
                Ordinal = e.Ordinal,
                DayOfMonth = e.DayOfMonth,
                IntervalDays = e.IntervalDays,
                Anchor = ParseDate(e.AnchorDate),
                Once = ParseDate(e.Date),
            };
        }

        // Walks forward a day at a time and asks each date whether it matches.
        // Slower than computing the next date per mode, and far harder to get
        // wrong: one predicate covers all six recurrences, "the 31st" simply
        // never matches in a short month, and there is no arithmetic to
        // misplace at a month or year boundary.
        private static DateTime? NextOccurrence(ScheduleEntry e, DateTime now)
        {
            var time = ParseTime(e.Time);
            if (time == null) return null;
            if (ValidationError(e) != null) return null;

            var recurrence = Parse(e);
            var from = now.Date;

            for (var i = 0; i <= 366; i++)
            {
                var date = from.AddDays(i);
                if (!Matches(recurrence, date)) continue;
                var candidate = date.Add(time.Value);
                if (candidate > now) return candidate;
            }
            return null;
        }

        private static bool Matches(Recurrence r, DateTime date)
        {
            switch (r.Mode)
            {
                case RepeatDaily:
                    return true;

                case RepeatWeekly:
                    return r.Days.Contains(date.DayOfWeek);

                case RepeatMonthlyWeekday:
                    return r.Days.Contains(date.DayOfWeek) && OrdinalMatches(date, r.Ordinal);

                case RepeatMonthlyDay:
                    return date.Day == r.DayOfMonth;

                case RepeatEveryNDays:
                    if (r.Anchor == null || r.IntervalDays < 1) return false;
                    var span = (date - r.Anchor.Value.Date).Days;
                    return span >= 0 && span % r.IntervalDays == 0;

                case RepeatOnce:
                    return r.Once != null && r.Once.Value.Date == date.Date;

                default:
                    return false;
            }
        }

        private static bool OrdinalMatches(DateTime date, string ordinal)
        {
            // "Last" is the only one that needs the month's length: if adding
            // a week lands in the next month, this is the last such weekday.
            if (string.Equals(ordinal, "Last", StringComparison.OrdinalIgnoreCase))
                return date.AddDays(7).Month != date.Month;

            // Every month contains a first through fourth of every weekday,
            // because every month has at least 28 days. A fifth does not always
            // exist, which is why it is not offered.
            var which = (date.Day - 1) / 7 + 1;
            switch (ordinal == null ? "" : ordinal.ToLowerInvariant())
            {
                case "first": return which == 1;
                case "second": return which == 2;
                case "third": return which == 3;
                case "fourth": return which == 4;
                default: return false;
            }
        }

        private static TimeSpan? ParseTime(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return null;
            if (TimeSpan.TryParseExact(raw.Trim(), @"hh\:mm", CultureInfo.InvariantCulture, out var ts))
                return ts;
            if (TimeSpan.TryParseExact(raw.Trim(), @"h\:mm", CultureInfo.InvariantCulture, out ts))
                return ts;
            return null;
        }

        private static DateTime? ParseDate(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return null;
            return DateTime.TryParseExact(raw.Trim(), "yyyy-MM-dd", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var d) ? d : (DateTime?)null;
        }

        private static readonly Dictionary<string, DayOfWeek> DayNames = new Dictionary<string, DayOfWeek>(StringComparer.OrdinalIgnoreCase)
        {
            { "mon", DayOfWeek.Monday }, { "monday", DayOfWeek.Monday },
            { "tue", DayOfWeek.Tuesday }, { "tues", DayOfWeek.Tuesday }, { "tuesday", DayOfWeek.Tuesday },
            { "wed", DayOfWeek.Wednesday }, { "wednesday", DayOfWeek.Wednesday },
            { "thu", DayOfWeek.Thursday }, { "thur", DayOfWeek.Thursday }, { "thurs", DayOfWeek.Thursday }, { "thursday", DayOfWeek.Thursday },
            { "fri", DayOfWeek.Friday }, { "friday", DayOfWeek.Friday },
            { "sat", DayOfWeek.Saturday }, { "saturday", DayOfWeek.Saturday },
            { "sun", DayOfWeek.Sunday }, { "sunday", DayOfWeek.Sunday }
        };

        private static DayOfWeek? ParseDay(string token)
        {
            if (string.IsNullOrWhiteSpace(token)) return null;
            return DayNames.TryGetValue(token.Trim(), out var day) ? day : (DayOfWeek?)null;
        }

        private static HashSet<DayOfWeek> ParsedDays(ScheduleEntry e)
        {
            var set = new HashSet<DayOfWeek>();
            if (e.Days == null) return set;
            foreach (var token in e.Days)
            {
                var day = ParseDay(token);
                if (day != null) set.Add(day.Value);
            }
            return set;
        }

        // Takes the tail of a chat command and turns it into a recurrence.
        // Returns null on success, or the Problem it could not read past. The
        // menu writes the same fields directly; this exists so the console is
        // not the poor relation.
        //
        // The tokens it accepts stay English -- "weekdays", "first Thursday" --
        // because they are a command grammar, not prose. Only the complaint
        // about them is translated.
        private static Problem ApplyPattern(ScheduleEntry e, string[] tokens)
        {
            var list = new List<string>();
            foreach (var t in tokens)
                if (!string.IsNullOrWhiteSpace(t)) list.Add(t.Trim());

            // Politeness words people will type anyway.
            while (list.Count > 0 &&
                   (list[0].Equals("the", StringComparison.OrdinalIgnoreCase) ||
                    list[0].Equals("on", StringComparison.OrdinalIgnoreCase) &&
                    list.Count > 1 && ParseDate(list[1]) == null && ParseDay(list[1]) != null))
                list.RemoveAt(0);

            if (list.Count == 0 || list[0].Equals("daily", StringComparison.OrdinalIgnoreCase))
            {
                e.Repeat = RepeatDaily;
                return null;
            }

            var head = list[0].ToLowerInvariant();

            if (head == "weekdays" || head == "weekends")
            {
                e.Repeat = RepeatWeekly;
                e.Days = head == "weekdays"
                    ? new List<string> { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday" }
                    : new List<string> { "Saturday", "Sunday" };
                return null;
            }

            if (head == "day" && list.Count >= 2 && int.TryParse(list[1], out var dayOfMonth))
            {
                if (dayOfMonth < 1 || dayOfMonth > 31) return new Problem("ErrDayOfMonth");
                e.Repeat = RepeatMonthlyDay;
                e.DayOfMonth = dayOfMonth;
                return null;
            }

            if (head == "every" && list.Count >= 2 && int.TryParse(list[1], out var interval))
            {
                if (interval < 1) return new Problem("ErrInterval");
                e.Repeat = RepeatEveryNDays;
                e.IntervalDays = interval;
                e.AnchorDate = DateTime.Now.ToString("yyyy-MM-dd");
                return null;
            }

            // "every Tuesday" -- drop the word and read the rest as days.
            if (head == "every" && list.Count >= 2)
            {
                list.RemoveAt(0);
                head = list[0].ToLowerInvariant();
            }

            if ((head == "once" || head == "on") && list.Count >= 2)
            {
                if (ParseDate(list[1]) == null) return new Problem("ErrBadDate", list[1]);
                e.Repeat = RepeatOnce;
                e.Date = list[1].Trim();
                return null;
            }

            foreach (var ordinal in Ordinals)
            {
                if (!string.Equals(ordinal, head, StringComparison.OrdinalIgnoreCase)) continue;
                if (list.Count < 2) return new Problem("ErrOrdinalNeedsDay", ordinal, ordinal.ToLowerInvariant());
                var day = ParseDay(list[1]);
                if (day == null) return new Problem("ErrNotADay", list[1]);
                e.Repeat = RepeatMonthlyWeekday;
                e.Ordinal = ordinal;
                e.Days = new List<string> { day.Value.ToString() };
                return null;
            }

            // Otherwise: a list of weekday names, comma or space separated.
            var days = new List<string>();
            foreach (var token in string.Join(",", list.ToArray()).Split(','))
            {
                var t = token.Trim();
                if (t.Length == 0) continue;
                var day = ParseDay(t);
                if (day == null) return new Problem("ErrNotADayOrPattern", t);
                days.Add(day.Value.ToString());
            }
            if (days.Count == 0) return new Problem("ErrNoDaysGiven");
            e.Repeat = RepeatWeekly;
            e.Days = days;
            return null;
        }

        // Every phrase the plugin shows a player is composed from lang keys,
        // not built by concatenating English. That is a uMod requirement, and
        // it is also what stops "the first Thursday of the month" being
        // untranslatable: word order differs between languages, so the ordinal
        // and the weekday are format arguments rather than glued together.
        //
        // Each of these takes the viewer's id so a translated server can show
        // two players different languages. Pass null for console output.
        private string T(string key, string user, params object[] args)
        {
            var message = lang.GetMessage(key, this, user);
            return args.Length == 0 ? message : string.Format(message, args);
        }

        // The zone and DST state, attached to every time the plugin prints.
        // The schedule is local wall-clock (ADR-0013), so "05:00" means a
        // different absolute moment either side of a DST change, and an admin
        // reading "next Sunday 05:00" deserves to know which 05:00 that is.
        //
        // Computed for the moment being displayed, not for now: a date in
        // November can be standard time while today is still daylight time.
        private string ZoneSuffix(DateTime when, string user)
        {
            try
            {
                var tz = TimeZoneInfo.Local;
                var dst = tz.IsDaylightSavingTime(when);
                var offset = tz.GetUtcOffset(when);
                var sign = offset < TimeSpan.Zero ? "-" : "+";
                var abs = offset.Duration();
                var name = dst ? tz.DaylightName : tz.StandardName;
                if (string.IsNullOrWhiteSpace(name)) name = tz.Id;
                var utc = $"{sign}{abs.Hours:00}:{abs.Minutes:00}";
                return T(dst ? "ZoneDst" : "Zone", user, name, utc);
            }
            catch
            {
                // Some Mono builds have thin zone data. Saying nothing beats
                // saying something wrong about what time it is.
                return T("ZoneUnknown", user);
            }
        }

        // Just the offset. The full zone name is three lines of wrapped text in
        // a panel row, and the summary line already carries it.
        private string ZoneShort(DateTime when, string user)
        {
            try
            {
                var tz = TimeZoneInfo.Local;
                var offset = tz.GetUtcOffset(when);
                var sign = offset < TimeSpan.Zero ? "-" : "+";
                var abs = offset.Duration();
                var utc = $"{sign}{abs.Hours:00}:{abs.Minutes:00}";
                return T(tz.IsDaylightSavingTime(when) ? "ZoneShortDst" : "ZoneShort", user, utc);
            }
            catch
            {
                return T("ZoneShortUnknown", user);
            }
        }

        private string Stamp(DateTime when, string user)
        {
            return T("Stamp", user,
                     when.ToString("ddd dd MMM yyyy HH:mm", CultureInfo.InvariantCulture),
                     ZoneSuffix(when, user));
        }

        // "in 4 minutes", "today at 11:10", "tomorrow at 05:00", "Saturday at
        // 11:10". The panel is read at a glance, and an absolute date answers a
        // question nobody asked: "next Saturday 5 September 2026" for something
        // four minutes away is technically true and actively misleading.
        private string Friendly(DateTime when, string user)
        {
            var now = DateTime.Now;
            var span = when - now;

            if (span.TotalSeconds <= 0) return T("WhenNow", user);
            if (span.TotalSeconds < 60) return T("WhenUnderMinute", user);
            if (span.TotalMinutes < 60)
            {
                var minutes = WholeMinutes((int)span.TotalSeconds);
                return T(minutes == 1 ? "WhenInMinute" : "WhenInMinutes", user, minutes);
            }

            var at = when.ToString("HH:mm", CultureInfo.InvariantCulture);
            if (when.Date == now.Date) return T("WhenToday", user, at);
            if (when.Date == now.Date.AddDays(1)) return T("WhenTomorrow", user, at);
            if ((when.Date - now.Date).TotalDays < 7)
                return T("WhenAt", user, DayName(when.DayOfWeek, user), at);
            return T("WhenAt", user, when.ToString("ddd d MMM", CultureInfo.InvariantCulture), at);
        }

        // True when a DST transition falls between the two moments, which is
        // exactly when a wall-clock schedule surprises somebody.
        private static bool OffsetChangesBetween(DateTime a, DateTime b)
        {
            try { return TimeZoneInfo.Local.GetUtcOffset(a) != TimeZoneInfo.Local.GetUtcOffset(b); }
            catch { return false; }
        }

        // Weekday names come from lang rather than from DayOfWeek.ToString(),
        // which is always English regardless of the server's culture.
        private string DayName(DayOfWeek day, string user)
        {
            return T("Day" + day, user);
        }

        private string DayNameShort(DayOfWeek day, string user)
        {
            return T("DayShort" + day, user);
        }

        private string Describe(ScheduleEntry e, string user)
        {
            var kind = T(e.IsValidate ? "KindValidate" : e.IsUpdate ? "KindUpdate" : "KindRestart", user);
            return T("EntryDescription", user, kind, DescribeRecurrence(e, user), e.Time);
        }

        private string DescribeRecurrence(ScheduleEntry e, string user)
        {
            switch (Normalize(e.Repeat))
            {
                case RepeatDaily:
                    return T("RecurDaily", user);
                case RepeatWeekly:
                    return T("RecurWeekly", user, DayList(e, user));
                case RepeatMonthlyWeekday:
                    return T("RecurMonthlyWeekday", user, OrdinalWord(e.Ordinal, user), DayList(e, user));
                case RepeatMonthlyDay:
                    return T("RecurMonthlyDay", user, e.DayOfMonth);
                case RepeatEveryNDays:
                    return e.IntervalDays == 1
                        ? T("RecurDaily", user)
                        : T("RecurEveryNDays", user, e.IntervalDays);
                case RepeatOnce:
                    return T("RecurOnce", user, e.Date);
                default:
                    return e.Repeat;
            }
        }

        private string OrdinalWord(string ordinal, string user)
        {
            foreach (var known in Ordinals)
                if (string.Equals(known, ordinal, StringComparison.OrdinalIgnoreCase))
                    return T("Ordinal" + known, user);
            return ordinal ?? "";
        }

        private string DayList(ScheduleEntry e, string user)
        {
            // Monday first, which is how a schedule reads, rather than
            // DayOfWeek's Sunday-first numbering.
            var days = ParsedDays(e)
                .OrderBy(d => ((int)d + 6) % 7)
                .Select(d => DayName(d, user))
                .ToArray();
            return days.Length == 0 ? T("DayListEmpty", user) : string.Join(", ", days);
        }

        #endregion

        #region Countdown

        private void BeginCountdown(DateTime target, bool isUpdate, bool isValidate, ScheduleEntry entry, string key)
        {
            if (_countdownActive || _shuttingDown) return;

            _countdownActive = true;
            _countdownTarget = target;
            _countdownEntry = entry;
            _countdownIsUpdate = isUpdate;
            _countdownIsValidate = isValidate;
            _countdownKey = key;
            _announced.Clear();

            var remaining = (int)Math.Round((target - DateTime.Now).TotalSeconds);
            _countdownStarted = DateTime.Now;

            // Everything at or above the time actually remaining has already
            // been said by the line below, or is in the past. Without this the
            // first tick repeats the opening announcement a second later.
            foreach (var point in _config.Countdown.AnnounceAt)
                if (point >= remaining) _announced.Add(point);
            Puts($"Countdown started: {KindWord(null)} in {remaining}s (entry {key}).");
            Broadcast("CountdownStart", u => new object[] { KindWord(u), FormatRemaining(remaining) });

            ShowBars();

            _countdownTimer?.Destroy();
            _countdownTimer = timer.Every(1f, CountdownTick);
        }

        private void CountdownTick()
        {
            if (!_countdownActive || _shuttingDown) return;

            // Remaining is recomputed from the wall clock every tick rather
            // than decremented. That makes the countdown immune to timescale,
            // to a stalled frame, and to timer drift over ten minutes -- the
            // restart lands when it said it would, and the worst a hitch can
            // do is skip an announcement.
            var remaining = (int)Math.Ceiling((_countdownTarget - DateTime.Now).TotalSeconds);

            if (remaining <= 0)
            {
                _countdownTimer?.Destroy();
                _countdownTimer = null;
                Execute();
                return;
            }

            UpdateBars(remaining);

            foreach (var point in _config.Countdown.AnnounceAt)
            {
                if (remaining > point) continue;
                if (!_announced.Add(point)) continue;
                Broadcast("CountdownTick", u => new object[] { KindWord(u), FormatRemaining(remaining) });
                break;
            }
        }

        // A countdown runs from a copy of the schedule, so switching an entry
        // off only stopped it happening AGAIN. The countdown already under way
        // carried on, and the panel showed the entry as disabled the whole
        // time -- which reads as "canceled" and is not.
        //
        // Anything that disables, deletes or edits the entry a live countdown
        // came from now cancels that countdown too. Cancelling is the safe
        // direction: the envelope forbids restarting a server unannounced, and
        // an admin who has just switched the thing off is not expecting one.
        private bool CancelCountdownFor(ScheduleEntry entry, string by)
        {
            if (!_countdownActive || _shuttingDown) return false;
            if (_countdownEntry == null || !ReferenceEquals(_countdownEntry, entry)) return false;
            CancelCountdown(by);
            return true;
        }

        private void CancelCountdown(string by)
        {
            if (!_countdownActive) return;
            if (_shuttingDown) return;

            _countdownTimer?.Destroy();
            _countdownTimer = null;
            _countdownActive = false;
            _countdownEntry = null;
            _countdownKey = "";
            _countdownIsUpdate = false;
            _countdownIsValidate = false;
            _announced.Clear();
            RemoveBars();

            Broadcast("Canceled");
            Puts($"Countdown canceled by {by}.");
        }

        private void Execute()
        {
            if (_shuttingDown) return;
            _shuttingDown = true;
            _countdownActive = false;
            RemoveBars();

            if (!string.IsNullOrEmpty(_countdownKey))
            {
                _lastFired[_countdownKey] = DateTime.Now;
                try
                {
                    Interface.Oxide.DataFileSystem.WriteObject(LastFiredFile, _lastFired);
                }
                catch (Exception ex)
                {
                    // Not fatal. The only cost is that a DST repeat could fire
                    // twice, which is a duplicate restart, not a missed one.
                    PrintWarning($"Could not persist the fired-recently guard: {ex.Message}");
                }
            }

            // A one-off has done the only thing it was for. Disabling it here
            // rather than deleting it leaves a record of what ran and when,
            // and lets an admin re-enable it rather than retype the date.
            if (_countdownEntry != null && Normalize(_countdownEntry.Repeat) == RepeatOnce)
            {
                _countdownEntry.Enabled = false;
                SaveConfig();
                Puts($"One-off entry fired ({Describe(_countdownEntry, null)}); it has disabled itself.");
            }

            // Flags first, while a failure can still be reported and while the
            // server is still up. A failed flag write downgrades an update to
            // a plain restart, which is the safe direction to fail in.
            if (_countdownIsUpdate)
                WriteFlags(_countdownIsValidate);

            Broadcast("Now", u => new object[] { KindWord(u) });

            var kicked = 0;
            foreach (var p in players.Connected.ToArray())
            {
                // Rule 4: never trust a reference across a frame. This list was
                // built this frame, but Kick can disconnect players as it goes.
                if (p == null || !p.IsConnected) continue;
                try
                {
                    p.Kick(T("KickReason", p.Id));
                    kicked++;
                }
                catch (Exception ex)
                {
                    PrintWarning($"Could not kick {p.Name}: {ex.Message}");
                }
            }
            Puts($"Kicked {kicked} player(s). Quitting.");

            var delay = Math.Max(0.1f, _config.Countdown.KickDelaySeconds);
            timer.Once(delay, Quit);
        }

        private void Quit() => Quit(false);

        private void Quit(bool isRetry)
        {
            try
            {
                // "quit" saves the world on the way out. A hard kill does not,
                // and on a server running server.saveinterval 300 that is up
                // to five minutes of everyone's progress (ADR-0002).
                //
                // Routed through Covalence rather than ConVar.Global.quit so
                // that the shutdown path carries no compile-time dependency on
                // Assembly-CSharp -- see the note at the top (ADR-0014).
                server.Command("quit");
            }
            catch (Exception ex)
            {
                if (!isRetry)
                {
                    PrintError($"quit failed: {ex.Message}. Retrying once in five seconds.");
                    timer.Once(5f, () => Quit(true));
                    return;
                }
                // Giving up here leaves a server that is up, empty and not
                // restarting. That is the worse half of the safety envelope,
                // so it is an error rather than a warning, and the countdown
                // state is released so an admin can retry by hand.
                PrintError($"quit failed twice: {ex.Message}. The server is STILL UP and players " +
                           "have been kicked. Run \"quit\" from the console, or use hotwire now 10.");
                _shuttingDown = false;
            }
        }

        private void WriteFlags(bool validate)
        {
            var root = ServerRoot();
            if (root == null)
            {
                PrintError("No server root, so no update flag was written. Restarting without updating.");
                return;
            }

            var name = validate ? _config.General.ValidateFlag : _config.General.UpdateFlag;
            if (string.IsNullOrWhiteSpace(name))
            {
                PrintError("The flag file name is empty. Restarting without updating.");
                return;
            }

            var path = Path.Combine(root, name);
            try
            {
                File.WriteAllText(path, $"Written by Hotwire at {DateTime.Now:yyyy-MM-dd HH:mm:ss}{Environment.NewLine}");
                Puts($"Wrote {path}. The launcher will act on it, then delete it -- one flag buys one update.");
            }
            catch (Exception ex)
            {
                PrintError($"Could not write {path}: {ex.Message}. Restarting without updating.");
            }
        }

        private string ServerRoot()
        {
            if (!string.IsNullOrWhiteSpace(_config.General.ServerRoot))
                return _config.General.ServerRoot.Trim();
            try
            {
                var root = Interface.Oxide.RootDirectory;
                return string.IsNullOrWhiteSpace(root) ? null : root;
            }
            catch
            {
                return null;
            }
        }

        // Takes the viewer because it is dropped into a message that is
        // itself translated per player -- a server-language kind word inside a
        // German sentence is exactly the half-translation the lang API exists
        // to prevent. Pass null for console output.
        private string KindWord(string user)
        {
            return T(_countdownIsValidate ? "KindValidate"
                   : _countdownIsUpdate ? "KindUpdate"
                   : "KindRestart", user);
        }

        // Rounded UP, and that is the whole point.
        //
        // An announcement is written once and then sits in chat for a minute
        // while the bar keeps counting. With truncation, 180s announces "3
        // minutes" and one second later 179/60 is 2, so the bar reads 2m
        // beside a chat line still saying 3. Both were doing the same
        // arithmetic; the arithmetic was wrong for a "time remaining" phrase.
        //
        // Rounding up makes "3 minutes" true until it is actually 2 minutes
        // away, so the chat line and the bar agree for the whole minute the
        // line is on screen.
        private static int WholeMinutes(int seconds)
        {
            return (seconds + 59) / 60;
        }

        private static string FormatRemaining(int seconds)
        {
            // ADR-0004: plain strings. Upstream ships a regex template
            // mini-language to render this, which is a large surface for
            // "5 minutes left".
            if (seconds >= 60)
            {
                var minutes = WholeMinutes(seconds);
                return minutes == 1 ? "1 minute" : $"{minutes} minutes";
            }
            if (seconds == 1) return "1 second";
            return $"{seconds} seconds";
        }

        #endregion

        #region Status surface

        // ADR-0003 renders the countdown through a status surface players
        // already read, rather than adding a fifth thing fighting for a screen
        // corner.
        //
        // Written against AdvancedStatus 0.1.26 by IIIaKa, read out of the
        // installed plugin -- signatures in docs/GAME-API.md. Everything here
        // is still wrapped: the plugin is paid and EULA'd, so most servers
        // will not have it, and a version that changes its API must cost us a
        // cosmetic bar and never a countdown.
        private const string BarId = "hotwire_countdown";

        // Fired by AdvancedStatus when it is ready to take bars. Without this
        // we would create bars during OnServerInitialized that it silently
        // drops, because every one of its API methods checks _isReady first.
        private void OnAdvancedStatusLoaded()
        {
            if (_countdownActive) ShowBars();
        }

        private bool StatusAvailable()
        {
            if (!_config.StatusBar.Enabled || _statusDisabled) return false;
            if (AdvancedStatus == null) return false;
            try
            {
                // IsReady() returns true, or null when it is not ready.
                return AdvancedStatus.Call("IsReady") is bool ready && ready;
            }
            catch (Exception ex)
            {
                DisableStatus(ex);
                return false;
            }
        }

        private void DisableStatus(Exception ex)
        {
            _statusDisabled = true;
            PrintWarning($"The status bar failed ({ex.Message}). Falling back to chat for the rest " +
                         "of this session. The countdown itself is unaffected.");
        }

        // Unix epoch seconds, which is what AdvancedStatus compares against.
        //
        // VERIFY: it reads the clock as Network.TimeEx.currentTimestamp, a
        // Facepunch type. Computing the same value here keeps this region free
        // of Facepunch types, which matters: if the menu region ever has to be
        // deleted after a Rust update, everything else still compiles.
        private static readonly DateTime UnixEpoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        private static double UnixAt(DateTime when)
        {
            return (when.ToUniversalTime() - UnixEpoch).TotalSeconds;
        }

        // AdvancedStatus passes an un-prefixed hex string straight through to
        // CUI, where it is unparseable and every bar renders white. Normalize
        // to #RRGGBB, and expand #RGB shorthand, which CUI does not understand
        // either.
        private static string Hex(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return "#FFFFFF";
            var v = value.Trim();
            if (!v.StartsWith("#")) v = "#" + v;
            if (v.Length == 4)
                v = "#" + v[1] + v[1] + v[2] + v[2] + v[3] + v[3];
            return v.Length >= 7 ? v.Substring(0, 7) : "#FFFFFF";
        }

        private int RemainingSeconds()
        {
            return Math.Max(0, (int)Math.Ceiling((_countdownTarget - DateTime.Now).TotalSeconds));
        }

        private string CountdownText(int remaining)
        {
            // Same rounding as the chat announcements, from the same helper,
            // so the bar and a line already sitting in chat cannot disagree.
            string text;
            if (remaining >= 60) text = WholeMinutes(remaining) + "m";
            else if (_config.StatusBar.SecondsInFinalMinute) text = remaining + "s";
            else text = "<1m";

            var min = Math.Max(1, Math.Min(12, _config.StatusBar.CountdownMinWidth));
            return text.Length >= min ? text : text.PadRight(min);
        }

        // BarType is TimeProgress, not TimeProgressCounter. Both drive the fill
        // from the timestamps on AdvancedStatus's own tick and delete the bar
        // when TimeStamp passes -- so neither the fill nor the removal needs
        // pushing from here. The Counter variant additionally formats its own
        // countdown string, in code, with no format parameter: it would put
        // seconds on the bar for the whole countdown, and its short strings hit
        // the SubText rect under-allocation described above. Rendering SubText
        // here is the only way to control either.
        private Dictionary<string, object> BarParameters(int remaining, string user)
        {
            var progress = Hex(_config.StatusBar.ProgressColor);
            var style = (_config.StatusBar.FillStyle ?? "").Trim();
            var fills = style.Equals("Fills", StringComparison.OrdinalIgnoreCase)
                        || style.Equals("Drains", StringComparison.OrdinalIgnoreCase);

            var p = new Dictionary<string, object>
            {
                // Both required; CreateBar returns silently without them.
                ["Plugin"] = Name,
                ["Id"] = BarId,
                ["Category"] = _config.StatusBar.Category,
                ["Order"] = _config.StatusBar.Order,

                ["BarType"] = fills ? "TimeProgress" : "Timed",

                ["Text"] = T("BarLabel", user),
                ["Text_Color"] = Hex(_config.StatusBar.TextColor),
                ["Text_Offset_Horizontal"] = _config.StatusBar.TextIndent,

                ["SubText"] = CountdownText(remaining),

                // Doubles, and checked as such -- an int or a float here is
                // ignored in silence and the bar quietly becomes a plain one.
                ["TimeStampStart"] = UnixAt(_countdownStarted),
                ["TimeStamp"] = UnixAt(_countdownTarget)
            };

            p["Progress_Color"] = progress;

            if (fills)
            {
                // TimeProgress recomputes Progress every tick from the
                // timestamps, so a value set here would be overwritten at once.
                p["Progress_Reverse"] = style.Equals("Drains", StringComparison.OrdinalIgnoreCase);
            }
            else
            {
                // Timed leaves Progress alone. A float: an int or a double here
                // is ignored in silence and the bar renders empty.
                p["Progress"] = 1f;
            }

            p["Image_Color"] = string.IsNullOrWhiteSpace(_config.StatusBar.IconColor)
                ? progress
                : Hex(_config.StatusBar.IconColor);

            // Sprite, then local file, then URL -- cheapest first. A URL is
            // rendered as a RawImage with the address directly, so it needs no
            // ImageLibrary round trip.
            if (!string.IsNullOrWhiteSpace(_config.StatusBar.ImageSprite))
                p["Image_Sprite"] = _config.StatusBar.ImageSprite.Trim();
            else if (!string.IsNullOrWhiteSpace(_config.StatusBar.ImageLocal))
                p["Image_Local"] = _config.StatusBar.ImageLocal.Trim();
            else if (!string.IsNullOrWhiteSpace(_config.StatusBar.ImageUrl))
                p["Image"] = _config.StatusBar.ImageUrl.Trim();

            // Main_Color and Main_Transparency are deliberately left alone
            // unless set: the frame then inherits AdvancedStatus's own, and
            // matches every other plugin's bars even after it is retuned.
            if (!string.IsNullOrWhiteSpace(_config.StatusBar.MainColor))
                p["Main_Color"] = Hex(_config.StatusBar.MainColor);

            return p;
        }

        private void ShowBars()
        {
            if (!StatusAvailable()) return;
            var remaining = RemainingSeconds();
            _lastSubText = CountdownText(remaining);
            try
            {
                foreach (var player in players.Connected.ToArray())
                {
                    if (player == null || !player.IsConnected) continue;
                    // Rebuilt per player rather than once: the label is a lang
                    // string, and one dictionary shared across everyone would
                    // show the server's language to a player who reads another.
                    // The string overload, so nothing here needs a BasePlayer.
                    AdvancedStatus.Call("CreateBar", player.Id, BarParameters(remaining, player.Id));
                }
            }
            catch (Exception ex)
            {
                DisableStatus(ex);
            }
        }

        private void ShowBarFor(IPlayer player)
        {
            if (!StatusAvailable() || player == null || !player.IsConnected) return;
            try
            {
                AdvancedStatus.Call("CreateBar", player.Id, BarParameters(RemainingSeconds(), player.Id));
            }
            catch (Exception ex)
            {
                DisableStatus(ex);
            }
        }

        // Only the countdown text is pushed, and only when it changes -- once a
        // minute by default. The fill animates on AdvancedStatus's own tick
        // without any of this.
        private void UpdateBars(int remaining)
        {
            if (!StatusAvailable()) return;

            var text = CountdownText(remaining);
            if (text == _lastSubText) return;
            _lastSubText = text;

            try
            {
                var parameters = new Dictionary<string, object>
                {
                    ["Plugin"] = Name,
                    ["Id"] = BarId,
                    ["SubText"] = text
                };
                foreach (var player in players.Connected.ToArray())
                {
                    if (player == null || !player.IsConnected) continue;
                    AdvancedStatus.Call("UpdateContent", player.Id, parameters);
                }
            }
            catch (Exception ex)
            {
                DisableStatus(ex);
            }
        }

        private void RemoveBars()
        {
            _lastSubText = null;
            if (AdvancedStatus == null || _statusDisabled) return;
            try
            {
                // The bar removes itself when its timestamp passes, so this is
                // for the endings that arrive early: a cancel, an unload, a
                // shutdown that beats the clock.
                AdvancedStatus.Call("DeleteBarForAll", BarId, Name);
            }
            catch (Exception ex)
            {
                PrintWarning($"Could not remove the status bar: {ex.Message}");
            }
        }

        // A player who connects mid-countdown gets the bar too. They also get
        // the next chat announcement, so this is belt and braces rather than
        // their only warning.
        private void OnUserConnected(IPlayer player)
        {
            if (_countdownActive && !_shuttingDown) ShowBarFor(player);
        }

        #endregion

        #region Framework release check

        private void CheckFrameworkRelease()
        {
            if (!_config.Framework.Enabled) return;

            webrequest.Enqueue(_config.Framework.Url, null, (code, response) =>
            {
                if (code != 200 || string.IsNullOrEmpty(response))
                {
                    PrintWarning($"Framework release check failed (HTTP {code}). Will try again next interval.");
                    return;
                }

                string latest;
                try
                {
                    // VERIFY: the response shape of the uMod release feed is
                    // assumed, not confirmed. Parsed defensively so that a
                    // changed feed logs a warning instead of throwing on a
                    // timer forever.
                    latest = JObject.Parse(response)["latest_release_version"]?.ToString();
                }
                catch (Exception ex)
                {
                    PrintWarning($"Could not read the release feed: {ex.Message}");
                    return;
                }

                if (string.IsNullOrEmpty(latest))
                {
                    PrintWarning("The release feed had no latest_release_version field. Check the URL.");
                    return;
                }

                var installed = InstalledFrameworkVersion();
                if (installed == null)
                {
                    PrintWarning("Could not read the installed framework version. Skipping the comparison.");
                    return;
                }

                if (_knownFrameworkVersion == null) _knownFrameworkVersion = installed;
                if (latest == installed || latest == _knownFrameworkVersion) return;

                _knownFrameworkVersion = latest;

                var when = ParseTime(_config.Framework.UpdateAt);
                if (when == null)
                {
                    PrintError($"\"{_config.Framework.UpdateAt}\" is not a valid HH:mm. No update was scheduled.");
                    return;
                }

                var now = DateTime.Now;
                var target = now.Date.Add(when.Value);
                if (target <= now) target = target.AddDays(1);

                _oneShotTarget = target;
                _oneShotValidate = _config.Framework.Validate;
                // The version only. The word around it is a lang string,
                // added when the line is rendered for a particular reader.
                _oneShotReason = latest;

                Puts($"Framework {latest} is available (installed {installed}). " +
                     $"An announced update is scheduled for {target:yyyy-MM-dd HH:mm}.");
                Broadcast("FrameworkFound", target.ToString("HH:mm"));
            }, this, Oxide.Core.Libraries.RequestMethod.GET);
        }

        private string InstalledFrameworkVersion()
        {
            try
            {
                // VERIFY: assumed extension name. Wrapped because being wrong
                // here should disable one optional feature, not the plugin.
                foreach (var ext in Interface.Oxide.GetAllExtensions())
                    if (ext != null && ext.Name == "Rust")
                        return ext.Version.ToString();
            }
            catch (Exception ex)
            {
                PrintWarning($"Could not enumerate extensions: {ex.Message}");
            }
            return null;
        }

        #endregion

        #region Admin menu

        // The only part of this plugin that touches Facepunch types. Rust's UI
        // has no Covalence route -- CuiHelper.AddUi takes a BasePlayer -- so
        // building a panel means naming BasePlayer and the Cui* classes, which
        // reverses part of ADR-0014 (see ADR-0016).
        //
        // Everything the menu does, the chat commands already do. That is
        // ADR-0006's condition and it is load-bearing here: if this region
        // stops compiling after a Rust update, the fix is to delete it, and
        // the schedule is still fully editable.
        //
        // Lifecycle rules, because CUI lifecycle is where these plugins go
        // wrong: one root element name, destroyed before every redraw,
        // destroyed on close, on disconnect and on unload; the BasePlayer is
        // re-fetched at each use and never held across a frame.

        // Two elements, and the split matters. The root owns CursorEnabled and
        // is created ONCE per open; the content is destroyed and rebuilt on
        // every click. Rust frees the mouse only while some UI asks for it, so
        // if the cursor-owning element is destroyed and re-added across two
        // frames -- which is what fast clicking causes -- there is a frame with
        // nothing asking, and the game re-locks the cursor to look-control and
        // parks it at screen center.
        private const string MenuRoot = "hotwire.menu";
        private const string MenuContent = "hotwire.menu.content";

        private class MenuState
        {
            public string List = "";
            public int Index = -1;                 // -1 means the list view
            public bool RootDrawn;
            public bool Editing => Index >= 0;
        }

        private readonly Dictionary<string, MenuState> _menus = new Dictionary<string, MenuState>();

        // Colors are space-separated floats, not hex, and they must be
        // formatted with the invariant culture: on a server whose locale uses a
        // comma decimal separator, "0.35" becomes "0,35" and the whole panel
        // renders wrong. Same reason Anchor() exists below.
        private const string ColBackground = "0.10 0.10 0.11 0.96";
        private const string ColHeader = "0.16 0.16 0.18 1.00";
        private const string ColRow = "0.18 0.18 0.20 0.90";
        private const string ColButton = "0.28 0.28 0.31 1.00";
        private const string ColOn = "0.33 0.56 0.33 1.00";
        private const string ColOff = "0.42 0.22 0.22 1.00";
        private const string ColDanger = "0.58 0.24 0.20 1.00";
        private const string ColText = "0.90 0.90 0.90 1.00";
        private const string ColMuted = "0.62 0.62 0.65 1.00";

        private static string Anchor(double x, double y)
        {
            return x.ToString("0.####", CultureInfo.InvariantCulture) + " " +
                   y.ToString("0.####", CultureInfo.InvariantCulture);
        }

        private static BasePlayer ToBasePlayer(IPlayer player)
        {
            // Rule 4: fetched fresh every time, never stored. Rust destroys
            // entities constantly and a menu can outlive the player it is on.
            var basePlayer = player == null ? null : player.Object as BasePlayer;
            if (basePlayer == null || basePlayer.IsDestroyed) return null;
            return basePlayer;
        }

        private void CmdMenu(IPlayer player)
        {
            if (!Allowed(player, PermStatus)) return;
            if (player.IsServer) { Reply(player, "MenuNeedsPlayer"); return; }
            if (ToBasePlayer(player) == null) { Reply(player, "MenuNeedsPlayer"); return; }

            _menus[player.Id] = new MenuState();
            DrawMenu(player);
        }

        private void CloseMenu(IPlayer player)
        {
            _menus.Remove(player.Id);
            var basePlayer = ToBasePlayer(player);
            if (basePlayer == null) return;
            // Destroying the root takes the content with it; it is a child.
            try { CuiHelper.DestroyUi(basePlayer, MenuRoot); }
            catch (Exception ex) { PrintWarning($"Could not close the menu: {ex.Message}"); }
        }

        private void OnUserDisconnected(IPlayer player)
        {
            if (player == null) return;
            _menus.Remove(player.Id);
            // No DestroyUi: they are gone, and the panel goes with them.
        }

        private void CloseAllMenus()
        {
            foreach (var id in _menus.Keys.ToArray())
            {
                var player = players.FindPlayerById(id);
                if (player != null && player.IsConnected)
                {
                    var basePlayer = ToBasePlayer(player);
                    if (basePlayer != null)
                    {
                        try { CuiHelper.DestroyUi(basePlayer, MenuRoot); }
                        catch { /* going away regardless */ }
                    }
                }
            }
            _menus.Clear();
        }

        private void DrawMenu(IPlayer player)
        {
            var basePlayer = ToBasePlayer(player);
            if (basePlayer == null) { _menus.Remove(player.Id); return; }

            MenuState state;
            if (!_menus.TryGetValue(player.Id, out state)) return;

            try
            {
                var ui = new CuiElementContainer();

                if (!state.RootDrawn)
                {
                    // First draw only. Anything stale from a previous session
                    // goes here, and never again while the menu is open.
                    CuiHelper.DestroyUi(basePlayer, MenuRoot);
                    ui.Add(new CuiPanel
                    {
                        Image = { Color = ColBackground },
                        RectTransform = { AnchorMin = Anchor(0.22, 0.12), AnchorMax = Anchor(0.78, 0.88) },
                        CursorEnabled = true
                    }, "Overlay", MenuRoot);
                    state.RootDrawn = true;
                }
                else
                {
                    // Redraw: only the content goes. The root, and with it the
                    // cursor, stays put.
                    CuiHelper.DestroyUi(basePlayer, MenuContent);
                }

                // Transparent, and deliberately does NOT request the cursor.
                ui.Add(new CuiPanel
                {
                    Image = { Color = "0 0 0 0" },
                    RectTransform = { AnchorMin = Anchor(0, 0), AnchorMax = Anchor(1, 1) }
                }, MenuRoot, MenuContent);

                ui.Add(new CuiPanel
                {
                    Image = { Color = ColHeader },
                    RectTransform = { AnchorMin = Anchor(0, 0.92), AnchorMax = Anchor(1, 1) }
                }, MenuContent, MenuContent + ".header");

                Label(ui, MenuContent + ".header", 0.02, 0, 0.8, 1,
                      state.Editing
                          ? T("MenuTitleEditing", player.Id, Version, state.List, state.Index)
                          : T("MenuTitleList", player.Id, Version),
                      15, ColText, TextAnchor.MiddleLeft);

                Button(ui, MenuContent + ".header", 0.93, 0.15, 0.98, 0.85, "X", "hotwire.ui close", ColDanger);

                // A live countdown is the most important thing on this screen,
                // and it used to be the one thing the panel did not show. An
                // admin switching an entry off saw it read "disabled" and
                // reasonably concluded the restart was called off.
                var top = 0.88;
                if (_countdownActive && !_shuttingDown)
                {
                    ui.Add(new CuiPanel
                    {
                        Image = { Color = ColDanger },
                        RectTransform = { AnchorMin = Anchor(0.02, 0.815), AnchorMax = Anchor(0.98, 0.905) }
                    }, MenuContent, MenuContent + ".live");

                    Label(ui, MenuContent + ".live", 0.02, 0, 0.72, 1,
                          T("MenuCountingDown", player.Id, KindWord(player.Id),
                            FormatRemaining(RemainingSeconds())),
                          14, ColText, TextAnchor.MiddleLeft);
                    Button(ui, MenuContent + ".live", 0.74, 0.15, 0.98, 0.85,
                           T("MenuCancel", player.Id), "hotwire.ui cancelcountdown", ColButton);

                    top = 0.79;
                }

                if (state.Editing) DrawEdit(ui, player, state, top);
                else DrawList(ui, player, top);

                CuiHelper.AddUi(basePlayer, ui);
            }
            catch (Exception ex)
            {
                // A broken panel must never be able to take the schedule with
                // it. Close it, say so, and leave the chat commands standing.
                PrintError($"The menu failed to draw: {ex.Message}. Use the chat commands instead.");
                _menus.Remove(player.Id);
                // A half-built panel would keep the cursor and cover the
                // screen with no way to close it.
                try { CuiHelper.DestroyUi(basePlayer, MenuRoot); } catch { /* nothing more to try */ }
            }
        }

        private void DrawList(CuiElementContainer ui, IPlayer player, double top)
        {
            const double height = 0.075, gap = 0.013;
            var rows = new List<KeyValuePair<string, int>>();
            for (var i = 0; i < _config.Restarts.Count; i++) rows.Add(new KeyValuePair<string, int>("restart", i));
            for (var i = 0; i < _config.Updates.Count; i++) rows.Add(new KeyValuePair<string, int>("update", i));

            if (rows.Count == 0)
                Label(ui, MenuContent, 0.04, 0.75, 0.96, 0.85,
                      T("MenuNothingScheduled", player.Id), 14, ColMuted, TextAnchor.MiddleLeft);

            // One fewer visible row when the countdown banner is up.
            var shown = Math.Min(rows.Count, top > 0.85 ? 9 : 8);
            for (var i = 0; i < shown; i++)
            {
                var listName = rows[i].Key;
                var index = rows[i].Value;
                var entry = listName == "restart" ? _config.Restarts[index] : (ScheduleEntry)_config.Updates[index];

                var y1 = top - i * (height + gap);
                var y0 = y1 - height;

                ui.Add(new CuiPanel
                {
                    Image = { Color = ColRow },
                    RectTransform = { AnchorMin = Anchor(0.02, y0), AnchorMax = Anchor(0.98, y1) }
                }, MenuContent, MenuContent + ".row" + i);

                var problem = ValidationError(entry);
                var next = entry.Enabled && problem == null ? NextOccurrence(entry, DateTime.Now) : null;
                var detail = problem != null
                    ? T("MenuBroken", player.Id, Text(problem, player.Id))
                    : next != null
                        ? Friendly(next.Value, player.Id) +
                          (OffsetChangesBetween(DateTime.Now, next.Value)
                              ? "   " + T("MenuClocksChangeShort", player.Id)
                              : "")
                        : T(entry.Enabled ? "MenuNoOccurrenceShort" : "MenuDisabled", player.Id);

                Label(ui, MenuContent + ".row" + i, 0.02, 0.45, 0.62, 0.98,
                      Sentence(Describe(entry, player.Id)), 13, ColText, TextAnchor.MiddleLeft);
                Label(ui, MenuContent + ".row" + i, 0.02, 0.05, 0.62, 0.5, detail, 11,
                      problem != null ? "0.85 0.45 0.40 1.00" : ColMuted, TextAnchor.MiddleLeft);

                Button(ui, MenuContent + ".row" + i, 0.63, 0.15, 0.75, 0.85,
                       T(entry.Enabled ? "MenuOn" : "MenuOff", player.Id),
                       $"hotwire.ui toggle {listName} {index}",
                       entry.Enabled ? ColOn : ColOff);
                Button(ui, MenuContent + ".row" + i, 0.76, 0.15, 0.87, 0.85,
                       T("MenuEdit", player.Id), $"hotwire.ui edit {listName} {index}", ColButton);
                Button(ui, MenuContent + ".row" + i, 0.88, 0.15, 0.98, 0.85,
                       T("MenuDelete", player.Id), $"hotwire.ui delete {listName} {index}", ColDanger);
            }

            if (rows.Count > shown)
                Label(ui, MenuContent, 0.04, 0.11, 0.96, 0.16,
                      T("MenuMoreRows", player.Id, rows.Count - shown),
                      11, ColMuted, TextAnchor.MiddleLeft);

            Button(ui, MenuContent, 0.02, 0.02, 0.26, 0.09, T("MenuAddRestart", player.Id),
                   "hotwire.ui add restart", ColButton);
            Button(ui, MenuContent, 0.27, 0.02, 0.51, 0.09, T("MenuAddUpdate", player.Id),
                   "hotwire.ui add update", ColButton);
            Label(ui, MenuContent, 0.54, 0.02, 0.98, 0.09,
                  T("MenuAddHint", player.Id),
                  11, ColMuted, TextAnchor.MiddleRight);
        }

        private void DrawEdit(CuiElementContainer ui, IPlayer player, MenuState state, double top)
        {
            var list = ListFor(state.List);
            if (list == null || state.Index < 0 || state.Index >= list.Count)
            {
                state.Index = -1;
                DrawList(ui, player, top);
                return;
            }

            var entry = list[state.Index];
            var mode = Normalize(entry.Repeat);
            var prefix = $"hotwire.ui";
            var target = $"{state.List} {state.Index}";

            var y = top - 0.08;
            const double h = 0.075, gap = 0.02;

            // Time -- stepped by buttons rather than typed. An input field is
            // one more unverified Cui component and one more way to end up
            // with "5:0" in a field that must parse.
            // Coarse and fine steps in one row, so any hour is at most four
            // clicks away instead of twelve.
            var uh = T("UnitHourShort", player.Id);
            var um = T("UnitMinuteShort", player.Id);
            Label(ui, MenuContent, 0.04, y, 0.20, y + h, T("MenuTime", player.Id), 13, ColMuted, TextAnchor.MiddleLeft);
            Button(ui, MenuContent, 0.21, y, 0.27, y + h, "-6" + uh, $"{prefix} time {target} -360", ColButton);
            Button(ui, MenuContent, 0.275, y, 0.335, y + h, "-1" + uh, $"{prefix} time {target} -60", ColButton);
            Button(ui, MenuContent, 0.34, y, 0.40, y + h, "-15" + um, $"{prefix} time {target} -15", ColButton);
            Button(ui, MenuContent, 0.405, y, 0.465, y + h, "-5" + um, $"{prefix} time {target} -5", ColButton);
            Label(ui, MenuContent, 0.47, y, 0.60, y + h, entry.Time, 17, ColText, TextAnchor.MiddleCenter);
            Button(ui, MenuContent, 0.605, y, 0.665, y + h, "+5" + um, $"{prefix} time {target} 5", ColButton);
            Button(ui, MenuContent, 0.67, y, 0.73, y + h, "+15" + um, $"{prefix} time {target} 15", ColButton);
            Button(ui, MenuContent, 0.735, y, 0.795, y + h, "+1" + uh, $"{prefix} time {target} 60", ColButton);
            Button(ui, MenuContent, 0.80, y, 0.86, y + h, "+6" + uh, $"{prefix} time {target} 360", ColButton);
            Label(ui, MenuContent, 0.87, y, 0.99, y + h, ZoneShort(DateTime.Now, player.Id), 11, ColMuted, TextAnchor.MiddleLeft);

            y -= h + gap;
            Label(ui, MenuContent, 0.04, y, 0.24, y + h, T("MenuRepeat", player.Id), 13, ColMuted,
                  TextAnchor.MiddleLeft);
            Button(ui, MenuContent, 0.25, y, 0.32, y + h, "<", $"{prefix} repeat {target} -1", ColButton);
            Label(ui, MenuContent, 0.33, y, 0.63, y + h, RepeatLabel(mode, player.Id), 14, ColText,
                  TextAnchor.MiddleCenter);
            Button(ui, MenuContent, 0.64, y, 0.71, y + h, ">", $"{prefix} repeat {target} 1", ColButton);

            y -= h + gap;

            if (mode == RepeatWeekly || mode == RepeatMonthlyWeekday)
            {
                var selected = ParsedDays(entry);
                var order = new[]
                {
                    DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday, DayOfWeek.Thursday,
                    DayOfWeek.Friday, DayOfWeek.Saturday, DayOfWeek.Sunday
                };
                Label(ui, MenuContent, 0.04, y, 0.24, y + h,
                      T(mode == RepeatWeekly ? "MenuDays" : "MenuWeekday", player.Id), 13, ColMuted,
                      TextAnchor.MiddleLeft);
                for (var i = 0; i < order.Length; i++)
                {
                    var x0 = 0.25 + i * 0.098;
                    Button(ui, MenuContent, x0, y, x0 + 0.09, y + h,
                           DayNameShort(order[i], player.Id),
                           $"{prefix} day {target} {order[i]}",
                           selected.Contains(order[i]) ? ColOn : ColButton);
                }
                y -= h + gap;
            }

            if (mode == RepeatMonthlyWeekday)
            {
                Label(ui, MenuContent, 0.04, y, 0.24, y + h, T("MenuWhich", player.Id), 13, ColMuted,
                      TextAnchor.MiddleLeft);
                for (var i = 0; i < Ordinals.Length; i++)
                {
                    var x0 = 0.25 + i * 0.138;
                    Button(ui, MenuContent, x0, y, x0 + 0.13, y + h, OrdinalWord(Ordinals[i], player.Id),
                           $"{prefix} ordinal {target} {Ordinals[i]}",
                           string.Equals(Ordinals[i], entry.Ordinal, StringComparison.OrdinalIgnoreCase)
                               ? ColOn : ColButton);
                }
                y -= h + gap;
            }

            if (mode == RepeatMonthlyDay)
            {
                var ud = T("UnitDayShort", player.Id);
                Label(ui, MenuContent, 0.04, y, 0.24, y + h, T("MenuDayOfMonth", player.Id), 13, ColMuted,
                      TextAnchor.MiddleLeft);
                Button(ui, MenuContent, 0.25, y, 0.31, y + h, "-7" + ud, $"{prefix} dom {target} -7", ColButton);
                Button(ui, MenuContent, 0.315, y, 0.375, y + h, "-1" + ud, $"{prefix} dom {target} -1", ColButton);
                Label(ui, MenuContent, 0.38, y, 0.47, y + h,
                      T("MenuDayOfMonthValue", player.Id, entry.DayOfMonth), 15, ColText, TextAnchor.MiddleCenter);
                Button(ui, MenuContent, 0.475, y, 0.535, y + h, "+1" + ud, $"{prefix} dom {target} 1", ColButton);
                Button(ui, MenuContent, 0.54, y, 0.60, y + h, "+7" + ud, $"{prefix} dom {target} 7", ColButton);
                if (entry.DayOfMonth > 28)
                    Label(ui, MenuContent, 0.62, y, 0.98, y + h,
                          T("MenuShortMonthWarning", player.Id), 11, "0.85 0.65 0.40 1.00",
                          TextAnchor.MiddleLeft);
                y -= h + gap;
            }

            if (mode == RepeatEveryNDays)
            {
                var un = T("UnitDayShort", player.Id);
                Label(ui, MenuContent, 0.04, y, 0.24, y + h, T("MenuEvery", player.Id), 13, ColMuted,
                      TextAnchor.MiddleLeft);
                Button(ui, MenuContent, 0.25, y, 0.31, y + h, "-7" + un, $"{prefix} interval {target} -7", ColButton);
                Button(ui, MenuContent, 0.315, y, 0.375, y + h, "-1" + un, $"{prefix} interval {target} -1", ColButton);
                Label(ui, MenuContent, 0.38, y, 0.50, y + h,
                      T(entry.IntervalDays == 1 ? "MenuOneDay" : "MenuNDays", player.Id, entry.IntervalDays),
                      15, ColText, TextAnchor.MiddleCenter);
                Button(ui, MenuContent, 0.505, y, 0.565, y + h, "+1" + un, $"{prefix} interval {target} 1", ColButton);
                Button(ui, MenuContent, 0.57, y, 0.63, y + h, "+7" + un, $"{prefix} interval {target} 7", ColButton);
                Label(ui, MenuContent, 0.65, y, 0.98, y + h,
                      T("MenuCountingFrom", player.Id,
                        string.IsNullOrWhiteSpace(entry.AnchorDate)
                            ? T("MenuToday", player.Id)
                            : entry.AnchorDate),
                      11, ColMuted, TextAnchor.MiddleLeft);
                y -= h + gap;
            }

            if (mode == RepeatOnce)
            {
                // Three steppers, not a day counter. The old +1m button added
                // thirty days, so stepping "a month" from the 31st landed on
                // the 2nd -- a label that lied. Month steps now move months,
                // and the day clamps to whatever the target month actually has.
                var picked = ParseDate(entry.Date) ?? DateTime.Now.Date.AddDays(1);

                var udd = T("UnitDayShort", player.Id);
                var umo = T("UnitMonthShort", player.Id);
                var uy = T("UnitYearShort", player.Id);
                Label(ui, MenuContent, 0.04, y, 0.20, y + h, T("MenuDate", player.Id), 13, ColMuted, TextAnchor.MiddleLeft);

                Button(ui, MenuContent, 0.21, y, 0.26, y + h, "-1" + udd, $"{prefix} dateday {target} -1", ColButton);
                Label(ui, MenuContent, 0.265, y, 0.335, y + h, picked.Day.ToString("00"), 16, ColText, TextAnchor.MiddleCenter);
                Button(ui, MenuContent, 0.34, y, 0.39, y + h, "+1" + udd, $"{prefix} dateday {target} 1", ColButton);

                // "mo", not "M". Capital M for month is a date-format
                // convention borrowed from strftime, and the only reason it
                // exists is that lower-case m was already taken by minutes in
                // a machine-readable string. Nothing on a button should ask
                // someone to know that. It is UnitMonthShort in lang, so a
                // translator can pick whatever two characters work for them.
                Button(ui, MenuContent, 0.42, y, 0.47, y + h, "-1" + umo, $"{prefix} datemonth {target} -1", ColButton);
                Label(ui, MenuContent, 0.475, y, 0.595, y + h,
                      picked.ToString("MMMM", CultureInfo.InvariantCulture), 15, ColText, TextAnchor.MiddleCenter);
                Button(ui, MenuContent, 0.60, y, 0.65, y + h, "+1" + umo, $"{prefix} datemonth {target} 1", ColButton);

                Button(ui, MenuContent, 0.68, y, 0.73, y + h, "-1" + uy, $"{prefix} dateyear {target} -1", ColButton);
                Label(ui, MenuContent, 0.735, y, 0.825, y + h, picked.Year.ToString(), 15, ColText, TextAnchor.MiddleCenter);
                Button(ui, MenuContent, 0.83, y, 0.88, y + h, "+1" + uy, $"{prefix} dateyear {target} 1", ColButton);

                // Its own row. Drawing it into a half-height band left the
                // next control sitting on top of it, which is how "Saturday"
                // ended up behind the Enabled button.
                y -= h + gap;
                Label(ui, MenuContent, 0.21, y, 0.98, y + h,
                      picked.ToString("dddd d MMMM yyyy", CultureInfo.InvariantCulture),
                      12, ColMuted, TextAnchor.MiddleLeft);
                y -= h + gap;
            }

            if (entry is UpdateEntry)
            {
                var update = (UpdateEntry)entry;
                Label(ui, MenuContent, 0.04, y, 0.24, y + h, T("MenuValidate", player.Id), 13, ColMuted,
                      TextAnchor.MiddleLeft);
                Button(ui, MenuContent, 0.25, y, 0.40, y + h, T(update.Validate ? "MenuOn" : "MenuOff", player.Id),
                       $"{prefix} validate {target}", update.Validate ? ColOn : ColButton);
                Label(ui, MenuContent, 0.42, y, 0.98, y + h,
                      T("MenuValidateHint", player.Id), 11, ColMuted, TextAnchor.MiddleLeft);
                y -= h + gap;
            }

            Label(ui, MenuContent, 0.04, y, 0.24, y + h, T("MenuEnabled", player.Id), 13, ColMuted,
                  TextAnchor.MiddleLeft);
            Button(ui, MenuContent, 0.25, y, 0.40, y + h, T(entry.Enabled ? "MenuOn" : "MenuOff", player.Id),
                   $"{prefix} toggle {target}", entry.Enabled ? ColOn : ColOff);

            // The answer first, in the largest text on the panel, because
            // "when does this happen" is the only question the edit view is
            // ever really asked. The rule and the exact moment go underneath
            // for when they are the question instead.
            var problem = ValidationError(entry);

            // Computed only when the entry would actually run. Showing "next:
            // tomorrow at 05:00" under a switch reading OFF is the same false
            // reassurance that let a disabled entry restart a server (ADR-0017).
            var next = problem == null && entry.Enabled ? NextOccurrence(entry, DateTime.Now) : null;

            var kind = T(entry.IsValidate ? "KindValidate"
                       : entry.IsUpdate ? "KindUpdate"
                       : "KindRestart", player.Id);
            var recurrence = Normalize(entry.Repeat) == RepeatOnce
                ? T("RecurOnceShort", player.Id)
                : DescribeRecurrence(entry, player.Id);
            var rule = Sentence(T("MenuRule", player.Id, kind, recurrence));

            string headline, detail, headlineColor;
            if (problem != null)
            {
                headline = T("MenuNotValid", player.Id);
                detail = Text(problem, player.Id);
                headlineColor = "0.85 0.45 0.40 1.00";
            }
            else if (!entry.Enabled)
            {
                var would = NextOccurrence(entry, DateTime.Now);
                headline = T("MenuDisabled", player.Id);
                detail = would == null
                    ? T("MenuNoOccurrence", player.Id, rule)
                    : T("MenuWouldRun", player.Id, rule, Friendly(would.Value, player.Id),
                        would.Value.ToString("dddd d MMMM yyyy 'at' HH:mm", CultureInfo.InvariantCulture));
                headlineColor = "0.85 0.65 0.40 1.00";
            }
            else if (next == null)
            {
                headline = T("MenuNeverRuns", player.Id);
                detail = T("MenuNoOccurrence", player.Id, rule);
                headlineColor = "0.85 0.65 0.40 1.00";
            }
            else
            {
                headline = Sentence(Friendly(next.Value, player.Id));
                detail = T("MenuNextDetail", player.Id, rule,
                           next.Value.ToString("dddd d MMMM yyyy 'at' HH:mm", CultureInfo.InvariantCulture),
                           ZoneSuffix(next.Value, player.Id));
                if (OffsetChangesBetween(DateTime.Now, next.Value))
                    detail += "  " + T("ClocksChange", player.Id);
                headlineColor = ColText;
            }

            // Sits under the fields rather than pinned to the bottom of the
            // panel, so the form and its result read as one thing instead of
            // being separated by half a screen of nothing. Floored so it can
            // never reach the buttons on a form with every row showing.
            y -= h + gap;
            var summaryTop = y + h;
            var summaryBottom = summaryTop - 0.12;
            if (summaryBottom < 0.12)
            {
                summaryBottom = 0.12;
                summaryTop = 0.24;
            }

            ui.Add(new CuiPanel
            {
                Image = { Color = ColRow },
                RectTransform = { AnchorMin = Anchor(0.02, summaryBottom), AnchorMax = Anchor(0.98, summaryTop) }
            }, MenuContent, MenuContent + ".summary");

            Label(ui, MenuContent + ".summary", 0.02, 0.44, 0.98, 0.94, headline, 18,
                  headlineColor, TextAnchor.MiddleLeft);
            Label(ui, MenuContent + ".summary", 0.02, 0.08, 0.98, 0.44, detail, 11,
                  ColMuted, TextAnchor.MiddleLeft);

            Button(ui, MenuContent, 0.02, 0.02, 0.20, 0.09, T("MenuBack", player.Id),
                   "hotwire.ui list", ColButton);
            Button(ui, MenuContent, 0.80, 0.02, 0.98, 0.09, T("MenuDelete", player.Id),
                   $"{prefix} delete {target}", ColDanger);
        }

        private string RepeatLabel(string mode, string user)
        {
            foreach (var known in RepeatModes)
                if (known == mode) return T("Mode" + known, user);
            return mode;
        }

        private static void Label(CuiElementContainer ui, string parent, double x0, double y0, double x1,
                                  double y1, string text, int size, string color, TextAnchor align)
        {
            ui.Add(new CuiLabel
            {
                Text = { Text = text ?? "", FontSize = size, Color = color, Align = align },
                RectTransform = { AnchorMin = Anchor(x0, y0), AnchorMax = Anchor(x1, y1) }
            }, parent);
        }

        private static void Button(CuiElementContainer ui, string parent, double x0, double y0, double x1,
                                   double y1, string text, string command, string color)
        {
            ui.Add(new CuiButton
            {
                Button = { Command = command, Color = color },
                RectTransform = { AnchorMin = Anchor(x0, y0), AnchorMax = Anchor(x1, y1) },
                Text = { Text = text, FontSize = 12, Color = ColText, Align = TextAnchor.MiddleCenter }
            }, parent);
        }

        // Every button in the panel comes back through here. The menu holds no
        // draft state: each click edits the entry and saves, then redraws. That
        // is fewer moving parts than a save/cancel model, and it cannot lose an
        // edit when someone disconnects mid-change. New entries start disabled,
        // so a half-configured one cannot fire.
        private void CmdMenuAction(IPlayer player, string command, string[] args)
        {
            if (player == null || player.IsServer) return;
            if (args.Length == 0) return;

            var action = args[0].ToLowerInvariant();

            if (action == "close") { CloseMenu(player); return; }

            if (!_menus.ContainsKey(player.Id)) return;

            if (action == "cancelcountdown")
            {
                if (!Allowed(player, PermCancel)) return;
                if (_shuttingDown) Reply(player, "TooLateToCancel");
                else if (!_countdownActive) Reply(player, "NoCountdownRunning");
                else CancelCountdown(player.Name);
                DrawMenu(player);
                return;
            }

            if (action == "list")
            {
                _menus[player.Id].Index = -1;
                DrawMenu(player);
                return;
            }

            if (action == "add")
            {
                if (!Allowed(player, PermEdit)) return;
                if (args.Length < 2) return;
                var which = args[1].ToLowerInvariant();
                if (which == "restart")
                {
                    _config.Restarts.Add(new ScheduleEntry { Enabled = false });
                    _menus[player.Id].List = "restart";
                    _menus[player.Id].Index = _config.Restarts.Count - 1;
                }
                else
                {
                    _config.Updates.Add(new UpdateEntry { Enabled = false });
                    _menus[player.Id].List = "update";
                    _menus[player.Id].Index = _config.Updates.Count - 1;
                }
                SaveConfig();
                DrawMenu(player);
                return;
            }

            if (args.Length < 3) return;
            var listName = args[1].ToLowerInvariant();
            var list = ListFor(listName);
            int index;
            if (list == null || !int.TryParse(args[2], out index) || index < 0 || index >= list.Count) return;

            if (action == "edit")
            {
                _menus[player.Id].List = listName;
                _menus[player.Id].Index = index;
                DrawMenu(player);
                return;
            }

            if (!Allowed(player, PermEdit)) return;
            var entry = list[index];

            // Captured before the switch: "delete" removes the entry from the
            // list, and "toggle" is the case that started all this.
            var wasCountingDownForThis = _countdownActive && !_shuttingDown &&
                                         _countdownEntry != null && ReferenceEquals(_countdownEntry, entry);

            switch (action)
            {
                case "toggle":
                    if (!entry.Enabled)
                    {
                        var problem = ValidationError(entry);
                        if (problem != null)
                        {
                            Reply(player, "CannotEnable", Text(problem, player.Id));
                            return;
                        }
                    }
                    entry.Enabled = !entry.Enabled;
                    break;

                case "delete":
                    Puts($"{player.Name} deleted {listName} {index} ({Describe(entry, null)}) from the menu.");
                    list.RemoveAt(index);
                    _menus[player.Id].Index = -1;
                    break;

                case "time":
                {
                    int delta;
                    if (args.Length < 4 || !int.TryParse(args[3], out delta)) return;
                    var current = ParseTime(entry.Time) ?? TimeSpan.Zero;
                    var minutes = ((int)current.TotalMinutes + delta) % (24 * 60);
                    if (minutes < 0) minutes += 24 * 60;
                    entry.Time = $"{minutes / 60:00}:{minutes % 60:00}";
                    break;
                }

                case "repeat":
                {
                    int step;
                    if (args.Length < 4 || !int.TryParse(args[3], out step)) return;
                    var at = Array.IndexOf(RepeatModes, Normalize(entry.Repeat));
                    if (at < 0) at = 0;
                    at = (at + step + RepeatModes.Length) % RepeatModes.Length;
                    entry.Repeat = RepeatModes[at];

                    // Give the new mode something usable rather than leaving it
                    // invalid and making the admin hunt for what is missing.
                    if ((entry.Repeat == RepeatWeekly || entry.Repeat == RepeatMonthlyWeekday) &&
                        ParsedDays(entry).Count == 0)
                        entry.Days = new List<string> { DateTime.Now.DayOfWeek.ToString() };
                    if (entry.Repeat == RepeatMonthlyWeekday && ParsedDays(entry).Count > 1)
                        entry.Days = new List<string> { entry.Days[0] };
                    if (entry.Repeat == RepeatEveryNDays && ParseDate(entry.AnchorDate) == null)
                        entry.AnchorDate = DateTime.Now.ToString("yyyy-MM-dd");
                    if (entry.Repeat == RepeatOnce && ParseDate(entry.Date) == null)
                        entry.Date = DateTime.Now.AddDays(1).ToString("yyyy-MM-dd");
                    break;
                }

                case "day":
                {
                    if (args.Length < 4) return;
                    var day = ParseDay(args[3]);
                    if (day == null) return;
                    var name = day.Value.ToString();
                    if (entry.Days == null) entry.Days = new List<string>();

                    if (Normalize(entry.Repeat) == RepeatMonthlyWeekday)
                    {
                        // An ordinal applies to exactly one weekday. "The first
                        // Monday and Thursday" is two rules, not one.
                        entry.Days = new List<string> { name };
                    }
                    else if (ParsedDays(entry).Contains(day.Value))
                    {
                        entry.Days = entry.Days.Where(d => ParseDay(d) != day.Value).ToList();
                    }
                    else
                    {
                        entry.Days.Add(name);
                    }
                    break;
                }

                case "ordinal":
                    if (args.Length < 4) return;
                    foreach (var o in Ordinals)
                        if (string.Equals(o, args[3], StringComparison.OrdinalIgnoreCase)) entry.Ordinal = o;
                    break;

                case "dom":
                {
                    int delta;
                    if (args.Length < 4 || !int.TryParse(args[3], out delta)) return;
                    entry.DayOfMonth = Math.Max(1, Math.Min(31, entry.DayOfMonth + delta));
                    break;
                }

                case "interval":
                {
                    int delta;
                    if (args.Length < 4 || !int.TryParse(args[3], out delta)) return;
                    entry.IntervalDays = Math.Max(1, Math.Min(365, entry.IntervalDays + delta));
                    break;
                }

                case "dateday":
                case "datemonth":
                case "dateyear":
                {
                    int delta;
                    if (args.Length < 4 || !int.TryParse(args[3], out delta)) return;
                    var current = ParseDate(entry.Date) ?? DateTime.Now.Date.AddDays(1);

                    DateTime moved;
                    if (action == "dateday")
                    {
                        moved = current.AddDays(delta);
                    }
                    else
                    {
                        // Move the month or the year, then clamp the day to
                        // what that month actually has. 31 January stepped a
                        // month forward is 28 February, not 3 March.
                        var shifted = action == "datemonth"
                            ? current.AddMonths(delta)
                            : current.AddYears(delta);
                        var days = DateTime.DaysInMonth(shifted.Year, shifted.Month);
                        moved = new DateTime(shifted.Year, shifted.Month, Math.Min(current.Day, days));
                    }

                    // A one-off in the past would never fire and would sit
                    // there looking scheduled.
                    if (moved < DateTime.Now.Date) moved = DateTime.Now.Date;
                    entry.Date = moved.ToString("yyyy-MM-dd");
                    break;
                }

                case "validate":
                {
                    var update = entry as UpdateEntry;
                    if (update == null) return;
                    update.Validate = !update.Validate;
                    break;
                }

                default:
                    return;
            }

            // Anything that made a live entry invalid switches it off rather
            // than being left to fail at three in the morning.
            if (entry.Enabled && ValidationError(entry) != null)
            {
                entry.Enabled = false;
                Reply(player, "EditMadeInvalid");
            }

            // The entry a live countdown came from was just disabled, deleted
            // or rescheduled. Stop the countdown; anything else lets a restart
            // arrive that the admin believes they called off.
            if (wasCountingDownForThis && (action != "toggle" || !entry.Enabled))
            {
                CancelCountdown(player.Name);
                Reply(player, "CountdownCanceledToo");
            }

            SaveConfig();
            DrawMenu(player);
        }

        #endregion

        #region Commands

        // ADR-0006: these are written first and must do everything an admin
        // menu would. A broken CUI panel must never mean a schedule cannot be
        // changed, so the panel -- when it exists -- will be a second way in,
        // never the only one.
        private void CmdHotwire(IPlayer player, string command, string[] args)
        {
            var sub = args.Length > 0 ? args[0].ToLowerInvariant() : "status";

            switch (sub)
            {
                case "status": CmdStatus(player); return;
                case "menu": CmdMenu(player); return;   // ADR-0016: goes with the menu
                case "check": CmdCheck(player); return;
                case "list": CmdList(player); return;
                case "now": CmdNow(player, args); return;
                case "cancel": CmdCancel(player); return;
                case "add": CmdAdd(player, args); return;
                case "set": case "edit": CmdSet(player, args); return;
                case "remove": case "delete": CmdRemove(player, args); return;
                case "enable": CmdToggle(player, args, true); return;
                case "disable": CmdToggle(player, args, false); return;
                default: Reply(player, "Usage"); return;
            }
        }

        private void CmdStatus(IPlayer player)
        {
            if (!Allowed(player, PermStatus)) return;

            if (_countdownActive)
            {
                Reply(player, "StatusCounting", KindWord(player.Id), FormatRemaining(RemainingSeconds()));
                return;
            }

            var next = DescribeNext(player.Id);
            if (next == null) Reply(player, "StatusNone");
            else Reply(player, "StatusNext", next);
        }

        private string DescribeNext(string user)
        {
            var now = DateTime.Now;
            ScheduleEntry best = null;
            DateTime bestTarget = DateTime.MaxValue;

            foreach (var e in AllEntries())
            {
                if (!e.Enabled) continue;
                var next = NextOccurrence(e, now);
                if (next == null) continue;
                if (next.Value < bestTarget || (next.Value == bestTarget && Rank(e) > Rank(best)))
                {
                    best = e;
                    bestTarget = next.Value;
                }
            }

            if (_oneShotTarget != null && _oneShotTarget.Value < bestTarget)
            {
                var word = T(_oneShotValidate ? "KindValidateShort" : "KindUpdateShort", user);
                return T("NextOneShot", user, word, Stamp(_oneShotTarget.Value, user),
                         T("ReasonFramework", user, _oneShotReason));
            }

            if (best == null) return null;
            var kind = T(best.IsValidate ? "KindValidate" : best.IsUpdate ? "KindUpdate" : "KindRestart", user);
            return T("NextEntry", user, kind, DescribeRecurrence(best, user), Stamp(bestTarget, user));
        }

        // Answers the questions you would otherwise have to spend a real
        // restart to answer: where the flag will be written, whether that is
        // actually the server root, and whether a flag is sitting there
        // already. Read-only apart from a write probe it cleans up.
        //
        // Deliberately not lang strings. This is a diagnostic dump for an
        // admin console, not something a player ever sees, and twenty
        // untranslated keys would make the lang file worse for no gain.
        private void CmdCheck(IPlayer player)
        {
            if (!Allowed(player, PermStatus)) return;

            var lines = new List<string> { $"Hotwire {Version} check" };

            var fromConfig = !string.IsNullOrWhiteSpace(_config.General.ServerRoot);
            var root = ServerRoot();

            if (root == null)
            {
                lines.Add("  server root  : CANNOT BE DETERMINED");
                lines.Add("                 Updates cannot be written. Restarts still work.");
                lines.Add("                 Set \"Server root\" in the config to fix it.");
            }
            else
            {
                lines.Add($"  server root  : {root}");
                lines.Add($"                 (from {(fromConfig ? "the config" : "Oxide")})");

                var exists = Directory.Exists(root);
                lines.Add($"  exists       : {(exists ? "yes" : "NO -- nothing will be written there")}");

                // The real question. A directory that exists is not
                // necessarily the directory the launcher watches; one holding
                // RustDedicated is.
                var looksRight = false;
                if (exists)
                {
                    try
                    {
                        looksRight = File.Exists(Path.Combine(root, "RustDedicated.exe"))
                                     || File.Exists(Path.Combine(root, "RustDedicated"))
                                     || Directory.Exists(Path.Combine(root, "RustDedicated_Data"));
                    }
                    catch (Exception ex)
                    {
                        lines.Add($"  (could not inspect it: {ex.Message})");
                    }
                }
                lines.Add($"  is the root  : {(looksRight ? "yes -- RustDedicated found here" : "UNCONFIRMED -- no RustDedicated here")}");
                if (exists && !looksRight)
                    lines.Add("                 This is probably not where your launcher looks.");

                if (exists)
                {
                    string writable;
                    try
                    {
                        var probe = Path.Combine(root, ".hotwire_write_probe");
                        File.WriteAllText(probe, "");
                        File.Delete(probe);
                        writable = "yes";
                    }
                    catch (Exception ex)
                    {
                        writable = $"NO -- {ex.Message}";
                    }
                    lines.Add($"  writable     : {writable}");
                }

                var updatePath = SafeCombine(root, _config.General.UpdateFlag);
                var validatePath = SafeCombine(root, _config.General.ValidateFlag);
                lines.Add($"  update flag  : {updatePath ?? "(no file name set)"}");
                lines.Add($"  validate flag: {validatePath ?? "(no file name set)"}");

                // A flag left lying about means the NEXT restart updates,
                // whether or not anyone meant it to. Worth shouting about.
                try
                {
                    if (updatePath != null && File.Exists(updatePath))
                        lines.Add("  !! UPDATE.flag is present RIGHT NOW. The next restart will update.");
                    if (validatePath != null && File.Exists(validatePath))
                        lines.Add("  !! VALIDATE.flag is present RIGHT NOW. The next restart will validate.");
                }
                catch (Exception ex)
                {
                    lines.Add($"  (could not check for existing flags: {ex.Message})");
                }
            }

            lines.Add($"  clock        : {Stamp(DateTime.Now, player.Id)}");
            try
            {
                if (!TimeZoneInfo.Local.SupportsDaylightSavingTime)
                    lines.Add("                 this zone has no DST, so the guard below rarely matters");
            }
            catch { /* reported as "server local time" above */ }

            var enabled = AllEntries().Count(e => e.Enabled);
            var total = _config.Restarts.Count + _config.Updates.Count;
            lines.Add($"  schedule     : {enabled} enabled of {total}");
            var next = DescribeNext(player.Id);
            lines.Add($"  next         : {next ?? "nothing scheduled"}");
            lines.Add($"  countdown    : starts {_config.Countdown.StartSeconds}s before, " +
                      $"{_config.Countdown.AnnounceAt.Count} announcements");

            // Whether one is running RIGHT NOW, which is the first thing to
            // establish when the status bar has not appeared: no countdown
            // means no bar, and that is the schedule's problem, not the bar's.
            if (_shuttingDown)
                lines.Add("                 SHUTTING DOWN now");
            else if (_countdownActive)
                lines.Add($"                 RUNNING NOW: {KindWord(null)} in {FormatRemaining(RemainingSeconds())}");
            else
                lines.Add("                 not running");
            lines.Add($"  DST guard    : {_config.General.MinimumHoursBetweenSameEntry}h " +
                      $"({_lastFired.Count} entr{(_lastFired.Count == 1 ? "y" : "ies")} on record)");

            string status;
            if (AdvancedStatus == null) status = "not installed -- chat only";
            else if (!_config.StatusBar.Enabled) status = "installed, disabled in config -- chat only";
            else if (_statusDisabled) status = "installed, DISABLED for this session after an error";
            else status = StatusAvailable() ? "installed and ready" : "installed, not ready yet";
            lines.Add($"  status bar   : {status}");

            if (_config.Framework.Enabled)
                lines.Add($"  framework    : checking every {_config.Framework.CheckIntervalMinutes}m, " +
                          $"installed {InstalledFrameworkVersion() ?? "unknown"}, would update at {_config.Framework.UpdateAt}");
            else
                lines.Add("  framework    : checks off");

            player.Reply(string.Join("\n", lines.ToArray()));
        }

        private static string SafeCombine(string root, string name)
        {
            if (string.IsNullOrWhiteSpace(name)) return null;
            try { return Path.Combine(root, name); }
            catch { return null; }
        }

        private void CmdList(IPlayer player)
        {
            if (!Allowed(player, PermStatus)) return;

            var lines = new List<string>();
            for (var i = 0; i < _config.Restarts.Count; i++)
                lines.Add(DescribeRow("restart", i, _config.Restarts[i], player.Id));
            for (var i = 0; i < _config.Updates.Count; i++)
                lines.Add(DescribeRow("update", i, _config.Updates[i], player.Id));

            if (lines.Count == 0)
            {
                Reply(player, "ListEmpty");
                return;
            }
            player.Reply(Prefix() + string.Join("\n", lines.ToArray()));
        }

        private string DescribeRow(string list, int index, ScheduleEntry e, string user)
        {
            var state = T(e.Enabled ? "StateEnabled" : "StateDisabled", user);
            var problem = ValidationError(e);
            var next = e.Enabled && problem == null ? NextOccurrence(e, DateTime.Now) : null;

            var row = $"{list} {index}: {Describe(e, user)} [{state}]";
            if (problem != null) return row + " -- " + T("MenuBroken", user, Text(problem, user));
            if (next != null)
            {
                row += $" -- next {Stamp(next.Value, user)}";
                if (OffsetChangesBetween(DateTime.Now, next.Value))
                    row += " (" + T("MenuClocksChangeShort", user) + ")";
            }
            return row;
        }

        // hotwire set <restart|update> <index> <time|pattern|validate> <value...>
        //
        // "pattern" takes the same words as add, so anything you can create you
        // can change without deleting and retyping it.
        private void CmdSet(IPlayer player, string[] args)
        {
            if (!Allowed(player, PermEdit)) return;
            if (args.Length < 5) { Reply(player, "UsageSet"); return; }

            var list = ListFor(args[1]);
            if (list == null) { Reply(player, "UsageSet"); return; }
            if (!int.TryParse(args[2], out var index) || index < 0 || index >= list.Count)
            {
                Reply(player, "BadIndex", args[2]);
                return;
            }

            var entry = list[index];
            var field = args[3].ToLowerInvariant();
            var rest = args.Skip(4).ToArray();

            switch (field)
            {
                case "time":
                    if (ParseTime(rest[0]) == null) { Reply(player, "BadTime", rest[0]); return; }
                    entry.Time = rest[0].Trim();
                    break;

                case "pattern":
                case "repeat":
                case "days":
                {
                    // Work on a copy: a half-applied pattern would leave the
                    // entry in a state nobody asked for.
                    var draft = CopyOf(entry);
                    var problem = ApplyPattern(draft, rest);
                    if (problem != null) { Reply(player, "Raw", Text(problem, player.Id)); return; }
                    entry.Repeat = draft.Repeat;
                    entry.Days = draft.Days;
                    entry.Ordinal = draft.Ordinal;
                    entry.DayOfMonth = draft.DayOfMonth;
                    entry.IntervalDays = draft.IntervalDays;
                    entry.AnchorDate = draft.AnchorDate;
                    entry.Date = draft.Date;
                    break;
                }

                case "validate":
                {
                    var update = entry as UpdateEntry;
                    if (update == null) { Reply(player, "ValidateNotOnRestart"); return; }
                    update.Validate = rest[0].Equals("true", StringComparison.OrdinalIgnoreCase)
                                      || rest[0] == "1";
                    break;
                }

                default:
                    Reply(player, "UsageSet");
                    return;
            }

            var rescheduled = CancelCountdownFor(entry, player.Name);
            if (rescheduled) Reply(player, "CountdownCanceledToo");

            var stillBroken = ValidationError(entry);
            if (stillBroken != null)
            {
                entry.Enabled = false;
                Reply(player, "SavedButInvalid", Text(stillBroken, player.Id));
            }
            else
            {
                Reply(player, "Raw", DescribeRow(args[1].ToLowerInvariant(), index, entry, player.Id));
            }

            SaveConfig();
            Puts($"{player.Name} edited {args[1]} {index}: {Describe(entry, null)}");
        }

        private static ScheduleEntry CopyOf(ScheduleEntry e)
        {
            return new ScheduleEntry
            {
                Time = e.Time,
                Repeat = e.Repeat,
                Days = e.Days == null ? new List<string>() : new List<string>(e.Days),
                Ordinal = e.Ordinal,
                DayOfMonth = e.DayOfMonth,
                IntervalDays = e.IntervalDays,
                AnchorDate = e.AnchorDate,
                Date = e.Date,
                Enabled = e.Enabled
            };
        }

        private void CmdNow(IPlayer player, string[] args)
        {
            if (!Allowed(player, PermRestart)) return;
            if (_shuttingDown) { Reply(player, "AlreadyShuttingDown"); return; }
            if (_countdownActive) { Reply(player, "AlreadyCounting"); return; }

            var isUpdate = false;
            var isValidate = false;
            var seconds = _config.Countdown.StartSeconds;

            for (var i = 1; i < args.Length; i++)
            {
                var a = args[i].ToLowerInvariant();
                if (a == "update") { isUpdate = true; continue; }
                if (a == "validate") { isUpdate = true; isValidate = true; continue; }
                if (int.TryParse(a, out var s) && s > 0) { seconds = s; continue; }
                Reply(player, "UsageNow");
                return;
            }

            // A manual countdown carries no key, so the fired-recently guard
            // does not apply to it and does not learn from it. An admin asking
            // for a restart means it.
            BeginCountdown(DateTime.Now.AddSeconds(seconds), isUpdate, isValidate, null, "");
            Puts($"Manual {KindWord(null)} started by {player.Name} ({seconds}s).");
        }

        private void CmdCancel(IPlayer player)
        {
            if (!Allowed(player, PermCancel)) return;
            if (_shuttingDown) { Reply(player, "TooLateToCancel"); return; }
            if (!_countdownActive) { Reply(player, "NothingToCancel"); return; }
            CancelCountdown(player.Name);
        }

        private void CmdAdd(IPlayer player, string[] args)
        {
            if (!Allowed(player, PermEdit)) return;

            // hotwire add <restart|update|validate> <HH:mm> [days]
            if (args.Length < 3) { Reply(player, "UsageAdd"); return; }

            var kind = args[1].ToLowerInvariant();
            if (kind != "restart" && kind != "update" && kind != "validate") { Reply(player, "UsageAdd"); return; }

            var time = args[2];
            if (ParseTime(time) == null) { Reply(player, "BadTime", time); return; }

            ScheduleEntry entry = kind == "restart"
                ? new ScheduleEntry()
                : new UpdateEntry { Validate = kind == "validate" };
            entry.Time = time;
            entry.Enabled = true;

            var problem = ApplyPattern(entry, args.Skip(3).ToArray());
            if (problem != null) { Reply(player, "Raw", Text(problem, player.Id)); return; }

            problem = ValidationError(entry);
            if (problem != null) { Reply(player, "Raw", Text(problem, player.Id)); return; }

            var listName = kind == "restart" ? "restart" : "update";
            if (kind == "restart") _config.Restarts.Add(entry);
            else _config.Updates.Add((UpdateEntry)entry);

            var index = (kind == "restart" ? _config.Restarts.Count : _config.Updates.Count) - 1;
            SaveConfig();
            Reply(player, "Added", DescribeRow(listName, index, entry, player.Id));
            Puts($"{player.Name} added {Describe(entry, null)}.");
        }

        private void CmdRemove(IPlayer player, string[] args)
        {
            if (!Allowed(player, PermEdit)) return;
            if (args.Length < 3) { Reply(player, "UsageRemove"); return; }

            var list = ListFor(args[1]);
            if (list == null) { Reply(player, "UsageRemove"); return; }
            if (!int.TryParse(args[2], out var index) || index < 0 || index >= list.Count)
            {
                Reply(player, "BadIndex", args[2]);
                return;
            }

            var removed = list[index];
            var stopped = CancelCountdownFor(removed, player.Name);
            list.RemoveAt(index);
            SaveConfig();
            if (stopped) Reply(player, "CountdownCanceledToo");
            Reply(player, "Removed", Describe(removed, player.Id));
            Puts($"{player.Name} removed {args[1]} {index} ({Describe(removed, null)}).");
        }

        private void CmdToggle(IPlayer player, string[] args, bool enable)
        {
            if (!Allowed(player, PermEdit)) return;
            if (args.Length < 3) { Reply(player, "UsageToggle"); return; }

            var list = ListFor(args[1]);
            if (list == null) { Reply(player, "UsageToggle"); return; }
            if (!int.TryParse(args[2], out var index) || index < 0 || index >= list.Count)
            {
                Reply(player, "BadIndex", args[2]);
                return;
            }

            var stopped = !enable && CancelCountdownFor(list[index], player.Name);
            list[index].Enabled = enable;
            if (enable) ValidateSchedule();
            SaveConfig();
            if (stopped) Reply(player, "CountdownCanceledToo");
            Reply(player, enable ? "Enabled" : "Disabled", args[1].ToLowerInvariant(), index.ToString());
            Puts($"{player.Name} {(enable ? "enabled" : "disabled")} {args[1]} {index}.");
        }

        private IList<ScheduleEntry> ListFor(string word)
        {
            switch (word.ToLowerInvariant())
            {
                case "restart": case "restarts": return _config.Restarts;
                case "update": case "updates": return new UpdateListView(_config.Updates);
                default: return null;
            }
        }

        // A thin view so the edit commands can treat both lists the same way
        // without copying entries and silently editing the copy.
        private class UpdateListView : IList<ScheduleEntry>
        {
            private readonly List<UpdateEntry> _inner;
            public UpdateListView(List<UpdateEntry> inner) { _inner = inner; }

            public ScheduleEntry this[int index]
            {
                get => _inner[index];
                set => _inner[index] = (UpdateEntry)value;
            }
            public int Count => _inner.Count;
            public bool IsReadOnly => false;
            public void Add(ScheduleEntry item) => _inner.Add((UpdateEntry)item);
            public void Clear() => _inner.Clear();
            public bool Contains(ScheduleEntry item) => _inner.Contains(item as UpdateEntry);
            public void CopyTo(ScheduleEntry[] array, int arrayIndex)
            {
                for (var i = 0; i < _inner.Count; i++) array[arrayIndex + i] = _inner[i];
            }
            public IEnumerator<ScheduleEntry> GetEnumerator()
            {
                foreach (var e in _inner) yield return e;
            }
            System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
            public int IndexOf(ScheduleEntry item) => _inner.IndexOf(item as UpdateEntry);
            public void Insert(int index, ScheduleEntry item) => _inner.Insert(index, (UpdateEntry)item);
            public bool Remove(ScheduleEntry item) => _inner.Remove(item as UpdateEntry);
            public void RemoveAt(int index) => _inner.RemoveAt(index);
        }

        private bool Allowed(IPlayer player, string perm)
        {
            if (player.IsServer) return true;
            if (permission.UserHasPermission(player.Id, perm)) return true;
            Reply(player, "NoPermission", perm);
            return false;
        }

        private string Prefix()
        {
            var name = _config.General.AnnouncementName;
            if (string.IsNullOrWhiteSpace(name)) return "";
            var color = _config.General.AnnouncementColor;
            return string.IsNullOrWhiteSpace(color)
                ? name.Trim() + ": "
                : $"<color={color.Trim()}>{name.Trim()}</color>: ";
        }

        // Lang files are written once and never rewritten, so correcting a
        // default string does nothing for a server that already has the old
        // one. Sentences are capitalized here instead, where the fix reaches
        // everybody -- and where a translator is free to write lower case and
        // still get a sentence.
        private static string Sentence(string text)
        {
            if (string.IsNullOrEmpty(text)) return text;
            return char.ToUpper(text[0]) + text.Substring(1);
        }

        private void Reply(IPlayer player, string key, params string[] args)
        {
            var msg = lang.GetMessage(key, this, player.Id);
            player.Reply(Prefix() + Sentence(args.Length == 0 ? msg : string.Format(msg, args)));
        }

        private void Broadcast(string key, params string[] args)
        {
            foreach (var p in players.Connected.ToArray())
            {
                if (p == null || !p.IsConnected) continue;
                var msg = lang.GetMessage(key, this, p.Id);
                p.Message(Prefix() + Sentence(args.Length == 0 ? msg : string.Format(msg, args)));
            }
        }

        // For messages whose ARGUMENTS are themselves translated, not just the
        // template around them: the factory runs once per recipient, so a
        // player reading German gets the German kind word inside the German
        // sentence rather than the server's.
        private void Broadcast(string key, Func<string, object[]> args)
        {
            foreach (var p in players.Connected.ToArray())
            {
                if (p == null || !p.IsConnected) continue;
                var msg = lang.GetMessage(key, this, p.Id);
                p.Message(Prefix() + Sentence(string.Format(msg, args(p.Id))));
            }
        }

        #endregion

        #region Messages

        // Every string a player can see lives here, including the words the
        // schedule descriptions are assembled from. Sentences take their parts
        // as {0}-style arguments rather than being concatenated in code, so a
        // translator can put the ordinal after the weekday, or the time before
        // the day, without touching the plugin.
        //
        // Deliberately absent: the "hotwire check" diagnostic dump. It is a
        // console tool for whoever runs the server, never seen in game, and
        // forty untranslated column-aligned fragments would make this file
        // worse for nobody's benefit.
        protected override void LoadDefaultMessages()
        {
            lang.RegisterMessages(new Dictionary<string, string>
            {
                // The bar is a glance surface: players need to know the server
                // is going down, not which flavor of going down it is. The
                // chat announcements carry that distinction.
                ["BarLabel"] = "Server Restart",

                ["KindRestart"] = "restart",
                ["KindUpdate"] = "update and restart",
                ["KindValidate"] = "validate and restart",
                // Without the "and restart", for lines that already say it.
                ["KindUpdateShort"] = "update",
                ["KindValidateShort"] = "validate",
                ["ReasonFramework"] = "framework {0}",

                ["CountdownStart"] = "Scheduled {0} in {1}. The server will save before it goes down.",
                ["CountdownTick"] = "Server {0} in {1}.",
                ["Now"] = "{0} now. See you in a few minutes.",
                ["Canceled"] = "The scheduled restart has been canceled.",
                ["CountdownCanceledToo"] = "That entry had a countdown running. It has been canceled too.",
                ["NoCountdownRunning"] = "Nothing is counting down.",
                ["KickReason"] = "Scheduled restart. Back shortly.",

                ["FrameworkFound"] = "A new framework release is available. An update is scheduled for {0}.",

                ["StatusCounting"] = "Counting down: {0} in {1}.",
                ["StatusNext"] = "Next: {0}.",
                ["StatusNone"] = "Nothing is scheduled. No entry is enabled.",
                ["ListEmpty"] = "The schedule is empty.",

                ["NoPermission"] = "You need the permission {0}.",
                ["AlreadyCounting"] = "A countdown is already running. Cancel it first.",
                ["AlreadyShuttingDown"] = "The server is already shutting down.",
                ["NothingToCancel"] = "Nothing is counting down.",
                ["TooLateToCancel"] = "Too late -- players have already been kicked.",
                ["BadTime"] = "\"{0}\" is not a valid time. Use HH:mm, such as 05:00.",
                ["BadIndex"] = "\"{0}\" is not a valid index. Run: hotwire list",
                ["Raw"] = "{0}",
                ["Enabled"] = "Enabled {0} {1}.",
                ["Disabled"] = "Disabled {0} {1}.",
                ["Added"] = "Added: {0}",
                ["Removed"] = "Removed: {0}",
                ["CannotEnable"] = "Cannot enable: {0}",
                ["EditMadeInvalid"] = "That change made the entry invalid, so it has been disabled.",
                ["SavedButInvalid"] = "Saved, but the entry is now invalid and has been disabled: {0}",

                ["ValidateNotOnRestart"] = "Only an update entry can validate. Remove it and add it as an update.",
                ["MenuNeedsPlayer"] = "The menu only opens in game. Use the chat commands from the console.",

                // -- Time and zone ----------------------------------------
                // {0} is the zone name, {1} the offset as +HH:mm or -HH:mm.
                ["Zone"] = "{0} (UTC{1})",
                ["ZoneDst"] = "{0} (UTC{1}, DST)",
                ["ZoneUnknown"] = "server local time",
                ["ZoneShort"] = "UTC{0}",
                ["ZoneShortDst"] = "UTC{0} DST",
                ["ZoneShortUnknown"] = "local",

                // {0} is the date and time, {1} the zone from the keys above.
                ["Stamp"] = "{0} {1}",

                ["WhenNow"] = "now",
                ["WhenUnderMinute"] = "in under a minute",
                ["WhenInMinute"] = "in {0} minute",
                ["WhenInMinutes"] = "in {0} minutes",
                ["WhenToday"] = "today at {0}",
                ["WhenTomorrow"] = "tomorrow at {0}",
                ["WhenAt"] = "{0} at {1}",

                // -- Weekdays ---------------------------------------------
                // Not taken from DayOfWeek.ToString(), which is English on
                // every server regardless of its culture.
                ["DayMonday"] = "Monday",
                ["DayTuesday"] = "Tuesday",
                ["DayWednesday"] = "Wednesday",
                ["DayThursday"] = "Thursday",
                ["DayFriday"] = "Friday",
                ["DaySaturday"] = "Saturday",
                ["DaySunday"] = "Sunday",

                // Three or four characters. These sit on seven buttons across
                // one panel row, so length is a layout constraint, not taste.
                ["DayShortMonday"] = "Mon",
                ["DayShortTuesday"] = "Tue",
                ["DayShortWednesday"] = "Wed",
                ["DayShortThursday"] = "Thu",
                ["DayShortFriday"] = "Fri",
                ["DayShortSaturday"] = "Sat",
                ["DayShortSunday"] = "Sun",

                ["OrdinalFirst"] = "first",
                ["OrdinalSecond"] = "second",
                ["OrdinalThird"] = "third",
                ["OrdinalFourth"] = "fourth",
                ["OrdinalLast"] = "last",

                // -- Describing an entry ----------------------------------
                // {0} kind, {1} recurrence, {2} the time as HH:mm.
                ["EntryDescription"] = "{0} {1} at {2}",
                ["RecurDaily"] = "daily",
                ["RecurWeekly"] = "every {0}",
                // {0} is the ordinal word, {1} the weekday.
                ["RecurMonthlyWeekday"] = "on the {0} {1} of the month",
                ["RecurMonthlyDay"] = "on day {0} of the month",
                ["RecurEveryNDays"] = "every {0} days",
                ["RecurOnce"] = "once on {0}",
                ["RecurOnceShort"] = "once",
                ["DayListEmpty"] = "no days",

                // {0} kind, {1} recurrence, {2} the next occurrence.
                ["NextEntry"] = "{0} {1} -- next {2}",
                // {0} kind, {1} the moment, {2} why it was scheduled.
                ["NextOneShot"] = "{0} once -- next {1} ({2})",

                ["StateEnabled"] = "enabled",
                ["StateDisabled"] = "disabled",

                // -- Validation -------------------------------------------
                // The command grammar itself stays English -- "weekdays",
                // "first Thursday" -- because it is typed, not read. Only the
                // complaint about it is translated. Where a message lists the
                // accepted words, they arrive as an argument so the list can
                // never drift out of step with the parser.
                ["ErrBadTime"] = "\"{0}\" is not a valid time. Use HH:mm, such as 05:00.",
                ["ErrBadDate"] = "\"{0}\" is not a valid date. Use yyyy-MM-dd.",
                ["ErrNoDays"] = "No days are selected.",
                ["ErrNoDaysGiven"] = "No days were given.",
                ["ErrNoWeekday"] = "No weekday is selected.",
                ["ErrBadOrdinal"] = "\"{0}\" is not one of: {1}.",
                ["ErrDayOfMonth"] = "Day of month must be between 1 and 31.",
                ["ErrInterval"] = "The interval must be at least one day.",
                ["ErrBadRepeat"] = "\"{0}\" is not a repeat mode. Use one of: {1}.",
                ["ErrOrdinalNeedsDay"] = "\"{0}\" needs a day, such as \"{1} Thursday\".",
                ["ErrNotADay"] = "\"{0}\" is not a day name.",
                ["ErrNotADayOrPattern"] = "\"{0}\" is not a day name, and not a pattern I recognize.",

                // -- The in-game panel ------------------------------------
                ["MenuTitleList"] = "Hotwire {0}  /  Schedule",
                ["MenuTitleEditing"] = "Hotwire {0}  /  Editing {1} {2}",
                ["MenuCountingDown"] = "COUNTING DOWN  --  {0} in {1}",
                ["MenuCancel"] = "Cancel the restart",
                ["MenuNothingScheduled"] = "Nothing scheduled. Add a restart or an update below.",
                ["MenuEdit"] = "Edit",
                ["MenuDelete"] = "Delete",
                ["MenuBack"] = "< Back",
                ["MenuOn"] = "ON",
                ["MenuOff"] = "OFF",
                ["MenuMoreRows"] = "...and {0} more. Use \"hotwire list\" to see them all.",
                ["MenuAddRestart"] = "+ Restart",
                ["MenuAddUpdate"] = "+ Update",
                ["MenuAddHint"] = "New entries start disabled. Turn one ON when it is right.",

                ["MenuTime"] = "Time",
                ["MenuRepeat"] = "Repeat",
                ["MenuDays"] = "Days",
                ["MenuWeekday"] = "Weekday",
                ["MenuWhich"] = "Which",
                ["MenuDayOfMonth"] = "Day of month",
                ["MenuDayOfMonthValue"] = "day {0}",
                ["MenuShortMonthWarning"] = "Skipped in months this short.",
                ["MenuEvery"] = "Every",
                ["MenuOneDay"] = "{0} day",
                ["MenuNDays"] = "{0} days",
                ["MenuCountingFrom"] = "counting from {0}",
                ["MenuToday"] = "today",
                ["MenuDate"] = "Date",
                ["MenuValidate"] = "Validate",
                ["MenuValidateHint"] = "Re-checksums the whole install. Slow.",
                ["MenuEnabled"] = "Enabled",

                // The repeat picker. Each names a rule rather than describing
                // one occurrence, which is why they read differently from the
                // Recur keys above.
                ["ModeDaily"] = "Every day",
                ["ModeWeekly"] = "Certain weekdays",
                ["ModeMonthlyWeekday"] = "Nth weekday of the month",
                ["ModeMonthlyDay"] = "A date each month",
                ["ModeEveryNDays"] = "Every N days",
                ["ModeOnce"] = "Once, on a date",

                // Suffixes on the stepper buttons: "-6" + h, "+15" + m. Kept
                // apart from the number so a translator changes the unit
                // without touching the arithmetic.
                ["UnitHourShort"] = "h",
                ["UnitMinuteShort"] = "m",
                ["UnitDayShort"] = "d",
                ["UnitMonthShort"] = "mo",
                ["UnitYearShort"] = "y",

                // The verdict shown under the edit form.
                ["MenuNotValid"] = "Not valid",
                ["MenuDisabled"] = "Disabled",
                ["MenuNeverRuns"] = "Never runs",
                ["MenuBroken"] = "BROKEN: {0}",
                // {0} is the rule, already a sentence fragment of its own.
                ["MenuNoOccurrence"] = "{0}. It has no occurrence in the next year.",
                ["MenuNoOccurrenceShort"] = "No occurrence in the next year",
                ["MenuRule"] = "{0} {1}",
                // {0} rule, {1} the moment in words, {2} the exact date.
                ["MenuWouldRun"] = "{0}. Would run {1}, on {2}.",
                // {0} rule, {1} the exact date, {2} the zone.
                ["MenuNextDetail"] = "{0}. {1}, {2}.",
                ["ClocksChange"] = "The clocks change before then.",
                ["MenuClocksChangeShort"] = "clocks change before then",

                ["Usage"] = "hotwire status | menu | check | list | now [update|validate] [seconds] | cancel | " +
                            "add <restart|update|validate> <HH:mm> [pattern] | set <restart|update> <index> " +
                            "<time|pattern|validate> <value> | remove <restart|update> <index> | " +
                            "enable|disable <restart|update> <index>",
                ["UsageSet"] = "hotwire set <restart|update> <index> <time|pattern|validate> <value>",
                ["UsageNow"] = "hotwire now [update|validate] [seconds]",
                ["UsageAdd"] = "hotwire add <restart|update|validate> <HH:mm> [pattern]. Patterns: daily | " +
                               "weekdays | weekends | Mon,Thu | first Thursday | last Friday | day 15 | " +
                               "every 2 days | once 2026-12-24",
                ["UsageRemove"] = "hotwire remove <restart|update> <index>",
                ["UsageToggle"] = "hotwire enable|disable <restart|update> <index>"
            }, this);
        }

        #endregion
    }
}
