using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using Oxide.Core;
using Oxide.Core.Libraries.Covalence;
using Oxide.Core.Plugins;
using Oxide.Game.Rust.Cui;
using UnityEngine;

namespace Oxide.Plugins
{
    [Info("Hotwire", "xman2000", "1.1.32")]
    [Description("Scheduled restarts and updates. Announces, counts down, writes a flag, quits.")]
    internal class Hotwire : CovalencePlugin
    {
        // =================================================================
        //  WHAT THIS PLUGIN DELIBERATELY DOES NOT DO
        //
        //  It does not spawn processes, write scheduled tasks or shell out.
        //  It writes a flag file and quits; the launcher does the rest.
        //
        //  Everything that schedules, announces or shuts the server down goes
        //  through Covalence, which is a stable Oxide interface rather than a
        //  moving Facepunch one. That is a safety decision, not a style one:
        //  a wrong guess at a Facepunch signature is a COMPILE
        //  error, and a plugin that does not compile is a plugin that never
        //  restarts the server. try/catch cannot save you from code that never
        //  runs. server.Command("quit") runs the same console command as
        //  ConVar.Global.quit with none of that exposure.
        //
        //  The ONE exception is the admin menu, which cannot exist without
        //  Facepunch types -- CuiHelper.AddUi takes a BasePlayer, and Rust's
        //  UI has no Covalence route. It is confined to a single region so
        //  that deleting it stays a real option, and everything it does the
        //  chat commands also do.
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

            [JsonProperty("Panel")]
            public PanelSettings Panel = new PanelSettings();
        }

        // Reporting to a Hotwire panel. Nothing is sent anywhere unless this
        // server has been connected with hotwire-setup, which writes the key to
        // oxide/data/Hotwire/panel.json. Deleting that file (or running
        // hotwire-setup detach) disconnects it; turning this off stops
        // reporting and leaves the connection in place.
        private class PanelSettings
        {
            [JsonProperty("Report to the panel when connected")]
            public bool Enabled = true;

            // How often the server says "still here". The panel counts a
            // server as silent after ten minutes without one.
            [JsonProperty("Heartbeat every this many seconds")]
            public int HeartbeatSeconds = 30;

            // Messages, saves, plugin reloads and unloads, kicks and announced restarts
            // queued in the panel. Off means the panel's buttons do nothing on
            // this server; queued commands expire there unanswered.
            [JsonProperty("Accept commands from the panel")]
            public bool AcceptCommands = true;

            [JsonProperty("Check for commands every this many seconds")]
            public int CommandSeconds = 30;

            // A restart from the panel always goes through the countdown, and
            // never with less warning than this, whatever the panel asked for.
            [JsonProperty("Shortest restart countdown from the panel (seconds)")]
            public int MinimumRestartSeconds = 60;

            // The account's ban list, written into this server's own ban list so
            // it is enforced locally and a panel outage never affects logins.
            // Only bans the panel added are ever lifted; a ban made here stays.
            [JsonProperty("Enforce the panel's ban list")]
            public bool EnforceBans = true;

            [JsonProperty("Check the ban list every this many seconds")]
            public int BanSeconds = 120;

            // The map's seed, size, custom map address and last wipe, so the
            // panel can show the map, and the map markers other plugins placed
            // (zones, event circles and their labels). Never players, shops or
            // bases.
            [JsonProperty("Report the map and its markers")]
            public bool ReportMap = true;

            [JsonProperty("Send map markers at most every this many seconds")]
            public int MarkerSeconds = 60;

            // The map image itself: the one Rust renders for the Rust+ app when
            // the server starts. Sent once per map, only when the panel does not
            // already have it.
            [JsonProperty("Send the map image")]
            public bool SendMapImage = true;

            // When Rust+ is turned off (app.port -1) the game renders no image,
            // so the plugin renders the same one itself, once per map. It takes
            // the game a few seconds; the plugin waits until the server has been
            // up for two minutes.
            [JsonProperty("Render the map image if Rust+ has not")]
            public bool RenderMapImage = true;

            // How the world is laid out, for the panel's map layers: landmarks,
            // roads, rails, rivers, power lines, the train tunnels and the
            // underwater labs. Read from the world the game generated, never
            // players or anything that moves. Sent once per map, again after a
            // week.
            [JsonProperty("Send the map layout")]
            public bool SendMapLayout = true;

            // The restart and update schedule, as it stands, with when each
            // entry next fires. Sent when it changes.
            [JsonProperty("Report the schedule")]
            public bool ReportSchedule = true;

            // Adding, editing, enabling, disabling and removing schedule entries
            // from the panel. They are checked exactly as the chat commands check
            // them, and refused if the schedule changed here since the panel
            // last saw it. Off leaves the schedule editable only in game.
            [JsonProperty("Accept schedule changes from the panel")]
            public bool AcceptScheduleChanges = true;

            // Oxide's own log (oxide/logs/oxide_<date>.txt), so the panel can
            // show what plugins said: compile failures, hook errors, warnings.
            // Card numbers and SSNs are masked before a line is sent, and Steam
            // IDs are removed below the "identified" player data level. The log
            // file on this machine stays the full record either way.
            [JsonProperty("Send the Oxide log")]
            public bool SendLog = true;

            // What the game server writes to its console that Oxide does not:
            // saves, joins and leaves, Rust's own warnings and errors, anything
            // another mod prints. Oxide's lines are sent once, from its own log,
            // and chat never goes this way (it has its own setting). IP addresses
            // are masked, card numbers and SSNs too, and Steam IDs below the
            // "identified" level. Kept in oxide/logs/hotwire_log_<date>.txt until
            // the panel has it.
            // How long anything waiting for the panel is kept on this machine:
            // reports that cannot be sent again, and log lines. A week is long
            // enough for an outage; a server that has not reached the panel in
            // seven days has a bigger problem than its spool. Raise it if you
            // want a longer reach back, up to 90 days, which is as far back as
            // the panel keeps a line anyway. The bounds on size hold either way.
            [JsonProperty("Keep unsent reports and log lines for this many days")]
            public int SpoolDays = 7;

            [JsonProperty("Send the server console")]
            public bool SendConsole = true;

            [JsonProperty("Send the log every this many seconds")]
            public int LogSeconds = 60;

            // Who is online, and when each player joins and leaves, by Steam ID
            // and name. Sent only while the panel's player data level is
            // "identified"; below it nothing about a player leaves this machine
            // beyond the count in the heartbeat.
            [JsonProperty("Send who is online, and player joins and leaves")]
            public bool SendPlayers = true;

            // What players say in chat, with its channel (global, team, local,
            // clan). Only at the "identified" level, with card numbers and SSNs
            // masked first. Chat commands are not chat and are never sent.
            [JsonProperty("Send chat")]
            public bool SendChat = true;

            // In-game (F7) reports: who reported whom, the kind, the subject and
            // the message. Sent only when the account's owner has turned them on
            // in the panel and the level is "identified"; false here keeps them
            // on this server whatever the panel says.
            [JsonProperty("Send in-game reports when the panel asks for them")]
            public bool SendReports = true;

            [JsonProperty("Send player joins, leaves and chat every this many seconds")]
            public int EventSeconds = 30;

            // How much of the server's time each plugin used since the last
            // report, and the memory allocated while it ran: the totals Oxide
            // keeps for "oxide.plugins", sent as the change. Plugin names and
            // numbers only; nothing about players.
            [JsonProperty("Report each plugin's server time")]
            public bool ReportPluginTime = true;

            [JsonProperty("Send plugin server time every this many seconds")]
            public int PluginTimeSeconds = 60;
        }

        // Recurrence is stored as explicit fields rather than as a cron
        // string or a phrase to be parsed. Every value validates on
        // its own, an error can name the exact field that is wrong, and the
        // menu maps one control per field instead of round-tripping somebody's
        // hand-written wording through a serializer.
        //
        // Only the fields the chosen Repeat mode needs are read. The rest sit
        // there holding whatever they held, which is what lets you switch a
        // schedule from weekly to monthly and back without retyping it.
        private class ScheduleEntry
        {
            // A stable name for the entry, so the panel can say "change this
            // one" even after someone reorders or removes entries in game.
            // Written the first time the config is saved; never reused.
            [JsonProperty("Id")]
            public string Id = "";

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
            // The best idea upstream has, and the one most able to
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

        // Render the countdown through a status surface players
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
            public string ProgressColor = "#C0392B";

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
            // guard has to be on disk rather than in memory.
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
            if (_config.Panel == null) { _config.Panel = new PanelSettings(); repaired.Add("Panel"); }

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

        protected override void SaveConfig()
        {
            EnsureEntryIds();
            Config.WriteObject(_config, true);
        }

        private void EnsureEntryIds()
        {
            if (_config == null) return;
            var seen = new HashSet<string>();
            foreach (var entry in AllEntries())
            {
                if (entry == null) continue;
                if (string.IsNullOrWhiteSpace(entry.Id) || !seen.Add(entry.Id))
                {
                    entry.Id = NewEntryId();
                    seen.Add(entry.Id);
                }
            }
        }

        private static string NewEntryId()
        {
            var bytes = new byte[6];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
            return Hex(bytes);
        }

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

        private Timer _panelTimer;

        #endregion

        #region Lifecycle

        private void Init()
        {
            permission.RegisterPermission(PermStatus, this);
            permission.RegisterPermission(PermRestart, this);
            permission.RegisterPermission(PermCancel, this);
            permission.RegisterPermission(PermEdit, this);

            AddCovalenceCommand(new[] { "hotwire", "hw" }, nameof(CmdHotwire));
            AddCovalenceCommand("hotwire.ui", nameof(CmdMenuAction));   // goes with the menu

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

        // Oxide passes true once, when the server finishes booting, and false to a
        // plugin loaded into a server that is already running.
        private void OnServerInitialized(bool initial)
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

            PrepareSession(initial);
            StartPanelReporting();
        }

        private void Unload()
        {
            // First, before anything that could throw: the game must not call into
            // an unloaded plugin.
            try { StopConsoleCapture(); } catch { }

            _scanTimer?.Destroy();
            _countdownTimer?.Destroy();
            _frameworkTimer?.Destroy();
            _panelTimer?.Destroy();
            _sessionTimer?.Destroy();

            // Player events still queued would go with the plugin: keep them to send after the reload.
            try
            {
                if (_panel != null && _events.Count > 0 && (PolicyAllowsKind("events") || PolicyHolds(_policy)))
                    SpoolQueuedEvents(true);
            }
            catch (Exception ex)
            {
                PrintWarning($"Panel: queued player events could not be kept for later ({ex.Message}).");
            }

            // The console stops being taken, and what was taken goes to the spool,
            // to be sent after the reload.
            try
            {
                if (_panel != null && !_consoleQueue.IsEmpty)
                {
                    LoadLogCursor();
                    FlushConsole(true);
                }
            }
            catch (Exception ex)
            {
                PrintWarning($"Panel: the last console lines could not be kept for later ({ex.Message}).");
            }

            CloseAllMenus();   // goes with the menu

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
        // The schedule is local wall-clock, so "05:00" means a
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
                // to five minutes of everyone's progress.
                //
                // Routed through Covalence rather than ConVar.Global.quit so
                // that the shutdown path carries no compile-time dependency on
                // Assembly-CSharp -- see the note at the top.
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
                Puts($"Wrote {path}. The launcher updates on its next start and deletes the flag once the update completes -- one flag buys one update. (Not if its UPDATE_MODE is off.)");
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
            // Plain strings. Upstream ships a regex template
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

        // The countdown renders through a status surface players
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

        #region Panel reporting

        // Talks to the Hotwire panel this server was connected to: a heartbeat,
        // the plugin list, commands queued in the panel, and the account's ban
        // list.
        //
        // Everything here is beside the game, never in its way. One request is
        // out at a time; answers are handled when they arrive; every failure is
        // caught and logged once. Nothing in the schedule, the countdown or the
        // flags waits on it. A panel that is down, slow or wrong changes what
        // this server reports, never what it does -- the one exception is a
        // command an admin queued, which is carried out the way the same chat
        // command would be, announced restarts included.
        //
        // Heartbeats are not kept and resent after an outage: a heartbeat says
        // "alive now", and late ones say nothing the next one does not. The
        // plugin list is state, not history, so the latest one is simply sent
        // until the panel accepts it.

        private const string PanelReportPath = "/api/v1/report";
        private const string PanelCommandsPath = "/api/v1/commands";
        private const string PanelBansPath = "/api/v1/bans";
        private const string BuildManifest = "appmanifest_258550.acf";
        private const string CommandsDataFile = "Hotwire/panel_commands";
        private const string BansDataFile = "Hotwire/panel_bans";

        private sealed class PanelLink
        {
            public string KeyId;
            public string Secret;
            public string Url;
        }

        private sealed class HandledCommand
        {
            public string Status;
            public string Result;
            public DateTime HandledUtc;
        }

        private sealed class AppliedBan
        {
            public long Expiry;
            public string Reason;
        }

        private sealed class InventoryItem
        {
            public string Name = "";
            public string File = "";
            public string Author = "";
            public string Version = "";
            public string Sha256Hex = "";
            public long Size;
            public bool Loaded;
            public string Error;
        }

        // A plugin file's hash and its [Info] line, read together once and kept
        // until the file's time or size changes. Reading every plugin's text on
        // every check allocated the whole plugins folder, megabytes, once a minute.
        private sealed class HashedFile
        {
            public DateTime Stamp;
            public long Size;
            public string Sha256Hex;
            public bool HasInfo;
            public string Title, Author, Version;
        }

        private PanelLink _panel;
        private DateTime _panelFileStamp = DateTime.MinValue;
        private string _panelState = "not started";
        private string _panelProblem;
        private bool _panelReporting;
        private bool _panelBusy;
        private int _panelFailures;
        private DateTime _panelNextAttempt = DateTime.MinValue;

        private DateTime _heartbeatDue = DateTime.MinValue;
        private DateTime _commandsDue = DateTime.MinValue;
        private DateTime _bansDue = DateTime.MinValue;
        private DateTime _inventoryCheckDue = DateTime.MinValue;

        private int _fpsFrames = -1;
        private float _fpsAt;
        private bool _cpuMeasured;
        private TimeSpan _cpuUsed;
        private DateTime _cpuAt;
        private MethodInfo _serverInfo;
        private bool _serverInfoMissing;

        private DateTime _manifestStamp = DateTime.MinValue;
        private string _buildId;
        private string _branch;

        private readonly Dictionary<string, HashedFile> _fileHashes = new Dictionary<string, HashedFile>(StringComparer.OrdinalIgnoreCase);
        private List<InventoryItem> _inventory;
        private string _inventoryHash;
        private string _inventorySentHash;
        private string _inventoryState = "not sent yet";

        private readonly Queue<JObject> _commandResults = new Queue<JObject>();
        private Dictionary<string, HandledCommand> _handledCommands = new Dictionary<string, HandledCommand>();
        private string _commandsState = "not checked yet";

        private Dictionary<string, AppliedBan> _appliedBans = new Dictionary<string, AppliedBan>();
        private string _bansListHash;
        private string _bansState = "not checked yet";
        private string _bansNotice;

        private string PanelFile() => Path.Combine(Interface.Oxide.DataDirectory, "Hotwire", "panel.json");

        private void StartPanelReporting()
        {
            _handledCommands = ReadData<Dictionary<string, HandledCommand>>(CommandsDataFile) ?? new Dictionary<string, HandledCommand>();
            _appliedBans = ReadData<Dictionary<string, AppliedBan>>(BansDataFile) ?? new Dictionary<string, AppliedBan>();

            if (!_config.Panel.Enabled)
            {
                _panelState = "off in the config";
                Puts("Panel reporting is off in the config. Nothing is sent.");
                return;
            }

            _panelTimer = timer.Every(5f, PanelTick);
            timer.Once(5f, PanelTick);
        }

        private T ReadData<T>(string name) where T : class
        {
            try { return Interface.Oxide.DataFileSystem.ReadObject<T>(name); }
            catch (Exception ex)
            {
                PrintWarning($"Could not read oxide/data/{name}.json ({ex.Message}). Starting it empty.");
                return null;
            }
        }

        private void WriteData(string name, object value)
        {
            try { Interface.Oxide.DataFileSystem.WriteObject(name, value); }
            catch (Exception ex) { PrintWarning($"Could not write oxide/data/{name}.json: {ex.Message}"); }
        }

        private void OnPluginLoaded(Plugin plugin) => _inventoryCheckDue = DateTime.UtcNow.AddSeconds(3);

        private void OnPluginUnloaded(Plugin plugin) => _inventoryCheckDue = DateTime.UtcNow.AddSeconds(3);

        private void PanelTick()
        {
            try
            {
                if (!_config.Panel.Enabled) return;

                RefreshPanelLink();
                // The log's spool fills whether or not the panel can be reached.
                try { TickLogSpool(); }
                catch (Exception ex) { PrintWarning($"Panel: the log spool could not be updated this tick ({ex.Message})."); }
                if (_panel != null && !_panelBusy && _panelFailures > 0) SpoolWhileUnreachable();
                if (_panel == null || _panelBusy || DateTime.UtcNow < _panelNextAttempt) return;

                PanelPump();
            }
            catch (Exception ex)
            {
                _panelBusy = false;
                PanelProblem($"reporting stopped for this tick after an error: {ex.Message}");
            }
        }

        // Sends the most urgent thing that is due, one request at a time.
        private void PanelPump()
        {
            if (_panel == null || _panelBusy) return;
            var now = DateTime.UtcNow;

            if (_commandResults.Count > 0)
            {
                if (PolicyAllowsKind("command_result")) { SendCommandResult(); return; }
                if (PolicyHolds(_policy))
                {
                    while (_commandResults.Count > 0) SpoolReport(PanelEnvelope("command_result", _commandResults.Dequeue()));
                }
                else
                {
                    // Not held for later: the panel lets an unanswered command expire.
                    Puts($"Panel: {_commandResults.Count} command answer{(_commandResults.Count == 1 ? " is" : "s are")} not sent: the panel's report policy does not include them.");
                    _commandResults.Clear();
                }
            }

            // The game is going down. Only acknowledgements still go out.
            if (_shuttingDown) return;

            if (now >= _inventoryCheckDue)
            {
                _inventoryCheckDue = now.AddSeconds(60);
                RefreshInventory();
            }
            if (_panelReporting && _inventoryHash != null && _inventoryHash != _inventorySentHash && PolicyAllowsKind("inventory")) { SendInventory(); return; }

            if (now >= _heartbeatDue && PolicyAllowsKind("heartbeat")) { SendHeartbeat(); return; }

            if (!_panelReporting) return;   // nothing else until the panel has accepted a heartbeat

            // How much player data may leave this machine, before anything that could carry any.
            if (now >= _sharingDue) { PollSharing(); return; }

            // What to send, and how often, for this account's plan.
            if (now >= _policyDue) { PollPolicy(); return; }

            if (SessionReportDue())
            {
                if (PolicyAllowsKind("session")) { SendSession(); return; }
                if (PolicyHolds(_policy)) SpoolSessionReports();
            }

            if (_config.Panel.ReportMap && !_mapOff)
            {
                if (now >= _mapCheckDue) { _mapCheckDue = now.AddSeconds(30); RefreshMap(); }
                if (_worldJson != null && _worldJson != _worldSentJson && PolicyAllowsKind("world")) { SendWorld(); return; }
                if (_markersJson != null && _markersJson != _markersSentJson && now >= _markersDue && PolicyAllowsKind("map_markers")) { SendMarkers(); return; }
                if (_config.Panel.SendMapLayout && PolicyAllowsKind("map_layout") && _worldSentJson != null && _worldSentJson == _worldJson && now >= _layoutDue && MapKey() != null && MapKey() != _layoutDoneKey)
                {
                    CheckMapLayout();
                    return;
                }
                if (_config.Panel.SendMapImage && PolicyAllowsKind("map_render") && _worldSentJson != null && _worldSentJson == _worldJson && now >= _imageDue && MapKey() != _imageDoneKey)
                {
                    CheckMapImage();
                    return;
                }
            }

            // Raidable Bases zones come from its hooks, not the game map read, so they are not gated on _mapOff.
            if (_config.Panel.ReportMap && _raidZonesJson != null && _raidZonesJson != _raidZonesSentJson && now >= _raidZonesDue && PolicyAllowsKind("raid_zones")) { SendRaidZones(); return; }

            if (_config.Panel.ReportSchedule)
            {
                if (now >= _scheduleCheckDue) { _scheduleCheckDue = now.AddSeconds(30); RefreshSchedule(); }
                if (_scheduleJson != null && _scheduleJson != _scheduleSentJson && PolicyAllowsKind("schedule")) { SendSchedule(); return; }
            }

            if (_config.Panel.AcceptCommands && PolicyAllowsCommands() && now >= _commandsDue) { PollCommands(); return; }
            if (_config.Panel.SendPlayers && now >= _playersCheckDue) { _playersCheckDue = now.AddSeconds(30); RefreshPlayers(); }
            if (_playersJson != null && _playersJson != _playersSentJson && now >= _playersSendNotBefore && PolicyAllowsKind("players")) { SendPlayers(); return; }
            if (_events.Count > 0 && !PolicyAllowsKind("events"))
            {
                if (PolicyHolds(_policy)) SpoolQueuedEvents(false);
                else _events.Clear();   // not held for later
            }
            if (_events.Count > 0 && now >= _eventsDue) { SendEvents(); return; }
            if (_config.Panel.ReportPluginTime && now >= _pluginTimeDue)
            {
                if (PolicyAllowsKind("plugin_time")) { if (SendPluginTime()) return; }
                else ForgetPluginTotals();
            }
            // Runs when the log is not allowed too: it walks the log and counts what it passes,
            // or, when the policy holds, leaves the cursor where it is.
            if ((_config.Panel.SendLog || _config.Panel.SendConsole) && now >= _logDue && SendLog()) return;
            if (_config.Panel.EnforceBans && PolicyAllowsBans() && now >= _bansDue) { PollBans(); return; }

            // Nothing live is due: one held report, if there are any.
            DrainSpool();
        }

        // Reads panel.json again only when it changes, so connecting, detaching
        // or reconnecting takes effect without a reload.
        private void RefreshPanelLink()
        {
            var path = PanelFile();
            if (!File.Exists(path))
            {
                if (_panel != null || _panelFileStamp != DateTime.MinValue || _panelState == "not started")
                {
                    if (_panel != null) Puts("panel.json is gone, so this server is no longer connected. Reporting stopped.");
                    else Puts("Not connected to a panel. Nothing is sent. (hotwire-setup connect connects this server.)");
                }
                _panel = null;
                _panelFileStamp = DateTime.MinValue;
                _panelState = "not connected";
                return;
            }

            var stamp = File.GetLastWriteTimeUtc(path);
            if (stamp == _panelFileStamp) return;
            _panelFileStamp = stamp;

            _panel = null;
            _panelReporting = false;
            _panelFailures = 0;
            _panelProblem = null;
            _panelNextAttempt = DateTime.MinValue;
            _heartbeatDue = DateTime.MinValue;
            _inventorySentHash = null;
            _bansListHash = null;
            _worldSentJson = null;
            _markersSentJson = null;
            _imageDoneKey = null;
            _imageDue = DateTime.MinValue;
            _layoutDoneKey = null;
            _layoutDue = DateTime.MinValue;
            _scheduleSentJson = null;
            _sharingDue = DateTime.MinValue;
            _policy = null;
            _policyDue = DateTime.MinValue;
            _logPending = null;
            _logDue = DateTime.MinValue;
            _playersJson = null;
            _playersSentJson = null;
            _playersCheckDue = DateTime.MinValue;
            _playersSendNotBefore = DateTime.MinValue;
            _events.Clear();
            _pluginTotals.Clear();
            _pluginTimeDue = DateTime.MinValue;

            JObject file;
            try
            {
                file = JObject.Parse(File.ReadAllText(path));
            }
            catch (Exception ex)
            {
                PanelRefuse($"{path} could not be read ({ex.Message}). Run hotwire-setup connect again.");
                return;
            }

            var keyId = (string)file["key_id"];
            var secret = (string)file["secret"];
            var url = (string)file["panel_url"];
            var folder = (string)file["folder"];

            if (string.IsNullOrWhiteSpace(keyId) || string.IsNullOrWhiteSpace(secret) || string.IsNullOrWhiteSpace(url))
            {
                PanelRefuse($"{path} is missing its key or the panel address. Run hotwire-setup connect again.");
                return;
            }

            // The panel address must be https: http:// would send this server's
            // reports unencrypted. Refusing is safe: reporting is never on the boot
            // path, so the server is unaffected.
            if (url.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            {
                PanelRefuse($"the panel address in {path} uses http://, which is not encrypted and cannot be trusted. " +
                            "Use the panel's https:// address, then run hotwire-setup connect again.");
                return;
            }

            if (!url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                PanelRefuse($"the panel address in {path} is not a web address. Run hotwire-setup connect again.");
                return;
            }

            // A copied server folder carries the original's key. Reporting
            // from the copy would make two servers speak as one, and the
            // original would look like it is flapping. Setup records the folder
            // it connected; anything else is refused rather than guessed at.
            if (string.IsNullOrWhiteSpace(folder))
            {
                PanelRefuse("panel.json does not say which folder it was written for (an older hotwire-setup wrote it). " +
                            "Run hotwire-setup connect again in this server's folder; the panel keeps the same server entry.");
                return;
            }

            var root = ServerRoot();
            if (root == null)
            {
                PanelRefuse("the server root cannot be determined, so it cannot be checked against the folder that was connected. " +
                            "Set \"Server root\" in the config.");
                return;
            }

            if (!SameFolder(folder, root))
            {
                PanelRefuse($"panel.json was written for {folder}, but this server runs from {root}. " +
                            "This looks like a copied server folder, so it will not report as the original. " +
                            "Run hotwire-setup connect in this folder to connect it as a server of its own.");
                return;
            }

            _panel = new PanelLink { KeyId = keyId.Trim(), Secret = secret, Url = url.Trim().TrimEnd('/') };
            _panelState = $"connected to {_panel.Url}, waiting for the first answer";
            Puts($"Connected to the panel at {_panel.Url}. Sending a heartbeat every {Math.Max(10, _config.Panel.HeartbeatSeconds)} seconds.");
        }

        private void PanelRefuse(string why)
        {
            _panel = null;
            _panelState = "NOT REPORTING -- " + why;
            PrintWarning("Not reporting to the panel: " + why);
        }

        private static bool SameFolder(string a, string b)
        {
            var comparison = Path.DirectorySeparatorChar == '\\' ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            return string.Equals(NormalizeFolder(a), NormalizeFolder(b), comparison);
        }

        private static string NormalizeFolder(string path)
        {
            var p = path.Trim();
            try { p = Path.GetFullPath(p); } catch { /* compared as written */ }
            return p.TrimEnd('\\', '/');
        }

        // ---------------------------------------------------------- transport

        // One signed request. body is null for a GET, and an empty body is
        // what gets signed. onAccepted runs only for a 2xx answer from the link
        // that was current when the request left. onRefused runs when the panel
        // understood the request and said no to its content (400, 413, 422): the
        // same bytes would be refused again, so the caller lets it go rather than
        // letting it block everything behind it.
        // signedResponse opts this request into a signed answer (HW-1): the panel
        // wraps the real body and signs it, and onAccepted runs only if that
        // signature verifies. Used for the answers the plugin acts on -- commands,
        // bans, the sharing level -- where a forged reply would be dangerous. A
        // reply that cannot be verified is dropped and retried, never acted on.
        private void PanelRequest(string method, string path, string body, Action<string> onAccepted, Action onRefused = null, float timeoutSeconds = 20f, bool signedResponse = false, Action<int> onFailed = null)
        {
            var link = _panel;
            var timestamp = ((long)(DateTime.UtcNow - UnixEpoch).TotalSeconds).ToString(CultureInfo.InvariantCulture);
            var nonce = PanelNonce();

            var headers = new Dictionary<string, string>
            {
                { "Accept", "application/json" },
                { "X-Hotwire-Key", link.KeyId },
                { "X-Hotwire-Timestamp", timestamp },
                { "X-Hotwire-Nonce", nonce },
                { "X-Hotwire-Signature", PanelSign(link.Secret, method, path, timestamp, nonce, body ?? "") }
            };
            if (signedResponse) headers["X-Hotwire-Signed-Response"] = "1";
            if (body != null) headers["Content-Type"] = "application/json";

            _panelBusy = true;
            var verb = method == "POST" ? Oxide.Core.Libraries.RequestMethod.POST : Oxide.Core.Libraries.RequestMethod.GET;
            webrequest.Enqueue(link.Url + path, body, (code, response) =>
            {
                _panelBusy = false;
                _panelLastCode = code;
                try
                {
                    if (!ReferenceEquals(link, _panel)) return;   // panel.json changed while this was out

                    if (code >= 200 && code < 300)
                    {
                        var accepted = response;
                        if (signedResponse)
                        {
                            // Fail closed: an answer the panel's secret did not sign
                            // is dropped, never acted on. Dropping a command changes
                            // nothing; acting on a forged one is the whole risk. It is
                            // logged once and retried on the next poll.
                            string verified;
                            if (!PanelVerifyResponse(link.Secret, code, timestamp, nonce, response, out verified))
                            {
                                PanelProblem($"the panel's answer to {path} was not signed with this server's key, so it was ignored. " +
                                             "If this keeps happening, something on the network may be answering in the panel's place.");
                                return;
                            }
                            accepted = verified;
                        }

                        if (_panelProblem != null) Puts("Reporting to the panel again.");
                        _panelProblem = null;
                        _panelFailures = 0;
                        _panelNextAttempt = DateTime.MinValue;
                        onAccepted(accepted);
                        PanelPump();
                        return;
                    }

                    if (onRefused != null && (code == 400 || code == 413 || code == 422)) onRefused();
                    onFailed?.Invoke(code);
                    PanelFailed(code, response);
                }
                catch (Exception ex)
                {
                    PanelProblem($"the panel's answer could not be used: {ex.Message}");
                }
            }, this, verb, headers, timeoutSeconds);
        }

        private void PanelFailed(int code, string response)
        {
            var message = PanelMessage(response);
            string problem;

            if (code == 0)
                problem = $"could not reach the panel at {_panel.Url}. The server is unaffected; it keeps trying.";
            else if (code == 401 && message.StartsWith("Timestamp", StringComparison.Ordinal))
                problem = "the panel refused the time on this machine. Its clock is more than five minutes out; " +
                          "set the clock to sync automatically (hotwire-setup doctor checks it).";
            else if (code == 401 && message.StartsWith("Unknown or revoked", StringComparison.Ordinal))
                problem = "the panel no longer accepts this server's key. The server was retired in the panel, " +
                          "or another machine was connected in its place. To connect this one again, make a code in the panel " +
                          "and run hotwire-setup connect in this folder.";
            else if (code == 401 && message.StartsWith("Replayed", StringComparison.Ordinal))
                problem = "the panel saw a repeated request. It retries by itself.";
            else if (code == 401)
                problem = $"the panel refused the signature ({message}). This is a bug; please report it with Hotwire {Version}.";
            else if (code == 422)
                problem = $"the panel refused a report as malformed ({message}). This is a bug; please report it with Hotwire {Version}.";
            else if (code == 413)
                problem = "the panel's web server refused a request as too large (its upload limit is lower than the map image). " +
                          "The server is unaffected; the map image is tried again in an hour.";
            else if (code == 429)
                problem = "the panel is asking this server to slow down. It backs off and retries.";
            else
                problem = $"the panel answered HTTP {code}{(message.Length > 0 ? " (" + message + ")" : "")}. It keeps trying.";

            if (code == 401 || code == 0) _panelReporting = false;
            PanelProblem(problem);
        }

        // Logs a problem once, not on every try, and waits longer between tries
        // each time: 1, 2, 4... heartbeat intervals, never more than ten minutes.
        // A change to panel.json starts again at once.
        private void PanelProblem(string problem)
        {
            _panelFailures++;
            var interval = Math.Max(10, _config.Panel.HeartbeatSeconds);
            var wait = Math.Min(600.0, interval * Math.Pow(2, Math.Min(_panelFailures - 1, 10)));
            _panelNextAttempt = DateTime.UtcNow.AddSeconds(wait);
            _panelState = "NOT REPORTING -- " + problem;

            if (problem != _panelProblem) PrintWarning("Panel: " + problem);
            _panelProblem = problem;
        }

        private static string PanelMessage(string response)
        {
            if (string.IsNullOrEmpty(response)) return "";
            try
            {
                var message = (string)JObject.Parse(response)["message"];
                if (!string.IsNullOrEmpty(message)) return message;
            }
            catch { /* not the panel's JSON envelope */ }
            return response.Length > 120 ? response.Substring(0, 120) : response;
        }

        private static JObject PanelData(string response)
        {
            return JObject.Parse(response)["data"] as JObject ?? new JObject();
        }

        private string PanelEnvelope(string kind, JObject payload)
        {
            return PanelBody(NewReportId(), DateTime.UtcNow, Version.ToString(), kind, payload);
        }

        // ---------------------------------------------------------- spool

        // Reports that cannot be sent again -- a session, player events, a
        // command's answer -- are kept on this machine when the panel cannot take
        // them, or when the panel's report policy says to hold them, and sent
        // later, oldest first, one at a time. Kept for thirty days at most and
        // within a disk bound, oldest let go first.
        private const string SpoolStateFile = "Hotwire/panel_spool";
        private const int SpoolDrainSeconds = 5;

        private sealed class SpoolState
        {
            public long Expired;
            public long Overflowed;
            public string PanelUrl;
        }

        private SpoolState _spoolState;
        // A backlog goes out one report or log batch at a time, never back to back.
        private DateTime _catchUpDue = DateTime.MinValue;
        private bool _spoolWarned;

        // How long anything waiting for the panel is kept here, from the config,
        // within reason: at least a day, and never past the panel's own 90-day
        // retention. A 0 or a negative in the file means the default week.
        private const int SpoolDaysDefault = 7;
        private const int SpoolDaysMax = 90;

        private int SpoolDays()
        {
            var days = _config == null ? SpoolDaysDefault : _config.Panel.SpoolDays;

            return days <= 0 ? SpoolDaysDefault : Math.Min(SpoolDaysMax, days);
        }

        private static string SpoolDirectory() => Path.Combine(Interface.Oxide.DataDirectory, "Hotwire", "spool");

        private SpoolState SpoolCounts()
        {
            return _spoolState ?? (_spoolState = ReadData<SpoolState>(SpoolStateFile) ?? new SpoolState());
        }

        private void SpoolProblem(string what, Exception ex)
        {
            if (_spoolWarned) return;
            _spoolWarned = true;
            PrintWarning($"Panel: could not {what} ({ex.Message}). Reporting carries on; held reports may be lost.");
        }

        // Keeps one report, exactly as it would have been sent.
        private void SpoolReport(string body)
        {
            try
            {
                var envelope = JObject.Parse(body);
                var id = (string)envelope["report_id"] ?? NewReportId();
                DateTime sent;
                if (!DateTime.TryParse((string)envelope["sent_at"], CultureInfo.InvariantCulture,
                        DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out sent))
                    sent = DateTime.UtcNow;

                var dir = SpoolDirectory();
                Directory.CreateDirectory(dir);
                var path = Path.Combine(dir, SpoolFileName(sent, id));
                var temp = path + ".tmp";
                File.WriteAllText(temp, body, new UTF8Encoding(false));
                if (File.Exists(path)) File.Delete(path);
                File.Move(temp, path);

                var state = SpoolCounts();
                if (_panel != null && state.PanelUrl != _panel.Url)
                {
                    state.PanelUrl = _panel.Url;
                    WriteData(SpoolStateFile, state);
                }
                SpoolPruneNow();
            }
            catch (Exception ex)
            {
                SpoolProblem("keep a report to send later", ex);
            }
        }

        private static List<SpoolEntry> SpoolEntries()
        {
            var dir = SpoolDirectory();
            if (!Directory.Exists(dir)) return new List<SpoolEntry>();
            var entries = new List<SpoolEntry>();
            foreach (var path in Directory.GetFiles(dir, "*.json"))
            {
                var time = SpoolFileTime(Path.GetFileName(path));
                if (time == null) continue;
                entries.Add(new SpoolEntry { Path = path, SentUtc = time.Value, Bytes = new FileInfo(path).Length });
            }
            return entries.OrderBy(e => Path.GetFileName(e.Path), StringComparer.Ordinal).ToList();
        }

        // Lets go of what is too old or does not fit, and counts it.
        private void SpoolPruneNow()
        {
            List<SpoolEntry> expired, overflowed;
            SpoolPrune(SpoolEntries(), DateTime.UtcNow, SpoolDays(), out expired, out overflowed);
            if (expired.Count == 0 && overflowed.Count == 0) return;

            foreach (var entry in expired.Concat(overflowed)) SpoolDelete(entry.Path);
            var state = SpoolCounts();
            state.Expired += expired.Count;
            state.Overflowed += overflowed.Count;
            WriteData(SpoolStateFile, state);
            if (expired.Count > 0)
                Puts($"Panel: {expired.Count} held report{(expired.Count == 1 ? " was" : "s were")} older than {SpoolDays()} days and {(expired.Count == 1 ? "was" : "were")} deleted unsent.");
            if (overflowed.Count > 0)
                Puts($"Panel: {overflowed.Count} of the oldest held report{(overflowed.Count == 1 ? " was" : "s were")} deleted unsent to keep the spool within {SpoolMaxBytes / (1024 * 1024)} MB.");
        }

        private static void SpoolDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); }
            catch { /* tried again at the next prune */ }
        }

        // Disconnecting, or connecting to another panel, lets go of what was
        // held for the old one: it belongs to that panel, not this one.
        private void SpoolForget(string why)
        {
            try
            {
                var entries = SpoolEntries();
                foreach (var entry in entries) SpoolDelete(entry.Path);
                _spoolState = new SpoolState { PanelUrl = _panel?.Url };
                WriteData(SpoolStateFile, _spoolState);
                if (entries.Count > 0) Puts($"Panel: {entries.Count} held report{(entries.Count == 1 ? " was" : "s were")} deleted unsent: {why}.");
            }
            catch (Exception ex)
            {
                SpoolProblem("clear the held reports", ex);
            }
        }

        // Sends the oldest held report, if nothing live is due and the last
        // catch-up send was long enough ago. Returns whether a request went out.
        private bool DrainSpool()
        {
            if (_panel == null || DateTime.UtcNow < _catchUpDue) return false;

            List<SpoolEntry> entries;
            try
            {
                var state = SpoolCounts();
                if (state.PanelUrl != null && state.PanelUrl != _panel.Url)
                {
                    SpoolForget("this server now reports to a different panel");
                    return false;
                }
                SpoolPruneNow();
                entries = SpoolEntries();
            }
            catch (Exception ex)
            {
                SpoolProblem("read the held reports", ex);
                return false;
            }

            foreach (var entry in entries)
            {
                string body, kind;
                try
                {
                    body = File.ReadAllText(entry.Path, Encoding.UTF8);
                    kind = (string)JObject.Parse(body)["kind"];
                }
                catch
                {
                    SpoolDelete(entry.Path);   // unreadable: it could never be sent
                    continue;
                }

                // Today's policy applies to what was held yesterday.
                if (!PolicyAllowsKind(kind))
                {
                    if (PolicyHolds(_policy)) return false;   // still held: wait
                    SpoolDelete(entry.Path);
                    continue;
                }

                var path = entry.Path;
                _catchUpDue = DateTime.UtcNow.AddSeconds(SpoolDrainSeconds);
                PanelRequest("POST", PanelReportPath, body, response => SpoolDelete(path), onFailed: code =>
                {
                    // A refusal would be refused again; anything else waits for the next pass.
                    if (!SpoolKeepsStatus(code)) SpoolDelete(path);
                });
                return true;
            }
            return false;
        }

        // For the heartbeat. Left out when nothing is held and nothing was let go.
        private JObject SpoolSummary()
        {
            try
            {
                var entries = SpoolEntries();
                var state = SpoolCounts();
                if (entries.Count == 0 && state.Expired == 0 && state.Overflowed == 0) return null;
                return new JObject
                {
                    ["pending"] = entries.Count,
                    ["oldest"] = entries.Count == 0 ? JValue.CreateNull() : (JToken)SessionTime(entries[0].SentUtc),
                    ["expired"] = state.Expired,
                    ["overflowed"] = state.Overflowed
                };
            }
            catch
            {
                return null;
            }
        }

        // The panel has been told what was let go, and nothing is held: start counting afresh.
        private void SpoolCountsDelivered()
        {
            var state = SpoolCounts();
            if (state.Expired == 0 && state.Overflowed == 0) return;
            state.Expired = 0;
            state.Overflowed = 0;
            WriteData(SpoolStateFile, state);
        }

        private string SpoolDescription()
        {
            try
            {
                var entries = SpoolEntries();
                var state = SpoolCounts();
                var held = entries.Count == 0
                    ? "nothing held"
                    : $"{entries.Count} held, oldest from {entries[0].SentUtc.ToLocalTime():yyyy-MM-dd HH:mm}";
                var dropped = state.Expired + state.Overflowed > 0
                    ? $"; {state.Expired} deleted unsent for age, {state.Overflowed} for space"
                    : "";
                return $"{held}{dropped} (keeps up to {SpoolDays()} days, {SpoolMaxBytes / (1024 * 1024)} MB)";
            }
            catch (Exception ex)
            {
                return $"cannot be read ({ex.Message})";
            }
        }

        // While the panel cannot be reached, what cannot be sent again goes to
        // disk, so a reload or a restart in the meantime does not lose it.
        private void SpoolWhileUnreachable()
        {
            if (SessionReportDue() && (PolicyAllowsKind("session") || PolicyHolds(_policy))) SpoolSessionReports();
            if (_events.Count > 0 && (PolicyAllowsKind("events") || PolicyHolds(_policy))) SpoolQueuedEvents(false);
        }

        private void SpoolSessionReports()
        {
            for (var i = 0; i < 2 && SessionReportDue(); i++)
            {
                Action done;
                var body = BuildSessionReport(out done);
                SpoolReport(body);
                done();
            }
        }

        // Held events go to disk a report's worth at a time, or once the oldest
        // has waited an hour -- not every few seconds -- so a month of them stays
        // a few hundred files. With `all`, whatever is queued goes now.
        private void SpoolQueuedEvents(bool all)
        {
            if (EffectiveSharingLevel() < 3)
            {
                _events.Clear();
                return;
            }

            while (_events.Count > 0 && (all || _events.Count >= EventsPerReport || OldestEventAge() >= TimeSpan.FromHours(1)))
            {
                var batch = _events.Take(EventsPerReport).ToList();
                SpoolReport(PanelEnvelope("events", new JObject { ["events"] = new JArray(batch) }));
                _events.RemoveAll(e => batch.Contains(e));
            }
        }

        private TimeSpan OldestEventAge()
        {
            DateTime at;
            if (_events.Count == 0) return TimeSpan.Zero;
            return DateTime.TryParse((string)_events[0]["at"], CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out at)
                ? DateTime.UtcNow - at
                : TimeSpan.FromHours(1);
        }

        // ---------------------------------------------------------- heartbeat

        private void SendHeartbeat()
        {
            _heartbeatDue = DateTime.UtcNow.AddSeconds(HeartbeatInterval());
            var payload = HeartbeatPayload();
            var spool = SpoolSummary();
            if (spool != null) payload["spool"] = spool;
            PanelRequest("POST", PanelReportPath, PanelEnvelope("heartbeat", payload), response =>
            {
                // What was let go has been told, and nothing is held: count afresh.
                if (spool != null && (int)spool["pending"] == 0) SpoolCountsDelivered();
                if (!_panelReporting)
                    Puts("The panel accepted a heartbeat. This server is reporting.");
                _panelReporting = true;
                _panelState = $"reporting to {_panel.Url} (last heartbeat accepted {DateTime.Now:HH:mm:ss})";
            });
        }

        private JObject HeartbeatPayload()
        {
            // Each fact is optional in the contract. One that cannot be read
            // is left out, never sent as a guess.
            var payload = new JObject();
            try { payload["players"] = players.Connected.Count(); } catch { }
            try { payload["max_players"] = server.MaxPlayers; } catch { }
            try { payload["uptime_seconds"] = (long)Time.realtimeSinceStartup; } catch { }
            try { var fps = AverageFps(); if (fps >= 0) payload["fps"] = fps; } catch { }
            try { var cpu = AverageCpuPercent(); if (cpu >= 0) payload["cpu_percent"] = cpu; } catch { }
            try { AddServerInfo(payload); } catch { }
            try { var v = InstalledFrameworkVersion(); if (v != null) payload["oxide_version"] = v; } catch { }
            try { var p = server.Protocol; if (!string.IsNullOrEmpty(p)) payload["rust_protocol"] = p; } catch { }
            try { var b = InstalledBuildId(); if (b != null) payload["rust_build_id"] = b; } catch { }
            try { var br = InstalledBranch(); if (br != null) payload["rust_branch"] = br; } catch { }
            // The port A2S answers on: server.queryport, or the game port when it is 0, as Rust itself does.
            try
            {
                var q = ConVar.Server.queryport > 0 ? ConVar.Server.queryport : ConVar.Server.port;
                if (q > 0 && q <= 65535) payload["query_port"] = q;
            }
            catch { }
            if (_inventoryHash != null) payload["inventory_hash"] = _inventoryHash;
            try { var l = LauncherIdentity(); if (l != null) payload["launcher"] = l; } catch { }
            return payload;
        }

        // The launcher writes oxide/data/Hotwire/launcher.json with its version, hash and
        // capabilities. We recompute the launcher's code hash from its own bytes (the same
        // way tools/launcher-hash.sh does) so the panel can tell an unmodified Hotwire
        // launcher from a modified or foreign one, and gate launcher-editing features on
        // what it actually advertises -- capabilities, not a version number. This is the
        // panel's confirmation that a "persist" or a wipe will really be carried out.
        private JObject LauncherIdentity()
        {
            var file = Path.Combine(Interface.Oxide.DataDirectory, "Hotwire", "launcher.json");
            if (!File.Exists(file)) return null;
            JObject declared;
            try { declared = JObject.Parse(File.ReadAllText(file)); }
            catch { return null; }

            var declaredHash = (string)declared["hash"] ?? "";
            var path = (string)declared["path"] ?? "";
            var caps = new JArray();
            foreach (var c in ((string)declared["capabilities"] ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var t = c.Trim();
                if (t.Length > 0) caps.Add(t);
            }

            // Verified only when the launcher file is present AND its recomputed hash matches
            // what it declared. A launcher that self-declares stock but has drifted comes back
            // verified=false, and the panel does not trust its capabilities.
            var verified = false;
            try
            {
                if (!string.IsNullOrEmpty(path) && !string.IsNullOrEmpty(declaredHash) && File.Exists(path))
                    verified = string.Equals(ComputeLauncherHash(path), declaredHash, StringComparison.OrdinalIgnoreCase);
            }
            catch { }

            return new JObject
            {
                ["version"] = (string)declared["version"] ?? "",
                ["platform"] = (string)declared["platform"] ?? "",
                ["hash"] = declaredHash,
                ["capabilities"] = caps,
                ["verified"] = verified,
            };
        }

        // Must match tools/launcher-hash.sh byte for byte: drop the SETTINGS block (both
        // markers inclusive) and the HOTWIRE_LAUNCHER_HASH line, right-trim each remaining
        // line, join with a newline after each, and SHA-256 the result.
        private static string ComputeLauncherHash(string path)
        {
            const string begin = "=== HOTWIRE SETTINGS BEGIN ===";
            const string end = "=== HOTWIRE SETTINGS END ===";
            var lines = File.ReadAllText(path).Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
            var count = lines.Length;
            // A file ending in \n yields a trailing empty element that awk never sees as a record.
            if (count > 0 && lines[count - 1].Length == 0) count--;

            var sb = new StringBuilder();
            var skip = false;
            for (var i = 0; i < count; i++)
            {
                var line = lines[i];
                if (line.IndexOf(begin, StringComparison.Ordinal) >= 0) skip = true;
                if (skip)
                {
                    if (line.IndexOf(end, StringComparison.Ordinal) >= 0) skip = false;
                    continue;
                }
                if (line.StartsWith("HOTWIRE_LAUNCHER_HASH=", StringComparison.Ordinal)) continue;
                sb.Append(line.TrimEnd(' ', '\t'));
                sb.Append('\n');
            }
            using (var sha = SHA256.Create())
                return Hex(sha.ComputeHash(Encoding.UTF8.GetBytes(sb.ToString())));
        }

        // Frames the engine actually ran since the last heartbeat, divided by the
        // time between them: the average, not a sample. The first heartbeat has
        // nothing to compare with and leaves it out.
        private int AverageFps()
        {
            var frames = Time.frameCount;
            var at = Time.realtimeSinceStartup;
            var result = -1;
            if (_fpsFrames >= 0 && at - _fpsAt >= 1f)
                result = (int)Math.Round((frames - _fpsFrames) / (at - _fpsAt));
            _fpsFrames = frames;
            _fpsAt = at;
            return result;
        }

        // The share of the whole machine's CPU this process used since the last
        // heartbeat, 0 to 100. The first heartbeat has nothing to compare with.
        private int AverageCpuPercent()
        {
            TimeSpan used;
            using (var process = System.Diagnostics.Process.GetCurrentProcess()) used = process.TotalProcessorTime;
            var at = DateTime.UtcNow;
            var result = -1;
            var seconds = (at - _cpuAt).TotalSeconds;
            if (_cpuMeasured && seconds >= 1)
            {
                var share = (used - _cpuUsed).TotalSeconds / seconds / Math.Max(1, Environment.ProcessorCount) * 100.0;
                result = (int)Math.Round(Math.Max(0.0, Math.Min(100.0, share)));
            }
            _cpuUsed = used;
            _cpuAt = at;
            _cpuMeasured = true;
            return result;
        }

        // Entities, memory, network and the join queue, from the game's own
        // serverinfo -- the figures RCON tools graph. Looked up by name while
        // running, so a Rust update that moves it drops these figures with a
        // warning instead of stopping the plugin compiling.
        private void AddServerInfo(JObject payload)
        {
            if (_serverInfoMissing) return;
            if (_serverInfo == null)
            {
                var game = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetName().Name == "Assembly-CSharp");
                var admin = game == null ? null : game.GetType("ConVar.Admin", false);
                _serverInfo = admin == null ? null : admin.GetMethod("ServerInfo", BindingFlags.Public | BindingFlags.Static, null, Type.EmptyTypes, null);
                if (_serverInfo == null)
                {
                    _serverInfoMissing = true;
                    PrintWarning("The game has no ConVar.Admin.ServerInfo, so the heartbeat carries no entity, memory or network figures. Everything else carries on.");
                    return;
                }
            }

            var info = _serverInfo.Invoke(null, null);
            if (info == null) return;
            CopyServerInfo(payload, info, "EntityCount", "entities");
            CopyServerInfo(payload, info, "MemoryUsageSystem", "memory_mb");
            CopyServerInfo(payload, info, "Memory", "managed_memory_mb");
            CopyServerInfo(payload, info, "NetworkIn", "network_in_bytes_per_second");
            CopyServerInfo(payload, info, "NetworkOut", "network_out_bytes_per_second");
            CopyServerInfo(payload, info, "Queued", "queued");
            CopyServerInfo(payload, info, "Joining", "joining");
        }

        private static void CopyServerInfo(JObject payload, object info, string field, string key)
        {
            var member = info.GetType().GetField(field, BindingFlags.Public | BindingFlags.Instance);
            if (member == null) return;
            var value = member.GetValue(info);
            if (value is int number && number >= 0) payload[key] = number;
        }

        // The build Steam installed, from the same manifest the launcher reads.
        // Read again only when the file changes.
        private string InstalledBuildId()
        {
            var root = ServerRoot();
            if (root == null) return null;
            var manifest = Path.Combine(Path.Combine(root, "steamapps"), BuildManifest);
            if (!File.Exists(manifest)) return null;

            var stamp = File.GetLastWriteTimeUtc(manifest);
            if (stamp != _manifestStamp)
            {
                _manifestStamp = stamp;
                var text = File.ReadAllText(manifest);
                var match = Regex.Match(text, "\"buildid\"\\s+\"(\\d+)\"");
                _buildId = match.Success ? match.Groups[1].Value : null;
                _branch = ManifestBranch(text);
            }
            return _buildId;
        }

        // The Steam branch that build came from, read from the same manifest.
        private string InstalledBranch()
        {
            return InstalledBuildId() == null ? null : _branch;
        }

        // ---------------------------------------------------------- session

        private const string SessionDataFile = "Hotwire/panel_session";

        // This server process as the plugin sees it: when it started, when it was
        // last known alive, and whether the game said it was shutting down. What
        // is still to be reported is kept with it, so a reload does not lose it.
        private sealed class SessionMarker
        {
            public DateTime StartedUtc;
            public DateTime LastAliveUtc;
            public bool CleanShutdown;
            public double? BootSeconds;
            public bool BootReported;
            public DateTime? PreviousStartedUtc;
            public DateTime? PreviousEndedUtc;
            public bool PreviousClean;
            public bool PreviousPending;
        }

        private SessionMarker _session;
        private Timer _sessionTimer;
        private string _sessionState = "not started";

        private void PrepareSession(bool initial)
        {
            var ticks = ProcessStartTicks();
            if (ticks == 0)
            {
                _sessionState = "the server process's start time cannot be read, so no session is reported";
                return;
            }

            var started = new DateTime(ticks, DateTimeKind.Utc);
            var now = DateTime.UtcNow;
            var saved = ReadData<SessionMarker>(SessionDataFile);

            if (saved != null && saved.StartedUtc == started)
            {
                _session = saved;   // a reload inside the same process: nothing new happened
            }
            else
            {
                _session = new SessionMarker
                {
                    StartedUtc = started,
                    LastAliveUtc = now,
                    // Only a real boot is timed. A plugin loaded into a running
                    // server cannot know how long the boot took.
                    BootSeconds = initial ? Math.Round((now - started).TotalSeconds, 2) : (double?)null
                };

                // What the last process never reported would be overwritten here:
                // keep it to send later instead, if this server reports anywhere.
                if (saved != null && _config.Panel.Enabled && File.Exists(PanelFile())) SpoolUnreportedSessions(saved);

                if (saved != null && saved.StartedUtc != default(DateTime))
                {
                    _session.PreviousStartedUtc = saved.StartedUtc;
                    _session.PreviousEndedUtc = saved.LastAliveUtc;
                    _session.PreviousClean = saved.CleanShutdown;
                    _session.PreviousPending = true;
                }

                WriteData(SessionDataFile, _session);
            }

            _sessionState = _session.BootReported ? "this boot reported" : "this boot not reported yet";
            _sessionTimer = timer.Every(300f, TouchSession);
        }

        // When the process was last known alive, so a run that ends without a
        // shutdown still has an approximate end.
        private void TouchSession()
        {
            if (_session == null) return;
            _session.LastAliveUtc = DateTime.UtcNow;
            WriteData(SessionDataFile, _session);
        }

        // Rust is shutting down on purpose. A run that ends without this was a
        // crash, a kill or a power loss.
        private void OnServerShutdown()
        {
            if (_session == null) return;
            _session.LastAliveUtc = DateTime.UtcNow;
            _session.CleanShutdown = true;
            WriteData(SessionDataFile, _session);
        }

        private bool SessionReportDue()
        {
            return _session != null && (_session.PreviousPending || (!_session.BootReported && _inventory != null));
        }

        // The previous run first, then this boot, as two session reports keyed
        // by when each run started.
        private void SendSession()
        {
            Action done;
            var body = BuildSessionReport(out done);
            PanelRequest("POST", PanelReportPath, body, response => done(), () => done(), onFailed: code =>
            {
                // Generated once: kept to send later rather than lost, and not also retried from memory.
                if (!SpoolKeepsStatus(code)) return;
                SpoolReport(body);
                done();
            });
        }

        // The next session report due: the previous run first, then this boot.
        private string BuildSessionReport(out Action done)
        {
            var session = _session;
            JObject payload;

            if (session.PreviousPending && session.PreviousStartedUtc != null)
            {
                payload = new JObject
                {
                    ["started_at"] = SessionTime(session.PreviousStartedUtc.Value),
                    ["ended_at"] = SessionTime(session.PreviousEndedUtc ?? session.PreviousStartedUtc.Value),
                    ["clean_shutdown"] = session.PreviousClean
                };
                done = () =>
                {
                    session.PreviousPending = false;
                    WriteData(SessionDataFile, session);
                };
            }
            else
            {
                payload = new JObject { ["started_at"] = SessionTime(session.StartedUtc) };
                if (session.BootSeconds != null) payload["boot_seconds"] = session.BootSeconds.Value;
                if (_inventory != null)
                {
                    payload["plugins_loaded"] = _inventory.Count(i => i.Loaded);
                    payload["compile_errors"] = new JArray(_inventory.Where(i => !i.Loaded && i.Error != null).Select(i => i.Name).ToArray());
                }
                try { var p = server.Protocol; if (!string.IsNullOrEmpty(p)) payload["rust_protocol"] = p; } catch { }
                try { var b = InstalledBuildId(); if (b != null) payload["rust_build_id"] = b; } catch { }
                done = () =>
                {
                    session.PreviousPending = false;
                    session.BootReported = true;
                    WriteData(SessionDataFile, session);
                    _sessionState = $"this boot reported {DateTime.Now:HH:mm:ss}";
                };
            }

            return PanelEnvelope("session", payload);
        }

        // Runs from before the previous process that were never told. Only what
        // is known is kept: a boot's plugin list is gone with its process.
        private void SpoolUnreportedSessions(SessionMarker saved)
        {
            try
            {
                if (saved.PreviousPending && saved.PreviousStartedUtc != null)
                {
                    SpoolReport(PanelEnvelope("session", new JObject
                    {
                        ["started_at"] = SessionTime(saved.PreviousStartedUtc.Value),
                        ["ended_at"] = SessionTime(saved.PreviousEndedUtc ?? saved.PreviousStartedUtc.Value),
                        ["clean_shutdown"] = saved.PreviousClean
                    }));
                }
                if (!saved.BootReported && saved.StartedUtc != default(DateTime))
                {
                    var boot = new JObject { ["started_at"] = SessionTime(saved.StartedUtc) };
                    if (saved.BootSeconds != null) boot["boot_seconds"] = saved.BootSeconds.Value;
                    SpoolReport(PanelEnvelope("session", boot));
                }
            }
            catch (Exception ex)
            {
                SpoolProblem("keep the previous run's session report", ex);
            }
        }

        private static string SessionTime(DateTime utc)
        {
            return utc.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture);
        }

        // ---------------------------------------------------------- plugin list

        // What is installed: every .cs file in the plugins folder, with its hash
        // and size, whether it loaded, and Oxide's error if it did not. The
        // plugin's own [Info] line names it, taken as written. Only these facts
        // leave the machine; the file itself never does.
        private void RefreshInventory()
        {
            var dir = Interface.Oxide.PluginDirectory;
            if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return;

            var loaded = new Dictionary<string, Plugin>(StringComparer.OrdinalIgnoreCase);
            foreach (var p in plugins.GetAll())
                if (p != null && !p.IsCorePlugin && !string.IsNullOrEmpty(p.Filename))
                    loaded[NormalizeFolder(p.Filename)] = p;

            Dictionary<string, string> errors = null;
            try { errors = Loader?.PluginErrors; } catch { }

            var items = new List<InventoryItem>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var path in Directory.GetFiles(dir, "*.cs"))
            {
                seen.Add(path);
                var info = new FileInfo(path);
                HashedFile hashed;
                if (!_fileHashes.TryGetValue(path, out hashed) || hashed.Stamp != info.LastWriteTimeUtc || hashed.Size != info.Length)
                {
                    byte[] bytes;
                    try { bytes = File.ReadAllBytes(path); }
                    catch { continue; }   // being written right now; the next check has it
                    using (var sha = SHA256.Create())
                        hashed = new HashedFile { Stamp = info.LastWriteTimeUtc, Size = bytes.LongLength, Sha256Hex = Hex(sha.ComputeHash(bytes)) };
                    hashed.HasInfo = ReadInfoAttribute(bytes, out hashed.Title, out hashed.Author, out hashed.Version);
                    _fileHashes[path] = hashed;
                }

                var fileName = Path.GetFileNameWithoutExtension(path);
                // The file name travels beside the [Info] title because Oxide reloads and
                // unloads by file name. It is not part of the plugin list hash.
                var item = new InventoryItem { Sha256Hex = hashed.Sha256Hex, Size = hashed.Size, File = fileName };

                Plugin plugin;
                item.Loaded = loaded.TryGetValue(NormalizeFolder(path), out plugin) && plugin.IsLoaded;

                if (hashed.HasInfo)
                {
                    item.Name = hashed.Title; item.Author = hashed.Author; item.Version = hashed.Version;
                }
                else if (plugin != null)
                {
                    item.Name = plugin.Title ?? fileName;
                    item.Author = plugin.Author ?? "";
                    item.Version = plugin.Version.ToString();
                }
                else
                {
                    item.Name = fileName;
                }

                if (!item.Loaded)
                {
                    string error;
                    if (errors != null && errors.TryGetValue(fileName, out error) && !string.IsNullOrEmpty(error))
                        item.Error = error.Length > 2000 ? error.Substring(0, 2000) : error;
                }

                items.Add(item);
            }

            foreach (var stale in _fileHashes.Keys.Where(k => !seen.Contains(k)).ToList())
                _fileHashes.Remove(stale);

            _inventory = items;
            _inventoryHash = InventoryHash(items.Select(i => new[] { i.Name, i.Author, i.Version, i.Sha256Hex }));
            if (_inventorySentHash == _inventoryHash)
                _inventoryState = $"{items.Count} plugin(s), unchanged since last sent";
        }

        private static readonly Regex InfoAttribute = new Regex(
            "\\[\\s*Info\\s*\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*,\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*,\\s*\"?([0-9][0-9A-Za-z.\\-+]*)\"?",
            RegexOptions.Compiled);

        // The bytes already read for the hash, decoded as File.ReadAllText decodes a
        // file: UTF-8 unless a byte order mark says otherwise.
        private static bool ReadInfoAttribute(byte[] bytes, out string title, out string author, out string version)
        {
            title = author = version = null;
            try
            {
                string text;
                using (var reader = new StreamReader(new MemoryStream(bytes), Encoding.UTF8, true))
                    text = reader.ReadToEnd();
                var match = InfoAttribute.Match(text);
                if (!match.Success) return false;
                title = Regex.Unescape(match.Groups[1].Value);
                author = Regex.Unescape(match.Groups[2].Value);
                version = match.Groups[3].Value;
                return title.Length > 0;
            }
            catch
            {
                return false;
            }
        }

        private void SendInventory()
        {
            var hash = _inventoryHash;
            var list = new JArray();
            foreach (var i in _inventory)
                list.Add(new JObject
                {
                    ["name"] = i.Name,
                    ["file"] = i.File,
                    ["author"] = i.Author,
                    ["version"] = i.Version,
                    ["sha256"] = "sha256:" + i.Sha256Hex,
                    ["size"] = i.Size,
                    ["loaded"] = i.Loaded,
                    ["error"] = i.Error
                });
            var count = _inventory.Count;

            PanelRequest("POST", PanelReportPath, PanelEnvelope("inventory", new JObject { ["inventory_hash"] = hash, ["plugins"] = list }), response =>
            {
                var first = _inventorySentHash == null;
                _inventorySentHash = hash;
                _inventoryState = $"{count} plugin(s), sent {DateTime.Now:HH:mm:ss}";
                Puts(first ? $"Sent the plugin list to the panel ({count} plugins)." : $"The plugin list changed; sent it to the panel ({count} plugins).");
            }, () =>
            {
                _inventorySentHash = hash;   // not again until the list changes
                _inventoryState = $"{count} plugin(s), REFUSED by the panel -- see the console";
            });
        }

        // ---------------------------------------------------------- map

        // The world's seed, size, custom map address and wipe time, and the map
        // markers other plugins placed. The panel shows the map from these.
        //
        // These live in the game's own types, which this plugin otherwise
        // never names: a Facepunch rename turns a named type into a compile
        // error, and a plugin that does not compile restarts nothing. So they
        // are looked up by name while running. If one has moved, map reporting
        // switches itself off with a warning and everything else carries on.

        private sealed class GameMap
        {
            public PropertyInfo Seed, Size, Url, Procedural, Name;
            public FieldInfo SaveCreated, ServerMapMarkers;
            public Type GenericRadius, VendingLabel;
            public FieldInfo Radius, Color1, Color2, Alpha, ShopName, ShopMachine;
        }

        private GameMap _gameMap;
        private bool _mapOff;
        private string _mapState = "not read yet";
        private DateTime _mapCheckDue = DateTime.MinValue;
        private DateTime _markersDue = DateTime.MinValue;
        private string _worldJson, _worldSentJson;
        private string _markersJson, _markersSentJson;
        private int _markerCount;

        // The raidable zones active now: Raidable Bases (ADR-0097) and Abandoned Bases (ADR-0055), each from its own
        // hooks. Keyed by rounded position, so an ended raid removes exactly the one it added, and one set because the
        // panel draws them the same way -- it labels the plugin's own unlabelled marker at that spot, and the circle is
        // already coloured by whatever put it there.
        private readonly Dictionary<string, JObject> _raids = new Dictionary<string, JObject>();
        private string _raidZonesJson, _raidZonesSentJson;
        private DateTime _raidZonesDue = DateTime.MinValue;

        private void RefreshMap()
        {
            try
            {
                if (_gameMap == null) _gameMap = FindGameMap();
                _worldJson = JsonConvert.SerializeObject(ReadWorld(_gameMap), Formatting.None);
                var markers = ReadMarkers(_gameMap);
                _markerCount = markers.Count;
                _markersJson = JsonConvert.SerializeObject(markers, Formatting.None);
            }
            catch (Exception ex)
            {
                var why = ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException.Message : ex.Message;
                _mapOff = true;
                _mapState = "OFF until the plugin reloads -- " + why;
                PrintWarning($"Map reporting is off until the plugin reloads: {why}. " +
                             "A Rust update may have moved something the map reads. Everything else carries on.");
            }
        }

        private static GameMap FindGameMap()
        {
            var game = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetName().Name == "Assembly-CSharp");
            if (game == null) throw new InvalidOperationException("the game assembly is not loaded");

            const BindingFlags staticMember = BindingFlags.Public | BindingFlags.Static;
            const BindingFlags instanceMember = BindingFlags.Public | BindingFlags.Instance;

            var world = GameType(game, "World");
            var save = GameType(game, "SaveRestore");
            var marker = GameType(game, "MapMarker");
            var radius = GameType(game, "MapMarkerGenericRadius");
            var label = GameType(game, "VendingMachineMapMarker");

            return new GameMap
            {
                Seed = Member(world.GetProperty("Seed", staticMember), "World.Seed"),
                Size = Member(world.GetProperty("Size", staticMember), "World.Size"),
                Url = Member(world.GetProperty("Url", staticMember), "World.Url"),
                Procedural = Member(world.GetProperty("Procedural", staticMember), "World.Procedural"),
                Name = Member(world.GetProperty("Name", staticMember), "World.Name"),
                SaveCreated = Member(save.GetField("SaveCreatedTime", staticMember), "SaveRestore.SaveCreatedTime"),
                ServerMapMarkers = Member(marker.GetField("serverMapMarkers", staticMember), "MapMarker.serverMapMarkers"),
                GenericRadius = radius,
                VendingLabel = label,
                Radius = Member(radius.GetField("radius", instanceMember), "MapMarkerGenericRadius.radius"),
                Color1 = Member(radius.GetField("color1", instanceMember), "MapMarkerGenericRadius.color1"),
                Color2 = Member(radius.GetField("color2", instanceMember), "MapMarkerGenericRadius.color2"),
                Alpha = Member(radius.GetField("alpha", instanceMember), "MapMarkerGenericRadius.alpha"),
                ShopName = Member(label.GetField("markerShopName", instanceMember), "VendingMachineMapMarker.markerShopName"),
                ShopMachine = Member(label.GetField("server_vendingMachine", instanceMember), "VendingMachineMapMarker.server_vendingMachine")
            };
        }

        private static Type GameType(Assembly game, string name)
        {
            var type = game.GetType(name, false);
            if (type == null) throw new InvalidOperationException($"the game has no type {name}");
            return type;
        }

        private static T Member<T>(T member, string name) where T : MemberInfo
        {
            if (member == null) throw new InvalidOperationException($"the game has no {name}");
            return member;
        }

        // Every value optional: one that cannot be read is left out.
        private static JObject ReadWorld(GameMap g)
        {
            var world = new JObject();

            var seed = g.Seed.GetValue(null, null);
            if (seed != null) world["seed"] = Convert.ToInt64(seed, CultureInfo.InvariantCulture);

            var size = g.Size.GetValue(null, null);
            if (size != null && Convert.ToInt64(size, CultureInfo.InvariantCulture) > 0) world["size"] = Convert.ToInt64(size, CultureInfo.InvariantCulture);

            var procedural = g.Procedural.GetValue(null, null);
            if (procedural is bool) world["procedural"] = (bool)procedural;

            var url = g.Url.GetValue(null, null) as string;
            world["level_url"] = string.IsNullOrWhiteSpace(url) ? null : url;

            var name = g.Name.GetValue(null, null) as string;
            if (!string.IsNullOrWhiteSpace(name)) world["map_name"] = name;

            var created = g.SaveCreated.GetValue(null);
            if (created is DateTime && (DateTime)created != default(DateTime))
                world["save_created_at"] = ((DateTime)created).ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture);

            return world;
        }

        // Only markers another plugin placed: generic radius circles, and text
        // labels that are not a real vending machine. A player's shop is left
        // out, because where it stands is where their base is.
        private static JArray ReadMarkers(GameMap g)
        {
            var result = new JArray();
            var all = g.ServerMapMarkers.GetValue(null) as System.Collections.IEnumerable;
            if (all == null) return result;

            foreach (var entry in all)
            {
                var component = entry as Component;
                if (component == null || component.transform == null) continue;
                var position = component.transform.position;

                if (g.GenericRadius.IsInstanceOfType(entry))
                {
                    var fill = (Color)g.Color1.GetValue(entry);
                    var outline = (Color)g.Color2.GetValue(entry);
                    result.Add(new JObject
                    {
                        ["type"] = "radius",
                        ["x"] = Math.Round(position.x, 1),
                        ["z"] = Math.Round(position.z, 1),
                        ["radius"] = Math.Round((float)g.Radius.GetValue(entry), 3),
                        ["color"] = HexColor(fill),
                        ["outline"] = HexColor(outline),
                        ["alpha"] = Math.Round(Mathf.Clamp01((float)g.Alpha.GetValue(entry)), 3)
                    });
                }
                else if (g.VendingLabel.IsInstanceOfType(entry))
                {
                    var machine = g.ShopMachine.GetValue(entry) as UnityEngine.Object;
                    if (machine != null) continue;   // a real shop
                    var text = g.ShopName.GetValue(entry) as string;
                    if (string.IsNullOrWhiteSpace(text)) continue;
                    result.Add(new JObject
                    {
                        ["type"] = "label",
                        ["x"] = Math.Round(position.x, 1),
                        ["z"] = Math.Round(position.z, 1),
                        ["label"] = text.Length > 200 ? text.Substring(0, 200) : text
                    });
                }
            }
            return result;
        }

        private static string HexColor(Color c)
        {
            Func<float, string> part = v => ((int)Math.Round(Mathf.Clamp01(v) * 255f)).ToString("X2", CultureInfo.InvariantCulture);
            return "#" + part(c.r) + part(c.g) + part(c.b);
        }

        private void SendWorld()
        {
            var json = _worldJson;
            PanelRequest("POST", PanelReportPath, PanelEnvelope("world", JObject.Parse(json)), response =>
            {
                _worldSentJson = json;
                _mapState = $"map sent {DateTime.Now:HH:mm:ss}; {_markerCount} marker(s)";
            }, () => { _worldSentJson = json; });
        }

        private void SendMarkers()
        {
            var json = _markersJson;
            var count = _markerCount;
            _markersDue = DateTime.UtcNow.AddSeconds(MarkerInterval());
            PanelRequest("POST", PanelReportPath, PanelEnvelope("map_markers", new JObject { ["markers"] = JArray.Parse(json) }), response =>
            {
                _markersSentJson = json;
                _mapState = $"map sent; {count} marker(s), last sent {DateTime.Now:HH:mm:ss}";
            }, () => { _markersSentJson = json; });
        }

        // ------------------------------------------------------ raidable bases

        // Oxide's Interface.CallHook(hook, object[] args) treats that array as the ARGUMENT LIST, not as one argument:
        // Oxide.Core's CSPlugin resizes a copy to the declared method's parameter count, drops the extra arguments, and
        // then type-checks. So a method declaring a single `object[] hookObjects` parameter is offered Raidable Bases'
        // FIRST argument (a Vector3) and never matches -- 1.1.17 and 1.1.18 subscribed to these hooks and were never
        // called once. The parameters below are that array positionally instead, which is how every other plugin reads
        // this hook.
        //
        // They are `object` rather than the real types for two reasons. Raidable Bases also fires a second, ONE-argument
        // OnRaidableBaseStarted(rb) with the base itself, which lands here too and would throw against a typed first
        // parameter; and a future Raidable Bases that reorders its array gives us a wrongly-typed value we ignore rather
        // than a hook that silently stops matching -- the failure this comment exists because of. Oxide accepts an
        // `object` parameter explicitly (HookMethod.HasMatchingSignature: `parameterType.FullName == "System.Object"`)
        // and invokes a non-exact match.
        //
        // The order is RaidableBases 3.1.8's `hookObjects` property, verified against warren's copy: Location,
        // Options.Level, AllowPVP, ID, 0f, 0f, loadTime, ownerId, GetOwner(), GetRaiders(), GetIntruders(), Entities,
        // BaseName, spawnDateTime, despawnDateTime, ProtectionRadius, GetLootAmountCounted(). We read four of them, and
        // must declare up to the last one we read.
        private void OnRaidableBaseStarted(object location, object level, object allowPvp, object id,
            object unused4, object unused5, object loadTime, object ownerId, object owner, object raiders,
            object intruders, object entities, object baseName, object spawnedAt, object despawnAt,
            object protectionRadius)
        {
            if (!_config.Panel.ReportMap) return;
            if (!(location is Vector3 loc)) return;   // the one-argument OnRaidableBaseStarted(rb) call arrives here too

            _raids[RaidKey(loc)] = RaidZone(loc, level, baseName, protectionRadius);
            RebuildRaidZones();
        }

        private void OnRaidableBaseEnded(object location) => RemoveRaid(location);

        private void OnRaidableBaseDespawned(object location) => RemoveRaid(location);

        // A raid's position rounds to a key so the Ended/Despawned hook removes exactly the one Started added.
        private void RemoveRaid(object location)
        {
            if (location is Vector3 loc && _raids.Remove(RaidKey(loc))) RebuildRaidZones();
        }

        // Abandoned Bases (nivex, 2.2.7) makes an inactive player's base raidable, and marks it with the same kind of
        // unlabelled circle Raidable Bases uses -- so the panel needs the same help to name it. Its hooks carry
        // object[11] { center, radius, AllowPVP, intruders, intruderIds, entities, privs, canDropBackpack, automatedEvent,
        // attackEvent, guid }, verified against warren's copy; we read the first two. Declared positionally for the reason
        // ADR-0054 exists, and `object` because OnAbandonedBaseDespawn is also fired with a plain List of entities, which
        // would throw against a typed first parameter.
        //
        // An abandoned base has no difficulty and no name to give: the panel labels it "Abandoned Base".
        private void OnAbandonedBaseStarted(object center, object radius)
        {
            if (!_config.Panel.ReportMap) return;
            if (!(center is Vector3 loc)) return;

            var zone = new JObject { ["x"] = Math.Round(loc.x, 1), ["z"] = Math.Round(loc.z, 1), ["type"] = "abandoned" };
            if (radius != null) { try { zone["radius"] = Math.Round(Convert.ToSingle(radius, CultureInfo.InvariantCulture), 1); } catch { } }

            _raids[RaidKey(loc)] = zone;
            RebuildRaidZones();
        }

        private void OnAbandonedBaseEnded(object center) => RemoveRaid(center);

        private void OnAbandonedBaseDespawn(object center) => RemoveRaid(center);

        private static string RaidKey(Vector3 loc)
        {
            return loc.x.ToString("0.0", CultureInfo.InvariantCulture) + "," + loc.z.ToString("0.0", CultureInfo.InvariantCulture);
        }

        // Each field is read with a guard, so a Raidable Bases that changes one of them gives a zone with fewer fields
        // rather than throwing inside a hook.
        private static JObject RaidZone(Vector3 loc, object level, object baseName, object protectionRadius)
        {
            var zone = new JObject { ["x"] = Math.Round(loc.x, 1), ["z"] = Math.Round(loc.z, 1) };
            if (level != null) { try { zone["difficulty"] = Convert.ToInt32(level, CultureInfo.InvariantCulture); } catch { } }
            if (protectionRadius != null) { try { zone["radius"] = Math.Round(Convert.ToSingle(protectionRadius, CultureInfo.InvariantCulture), 1); } catch { } }
            var name = baseName as string;
            if (!string.IsNullOrEmpty(name)) zone["name"] = name;
            return zone;
        }

        private void RebuildRaidZones()
        {
            var zones = new JArray();
            foreach (var zone in _raids.Values) zones.Add(zone);
            _raidZonesJson = new JObject { ["zones"] = zones }.ToString(Formatting.None);
        }

        private void SendRaidZones()
        {
            var json = _raidZonesJson;
            _raidZonesDue = DateTime.UtcNow.AddSeconds(60);   // at most once a minute, like the markers
            PanelRequest("POST", PanelReportPath, PanelEnvelope("raid_zones", JObject.Parse(json)), response =>
            {
                _raidZonesSentJson = json;
            }, () => { _raidZonesSentJson = json; });
        }

        // ---------------------------------------------------------- map layout

        // How the generator laid the world out: landmarks, roads, rails, rivers,
        // power lines, the train tunnel grid and the underwater labs. Fixed for
        // the life of a world, so it is sent once per map. What was sent is kept
        // in oxide/data so a restart sends nothing, and it is sent again after a
        // week in case the panel lost it. Looked up by name like the rest of the
        // map; non-public members too, because vanilla Rust marks these lists
        // internal and Oxide's build makes them public.

        private const string LayoutSentFile = "Hotwire/map_layout_sent";
        private const BindingFlags AnyInstance = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;

        private sealed class LayoutSent
        {
            public string KeyId;
            public string Map;
            public string Hash;
            public DateTime SentUtc;
        }

        private DateTime _layoutDue = DateTime.MinValue;
        private string _layoutDoneKey;
        private string _layoutState = "not sent yet";

        private void CheckMapLayout()
        {
            var key = MapKey();
            _layoutDue = DateTime.UtcNow.AddMinutes(10);

            JObject layout;
            try
            {
                layout = ReadLayout();
            }
            catch (Exception ex)
            {
                var why = ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException.Message : ex.Message;
                _layoutDoneKey = key;   // not again until the map changes or the plugin reloads
                _layoutState = "OFF for this map -- " + why;
                PrintWarning($"The map layout could not be read: {why}. A Rust update may have moved something it reads. Everything else carries on.");
                return;
            }

            var parts = key.Split('/');
            layout["seed"] = long.Parse(parts[0], CultureInfo.InvariantCulture);
            layout["size"] = long.Parse(parts[1], CultureInfo.InvariantCulture);
            var json = JsonConvert.SerializeObject(layout, Formatting.None);

            string hash;
            using (var sha = SHA256.Create()) hash = "sha256:" + Hex(sha.ComputeHash(Encoding.UTF8.GetBytes(json)));

            var sent = ReadData<LayoutSent>(LayoutSentFile);
            if (sent != null && sent.KeyId == _panel.KeyId && sent.Map == key && sent.Hash == hash && DateTime.UtcNow - sent.SentUtc < TimeSpan.FromDays(7))
            {
                _layoutDoneKey = key;
                _layoutState = $"already sent {sent.SentUtc.ToLocalTime():yyyy-MM-dd HH:mm}";
                return;
            }

            var kilobytes = json.Length / 1024;
            _layoutState = $"sending the map layout ({kilobytes} KB)";
            PanelRequest("POST", PanelReportPath, PanelEnvelope("map_layout", layout), response =>
            {
                _layoutDoneKey = key;
                _layoutState = $"sent {DateTime.Now:HH:mm:ss} ({kilobytes} KB)";
                WriteData(LayoutSentFile, new LayoutSent { KeyId = _panel?.KeyId, Map = key, Hash = hash, SentUtc = DateTime.UtcNow });
                Puts($"Sent the map layout to the panel ({kilobytes} KB).");
            }, () =>
            {
                _layoutState = "the panel refused the map layout -- see the console; tried again in an hour";
                _layoutDue = DateTime.UtcNow.AddHours(1);
            }, 60f);
        }

        // Each part is read on its own: one the game no longer has is left out
        // of the report, which the panel reads as unknown, not as none.
        private JObject ReadLayout()
        {
            var game = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetName().Name == "Assembly-CSharp");
            if (game == null) throw new InvalidOperationException("the game assembly is not loaded");

            var terrainMeta = GameType(game, "TerrainMeta");
            var path = Member(terrainMeta.GetProperty("Path", BindingFlags.Public | BindingFlags.Static), "TerrainMeta.Path").GetValue(null, null);
            if (path == null) throw new InvalidOperationException("the world has no TerrainMeta.Path yet");

            var layout = new JObject();
            var problems = new List<string>();
            Action<string, Func<JToken>> part = (name, read) =>
            {
                try { layout[name] = read(); }
                catch (Exception ex) { problems.Add(name + ": " + (ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException.Message : ex.Message)); }
            };

            part("landmarks", () => ReadLandmarks(game, path));
            part("paths", () => ReadPaths(path));
            part("tunnels", () => ReadTunnels(path));
            part("labs", () => ReadLabs(path));

            if (problems.Count > 0)
                PrintWarning("Part of the map layout could not be read and is left out: " + string.Join("; ", problems.ToArray()));
            if (layout.Count == 0) throw new InvalidOperationException("no part of it could be read");
            return layout;
        }

        private static System.Collections.IEnumerable LayoutList(object path, string name)
        {
            var field = Member(path.GetType().GetField(name, AnyInstance), "TerrainPath." + name);
            var list = field.GetValue(path) as System.Collections.IEnumerable;
            if (list == null) throw new InvalidOperationException($"TerrainPath.{name} is empty");
            return list;
        }

        private static object FieldOf(object target, string name)
        {
            var field = Member(target.GetType().GetField(name, AnyInstance), target.GetType().Name + "." + name);
            return field.GetValue(target);
        }

        private static JToken ReadLandmarks(Assembly game, object path)
        {
            var monument = GameType(game, "MonumentInfo");
            var result = new JArray();
            foreach (var entry in LayoutList(path, "Landmarks"))
            {
                var component = entry as Component;
                if (component == null || component.transform == null) continue;
                var position = component.transform.position;

                var o = new JObject
                {
                    ["x"] = Math.Round(position.x, 1),
                    ["z"] = Math.Round(position.z, 1),
                    ["on_map"] = (bool)FieldOf(entry, "shouldDisplayOnMap")
                };

                var phrase = FieldOf(entry, "displayPhrase");
                var english = PhraseText(phrase, "english");
                var token = PhraseText(phrase, "token");
                if (english != null) o["name"] = english;
                if (token != null) o["token"] = token;
                var root = component.transform.root;
                if (root != null && !string.IsNullOrEmpty(root.name)) o["prefab"] = root.name;

                var layer = entry.GetType().GetProperty("MapLayer", BindingFlags.Public | BindingFlags.Instance);
                if (layer != null) o["layer"] = layer.GetValue(entry, null)?.ToString();

                if (monument.IsInstanceOfType(entry))
                {
                    o["monument_type"] = FieldOf(entry, "Type")?.ToString();
                    o["safe_zone"] = (bool)FieldOf(entry, "IsSafeZone");
                    o["tunnel_link"] = (bool)FieldOf(entry, "HasDungeonLink");
                }
                result.Add(o);
            }
            return result;
        }

        private static string PhraseText(object phrase, string name)
        {
            if (phrase == null) return null;
            var field = phrase.GetType().GetField(name, AnyInstance);
            var value = field != null ? field.GetValue(phrase) as string : phrase.GetType().GetProperty(name, AnyInstance)?.GetValue(phrase, null) as string;
            return string.IsNullOrWhiteSpace(value) ? null : value;
        }

        private static JToken ReadPaths(object path)
        {
            var main = new HashSet<object>(LayoutList(path, "MainRoads").Cast<object>());
            var side = new HashSet<object>(LayoutList(path, "SideRoads").Cast<object>());
            var trail = new HashSet<object>(LayoutList(path, "TrailRoads").Cast<object>());

            var result = new JArray();
            foreach (var list in new[] { new[] { "Roads", "road" }, new[] { "Rails", "rail" }, new[] { "Rivers", "river" }, new[] { "Powerlines", "powerline" } })
            {
                foreach (var entry in LayoutList(path, list[0]))
                {
                    if (entry == null) continue;
                    var interpolator = FieldOf(entry, "Path");
                    var points = interpolator == null ? null : FieldOf(interpolator, "Points") as Vector3[];
                    if (points == null || points.Length < 2) continue;

                    var line = new JArray();
                    foreach (var point in points)
                        line.Add(new JArray((long)Math.Round(point.x), (long)Math.Round(point.z)));

                    var o = new JObject { ["type"] = list[1] };
                    var name = FieldOf(entry, "Name") as string;
                    if (!string.IsNullOrEmpty(name)) o["name"] = name;
                    o["width"] = Math.Round((float)FieldOf(entry, "Width"), 1);
                    if (list[1] == "road")
                    {
                        if (main.Contains(entry)) o["road_class"] = "main";
                        else if (side.Contains(entry)) o["road_class"] = "side";
                        else if (trail.Contains(entry)) o["road_class"] = "trail";
                    }
                    o["points"] = line;
                    result.Add(o);
                }
            }
            return result;
        }

        private static JToken ReadTunnels(object path)
        {
            var cells = new JArray();
            foreach (var entry in LayoutList(path, "DungeonGridCells"))
            {
                var component = entry as Component;
                if (component == null || component.transform == null) continue;
                var position = component.transform.position;
                cells.Add(new JObject
                {
                    ["x"] = Math.Round(position.x, 1),
                    ["z"] = Math.Round(position.z, 1),
                    ["north"] = Connected(FieldOf(entry, "North")),
                    ["south"] = Connected(FieldOf(entry, "South")),
                    ["west"] = Connected(FieldOf(entry, "West")),
                    ["east"] = Connected(FieldOf(entry, "East"))
                });
            }

            var entrances = new JArray();
            object cellSize = null;
            foreach (var entry in LayoutList(path, "DungeonGridEntrances"))
            {
                var component = entry as Component;
                if (component == null || component.transform == null) continue;
                var position = component.transform.position;
                entrances.Add(new JObject { ["x"] = Math.Round(position.x, 1), ["z"] = Math.Round(position.z, 1) });
                if (cellSize == null) cellSize = FieldOf(entry, "CellSize");
            }

            var tunnels = new JObject { ["cells"] = cells, ["entrances"] = entrances };
            // The cell size lives on an entrance; a world with none leaves it out rather than guessing it.
            if (cellSize != null) tunnels["cell_size"] = Convert.ToDouble(cellSize, CultureInfo.InvariantCulture);
            return tunnels;
        }

        // DungeonGridConnectionType: None or TrainTunnel.
        private static bool Connected(object connection) => connection != null && connection.ToString() != "None";

        private static JToken ReadLabs(object path)
        {
            var labs = new JArray();
            foreach (var entry in LayoutList(path, "DungeonBaseEntrances"))
            {
                var component = entry as Component;
                if (component == null || component.transform == null) continue;
                var position = component.transform.position;

                var floors = new JArray();
                foreach (var floor in (FieldOf(entry, "Floors") as System.Collections.IEnumerable) ?? new object[0])
                {
                    var pieces = new JArray();
                    foreach (var link in (FieldOf(floor, "Links") as System.Collections.IEnumerable) ?? new object[0])
                    {
                        var piece = link as Component;
                        if (piece == null || piece.transform == null) continue;
                        var at = piece.transform.position;
                        pieces.Add(new JObject
                        {
                            ["x"] = Math.Round(at.x, 1),
                            ["z"] = Math.Round(at.z, 1),
                            ["type"] = FieldOf(link, "Type")?.ToString()
                        });
                    }
                    floors.Add(pieces);
                }

                labs.Add(new JObject { ["x"] = Math.Round(position.x, 1), ["z"] = Math.Round(position.z, 1), ["floors"] = floors });
            }
            return labs;
        }

        // ---------------------------------------------------------- map image

        // The image Rust renders of this map for the Rust+ app at startup
        // (CompanionServer.Handlers.Map.ImageData: MapImageRenderer.Render at
        // scale 0.5, JPEG, 500 px of ocean around the world). The panel is asked
        // first whether it already holds this map's image, so a restart sends
        // nothing. Looked up by name, like the rest of the map.

        private const string MapRenderPath = "/api/v1/map-render";

        private DateTime _imageDue = DateTime.MinValue;
        private string _imageDoneKey;
        private string _imageState = "not checked yet";

        private string MapKey()
        {
            try
            {
                var world = JObject.Parse(_worldJson ?? "{}");
                if (world["seed"] == null || world["size"] == null) return null;
                return (string)world["seed"] + "/" + (string)world["size"];
            }
            catch { return null; }
        }

        private void CheckMapImage()
        {
            var key = MapKey();
            if (key == null) { _imageDue = DateTime.UtcNow.AddMinutes(10); return; }
            var parts = key.Split('/');
            long seed = long.Parse(parts[0], CultureInfo.InvariantCulture);
            long size = long.Parse(parts[1], CultureInfo.InvariantCulture);

            _imageDue = DateTime.UtcNow.AddMinutes(10);
            PanelRequest("GET", MapRenderPath, null, response =>
            {
                var held = PanelData(response)["render"] as JObject;
                if (held != null && (long?)held["seed"] == seed && (long?)held["size"] == size)
                {
                    // The panel has this map -- keep it, unless we can now render meaningfully sharper than what it holds.
                    var heldWidth = (int?)held["render_width"] ?? 0;
                    if (!_config.Panel.RenderMapImage || heldWidth >= WouldRenderWidth(size) - 64)
                    {
                        _imageDoneKey = key;
                        _imageState = heldWidth > 0 ? $"the panel has this map's image ({heldWidth} px)" : "the panel has this map's image";
                        return;
                    }
                    _imageState = $"the panel's image is {heldWidth} px; rendering a sharper one";
                    // fall through to render and send a sharper image
                }

                string source;
                var bytes = MapImageBytes(size, out source);
                if (bytes == null) return;   // said why in MapImageBytes; tried again later

                SendMapImage(key, seed, size, bytes, source);
            });
        }

        // The margin, in pixels of the render, the game draws around the world. MapImageRenderer keeps it fixed at any scale.
        private const int MapOceanMarginPixels = 500;

        // The panel keeps a map image at most this many pixels on a side, then downsizes; render to about this and no larger,
        // so no detail is wasted and the upload stays small.
        private const float MapTargetPixels = 4096f;

        // The image width MapImageRenderer would produce for this world at our target scale: the world at that scale plus a
        // margin each side. Used to decide whether the panel's held image is already sharp enough.
        private static int WouldRenderWidth(long worldSize)
        {
            var scale = worldSize > 0
                ? Mathf.Clamp((MapTargetPixels - 2f * MapOceanMarginPixels) / worldSize, 0.5f, 4f)
                : 0.5f;
            return (int)Math.Round(worldSize * scale) + 2 * MapOceanMarginPixels;
        }

        private byte[] MapImageBytes(long worldSize, out string source)
        {
            source = null;
            try
            {
                var game = AppDomain.CurrentDomain.GetAssemblies().FirstOrDefault(a => a.GetName().Name == "Assembly-CSharp");
                if (game == null) throw new InvalidOperationException("the game assembly is not loaded");

                // Our own render is preferred over Rust+'s cached image: Rust+ renders at scale 0.5, and a sharper map is
                // worth a few seconds of the server's time once per map. Rust+'s image is the fallback if rendering is off or
                // has not settled or fails.
                if (_config.Panel.RenderMapImage)
                {
                    if (Time.realtimeSinceStartup < 120f)
                    {
                        _imageState = "waiting for the server to settle before rendering the map image";
                        _imageDue = DateTime.UtcNow.AddSeconds(Math.Max(10, 120 - Time.realtimeSinceStartup));
                        return null;
                    }

                    var renderer = GameType(game, "MapImageRenderer");
                    var render = renderer.GetMethods(BindingFlags.Public | BindingFlags.Static)
                        .FirstOrDefault(m => m.Name == "Render" && RenderSignatureMatches(m.GetParameters()));
                    if (render == null) throw new InvalidOperationException("the game's MapImageRenderer.Render has a different shape now");

                    // Scale so the image is about MapTargetPixels on a side (world + two margins), never below the game's own
                    // 0.5 and never absurdly large. Then: out width, out height, out background, scale, lossy, transparent,
                    // oceanMargin -- the same call Rust+ makes, framed the same way, only sharper.
                    var scale = worldSize > 0
                        ? Mathf.Clamp((MapTargetPixels - 2f * MapOceanMarginPixels) / worldSize, 0.5f, 4f)
                        : 0.5f;
                    var args = new object[] { 0, 0, new Color(), scale, true, false, MapOceanMarginPixels };
                    var started = DateTime.UtcNow;
                    var rendered = render.Invoke(null, args) as byte[];
                    if (rendered != null && rendered.Length > 0)
                    {
                        Puts($"Rendered the map image for the panel ({args[0]} x {args[1]} px, scale {scale:0.00}, {(DateTime.UtcNow - started).TotalSeconds:0.0}s).");
                        source = "plugin_render";
                        return rendered;
                    }
                    // The render came back empty; fall through to Rust+'s cached image if it has one.
                }

                var cache = game.GetType("CompanionServer.Handlers.Map", false);
                var imageData = cache?.GetProperty("ImageData", BindingFlags.Public | BindingFlags.Static);
                var cached = imageData?.GetValue(null, null) as byte[];
                if (cached != null && cached.Length > 0) { source = "rust_plus"; return cached; }

                _imageState = _config.Panel.RenderMapImage
                    ? "the game could not render the map image yet, and Rust+ has none cached"
                    : "Rust+ has no map image (is app.port -1?) and rendering it is off in the config";
                _imageDue = DateTime.UtcNow.AddMinutes(_config.Panel.RenderMapImage ? 30 : 360);
                return null;
            }
            catch (Exception ex)
            {
                var why = ex is TargetInvocationException && ex.InnerException != null ? ex.InnerException.Message : ex.Message;
                _imageState = "OFF until the plugin reloads -- " + why;
                _imageDoneKey = MapKey();   // not again for this map this session
                PrintWarning($"The map image is not sent: {why}. Everything else carries on.");
                return null;
            }
        }

        private static bool RenderSignatureMatches(ParameterInfo[] p)
        {
            return p.Length == 7
                && p[0].ParameterType == typeof(int).MakeByRefType()
                && p[1].ParameterType == typeof(int).MakeByRefType()
                && p[2].ParameterType == typeof(Color).MakeByRefType()
                && p[3].ParameterType == typeof(float)
                && p[4].ParameterType == typeof(bool)
                && p[5].ParameterType == typeof(bool)
                && p[6].ParameterType == typeof(int);
        }

        private void SendMapImage(string key, long seed, long size, byte[] bytes, string source)
        {
            // The policy may have changed while the image was rendered; it is tried again later.
            if (!PolicyAllowsKind("map_render")) return;
            string hash;
            using (var sha = SHA256.Create()) hash = "sha256:" + Hex(sha.ComputeHash(bytes));

            var body = JsonConvert.SerializeObject(new JObject
            {
                ["seed"] = seed,
                ["size"] = size,
                ["sha256"] = hash,
                ["source"] = source,
                ["image_base64"] = Convert.ToBase64String(bytes)
            }, Formatting.None);

            var kilobytes = bytes.Length / 1024;
            _imageState = $"sending the map image ({kilobytes} KB)";
            PanelRequest("POST", MapRenderPath, body, response =>
            {
                _imageDoneKey = key;
                _imageState = $"sent the map image {DateTime.Now:HH:mm:ss} ({kilobytes} KB, {(source == "rust_plus" ? "from Rust+" : "rendered")})";
                Puts($"Sent the map image to the panel ({kilobytes} KB).");
            }, () =>
            {
                _imageState = "the panel refused the map image -- see the console; tried again in an hour";
                _imageDue = DateTime.UtcNow.AddHours(1);
            }, 120f);
        }

        // ---------------------------------------------------------- schedule

        // The restart and update schedule is Hotwire's own, so it is reported
        // as it stands and can be changed from the panel -- through the same
        // checks the chat commands use, never by writing the config file from
        // outside. A change is refused if the schedule moved here since the
        // panel last saw it, so an edit made in game is never silently undone.

        private DateTime _scheduleCheckDue = DateTime.MinValue;
        private string _scheduleJson;
        private string _scheduleSentJson;
        private string _scheduleState = "not sent yet";

        private static bool BoolArg(JObject args, string name)
        {
            var token = args[name];
            if (token == null) return false;
            if (token.Type == JTokenType.Boolean) return (bool)token;
            var text = token.ToString().Trim();
            return text == "1" || text.Equals("true", StringComparison.OrdinalIgnoreCase);
        }

        private JObject EntryState(ScheduleEntry e, string list)
        {
            var o = new JObject
            {
                ["list"] = list,
                ["id"] = e.Id ?? "",
                ["time"] = e.Time ?? "",
                ["repeat"] = Normalize(e.Repeat),
                ["days"] = new JArray((e.Days ?? new List<string>()).Select(d => (object)d).ToArray()),
                ["ordinal"] = e.Ordinal ?? "",
                ["day_of_month"] = e.DayOfMonth,
                ["interval_days"] = e.IntervalDays,
                ["anchor_date"] = e.AnchorDate ?? "",
                ["date"] = e.Date ?? "",
                ["enabled"] = e.Enabled
            };
            if (e is UpdateEntry) o["validate"] = ((UpdateEntry)e).Validate;
            return o;
        }

        // Every stored field of every entry, in a fixed order: what a schedule
        // change is checked against.
        private string ScheduleHash()
        {
            var all = new JArray();
            foreach (var e in _config.Restarts) all.Add(EntryState(e, "restarts"));
            foreach (var e in _config.Updates) all.Add(EntryState(e, "updates"));
            return "sha256:" + Sha256Hex(JsonConvert.SerializeObject(all, Formatting.None));
        }

        private void RefreshSchedule()
        {
            try
            {
                var now = DateTime.Now;
                Func<ScheduleEntry, string, JObject> row = (e, list) =>
                {
                    var o = EntryState(e, list);
                    o.Remove("list");
                    string description;
                    try { description = Describe(e, null); } catch { description = null; }
                    o["description"] = description;
                    var problem = ValidationError(e);
                    o["problem"] = problem == null ? null : Text(problem, null);
                    DateTime? next = null;
                    if (e.Enabled && problem == null) { try { next = NextOccurrence(e, now); } catch { next = null; } }
                    o["next_at"] = next == null ? null : next.Value.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture);
                    return o;
                };

                var payload = new JObject
                {
                    ["schedule_hash"] = ScheduleHash(),
                    ["timezone"] = TimeZoneInfo.Local.Id,
                    ["restarts"] = new JArray(_config.Restarts.Select(e => (object)row(e, "restarts")).ToArray()),
                    ["updates"] = new JArray(_config.Updates.Select(e => (object)row(e, "updates")).ToArray()),
                    ["countdown"] = new JObject
                    {
                        ["start_seconds"] = _config.Countdown.StartSeconds,
                        ["announce_at"] = new JArray(_config.Countdown.AnnounceAt.Select(x => (object)x).ToArray())
                    },
                    ["framework_check"] = new JObject
                    {
                        ["enabled"] = _config.Framework.Enabled,
                        ["check_every_minutes"] = _config.Framework.CheckIntervalMinutes,
                        ["update_at"] = _config.Framework.UpdateAt,
                        ["validate"] = _config.Framework.Validate
                    },
                    ["active"] = !_countdownActive ? null : new JObject
                    {
                        ["kind"] = _countdownIsValidate ? "validate" : _countdownIsUpdate ? "update" : "restart",
                        ["at"] = _countdownTarget.ToUniversalTime().ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture),
                        ["entry_id"] = _countdownEntry == null ? null : _countdownEntry.Id,
                        ["shutting_down"] = _shuttingDown
                    }
                };
                _scheduleJson = JsonConvert.SerializeObject(payload, Formatting.None);
            }
            catch (Exception ex)
            {
                _scheduleState = "could not be read: " + ex.Message;
            }
        }

        private void SendSchedule()
        {
            var json = _scheduleJson;
            var payload = JObject.Parse(json);
            var offset = TimeZoneInfo.Local.GetUtcOffset(DateTime.Now);
            payload["utc_offset_minutes"] = (int)offset.TotalMinutes;
            payload["server_time"] = DateTime.Now.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss", CultureInfo.InvariantCulture);
            PanelRequest("POST", PanelReportPath, PanelEnvelope("schedule", payload), response =>
            {
                _scheduleSentJson = json;
                _scheduleState = $"sent {DateTime.Now:HH:mm:ss}";
            }, () => { _scheduleSentJson = json; });
        }

        private void RunScheduleCommand(string verb, JObject args, out string status, out string result)
        {
            if (!_config.Panel.AcceptScheduleChanges)
            {
                status = "refused";
                result = "schedule changes from the panel are off in this server's Hotwire config";
                return;
            }

            var expected = (string)args["schedule_hash"];
            if (!string.IsNullOrEmpty(expected) && expected != ScheduleHash())
            {
                _scheduleCheckDue = DateTime.MinValue;
                status = "refused";
                result = "the schedule changed on the server since the panel last saw it; the panel now has the current one, so check it and try again";
                return;
            }

            if (verb == "schedule.add")
            {
                var listName = ((string)args["list"] ?? "").ToLowerInvariant();
                if (listName != "restarts" && listName != "updates") { status = "refused"; result = "list must be restarts or updates"; return; }
                string problem;
                var entry = BuildEntry(null, listName == "updates", args["entry"] as JObject, out problem);
                if (entry == null) { status = "refused"; result = problem; return; }
                entry.Id = NewEntryId();
                if (listName == "updates") _config.Updates.Add((UpdateEntry)entry); else _config.Restarts.Add(entry);
                SaveConfig();
                _scheduleCheckDue = DateTime.MinValue;
                status = "done"; result = "added: " + Describe(entry, null);
                Puts($"The panel added a schedule entry: {Describe(entry, null)}.");
                return;
            }

            var id = ((string)args["id"] ?? "").Trim();
            ScheduleEntry target = null;
            var inUpdates = false;
            foreach (var e in _config.Restarts) if (e.Id == id) target = e;
            foreach (var e in _config.Updates) if (e.Id == id) { target = e; inUpdates = true; }
            if (id.Length == 0 || target == null) { status = "refused"; result = "there is no schedule entry with that id here"; return; }

            switch (verb)
            {
                case "schedule.update":
                {
                    string problem;
                    var draft = BuildEntry(target, inUpdates, args["entry"] as JObject, out problem);
                    if (draft == null) { status = "refused"; result = problem; return; }
                    CancelCountdownFor(target, "the panel");
                    target.Time = draft.Time;
                    target.Repeat = draft.Repeat;
                    target.Days = draft.Days;
                    target.Ordinal = draft.Ordinal;
                    target.DayOfMonth = draft.DayOfMonth;
                    target.IntervalDays = draft.IntervalDays;
                    target.AnchorDate = draft.AnchorDate;
                    target.Date = draft.Date;
                    target.Enabled = draft.Enabled;
                    if (target is UpdateEntry && draft is UpdateEntry) ((UpdateEntry)target).Validate = ((UpdateEntry)draft).Validate;
                    status = "done"; result = "changed: " + Describe(target, null);
                    break;
                }
                case "schedule.remove":
                    CancelCountdownFor(target, "the panel");
                    if (inUpdates) _config.Updates.Remove((UpdateEntry)target); else _config.Restarts.Remove(target);
                    status = "done"; result = "removed: " + Describe(target, null);
                    break;
                case "schedule.enable":
                {
                    var problem = ValidationError(target);
                    if (problem != null) { status = "refused"; result = "it cannot be enabled: " + Text(problem, null); return; }
                    target.Enabled = true;
                    status = "done"; result = "enabled: " + Describe(target, null);
                    break;
                }
                default: // schedule.disable
                    CancelCountdownFor(target, "the panel");
                    target.Enabled = false;
                    status = "done"; result = "disabled: " + Describe(target, null);
                    break;
            }

            ValidateSchedule();
            SaveConfig();
            _scheduleCheckDue = DateTime.MinValue;
            Puts($"The panel changed the schedule ({verb}): {result}.");
        }

        // A checked copy of an entry with the given fields applied, or null and
        // why not. Each field is validated the way the chat commands validate
        // it, then the whole entry by ValidationError.
        private ScheduleEntry BuildEntry(ScheduleEntry from, bool isUpdate, JObject fields, out string problem)
        {
            problem = null;
            if (fields == null) { problem = "no entry was given"; return null; }

            ScheduleEntry draft = isUpdate ? new UpdateEntry() : new ScheduleEntry();
            if (from != null)
            {
                draft.Time = from.Time; draft.Repeat = from.Repeat;
                draft.Days = from.Days == null ? new List<string>() : new List<string>(from.Days);
                draft.Ordinal = from.Ordinal; draft.DayOfMonth = from.DayOfMonth; draft.IntervalDays = from.IntervalDays;
                draft.AnchorDate = from.AnchorDate; draft.Date = from.Date; draft.Enabled = from.Enabled;
                if (isUpdate && from is UpdateEntry) ((UpdateEntry)draft).Validate = ((UpdateEntry)from).Validate;
            }
            else
            {
                draft.Enabled = true;
            }

            if (fields["time"] != null)
            {
                var time = ((string)fields["time"] ?? "").Trim();
                if (ParseTime(time) == null) { problem = $"{time} is not a time; use HH:mm, 24-hour"; return null; }
                draft.Time = time;
            }
            if (fields["repeat"] != null)
            {
                var repeat = Normalize((string)fields["repeat"]);
                if (!RepeatModes.Contains(repeat)) { problem = $"{fields["repeat"]} is not a repeat; use one of {string.Join(", ", RepeatModes)}"; return null; }
                var wasEveryN = Normalize(draft.Repeat) == RepeatEveryNDays;
                draft.Repeat = repeat;
                if (repeat == RepeatEveryNDays && !wasEveryN && fields["anchor_date"] == null) draft.AnchorDate = DateTime.Now.ToString("yyyy-MM-dd");
            }
            if (fields["days"] is JArray)
            {
                var days = new List<string>();
                foreach (var token in (JArray)fields["days"])
                {
                    var day = ParseDay(token.ToString());
                    if (day == null) { problem = $"{token} is not a day"; return null; }
                    if (!days.Contains(day.Value.ToString())) days.Add(day.Value.ToString());
                }
                draft.Days = days;
            }
            if (fields["ordinal"] != null)
            {
                var ordinal = Ordinals.FirstOrDefault(o => string.Equals(o, (string)fields["ordinal"], StringComparison.OrdinalIgnoreCase));
                if (ordinal == null) { problem = $"{fields["ordinal"]} is not one of {string.Join(", ", Ordinals)}"; return null; }
                draft.Ordinal = ordinal;
            }
            if (fields["day_of_month"] != null)
            {
                int dom;
                if (!int.TryParse(fields["day_of_month"].ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out dom)) { problem = "day_of_month is not a whole number"; return null; }
                draft.DayOfMonth = dom;
            }
            if (fields["interval_days"] != null)
            {
                int interval;
                if (!int.TryParse(fields["interval_days"].ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out interval)) { problem = "interval_days is not a whole number"; return null; }
                draft.IntervalDays = interval;
            }
            if (fields["date"] != null) draft.Date = ((string)fields["date"] ?? "").Trim();
            if (fields["anchor_date"] != null)
            {
                var anchor = ((string)fields["anchor_date"] ?? "").Trim();
                if (anchor.Length > 0 && ParseDate(anchor) == null) { problem = $"{anchor} is not a date; use yyyy-MM-dd"; return null; }
                draft.AnchorDate = anchor;
            }
            if (fields["enabled"] != null) draft.Enabled = BoolArg(fields, "enabled");
            if (isUpdate && fields["validate"] != null) ((UpdateEntry)draft).Validate = BoolArg(fields, "validate");

            var invalid = ValidationError(draft);
            if (invalid != null) { problem = Text(invalid, null); return null; }
            return draft;
        }

        // ---------------------------------------------------------- commands

        private void PollCommands()
        {
            _commandsDue = DateTime.UtcNow.AddSeconds(CommandInterval());
            PanelRequest("GET", PanelCommandsPath, null, response =>
            {
                var commands = PanelData(response)["commands"] as JArray;
                _commandsState = $"checked {DateTime.Now:HH:mm:ss}";
                if (commands == null) return;
                foreach (var c in commands.OfType<JObject>()) ReceiveCommand(c);
            }, signedResponse: true);
        }

        private void ReceiveCommand(JObject command)
        {
            var id = (string)command["id"];
            if (string.IsNullOrEmpty(id)) return;

            // Already carried out: the panel did not hear back and sent it again.
            // Say what happened instead of doing it twice. A restart that is
            // repeated after the server came back up is exactly the harm this
            // stops.
            HandledCommand done;
            if (_handledCommands.TryGetValue(id, out done))
            {
                QueueCommandResult(id, "received", null);
                QueueCommandResult(id, done.Status, done.Result);
                return;
            }

            var verb = ((string)command["verb"] ?? "").ToLowerInvariant();
            var args = command["args"] as JObject ?? new JObject();

            // Recorded on disk before anything is done, so a command that ends
            // with the server quitting is known about when it comes back.
            var record = new HandledCommand { Status = "failed", Result = "interrupted before it finished", HandledUtc = DateTime.UtcNow };
            _handledCommands[id] = record;
            PruneHandledCommands();
            WriteData(CommandsDataFile, _handledCommands);
            QueueCommandResult(id, "received", null);

            string status, result;
            try
            {
                RunCommand(verb, args, out status, out result);
            }
            catch (Exception ex)
            {
                status = "failed";
                result = ex.Message;
            }

            record.Status = status;
            record.Result = result;
            WriteData(CommandsDataFile, _handledCommands);
            QueueCommandResult(id, status, result);
            Puts($"Panel command {id} ({verb}): {status}{(string.IsNullOrEmpty(result) ? "" : " -- " + result)}");
        }

        private void RunCommand(string verb, JObject args, out string status, out string result)
        {
            switch (verb)
            {
                case "message":
                {
                    var text = ((string)args["text"] ?? "").Trim();
                    if (text.Length == 0 || text.Length > 500) { status = "refused"; result = "the message is empty or longer than 500 characters"; return; }
                    var sent = 0;
                    foreach (var p in players.Connected.ToArray())
                    {
                        if (p == null || !p.IsConnected) continue;
                        p.Message(Prefix() + text);
                        sent++;
                    }
                    status = "done"; result = $"sent to {sent} player(s)";
                    return;
                }
                case "save":
                    server.Save();
                    status = "done"; result = "saved";
                    return;
                case "reload":
                {
                    var name = ((string)args["plugin"] ?? "").Trim();
                    if (!Regex.IsMatch(name, "^[A-Za-z0-9_]{1,64}$")) { status = "refused"; result = "not a plugin name"; return; }
                    if (!File.Exists(Path.Combine(Interface.Oxide.PluginDirectory, name + ".cs"))) { status = "failed"; result = $"there is no {name}.cs in the plugins folder"; return; }
                    // Reloading this plugin ends this plugin; let the answer go first.
                    if (string.Equals(name, Name, StringComparison.OrdinalIgnoreCase))
                    {
                        timer.Once(10f, () => Interface.Oxide.ReloadPlugin(name));
                        status = "done"; result = "reloading in 10 seconds";
                        return;
                    }
                    var ok = Interface.Oxide.ReloadPlugin(name);
                    status = ok ? "done" : "failed"; result = ok ? "reloaded" : "Oxide could not reload it; see the server console";
                    return;
                }
                case "unload":
                {
                    var name = ((string)args["plugin"] ?? "").Trim();
                    if (!Regex.IsMatch(name, "^[A-Za-z0-9_]{1,64}$")) { status = "refused"; result = "not a plugin name"; return; }
                    if (!File.Exists(Path.Combine(Interface.Oxide.PluginDirectory, name + ".cs"))) { status = "failed"; result = $"there is no {name}.cs in the plugins folder"; return; }
                    // Unloading this plugin would end the connection that could load it again.
                    if (string.Equals(name, Name, StringComparison.OrdinalIgnoreCase)) { status = "refused"; result = "Hotwire does not unload itself from the panel: it would stop hearing the panel. Unload it on the server."; return; }
                    var target = plugins.Find(name);
                    if (target == null || !target.IsLoaded) { status = "done"; result = "it was not loaded"; return; }
                    // Only unloads: the file stays, and Oxide loads it again at the next restart.
                    // OnPluginUnloaded refreshes the plugin list.
                    var ok = Interface.Oxide.UnloadPlugin(name);
                    status = ok ? "done" : "failed"; result = ok ? "unloaded; it loads again when the server restarts" : "Oxide would not unload it; see the server console";
                    return;
                }
                case "kick":
                {
                    var steamId = ((string)args["steamid"] ?? "").Trim();
                    if (!Regex.IsMatch(steamId, "^[0-9]{17}$")) { status = "refused"; result = "not a SteamID64"; return; }
                    var player = players.FindPlayerById(steamId);
                    if (player == null || !player.IsConnected) { status = "done"; result = "the player was not connected"; return; }
                    var reason = ((string)args["reason"] ?? "").Trim();
                    player.Kick(reason.Length > 0 ? reason : "Kicked by an admin");
                    status = "done"; result = "kicked";
                    return;
                }
                case "restart":
                {
                    if (_shuttingDown) { status = "refused"; result = "the server is already shutting down"; return; }
                    if (_countdownActive) { status = "refused"; result = $"a countdown is already running ({FormatRemaining(RemainingSeconds())} left)"; return; }
                    var asked = 0;
                    var delayToken = args["delay"];
                    if (delayToken != null) int.TryParse(delayToken.ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out asked);
                    var minimum = Math.Max(10, _config.Panel.MinimumRestartSeconds);
                    var seconds = Math.Max(asked, minimum);
                    // Optional, as "hotwire now update" / "now validate" in game: the
                    // restart also writes the update flag the launcher acts on.
                    var validate = BoolArg(args, "validate");
                    var update = validate || BoolArg(args, "update");
                    BeginCountdown(DateTime.Now.AddSeconds(seconds), update, validate, null, "");
                    _scheduleCheckDue = DateTime.MinValue;
                    var what = validate ? "validate" : update ? "update" : "restart";
                    status = "done";
                    result = asked < minimum
                        ? $"{what} countdown started: {seconds}s (raised from {asked}s so players are warned)"
                        : $"{what} countdown started: {seconds}s";
                    return;
                }
                case "countdown.cancel":
                    if (_shuttingDown) { status = "refused"; result = "too late: the server is already shutting down"; return; }
                    if (!_countdownActive) { status = "done"; result = "no countdown was running"; return; }
                    CancelCountdown("the panel");
                    _scheduleCheckDue = DateTime.MinValue;
                    status = "done"; result = "countdown canceled";
                    return;
                case "schedule.add":
                case "schedule.update":
                case "schedule.remove":
                case "schedule.enable":
                case "schedule.disable":
                    RunScheduleCommand(verb, args, out status, out result);
                    return;
                case "convar.set":
                case "convar.persist":
                {
                    // convar.set   -- apply a runtime convar live, in-process (like a
                    //                 console command; no RCON, no inbound path). Lost on restart,
                    //                 exactly as setting it in RCON would be.
                    // convar.persist -- ask the launcher to make a start-arg convar permanent by
                    //                 writing CONVAR.request; it applies on the next restart.
                    // The same fences the launcher enforces are enforced here: a dotted convar
                    // name only, never the map-defining convars (those are wipe) or rcon.password
                    // (a secret), and no shell-active character in a persisted value.
                    var name = ((string)args["name"] ?? "").Trim();
                    var value = (string)args["value"] ?? "";
                    if (!Regex.IsMatch(name, @"^[a-z][a-z0-9]*(\.[a-z0-9_]+)+$"))
                    { status = "refused"; result = "not a dotted convar name"; return; }
                    switch (name)
                    {
                        case "server.seed":
                        case "server.worldsize":
                        case "server.level":
                        case "server.levelurl":
                            status = "refused"; result = "map-defining convar; use wipe, not the convar editor"; return;
                        case "rcon.password":
                            status = "refused"; result = "rcon.password is a secret and is never set through the panel"; return;
                    }
                    if (value.Length == 0 || value.Length > 512)
                    { status = "refused"; result = "missing value, or longer than 512 characters"; return; }
                    foreach (var ch in value)
                    {
                        if (char.IsControl(ch)) { status = "refused"; result = "value has a control character"; return; }
                    }

                    if (verb == "convar.set")
                    {
                        try { server.Command(name, value); }
                        catch (Exception ex) { status = "failed"; result = "could not set it live: " + ex.Message; return; }
                        string actual = null;
                        try { actual = ConsoleSystem.Run(ConsoleSystem.Option.Server.Quiet(), name)?.ToString(); }
                        catch { /* readback is best-effort; not every convar echoes */ }
                        status = "done";
                        result = string.IsNullOrEmpty(actual)
                            ? "set live (value not read back); lasts until the next restart"
                            : "set live; server reports: " + actual.Trim();
                        return;
                    }

                    // convar.persist: a value written into a file the machine executes, so refuse
                    // any character that stays active inside the launcher's double quotes.
                    if (value.IndexOfAny(new[] { '"', '$', '`', '\\' }) >= 0)
                    { status = "refused"; result = "value has a shell-active character (\" $ ` \\)"; return; }
                    var root = ServerRoot();
                    if (root == null) { status = "failed"; result = "cannot find the server root to write the request"; return; }
                    var reqPath = Path.Combine(root, "CONVAR.request");
                    try { File.AppendAllText(reqPath, name + " " + value + Environment.NewLine, new UTF8Encoding(false)); }
                    catch (Exception ex) { status = "failed"; result = "could not write the request: " + ex.Message; return; }
                    status = "done";
                    result = "saved; the launcher makes it permanent on the next restart (needs the Hotwire launcher with convar_persist)";
                    return;
                }
                default:
                    status = "refused";
                    result = verb == "update"
                        ? "updates are carried out by the launcher, not the plugin"
                        : $"this plugin does not know the command '{verb}'";
                    return;
            }
        }

        private void QueueCommandResult(string id, string status, string result)
        {
            long numeric;
            JToken idToken = long.TryParse(id, NumberStyles.Integer, CultureInfo.InvariantCulture, out numeric) ? (JToken)numeric : id;
            _commandResults.Enqueue(new JObject { ["id"] = idToken, ["status"] = status, ["result"] = result });
        }

        private void SendCommandResult()
        {
            var payload = _commandResults.Peek();
            var body = PanelEnvelope("command_result", payload);
            PanelRequest("POST", PanelReportPath, body, response =>
            {
                if (_commandResults.Count > 0 && ReferenceEquals(_commandResults.Peek(), payload)) _commandResults.Dequeue();
            }, () =>
            {
                if (_commandResults.Count > 0 && ReferenceEquals(_commandResults.Peek(), payload)) _commandResults.Dequeue();
            }, onFailed: code =>
            {
                // Kept on disk, not retried from memory, so it is never sent twice.
                if (!SpoolKeepsStatus(code)) return;
                if (_commandResults.Count > 0 && ReferenceEquals(_commandResults.Peek(), payload)) _commandResults.Dequeue();
                SpoolReport(body);
            });
        }

        private void PruneHandledCommands()
        {
            var cutoff = DateTime.UtcNow.AddDays(-2);
            foreach (var key in _handledCommands.Where(kv => kv.Value == null || kv.Value.HandledUtc < cutoff).Select(kv => kv.Key).ToList())
                _handledCommands.Remove(key);
        }

        // ---------------------------------------------------------- player data

        // The account's sharing level decides how much player data leaves this
        // machine, and it is applied here, before anything is sent. It fails
        // CLOSED: with no answer, an unreadable one, an unknown level, or level 2
        // without a salt, the level is 0 -- no player fields at all. Not the
        // default, and not the last answer that worked. A poll that simply fails
        // (unreachable, 401, 5xx) is not an answer and keeps the level in force.
        //
        // The last answer is kept on disk with the key it came from, so a reload
        // does not fall silent; an answer for a different key is not used.
        // Nothing the plugin sends today carries a player's identity -- the log
        // and events senders that will read this come later.

        private const string SharingPath = "/api/v1/sharing";
        private const string SharingDataFile = "Hotwire/panel_sharing";
        private const int SharingPollSeconds = 120;

        private sealed class SharingAnswer
        {
            public string KeyId;
            public int Level;
            public string LevelHash;
            public string Salt;
            public bool Reports;              // in-game reports may leave; only a literal true
            public DateTime ReceivedUtc;
        }

        private SharingAnswer _sharing;
        private bool _sharingLoaded;
        private DateTime _sharingDue = DateTime.MinValue;

        // 0 counts only, 1 anonymous, 2 pseudonymous, 3 identified.
        private int EffectiveSharingLevel()
        {
            LoadSharingAnswer();
            var a = _sharing;
            if (a == null || _panel == null || a.KeyId != _panel.KeyId) return 0;
            if (a.Level < 0 || a.Level > 3) return 0;
            if (a.Level == 2 && !IsSalt(a.Salt)) return 0;
            return a.Level;
        }

        // In-game reports leave only at level 3, when the panel said a literal
        // true and this config has not turned them off.
        private bool ReportsAllowed()
        {
            return _config.Panel.SendReports && EffectiveSharingLevel() == 3 && _sharing != null && _sharing.Reports;
        }

        private string SharingDescription()
        {
            var level = EffectiveSharingLevel();
            var names = new[] { "counts only (0)", "anonymous (1)", "pseudonymous (2)", "identified (3)" };
            if (_sharing == null || _panel == null || _sharing.KeyId != _panel.KeyId)
                return names[0] + " until the panel answers";
            return $"{names[level]}, in-game reports {(ReportsAllowed() ? "sent" : "not sent")}, from the panel {_sharing.ReceivedUtc.ToLocalTime():yyyy-MM-dd HH:mm}";
        }

        private static bool IsSalt(string salt)
        {
            return salt != null && Regex.IsMatch(salt, "^[0-9a-f]{64}$");
        }

        private void LoadSharingAnswer()
        {
            if (_sharingLoaded) return;
            _sharingLoaded = true;
            _sharing = ReadData<SharingAnswer>(SharingDataFile);
        }

        private void PollSharing()
        {
            _sharingDue = DateTime.UtcNow.AddSeconds(SharingPollSeconds);
            var link = _panel;
            PanelRequest("GET", SharingPath, null, response =>
            {
                LoadSharingAnswer();
                SharingAnswer answer;
                try
                {
                    var envelope = JObject.Parse(response);
                    var data = envelope["data"] as JObject;
                    var ok = envelope["ok"] != null && envelope["ok"].Type == JTokenType.Boolean && (bool)envelope["ok"];
                    var levelToken = data == null ? null : data["sharing_level"];
                    var level = levelToken != null && levelToken.Type == JTokenType.Integer ? (int)levelToken : -1;
                    answer = new SharingAnswer
                    {
                        KeyId = link.KeyId,
                        // Anything but exactly 0-3 is recorded as 0, so a bad answer lowers, never raises.
                        Level = ok && level >= 0 && level <= 3 ? level : 0,
                        LevelHash = data == null ? null : (string)data["level_hash"],
                        Salt = data == null ? null : (string)data["salt"],
                        Reports = ok && data != null && data["reports"] != null && data["reports"].Type == JTokenType.Boolean && (bool)data["reports"],
                        ReceivedUtc = DateTime.UtcNow
                    };
                    if (answer.Level == 2 && !IsSalt(answer.Salt)) answer.Level = 0;
                }
                catch
                {
                    answer = new SharingAnswer { KeyId = link.KeyId, Level = 0, ReceivedUtc = DateTime.UtcNow };
                }

                var changed = _sharing == null || _sharing.KeyId != answer.KeyId || _sharing.LevelHash != answer.LevelHash || _sharing.Level != answer.Level || _sharing.Reports != answer.Reports;
                if (!changed) { _sharing.ReceivedUtc = answer.ReceivedUtc; return; }

                var before = _sharing == null || _sharing.KeyId != link.KeyId ? -1 : _sharing.Level;
                var reportsBefore = _sharing != null && _sharing.KeyId == link.KeyId && _sharing.Reports;
                _sharing = answer;
                WriteData(SharingDataFile, _sharing);
                if (reportsBefore != answer.Reports)
                {
                    Puts(answer.Reports ? "In-game reports: the panel asks for them, so they are sent." : "In-game reports: not sent.");
                    // Reports queued while they were allowed never leave once they are not.
                    if (!answer.Reports) _events.RemoveAll(e => (string)e["kind"] == "report");
                }
                if (before != answer.Level)
                {
                    Puts($"Player data sharing level from the panel: {SharingDescription()}.");
                    // Identity gathered under the old level never leaves under a lower one.
                    if (answer.Level < 3) _events.Clear();
                    _playersSentJson = null;
                    _playersCheckDue = DateTime.MinValue;
                }
            }, signedResponse: true);
        }

        // ---------------------------------------------------------- report policy

        // What the panel asks this server to send, and how often, for the
        // account's plan. It only ever lowers what this config allows: the
        // longer interval wins, and a switch is on only when both say on. It is
        // never about player data (that is the sharing level) and never changes
        // what the server does. Until an answer arrives, or when one cannot be
        // read, everything the config allows is sent, as before.

        private const string PolicyPath = "/api/v1/policy";
        private const int PolicyPollSeconds = 300;
        private const int PolicyPollMaxSeconds = 3600;

        private ReportPolicy _policy;
        private DateTime _policyDue = DateTime.MinValue;

        // The heartbeat's cap is well under the panel's ten silent minutes, so a
        // mistaken answer cannot make a server look down.
        private int HeartbeatInterval() => PolicyInterval(_config.Panel.HeartbeatSeconds, 10, _policy == null ? 0 : _policy.HeartbeatSeconds, 300);

        private int PluginTimeInterval() => PolicyInterval(_config.Panel.PluginTimeSeconds, 30, _policy == null ? 0 : _policy.PluginTimeSeconds, 3600);

        private int CommandInterval() => PolicyInterval(_config.Panel.CommandSeconds, 10, _policy == null ? 0 : _policy.CommandSeconds, 300);

        private int BanInterval() => PolicyInterval(_config.Panel.BanSeconds, 30, _policy == null ? 0 : _policy.BanSeconds, 3600);

        private int LogInterval() => PolicyInterval(_config.Panel.LogSeconds, 10, _policy == null ? 0 : _policy.LogSeconds, 900);

        private int EventInterval() => PolicyInterval(_config.Panel.EventSeconds, 10, _policy == null ? 0 : _policy.EventSeconds, 600);

        private int MarkerInterval() => PolicyInterval(_config.Panel.MarkerSeconds, 30, _policy == null ? 0 : _policy.MarkerSeconds, 3600);

        // The panel can ask to be asked less often, never more often.
        private int PolicyPollInterval() => PolicyInterval(PolicyPollSeconds, PolicyPollSeconds, _policy == null ? 0 : _policy.PolicySeconds, PolicyPollMaxSeconds);

        private bool PolicyAllowsCommands() => _policy == null || _policy.Commands != false;

        private bool PolicyAllowsBans() => _policy == null || _policy.Bans != false;

        private bool PolicyAllowsLogLevel(string level) => PolicyAllowsLevel(_policy, level);

        private bool PolicyAllowsKind(string kind) => PolicyAllowsKindOf(_policy, kind);

        private string PolicyDescription()
        {
            if (_policy == null) return "none yet: sending everything the config allows";

            var parts = new List<string>();
            if (_policy.LogLevels != null)
                parts.Add(_policy.LogLevels.Count == 0
                    ? "no log lines"
                    : "log " + string.Join(", ", _policy.LogLevels.OrderBy(l => l, StringComparer.Ordinal).ToArray()) + " only");
            parts.Add($"heartbeat every {HeartbeatInterval()}s");
            parts.Add($"plugin time every {PluginTimeInterval()}s");
            parts.Add($"log every {LogInterval()}s");
            parts.Add($"player events every {EventInterval()}s");
            parts.Add($"map markers every {MarkerInterval()}s");
            if (PolicyAllowsCommands()) parts.Add($"commands checked every {CommandInterval()}s");
            if (PolicyAllowsBans()) parts.Add($"ban list checked every {BanInterval()}s");
            parts.Add($"this policy checked every {PolicyPollInterval()}s");
            if (!PolicyAllowsCommands()) parts.Add("no command checks");
            if (!PolicyAllowsBans()) parts.Add("no ban list checks");
            if (_policy.Kinds != null)
                parts.Add(_policy.Kinds.Count == 0
                    ? "no reports at all"
                    : "only " + string.Join(", ", _policy.Kinds.OrderBy(k => k, StringComparer.Ordinal).ToArray()) + " reports");
            if (_policy.Hold && _policy.Kinds != null)
                parts.Add($"the rest held here for up to {SpoolDays()} days");

            var name = string.IsNullOrEmpty(_policy.Name) ? "unnamed" : _policy.Name;
            return $"{name}: {string.Join(", ", parts.ToArray())} (from the panel {_policy.ReceivedUtc.ToLocalTime():yyyy-MM-dd HH:mm})";
        }

        private void PollPolicy()
        {
            _policyDue = DateTime.UtcNow.AddSeconds(PolicyPollInterval());
            PanelRequest("GET", PolicyPath, null, response =>
            {
                var answer = ReadPolicy(response);
                if (answer == null)
                {
                    // An answer that cannot be read: send everything the config allows.
                    if (_policy != null) Puts("The panel's report policy could not be read. Sending everything the config allows.");
                    _policy = null;
                    return;
                }

                if (_policy != null && answer.Hash != null && answer.Hash == _policy.Hash)
                {
                    _policy.ReceivedUtc = answer.ReceivedUtc;
                    return;
                }

                _policy = answer;
                Puts($"Report policy from the panel: {PolicyDescription()}.");
            }, signedResponse: true);
        }

        // ---------------------------------------------------------- players

        // Who is online, sent when the set of players or a name changes. Only at
        // the "identified" level: below it, the heartbeat's count is all that
        // leaves this machine.
        private string _playersJson, _playersSentJson;
        private DateTime _playersCheckDue = DateTime.MinValue;
        private DateTime _playersSendNotBefore = DateTime.MinValue;
        private string _playersState = "nothing sent yet";

        private void RefreshPlayers()
        {
            if (EffectiveSharingLevel() < 3)
            {
                _playersJson = null;
                _playersSentJson = null;
                _playersState = "not sent: the player data level is below identified";
                return;
            }

            var list = new JArray();
            foreach (var player in players.Connected.Where(p => p != null).OrderBy(p => p.Id, StringComparer.Ordinal))
                list.Add(new JObject { ["steam_id"] = player.Id, ["name"] = MaskSourceGates(player.Name ?? "") });
            _playersJson = list.ToString(Formatting.None);
        }

        private void SendPlayers()
        {
            var json = _playersJson;
            var list = JArray.Parse(json);
            // When each connected, worked out as it is sent. It is not part of what
            // decides whether the list changed, so a clock tick never resends it.
            foreach (JObject entry in list)
            {
                try
                {
                    var player = players.FindPlayerById((string)entry["steam_id"]);
                    var connection = player == null ? null : (player.Object as BasePlayer)?.Connection;
                    if (connection != null)
                        entry["connected_at"] = DateTime.UtcNow.AddSeconds(-connection.GetSecondsConnected())
                            .ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture);
                }
                catch { }
            }

            // At most once a minute: a busy server's list changes far more often than
            // anyone needs to see it change.
            _playersSendNotBefore = DateTime.UtcNow.AddSeconds(60);
            var payload = new JObject { ["sharing_level"] = EffectiveSharingLevel(), ["players"] = list };
            PanelRequest("POST", PanelReportPath, PanelEnvelope("players", payload), response =>
            {
                _playersSentJson = json;
                _playersState = $"{list.Count} online, sent {DateTime.Now:HH:mm:ss}";
            }, () => { _playersSentJson = json; });
        }

        // Joins, leaves and chat, queued as they happen and sent in batches. Only
        // gathered while the level is "identified", and let go if it drops before
        // they are sent. Held in memory: a crash loses the unsent few seconds.
        private const int MaxQueuedEvents = 1000;
        private const int EventsPerReport = 200;
        private readonly List<JObject> _events = new List<JObject>();
        private DateTime _eventsDue = DateTime.MinValue;
        private int _eventsSent;
        private int _eventsDropped;
        private string _eventsState = "nothing sent yet";

        private void OnPlayerConnected(BasePlayer player)
        {
            if (player == null) return;
            QueueEvent(_config.Panel.SendPlayers, "join", player.UserIDString, new JObject { ["name"] = MaskSourceGates(player.displayName ?? "") });
            _playersCheckDue = DateTime.MinValue;
        }

        private void OnPlayerDisconnected(BasePlayer player, string reason)
        {
            if (player == null) return;
            QueueEvent(_config.Panel.SendPlayers, "leave", player.UserIDString, new JObject
            {
                ["name"] = MaskSourceGates(player.displayName ?? ""),
                ["reason"] = MaskSourceGates(reason ?? "")
            });
            _playersCheckDue = DateTime.MinValue;
        }

        // The channel is taken as an object and named by its value, so a Rust
        // update that moves the chat types cannot stop this plugin compiling.
        // Returns nothing, so it never changes whether a message is delivered.
        private void OnPlayerChat(BasePlayer player, string message, object channel)
        {
            if (player == null || string.IsNullOrEmpty(message)) return;
            QueueEvent(_config.Panel.SendChat, "chat", player.UserIDString, new JObject
            {
                ["channel"] = channel == null ? "unknown" : channel.ToString().ToLowerInvariant(),
                ["text"] = MaskSourceGates(message)
            });
        }

        // An F7 report. The game calls this for every report, whatever its report
        // convars say. Returns nothing, so it never changes what the game does.
        private void OnPlayerReported(BasePlayer reporter, string targetName, string targetId, string subject, string message, string type)
        {
            if (reporter == null || !ReportsAllowed()) return;
            var text = message ?? "";
            if (text.Length > 4000) text = text.Substring(0, 4000);
            QueueEvent(true, "report", reporter.UserIDString, new JObject
            {
                ["reporter_name"] = MaskSourceGates(reporter.displayName ?? ""),
                ["target_id"] = targetId ?? "",
                ["target_name"] = MaskSourceGates(targetName ?? ""),
                ["type"] = type ?? "",
                ["subject"] = MaskSourceGates(subject ?? ""),
                ["message"] = MaskSourceGates(text)
            });
        }

        private void QueueEvent(bool enabled, string kind, string actor, JObject data)
        {
            if (!enabled || _panel == null || !_config.Panel.Enabled || EffectiveSharingLevel() < 3) return;
            if (!PolicyAllowsKind("events") && !PolicyHolds(_policy)) return;
            if (_events.Count >= MaxQueuedEvents)
            {
                _events.RemoveAt(0);
                _eventsDropped++;
            }
            _events.Add(new JObject
            {
                ["at"] = DateTime.UtcNow.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture),
                ["kind"] = kind,
                ["actor"] = actor,
                ["data"] = data
            });
        }

        private void SendEvents()
        {
            var interval = EventInterval();
            if (EffectiveSharingLevel() < 3)
            {
                _events.Clear();
                _eventsState = "not sent: the player data level is below identified";
                _eventsDue = DateTime.UtcNow.AddSeconds(interval);
                return;
            }

            var batch = _events.Take(EventsPerReport).ToList();
            var payload = new JObject { ["events"] = new JArray(batch) };
            var body = PanelEnvelope("events", payload);
            PanelRequest("POST", PanelReportPath, body, response =>
            {
                _events.RemoveAll(e => batch.Contains(e));
                _eventsSent += batch.Count;
                _eventsState = $"{_eventsSent} sent since load, last at {DateTime.Now:HH:mm:ss}" +
                               (_eventsDropped > 0 ? $"; {_eventsDropped} dropped while the queue was full" : "");
                _eventsDue = _events.Count > 0 ? DateTime.UtcNow : DateTime.UtcNow.AddSeconds(interval);
            }, () =>
            {
                // Refused: the same events would be refused again, so they are let go.
                PrintWarning($"Panel: {batch.Count} player event{(batch.Count == 1 ? " was" : "s were")} refused (HTTP {_panelLastCode}) and will not be sent again.");
                _events.RemoveAll(e => batch.Contains(e));
                _eventsDue = DateTime.UtcNow.AddSeconds(interval);
            }, onFailed: code =>
            {
                // Kept on disk and taken out of the queue, so they are sent once, later.
                if (!SpoolKeepsStatus(code)) return;
                SpoolReport(body);
                _events.RemoveAll(e => batch.Contains(e));
                _eventsDue = DateTime.UtcNow.AddSeconds(interval);
            });
        }

        // ---------------------------------------------------------- plugin time

        // Oxide keeps, for every plugin that is not part of Oxide itself, the
        // seconds its hooks, timers, commands and web request callbacks have run
        // on the main thread, and the memory allocated while they did. Sent as
        // the change since the last report, so the panel can say which plugin is
        // costing the server its time. Work Oxide does not track -- a plugin's own
        // Unity components, coroutines, threads or Harmony patches -- is not here.
        private sealed class PluginTotals
        {
            public double Seconds;
            public long Bytes;
        }

        private Dictionary<Plugin, PluginTotals> _pluginTotals = new Dictionary<Plugin, PluginTotals>();
        private DateTime _pluginTotalsAt = DateTime.MinValue;
        private DateTime _pluginTimeDue = DateTime.MinValue;
        private string _pluginTimeState = "nothing sent yet";

        // While plugin time is not sent, the starting point is dropped, so the first
        // report after it is allowed again covers one interval, not the whole pause.
        private void ForgetPluginTotals()
        {
            _pluginTimeDue = DateTime.UtcNow.AddSeconds(PluginTimeInterval());
            _pluginTotals.Clear();
            _pluginTotalsAt = DateTime.MinValue;
            _pluginTimeState = "not sent: the panel's report policy does not include plugin time";
        }

        // Reads every plugin's totals and sends the change. The first read after
        // a load, and a plugin's first read after it loads, only sets the starting
        // point: there is no interval to measure yet. Returns whether a request went.
        private bool SendPluginTime()
        {
            var now = DateTime.UtcNow;
            _pluginTimeDue = now.AddSeconds(PluginTimeInterval());

            var current = new Dictionary<Plugin, PluginTotals>();
            var list = new JArray();
            foreach (var plugin in plugins.GetAll())
            {
                if (plugin == null || plugin.IsCorePlugin) continue;
                var totals = new PluginTotals { Seconds = plugin.TotalHookTime, Bytes = plugin.TotalHookMemory };
                current[plugin] = totals;

                PluginTotals before;
                if (!_pluginTotals.TryGetValue(plugin, out before)) continue;

                var milliseconds = (long)Math.Round(Math.Max(0.0, totals.Seconds - before.Seconds) * 1000.0);
                var kilobytes = Math.Max(0L, totals.Bytes - before.Bytes) / 1024;
                if (milliseconds <= 0 && kilobytes <= 0) continue;

                list.Add(new JObject
                {
                    ["file"] = string.IsNullOrEmpty(plugin.Filename) ? plugin.Name : Path.GetFileNameWithoutExtension(plugin.Filename),
                    ["name"] = plugin.Title ?? plugin.Name,
                    ["ms"] = milliseconds,
                    ["alloc_kb"] = kilobytes
                });
            }

            var hadBaseline = _pluginTotalsAt != DateTime.MinValue;
            var windowSeconds = hadBaseline ? (int)Math.Round((now - _pluginTotalsAt).TotalSeconds) : 0;
            _pluginTotals = current;
            _pluginTotalsAt = now;

            if (!hadBaseline || windowSeconds <= 0)
            {
                _pluginTimeState = "measuring: the first report goes after one interval";
                return false;
            }

            var payload = new JObject { ["window_seconds"] = windowSeconds, ["plugins"] = list };
            PanelRequest("POST", PanelReportPath, PanelEnvelope("plugin_time", payload), response =>
            {
                _pluginTimeState = $"{list.Count} plugin{(list.Count == 1 ? "" : "s")} over {windowSeconds}s, sent {DateTime.Now:HH:mm:ss}";
            });
            return true;
        }

        // ---------------------------------------------------------- ban list

        private void PollBans()
        {
            _bansDue = DateTime.UtcNow.AddSeconds(BanInterval());
            PanelRequest("GET", PanelBansPath, null, response =>
            {
                var data = PanelData(response);
                var enforced = data["enforced"] == null || (bool)data["enforced"];
                if (!enforced)
                {
                    _bansState = "this account's plan does not include ban sync; nothing is enforced from the panel";
                    if (_bansNotice != _bansState)
                        Puts("The panel's ban list is not enforced on this server: the account's plan does not include ban sync. " +
                             "Bans the panel added before stay in place.");
                    _bansNotice = _bansState;
                    return;
                }
                _bansNotice = null;

                var hash = (string)data["list_hash"];
                if (hash != null && hash == _bansListHash)
                {
                    _bansState = $"{_appliedBans.Count} ban(s) from the panel, unchanged (checked {DateTime.Now:HH:mm:ss})";
                    return;
                }

                var bans = data["bans"] as JArray;
                if (bans == null) return;
                ReconcileBans(bans);
                _bansListHash = hash;
            }, signedResponse: true);
        }

        // Writes the account's bans into this server's own ban list. Only bans
        // this plugin added are ever changed or lifted: a player banned here by
        // an admin stays banned whatever the panel says.
        private void ReconcileBans(JArray bans)
        {
            var now = (long)(DateTime.UtcNow - UnixEpoch).TotalSeconds;
            var wanted = new Dictionary<string, AppliedBan>();
            var mutes = 0;

            foreach (var b in bans.OfType<JObject>())
            {
                var id = ((string)b["steamid"] ?? "").Trim();
                if (!Regex.IsMatch(id, "^[0-9]{17}$")) continue;
                if (b["is_mute"] != null && (bool)b["is_mute"]) { mutes++; continue; }
                long expiry = 0;
                if (b["expiry"] != null) long.TryParse(b["expiry"].ToString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out expiry);
                if (expiry != 0 && expiry <= now) continue;
                wanted[id] = new AppliedBan { Expiry = expiry, Reason = ((string)b["reason"] ?? "").Trim() };
            }

            int added = 0, updated = 0, lifted = 0, alreadyLocal = 0;

            foreach (var kv in wanted)
            {
                AppliedBan ours;
                var isOurs = _appliedBans.TryGetValue(kv.Key, out ours);

                if (server.IsBanned(kv.Key))
                {
                    if (!isOurs) { alreadyLocal++; continue; }
                    if (ours.Expiry == kv.Value.Expiry) continue;
                    server.Unban(kv.Key);
                    ApplyBan(kv.Key, kv.Value, now);
                    updated++;
                }
                else
                {
                    ApplyBan(kv.Key, kv.Value, now);
                    if (isOurs) updated++; else added++;
                }
                _appliedBans[kv.Key] = kv.Value;
            }

            foreach (var id in _appliedBans.Keys.Where(k => !wanted.ContainsKey(k)).ToList())
            {
                if (server.IsBanned(id)) { server.Unban(id); lifted++; }
                _appliedBans.Remove(id);
            }

            WriteData(BansDataFile, _appliedBans);
            _bansState = $"{_appliedBans.Count} ban(s) from the panel (checked {DateTime.Now:HH:mm:ss})";

            if (added + updated + lifted > 0)
                Puts($"Ban list from the panel: {added} added, {updated} changed, {lifted} lifted." +
                     (alreadyLocal > 0 ? $" {alreadyLocal} were already banned here and are left as they are." : "") +
                     (mutes > 0 ? $" {mutes} mute(s) are not enforced by the plugin." : ""));
        }

        private void ApplyBan(string id, AppliedBan ban, long now)
        {
            var duration = ban.Expiry == 0 ? TimeSpan.Zero : TimeSpan.FromSeconds(Math.Max(1, ban.Expiry - now));
            var reason = ban.Reason.Length > 0 ? ban.Reason : "Banned";
            server.Ban(id, reason, duration);

            // A native ban stops the next join; it does not remove someone who is
            // already playing.
            var player = players.FindPlayerById(id);
            if (player != null && player.IsConnected) player.Kick(reason);
        }

        // ---------------------------------------------------------------- the log

        // One pipe for everything the server logs, from two sources:
        //  - Oxide's lines, read from its own file (oxide/logs/oxide_<date>.txt):
        //    complete from the moment the server started, compile failures from
        //    before this plugin loaded included, nothing lost to a crash.
        //  - The game's console, taken as it is written (Unity's log callback):
        //    saves, joins and leaves, Rust's own warnings and errors, anything
        //    another mod prints. Oxide's lines come round this way too and are
        //    left to the file; chat is never taken (it has its own setting).
        // Both are appended to one spool on this machine (oxide/logs/
        // hotwire_log_<date>.txt). The sender reads only the spool: one cursor,
        // one sequence, one set of rules, and whatever the panel has not taken
        // yet waits there -- through an outage, a reload or a held policy.
        private const string LogDataFile = "Hotwire/panel_log";
        private const int LogMaxReadBytes = 262144;
        private const int LogMaxBodyChars = 1000000;
        // A day's spool never grows past this; lines past it are counted as not sent.
        private const long LogSpoolMaxBytesPerDay = 64L * 1024 * 1024;
        // The console is taken on the game's own threads: one enqueue a line, no
        // more. At most this many wait for the next tick; a flood past it is
        // counted, not kept.
        private const int ConsoleQueueMax = 20000;
        // Written to the spool on the main thread, at most this many a tick, so a
        // flood cannot hold a frame.
        private const int ConsoleFlushMax = 5000;
        private const int ConsoleMaxLineChars = 16384;
        // A console line waits this long before it is written, so the Oxide line
        // it may be an echo of has certainly been seen.
        private static readonly long ConsoleSettleTicks = TimeSpan.FromSeconds(1).Ticks;
        private static readonly long EchoKeepTicks = TimeSpan.FromSeconds(30).Ticks;

        // Where the log has got to, kept across reloads so nothing is sent twice.
        // The session is this server process: a reload keeps it, a restart
        // starts a new one.
        private sealed class LogCursor
        {
            public string SessionKey;
            public long ProcessStartTicks;
            public long Seq;
            // How far Oxide's file has been read into the spool. Before the spool
            // this was how far it had been sent: the same place, so the update to
            // the spool neither repeats nor skips a line. The names stay.
            [JsonProperty("File")] public string ImportFile;
            [JsonProperty("Offset")] public long ImportOffset;
            // How far the spool has been sent.
            public string SpoolFile;
            public long SpoolOffset;
            // Lines not sent, by level, not yet told to the panel: kept here by
            // the report policy, or past a bound. They ride along with the next
            // batch that goes.
            public Dictionary<string, long> NotSent;
            public DateTime NotSentSinceUtc;
        }

        private sealed class LogSendBatch
        {
            public string Body;
            public string SpoolFile;
            public long EndOffset;
            public long EndSeq;
            public int Lines;
            public int Walked;
            public bool More;
            public Dictionary<string, long> NotSentCarried;
        }

        private sealed class LogEntry
        {
            public long Start;
            public OxideLine Line;
            public StringBuilder Body;
        }

        private struct ConsoleCapture
        {
            public long Ticks;
            public int Type;
            public string Text;
            public string Stack;
        }

        // Every Oxide message, as Oxide hands it to its loggers: the same text it
        // then gives the game's console, so the two can be matched exactly.
        private sealed class OxideEcho : Oxide.Core.Logging.Logger
        {
            private readonly Hotwire _owner;

            public OxideEcho(Hotwire owner) : base(true)
            {
                _owner = owner;
            }

            protected override void ProcessMessage(Oxide.Core.Logging.Logger.LogMessage message)
            {
                _owner.RememberOxideLine(message.ConsoleMessage);
            }
        }

        private LogCursor _logCursor;
        private LogSendBatch _logPending;
        private DateTime _logDue = DateTime.MinValue;
        private int _logBatchLines = 500;
        private string _logHeldFile;
        private long _logHeldOffset = -1;
        private int _panelLastCode;
        private bool _logSkippedMore;
        private bool _logMore;
        // A count of lines kept back is told on its own after an hour at the
        // latest, so it does not wait for the next line that goes.
        private const int LogNotSentFlushSeconds = 3600;
        private long _logLinesSent;
        private string _logState = "nothing sent yet";
        private DateTime _logPruneDue = DateTime.MinValue;

        private readonly System.Collections.Concurrent.ConcurrentQueue<ConsoleCapture> _consoleQueue = new System.Collections.Concurrent.ConcurrentQueue<ConsoleCapture>();
        private int _consoleQueued;
        private long _consoleDroppedError, _consoleDroppedWarning, _consoleDroppedInfo;
        private long _consoleKept, _consoleOxide, _consoleChat, _spoolPastBound;
        [ThreadStatic] private static bool _inConsoleCallback;
        private volatile bool _consoleOn;
        private bool _consoleHooked;
        private OxideEcho _oxideEcho;
        private readonly object _echoLock = new object();
        private readonly EchoSet _echo = new EchoSet();
        private bool _echoReady;

        private string LogDescription()
        {
            if (!_config.Panel.SendLog && !_config.Panel.SendConsole) return "off in the config";
            var text = EffectiveSharingLevel() >= 3
                ? "line text sent; card numbers, SSNs and IP addresses masked"
                : "line text sent; card numbers, SSNs and IP addresses masked, Steam IDs removed";
            if (_policy != null && _policy.LogLevels != null)
                text += _policy.LogLevels.Count == 0
                    ? "; the panel's policy sends no lines"
                    : "; the panel's policy sends " + string.Join(", ", _policy.LogLevels.OrderBy(l => l, StringComparer.Ordinal).ToArray()) + " only";
            return $"{_logState}; {text}";
        }

        private string ConsoleDescription()
        {
            if (!_config.Panel.SendConsole) return "off in the config";
            if (!_consoleHooked) return "not taken: not connected to a panel";
            var dropped = _consoleDroppedError + _consoleDroppedWarning + _consoleDroppedInfo + _spoolPastBound;
            return $"{_consoleKept} line{(_consoleKept == 1 ? "" : "s")} kept since load; {_consoleOxide} Oxide line{(_consoleOxide == 1 ? "" : "s")} left to Oxide's log, " +
                   $"{_consoleChat} chat line{(_consoleChat == 1 ? "" : "s")} not taken" + (dropped > 0 ? $", {dropped} past the bounds and counted" : "");
        }

        // Runs on every panel tick, reachable or not: the spool is how nothing is
        // lost while the panel cannot be reached. Only while connected, so a
        // server that is not connected writes nothing.
        private void TickLogSpool()
        {
            var connected = _panel != null;
            SetConsoleCapture(connected && _config.Panel.SendConsole);
            if (!connected) return;

            LoadLogCursor();
            if (_consoleHooked || !_consoleQueue.IsEmpty) FlushConsole(false);
            if (_config.Panel.SendLog) ImportOxideLog();
            if (DateTime.UtcNow >= _logPruneDue)
            {
                _logPruneDue = DateTime.UtcNow.AddHours(1);
                PruneLogSpool();
            }
        }

        private void SetConsoleCapture(bool wanted)
        {
            if (wanted == _consoleHooked) return;
            if (!wanted)
            {
                StopConsoleCapture();
                return;
            }

            try
            {
                lock (_echoLock) { _echoReady = false; _echo.Clear(); }
                // Adding a logger hands it every message Oxide cached from its
                // start; those arrive before _echoReady and are ignored.
                _oxideEcho = new OxideEcho(this);
                Interface.Oxide.RootLogger.AddLogger(_oxideEcho);
                lock (_echoLock) _echoReady = true;
                _consoleOn = true;
                Application.logMessageReceivedThreaded += OnConsoleLine;
                _consoleHooked = true;
            }
            catch (Exception ex)
            {
                StopConsoleCapture();
                PrintWarning($"Panel: the server console cannot be taken ({ex.Message}). Oxide's log is still sent.");
            }
        }

        private void StopConsoleCapture()
        {
            _consoleOn = false;
            try { Application.logMessageReceivedThreaded -= OnConsoleLine; } catch { }
            if (_oxideEcho != null)
            {
                try { Interface.Oxide.RootLogger.RemoveLogger(_oxideEcho); } catch { }
                _oxideEcho = null;
            }
            lock (_echoLock) _echoReady = false;
            _consoleHooked = false;
        }

        // Called on whichever thread logged, the game's main thread or another,
        // for every line the game writes. It only queues the line: no logging
        // (that would call it again), no Oxide call, nothing that can throw.
        private void OnConsoleLine(string text, string stackTrace, LogType type)
        {
            if (_inConsoleCallback || !_consoleOn) return;
            _inConsoleCallback = true;
            try
            {
                var kind = (int)type;
                if (System.Threading.Interlocked.Increment(ref _consoleQueued) > ConsoleQueueMax)
                {
                    System.Threading.Interlocked.Decrement(ref _consoleQueued);
                    if (kind == 2) System.Threading.Interlocked.Increment(ref _consoleDroppedWarning);
                    else if (kind == 3) System.Threading.Interlocked.Increment(ref _consoleDroppedInfo);
                    else System.Threading.Interlocked.Increment(ref _consoleDroppedError);
                    return;
                }
                _consoleQueue.Enqueue(new ConsoleCapture { Ticks = DateTime.UtcNow.Ticks, Type = kind, Text = text, Stack = kind == 2 || kind == 3 ? null : stackTrace });
            }
            catch
            {
                // Never back into the game's logging.
            }
            finally
            {
                _inConsoleCallback = false;
            }
        }

        private void RememberOxideLine(string consoleMessage)
        {
            lock (_echoLock)
            {
                if (_echoReady) _echo.Add(consoleMessage, DateTime.UtcNow.Ticks);
            }
        }

        // Writes what the console has said, once it has settled, to the spool.
        // `all` at an unload takes everything still queued.
        private void FlushConsole(bool all)
        {
            var cutoff = all ? long.MaxValue : DateTime.UtcNow.Ticks - ConsoleSettleTicks;
            var lines = new List<KeyValuePair<string, string>>();
            var handled = 0;
            ConsoleCapture line;
            while (handled < ConsoleFlushMax && _consoleQueue.TryPeek(out line) && line.Ticks <= cutoff && _consoleQueue.TryDequeue(out line))
            {
                handled++;
                System.Threading.Interlocked.Decrement(ref _consoleQueued);
                var text = line.Text ?? "";
                bool oxide;
                lock (_echoLock) oxide = _echo.TryConsume(text);
                if (oxide) { _consoleOxide++; continue; }
                if (IsChatLine(text)) { _consoleChat++; continue; }

                if (!string.IsNullOrEmpty(line.Stack)) text = text + "\n" + line.Stack.TrimEnd('\n', '\r', ' ');
                if (text.Length > ConsoleMaxLineChars) text = text.Substring(0, ConsoleMaxLineChars) + $" [cut at {ConsoleMaxLineChars} of {text.Length} characters]";
                var level = ConsoleLevel(line.Type);
                var at = new DateTime(line.Ticks, DateTimeKind.Utc).ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fff'Z'", CultureInfo.InvariantCulture);
                lines.Add(new KeyValuePair<string, string>(level, SpoolLogLine('e', at, level, null, text)));
            }
            lock (_echoLock) _echo.Expire(DateTime.UtcNow.Ticks - EchoKeepTicks);

            // A flood past the queue's bound, counted on the game's threads.
            AddNotSent("error", System.Threading.Interlocked.Exchange(ref _consoleDroppedError, 0));
            AddNotSent("warning", System.Threading.Interlocked.Exchange(ref _consoleDroppedWarning, 0));
            AddNotSent("info", System.Threading.Interlocked.Exchange(ref _consoleDroppedInfo, 0));

            _consoleKept += AppendLogSpool(lines);
        }

        // Appends whole lines to today's spool, within the day's bound; a line past
        // it is counted as not sent. Returns how many were written.
        private int AppendLogSpool(List<KeyValuePair<string, string>> lines)
        {
            if (lines.Count == 0) return 0;
            var path = Path.Combine(Interface.Oxide.LogDirectory, LogSpoolName(DateTime.Now));
            long size;
            try { size = File.Exists(path) ? new FileInfo(path).Length : 0; }
            catch { size = 0; }

            var sb = new StringBuilder();
            var written = 0;
            foreach (var pair in lines)
            {
                var bytes = Encoding.UTF8.GetByteCount(pair.Value) + 1;
                if (size + bytes > LogSpoolMaxBytesPerDay)
                {
                    AddNotSent(pair.Key, 1);
                    _spoolPastBound++;
                    continue;
                }
                size += bytes;
                sb.Append(pair.Value).Append('\n');
                written++;
            }

            if (sb.Length > 0)
            {
                try { File.AppendAllText(path, sb.ToString(), new UTF8Encoding(false)); }
                catch (Exception ex)
                {
                    PrintWarning($"Panel: {written} log line{(written == 1 ? "" : "s")} could not be kept in {path} ({ex.Message}) and will not be sent.");
                    return 0;
                }
            }
            if (_logCursor != null && _logCursor.NotSent != null) WriteData(LogDataFile, _logCursor);
            return written;
        }

        private void AddNotSent(string level, long count)
        {
            if (count <= 0 || _logCursor == null) return;
            if (_logCursor.NotSent == null)
            {
                _logCursor.NotSent = new Dictionary<string, long>(StringComparer.Ordinal);
                _logCursor.NotSentSinceUtc = DateTime.UtcNow;
            }
            long n;
            _logCursor.NotSent.TryGetValue(level ?? "none", out n);
            _logCursor.NotSent[level ?? "none"] = n + count;
        }

        // Reads what Oxide has written since the import cursor into the spool, a
        // bounded amount a tick. Only whole lines are read; a line still being
        // written, and the last entry of today's file (a stack trace may still be
        // arriving under it), wait one more pass.
        private void ImportOxideLog()
        {
            var dir = Interface.Oxide.LogDirectory;
            var today = OxideLogName(DateTime.Now);

            // Back after more than thirty days: the older files are skipped, not
            // read. They stay on this machine; only the panel does without them.
            if (LogFileTooOld(_logCursor.ImportFile, DateTime.Now, SpoolDays()))
            {
                var skippedFrom = _logCursor.ImportFile;
                _logCursor.ImportFile = NextOxideLog(dir, OxideLogName(DateTime.Now.Date.AddDays(-SpoolDays() - 1))) ?? today;
                _logCursor.ImportOffset = 0;
                WriteData(LogDataFile, _logCursor);
                Puts($"Panel: log files from {skippedFrom} until {_logCursor.ImportFile} are more than {SpoolDays()} days old and are not sent. They stay in oxide/logs.");
            }

            for (var hops = 0; hops < 400; hops++)
            {
                var current = Path.Combine(dir, _logCursor.ImportFile);
                var length = File.Exists(current) ? new FileInfo(current).Length : -1;
                if (length >= 0 && _logCursor.ImportOffset > length) _logCursor.ImportOffset = 0;   // the file was replaced
                if (length >= 0 && _logCursor.ImportOffset < length) break;
                if (string.CompareOrdinal(_logCursor.ImportFile, today) >= 0) return;

                var next = NextOxideLog(dir, _logCursor.ImportFile);
                if (next == null) return;
                _logCursor.ImportFile = next;
                _logCursor.ImportOffset = 0;
                WriteData(LogDataFile, _logCursor);
            }

            var file = _logCursor.ImportFile;
            var path = Path.Combine(dir, file);
            if (!File.Exists(path)) return;

            byte[] buffer;
            int read = 0;
            long fileLength;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                fileLength = stream.Length;
                if (_logCursor.ImportOffset >= fileLength) return;
                stream.Seek(_logCursor.ImportOffset, SeekOrigin.Begin);
                buffer = new byte[(int)Math.Min(LogMaxReadBytes, fileLength - _logCursor.ImportOffset)];
                while (read < buffer.Length)
                {
                    var n = stream.Read(buffer, read, buffer.Length - read);
                    if (n <= 0) break;
                    read += n;
                }
            }

            var finished = string.CompareOrdinal(file, today) < 0;
            var atEnd = _logCursor.ImportOffset + read >= fileLength;
            DateTime fileDate;
            if (file.Length < 16 || !DateTime.TryParseExact(file.Substring(6, 10), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out fileDate))
                fileDate = DateTime.MinValue;

            var raw = new List<KeyValuePair<long, string>>();
            var pos = 0;
            for (var i = 0; i < read; i++)
            {
                if (buffer[i] != (byte)'\n') continue;
                var len = i - pos;
                if (len > 0 && buffer[i - 1] == (byte)'\r') len--;
                raw.Add(new KeyValuePair<long, string>(_logCursor.ImportOffset + pos, Encoding.UTF8.GetString(buffer, pos, len)));
                pos = i + 1;
            }
            var consumed = _logCursor.ImportOffset + pos;
            if (finished && atEnd && pos < read)
            {
                raw.Add(new KeyValuePair<long, string>(_logCursor.ImportOffset + pos, Encoding.UTF8.GetString(buffer, pos, read - pos)));
                consumed = _logCursor.ImportOffset + read;
            }

            if (raw.Count == 0)
            {
                if (read == LogMaxReadBytes)
                {
                    // One line longer than a whole read: it cannot be sent whole, so it is skipped.
                    PrintWarning($"Panel: a line in {file} is longer than {LogMaxReadBytes} bytes and is not sent.");
                    _logCursor.ImportOffset += read;
                    WriteData(LogDataFile, _logCursor);
                }
                return;
            }

            var entries = new List<LogEntry>();
            foreach (var pair in raw)
            {
                var parsed = ParseOxideLine(pair.Value);
                if (parsed.Recognised || entries.Count == 0)
                    entries.Add(new LogEntry { Start = pair.Key, Line = parsed, Body = new StringBuilder(parsed.Body) });
                else
                    entries[entries.Count - 1].Body.Append('\n').Append(pair.Value);
            }

            long end = consumed;
            if (!(finished && atEnd))
            {
                var last = entries[entries.Count - 1];
                var waited = _logHeldFile == file && _logHeldOffset == last.Start;
                if (atEnd && !waited)
                {
                    _logHeldFile = file;
                    _logHeldOffset = last.Start;
                    entries.RemoveAt(entries.Count - 1);
                    end = last.Start;
                }
                else if (!atEnd && entries.Count > 1)
                {
                    entries.RemoveAt(entries.Count - 1);
                    end = last.Start;
                }
            }
            if (entries.Count == 0) return;

            var lines = new List<KeyValuePair<string, string>>(entries.Count);
            foreach (var entry in entries)
            {
                var at = LogLineUtc(fileDate, entry.Line.Hour, entry.Line.Minute, TimeZoneInfo.Local);
                lines.Add(new KeyValuePair<string, string>(entry.Line.Level ?? "none", SpoolLogLine('o', at, entry.Line.Level, entry.Line.Source, entry.Body.ToString())));
            }
            AppendLogSpool(lines);

            _logCursor.ImportFile = file;
            _logCursor.ImportOffset = end;
            WriteData(LogDataFile, _logCursor);
        }

        private static string NextLogSpool(string dir, string after)
        {
            try
            {
                DateTime date;
                return Directory.GetFiles(dir, "hotwire_log_????-??-??.txt")
                    .Select(Path.GetFileName)
                    .Where(name => LogSpoolDate(name, out date) && string.CompareOrdinal(name, after) > 0)
                    .OrderBy(name => name, StringComparer.Ordinal)
                    .FirstOrDefault();
            }
            catch
            {
                return null;
            }
        }

        // Spool files already sent, and any past thirty days, are removed; and
        // while what is left is over its bound, the oldest unsent days go too,
        // never today's. Only this plugin's own files, by their exact name, in
        // Oxide's log folder.
        private const long LogSpoolMaxBytes = 256L * 1024 * 1024;

        private void PruneLogSpool()
        {
            if (_logCursor == null) return;
            try
            {
                var oldest = DateTime.Now.Date.AddDays(-SpoolDays());
                var today = LogSpoolName(DateTime.Now);
                var kept = new List<KeyValuePair<string, long>>();
                foreach (var path in Directory.GetFiles(Interface.Oxide.LogDirectory, "hotwire_log_????-??-??.txt").OrderBy(p => p, StringComparer.Ordinal))
                {
                    var name = Path.GetFileName(path);
                    DateTime date;
                    if (!LogSpoolDate(name, out date)) continue;
                    if (string.CompareOrdinal(name, _logCursor.SpoolFile ?? "") < 0 || date < oldest) File.Delete(path);
                    else kept.Add(new KeyValuePair<string, long>(path, new FileInfo(path).Length));
                }

                var total = kept.Sum(k => k.Value);
                foreach (var file in kept)
                {
                    if (total <= LogSpoolMaxBytes || Path.GetFileName(file.Key) == today) break;
                    File.Delete(file.Key);
                    total -= file.Value;
                    PrintWarning($"Panel: {Path.GetFileName(file.Key)} was removed unsent: the log waiting for the panel is past {LogSpoolMaxBytes / (1024 * 1024)} MB. The server's own logs are untouched.");
                }
            }
            catch (Exception ex)
            {
                PrintWarning($"Panel: old log spool files could not be removed ({ex.Message}).");
            }
        }

        // Sends the next batch of the spool. A batch the panel has not accepted is
        // sent again as it was, with the same report id, so a retry never stores
        // a line twice. Returns whether a request went out.
        private bool SendLog()
        {
            var interval = LogInterval();
            if (!PolicyAllowsKind("log"))
            {
                // A batch built before was never committed, so its lines are read again later.
                _logPending = null;
                if (PolicyHolds(_policy))
                {
                    // Held: the cursor stays where it is, so the lines go when the log is allowed again.
                    _logDue = DateTime.UtcNow.AddSeconds(interval);
                    _logState = $"held: the panel's report policy does not include the log; lines wait here, up to {SpoolDays()} days";
                    return false;
                }

                // Walk on and count, so nothing piles up; the counts go with the
                // first batch once the log is allowed again.
                BuildLogBatch();
                _logDue = _logSkippedMore ? DateTime.UtcNow : DateTime.UtcNow.AddSeconds(interval);
                _logState = "not sent: the panel's report policy does not include the log; lines are counted";
                return false;
            }

            // Behind (an earlier day's spool, or more than one batch waiting): one
            // batch at a time, never back to back, so a long catch-up is gentle.
            var catchingUp = LogBehind();
            if (catchingUp && DateTime.UtcNow < _catchUpDue)
            {
                _logDue = _catchUpDue;
                return false;
            }

            if (_logPending == null) _logPending = BuildLogBatch();
            if (_logPending == null)
            {
                // Lines the policy kept here were passed over: read on at the next tick.
                _logDue = _logSkippedMore ? DateTime.UtcNow : DateTime.UtcNow.AddSeconds(interval);
                return false;
            }

            var batch = _logPending;
            if (catchingUp || batch.More) _catchUpDue = DateTime.UtcNow.AddSeconds(SpoolDrainSeconds);
            PanelRequest("POST", PanelReportPath, batch.Body, response =>
            {
                CommitLogBatch(batch);
                _logLinesSent += batch.Lines;
                _logState = $"{_logLinesSent} line{(_logLinesSent == 1 ? "" : "s")} sent since load, last at {DateTime.Now:HH:mm:ss}";
                _logMore = batch.More;
                _logDue = batch.More || LogBehind() ? _catchUpDue : DateTime.UtcNow.AddSeconds(interval);
            }, () =>
            {
                if (_panelLastCode == 413 && batch.Walked > 1)
                {
                    // Too large for the panel's web server: split it, never drop it.
                    _logBatchLines = Math.Max(1, batch.Walked / 2);
                    _logPending = null;
                    _logDue = DateTime.MinValue;
                    return;
                }

                // The panel understood these lines and refused them; the same
                // bytes would be refused again, so they are let go.
                PrintWarning($"Panel: {batch.Lines} log line{(batch.Lines == 1 ? " was" : "s were")} refused (HTTP {_panelLastCode}) and will not be sent again.");
                CommitLogBatch(batch);
            }, 60f);
            return true;
        }

        // Whether the log is behind: the last batch left more to send, or the
        // cursor is still in an earlier day's spool.
        private bool LogBehind()
        {
            if (_logMore) return true;
            if (_logCursor == null) return false;
            return string.CompareOrdinal(_logCursor.SpoolFile ?? "", LogSpoolName(DateTime.Now)) < 0;
        }

        private void CommitLogBatch(LogSendBatch batch)
        {
            if (!ReferenceEquals(batch, _logPending)) return;
            _logPending = null;
            _logCursor.SpoolFile = batch.SpoolFile;
            _logCursor.SpoolOffset = batch.EndOffset;
            _logCursor.Seq = batch.EndSeq;
            // The batch carried these counts; any counted since stay for the next.
            if (_logCursor.NotSent != null && batch.NotSentCarried != null)
            {
                foreach (var pair in batch.NotSentCarried)
                {
                    long n;
                    if (!_logCursor.NotSent.TryGetValue(pair.Key, out n)) continue;
                    if (n - pair.Value > 0) _logCursor.NotSent[pair.Key] = n - pair.Value;
                    else _logCursor.NotSent.Remove(pair.Key);
                }
                if (_logCursor.NotSent.Count == 0) _logCursor.NotSent = null;
                else _logCursor.NotSentSinceUtc = DateTime.UtcNow;
            }
            WriteData(LogDataFile, _logCursor);
        }

        private void LoadLogCursor()
        {
            if (_logCursor != null) return;

            var saved = ReadData<LogCursor>(LogDataFile);
            // The names come from a file on disk and go into a path: only the two
            // exact forms this plugin writes are read, never anything else.
            DateTime named;
            if (saved != null && !IsOxideLogName(saved.ImportFile)) saved.ImportFile = null;
            if (saved != null && !LogSpoolDate(saved.SpoolFile, out named)) saved.SpoolFile = null;
            if (saved == null || string.IsNullOrEmpty(saved.ImportFile))
            {
                // First time: today's Oxide file from its start, so this boot's
                // compile failures are included.
                saved = saved ?? new LogCursor();
                saved.ImportFile = OxideLogName(DateTime.Now);
                saved.ImportOffset = 0;
            }
            if (string.IsNullOrEmpty(saved.SpoolFile))
            {
                // First time with the spool: it starts empty, today.
                saved.SpoolFile = LogSpoolName(DateTime.Now);
                saved.SpoolOffset = 0;
            }

            var start = ProcessStartTicks();
            if (saved.SessionKey == null || start == 0 || saved.ProcessStartTicks != start)
            {
                saved.SessionKey = LogSessionKey(start == 0 ? DateTime.UtcNow.Ticks : start, ServerRoot() ?? "");
                saved.ProcessStartTicks = start;
                saved.Seq = 0;
            }

            _logCursor = saved;
            WriteData(LogDataFile, _logCursor);
        }

        private static long ProcessStartTicks()
        {
            try
            {
                var ticks = System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks;
                return ticks / TimeSpan.TicksPerSecond * TimeSpan.TicksPerSecond;
            }
            catch
            {
                return 0;
            }
        }

        private static bool IsOxideLogName(string fileName)
        {
            DateTime date;
            return fileName != null && fileName.Length == 20 && fileName.StartsWith("oxide_", StringComparison.Ordinal) && fileName.EndsWith(".txt", StringComparison.Ordinal)
                && DateTime.TryParseExact(fileName.Substring(6, 10), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out date);
        }

        private static string OxideLogName(DateTime localDate)
        {
            return "oxide_" + localDate.ToString("yyyy'-'MM'-'dd", CultureInfo.InvariantCulture) + ".txt";
        }

        private static string NextOxideLog(string dir, string after)
        {
            try
            {
                return Directory.GetFiles(dir, "oxide_????-??-??.txt")
                    .Select(Path.GetFileName)
                    .Where(name => IsOxideLogName(name) && string.CompareOrdinal(name, after) > 0)
                    .OrderBy(name => name, StringComparer.Ordinal)
                    .FirstOrDefault();
            }
            catch
            {
                return null;
            }
        }

        // The next batch from the spool: a run of lines from one stream (Oxide or
        // the console), as many as a batch takes, with what the policy keeps
        // here counted instead.
        private LogSendBatch BuildLogBatch()
        {
            _logSkippedMore = false;
            LoadLogCursor();
            var dir = Interface.Oxide.LogDirectory;
            var today = LogSpoolName(DateTime.Now);

            for (var hops = 0; hops < 400; hops++)
            {
                DateTime date;
                var tooOld = LogSpoolDate(_logCursor.SpoolFile, out date) && date < DateTime.Now.Date.AddDays(-SpoolDays());
                var current = Path.Combine(dir, _logCursor.SpoolFile);
                var length = File.Exists(current) ? new FileInfo(current).Length : -1;
                if (length >= 0 && _logCursor.SpoolOffset > length) _logCursor.SpoolOffset = 0;   // the file was replaced
                if (!tooOld && length >= 0 && _logCursor.SpoolOffset < length) break;
                if (!tooOld && string.CompareOrdinal(_logCursor.SpoolFile, today) >= 0) return null;

                var next = NextLogSpool(dir, _logCursor.SpoolFile) ?? (string.CompareOrdinal(_logCursor.SpoolFile, today) < 0 ? today : null);
                if (next == null) return null;
                _logCursor.SpoolFile = next;
                _logCursor.SpoolOffset = 0;
                WriteData(LogDataFile, _logCursor);
            }

            var file = _logCursor.SpoolFile;
            var path = Path.Combine(dir, file);
            if (!File.Exists(path)) return null;

            byte[] buffer;
            int read = 0;
            long fileLength;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                fileLength = stream.Length;
                if (_logCursor.SpoolOffset >= fileLength) return null;
                stream.Seek(_logCursor.SpoolOffset, SeekOrigin.Begin);
                buffer = new byte[(int)Math.Min(LogMaxReadBytes, fileLength - _logCursor.SpoolOffset)];
                while (read < buffer.Length)
                {
                    var n = stream.Read(buffer, read, buffer.Length - read);
                    if (n <= 0) break;
                    read += n;
                }
            }
            var atEnd = _logCursor.SpoolOffset + read >= fileLength;

            // Every spool line is written whole, so only a crash mid-write leaves
            // half of one; it is passed over once the day is done.
            var entries = new List<KeyValuePair<long, SpooledLine>>();
            var pos = 0;
            long unreadable = 0;
            for (var i = 0; i < read; i++)
            {
                if (buffer[i] != (byte)'\n') continue;
                var parsed = ReadSpoolLogLine(Encoding.UTF8.GetString(buffer, pos, i - pos));
                if (parsed == null) unreadable++;
                else entries.Add(new KeyValuePair<long, SpooledLine>(_logCursor.SpoolOffset + pos, parsed));
                pos = i + 1;
            }
            long consumed = _logCursor.SpoolOffset + pos;
            if (atEnd && pos < read && string.CompareOrdinal(file, today) < 0) { unreadable++; consumed = _logCursor.SpoolOffset + read; }
            if (unreadable > 0) AddNotSent("none", unreadable);

            if (entries.Count == 0)
            {
                if (consumed > _logCursor.SpoolOffset)
                {
                    _logCursor.SpoolOffset = consumed;
                    WriteData(LogDataFile, _logCursor);
                    _logSkippedMore = !atEnd;
                }
                else if (read == LogMaxReadBytes)
                {
                    PrintWarning($"Panel: a line in {file} is longer than {LogMaxReadBytes} bytes and is not sent.");
                    _logCursor.SpoolOffset += read;
                    WriteData(LogDataFile, _logCursor);
                }
                return null;
            }

            // One stream a batch: the run of lines from the first line's stream.
            var streamChar = entries[0].Value.Stream;
            var run = 1;
            while (run < entries.Count && entries[run].Value.Stream == streamChar) run++;

            var level = EffectiveSharingLevel();
            var logAllowed = PolicyAllowsKind("log");
            var count = Math.Min(run, _logBatchLines);
            while (true)
            {
                var lines = new JArray();
                var notSent = _logCursor.NotSent == null
                    ? new Dictionary<string, long>(StringComparer.Ordinal)
                    : new Dictionary<string, long>(_logCursor.NotSent, StringComparer.Ordinal);
                var keptHere = new Dictionary<string, long>(StringComparer.Ordinal);
                for (var i = 0; i < count; i++)
                {
                    var entry = entries[i].Value;
                    // A line the policy keeps here still takes its seq, so a line's
                    // seq never depends on which policy was in force.
                    if (!logAllowed || !PolicyAllowsLogLevel(entry.Level))
                    {
                        // A line with no level is only kept here when no log is sent at all.
                        var key = entry.Level ?? "none";
                        long n;
                        notSent.TryGetValue(key, out n);
                        notSent[key] = n + 1;
                        keptHere.TryGetValue(key, out n);
                        keptHere[key] = n + 1;
                        continue;
                    }
                    // Every line's text is sent. What can be picked out is removed
                    // first: card numbers, SSNs and IP addresses always, the value
                    // of an RCON command that sets a secret, and a Steam ID below
                    // the identified level. Nothing else is held back.
                    var body = MaskIps(MaskSourceGates(entry.Stream == 'e' ? MaskRconSecrets(entry.Text) : entry.Text));
                    var line = new JObject { ["seq"] = _logCursor.Seq + i + 1 };
                    if (entry.At != null) line["at"] = entry.At;
                    line["level"] = entry.Level == null ? JValue.CreateNull() : (JToken)entry.Level;
                    line["source"] = entry.Source == null ? JValue.CreateNull() : (JToken)entry.Source;
                    line["message"] = level >= 3 ? body : BlockSteamIds(body);
                    lines.Add(line);
                }

                var endOffset = count < entries.Count ? entries[count].Key : consumed;
                var endSeq = _logCursor.Seq + count;
                var more = count < entries.Count || !atEnd || NextLogSpool(dir, file) != null;

                if (lines.Count == 0)
                {
                    // Nothing here the policy sends. Move past it and keep the
                    // counts with the cursor, so a reload does not lose them.
                    foreach (var pair in keptHere) AddNotSent(pair.Key, pair.Value);
                    _logCursor.SpoolFile = file;
                    _logCursor.SpoolOffset = endOffset;
                    _logCursor.Seq = endSeq;
                    WriteData(LogDataFile, _logCursor);
                    _logSkippedMore = more;

                    if (!logAllowed || more || _logCursor.NotSent == null || (DateTime.UtcNow - _logCursor.NotSentSinceUtc).TotalSeconds < LogNotSentFlushSeconds) return null;
                    notSent = new Dictionary<string, long>(_logCursor.NotSent, StringComparer.Ordinal);
                }

                var payload = new JObject
                {
                    ["stream"] = streamChar == 'e' ? "engine" : "oxide",
                    ["session_key"] = _logCursor.SessionKey,
                    ["sharing_level"] = level,
                    ["lines"] = lines,
                    ["withheld"] = 0
                };
                if (notSent.Count > 0) payload["not_sent"] = JObject.FromObject(notSent);
                var envelope = PanelEnvelope("log", payload);
                if (envelope.Length > LogMaxBodyChars && count > 1)
                {
                    count = Math.Max(1, count / 2);
                    continue;
                }

                // Carried: what was counted before this batch, and what it keeps
                // here itself, which only becomes the cursor's when it is accepted.
                if (lines.Count > 0)
                    foreach (var pair in keptHere)
                    {
                        long n;
                        notSent.TryGetValue(pair.Key, out n);
                        if (n - pair.Value > 0) notSent[pair.Key] = n - pair.Value; else notSent.Remove(pair.Key);
                    }

                return new LogSendBatch
                {
                    Body = envelope,
                    SpoolFile = file,
                    EndOffset = lines.Count == 0 ? _logCursor.SpoolOffset : endOffset,
                    EndSeq = lines.Count == 0 ? _logCursor.Seq : endSeq,
                    Lines = lines.Count,
                    Walked = lines.Count == 0 ? 0 : count,
                    More = more,
                    NotSentCarried = notSent
                };
            }
        }

        #region Report policy

        // No game or Oxide types: checked outside the game, like the regions below.

        private sealed class ReportPolicy
        {
            public string Name;
            public string Hash;
            public int HeartbeatSeconds;      // 0: as the config says
            public int PluginTimeSeconds;     // 0: as the config says
            public int CommandSeconds;        // 0: as the config says, and so on
            public int BanSeconds;
            public int LogSeconds;
            public int EventSeconds;
            public int MarkerSeconds;
            public int PolicySeconds;         // 0: every five minutes
            public HashSet<string> LogLevels; // null: every level
            public bool? Commands;            // null: as the config says
            public bool? Bans;
            public HashSet<string> Kinds;     // null: every kind
            public bool Hold;                 // keep what Kinds stops, to send later
            public DateTime ReceivedUtc;
        }

        // Which reports may be sent at all. Polls are not reports.
        private static bool PolicyAllowsKindOf(ReportPolicy policy, string kind)
        {
            return policy == null || policy.Kinds == null || policy.Kinds.Contains(kind);
        }

        // Whether what the policy stops is kept here, to send when it is allowed again.
        private static bool PolicyHolds(ReportPolicy policy)
        {
            return policy != null && policy.Hold;
        }

        // A line with no level cannot be classified, so it is sent.
        private static bool PolicyAllowsLevel(ReportPolicy policy, string level)
        {
            if (policy == null || policy.LogLevels == null || string.IsNullOrEmpty(level)) return true;
            return policy.LogLevels.Contains(level.ToLowerInvariant());
        }

        // Null when the answer cannot be read. A field that is missing or not
        // of its type leaves that one thing as the config has it.
        private static ReportPolicy ReadPolicy(string response)
        {
            try
            {
                var envelope = JObject.Parse(response);
                var ok = envelope["ok"] != null && envelope["ok"].Type == JTokenType.Boolean && (bool)envelope["ok"];
                var data = envelope["data"] as JObject;
                if (!ok || data == null) return null;

                var policy = new ReportPolicy
                {
                    Name = data["policy"] != null && data["policy"].Type == JTokenType.String ? (string)data["policy"] : null,
                    Hash = data["policy_hash"] != null && data["policy_hash"].Type == JTokenType.String ? (string)data["policy_hash"] : null,
                    HeartbeatSeconds = PositiveInt(data["heartbeat_seconds"]),
                    PluginTimeSeconds = PositiveInt(data["plugin_time_seconds"]),
                    CommandSeconds = PositiveInt(data["command_seconds"]),
                    BanSeconds = PositiveInt(data["ban_seconds"]),
                    LogSeconds = PositiveInt(data["log_seconds"]),
                    EventSeconds = PositiveInt(data["event_seconds"]),
                    MarkerSeconds = PositiveInt(data["marker_seconds"]),
                    PolicySeconds = PositiveInt(data["policy_seconds"]),
                    Commands = data["commands"] != null && data["commands"].Type == JTokenType.Boolean ? (bool)data["commands"] : (bool?)null,
                    Bans = data["bans"] != null && data["bans"].Type == JTokenType.Boolean ? (bool)data["bans"] : (bool?)null,
                    Hold = data["hold"] != null && data["hold"].Type == JTokenType.Boolean && (bool)data["hold"],
                    ReceivedUtc = DateTime.UtcNow
                };

                var levels = data["log_levels"] as JArray;
                if (levels != null && levels.All(l => l.Type == JTokenType.String))
                    policy.LogLevels = new HashSet<string>(levels.Select(l => ((string)l).ToLowerInvariant()), StringComparer.Ordinal);

                var kinds = data["kinds"] as JArray;
                if (kinds != null && kinds.All(k => k.Type == JTokenType.String))
                    policy.Kinds = new HashSet<string>(kinds.Select(k => (string)k), StringComparer.Ordinal);

                return policy;
            }
            catch
            {
                return null;
            }
        }

        // How often something is done: the config's interval (never below its
        // floor), made longer by the panel's when the panel's is longer, and
        // the panel's never taken above a cap, so a mistaken answer cannot
        // make a server look silent or leave a command waiting for an hour.
        // 0 from the panel means it said nothing.
        private static int PolicyInterval(int configured, int floor, int fromPanel, int cap)
        {
            var seconds = Math.Max(floor, configured);
            return fromPanel <= 0 ? seconds : Math.Max(seconds, Math.Min(cap, fromPanel));
        }

        private static int PositiveInt(JToken token)
        {
            if (token == null || token.Type != JTokenType.Integer) return 0;
            try
            {
                var value = (long)token;
                return value > 0 && value <= int.MaxValue ? (int)value : 0;
            }
            catch { return 0; }   // larger than a long
        }

        #endregion

        #region Spool rules

        // No game or Oxide types: checked outside the game, like the regions below.

        // Kept for thirty days, then let go unsent: a server back after a long
        // time must not flood the panel, and the customer's disk is not ours.
        private const long SpoolMaxBytes = 50L * 1024 * 1024;
        private const int SpoolMaxFiles = 5000;

        private sealed class SpoolEntry
        {
            public string Path;
            public DateTime SentUtc;
            public long Bytes;
        }

        // Only reports that cannot be sent again are kept. The rest report the
        // current state, which the next pass sends afresh.
        private static bool SpoolKeepsKind(string kind)
        {
            return kind == "session" || kind == "events" || kind == "command_result";
        }

        // No answer, a timeout, "slow down" or a server error: the same report
        // may be taken later. Any other refusal would be refused again.
        private static bool SpoolKeepsStatus(int code)
        {
            return code <= 0 || code == 429 || (code >= 500 && code <= 599);
        }

        // Names sort oldest first: when the report was made, then its id.
        private static string SpoolFileName(DateTime sentUtc, string reportId)
        {
            return sentUtc.ToUniversalTime().ToString("yyyyMMdd'T'HHmmssfff", CultureInfo.InvariantCulture) + "_" + reportId + ".json";
        }

        private static DateTime? SpoolFileTime(string fileName)
        {
            DateTime time;
            if (fileName == null || fileName.Length < 18) return null;
            return DateTime.TryParseExact(fileName.Substring(0, 18), "yyyyMMdd'T'HHmmssfff", CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out time) ? time : (DateTime?)null;
        }

        // Which kept reports go unsent: anything older than the kept days, then
        // the oldest until what is left fits. Entries are oldest first.
        private static void SpoolPrune(List<SpoolEntry> entries, DateTime nowUtc, int days, out List<SpoolEntry> expired, out List<SpoolEntry> overflowed)
        {
            var limit = TimeSpan.FromDays(days);
            expired = entries.Where(e => nowUtc - e.SentUtc > limit).ToList();
            var kept = entries.Where(e => nowUtc - e.SentUtc <= limit).ToList();
            overflowed = new List<SpoolEntry>();
            var bytes = kept.Sum(e => e.Bytes);
            var i = 0;
            while (i < kept.Count && (kept.Count - i > SpoolMaxFiles || bytes > SpoolMaxBytes))
            {
                overflowed.Add(kept[i]);
                bytes -= kept[i].Bytes;
                i++;
            }
        }

        // A log file whose name says it is older than the kept days is skipped,
        // not read. A name that is not a date is never skipped.
        private static bool LogFileTooOld(string fileName, DateTime localToday, int days)
        {
            DateTime date;
            if (fileName == null || fileName.Length < 16) return false;
            if (!DateTime.TryParseExact(fileName.Substring(6, 10), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out date)) return false;
            return date < localToday.Date.AddDays(-days);
        }

        #endregion

        #region Manifest

        // No game or Oxide types: checked outside the game. The Steam branch in
        // the app manifest, read exactly as hotwire-setup reads it: UserConfig's
        // BetaKey. No key, or an empty one, is the public branch.
        private static string ManifestBranch(string manifest)
        {
            if (string.IsNullOrEmpty(manifest)) return null;
            var match = System.Text.RegularExpressions.Regex.Match(manifest, "\"UserConfig\"\\s*\\{[^}]*\"BetaKey\"\\s+\"([^\"]*)\"");
            return match.Success && match.Groups[1].Value.Length > 0 ? match.Groups[1].Value : "public";
        }

        #endregion

        #region Log lines

        // No game or Oxide types in this region either: it is compiled and
        // checked outside the game against the panel's published vectors and
        // real Oxide logs. No regular expressions -- these run on the game
        // thread, and a scan cannot backtrack.

        private static readonly string[] OxideLogTypes = { "Chat", "Error", "Info", "Warning", "Debug" };

        private sealed class OxideLine
        {
            public bool Recognised;
            public int Hour = -1;
            public int Minute = -1;
            public string Level;
            public string Source;
            public string Body = "";
        }

        // Oxide writes "<short time> [<type>] <text>", the time in the machine's
        // own culture ("18:52", "6:52 PM"). A plugin's own line starts its text
        // with "[<plugin title>] ". A line that does not start this way belongs
        // to the one before it (a stack trace). A time that cannot be read is
        // left out, never guessed.
        private static OxideLine ParseOxideLine(string text)
        {
            var result = new OxideLine { Body = text ?? "" };
            if (string.IsNullOrEmpty(text)) return result;

            var open = text.IndexOf(" [", StringComparison.Ordinal);
            if (open < 0 || open > 16) return result;

            var close = text.IndexOf(']', open + 2);
            if (close < 0 || (close + 1 < text.Length && text[close + 1] != ' ')) return result;

            var type = text.Substring(open + 2, close - open - 2);
            if (Array.IndexOf(OxideLogTypes, type) < 0) return result;

            result.Recognised = true;
            result.Level = type.ToLowerInvariant();
            ReadShortTime(text.Substring(0, open), out result.Hour, out result.Minute);

            var rest = close + 2 <= text.Length ? text.Substring(close + 2) : "";
            if (rest.Length > 0 && rest[0] == '[')
            {
                var end = rest.IndexOf("] ", StringComparison.Ordinal);
                if (end > 1 && end <= 64)
                {
                    result.Source = rest.Substring(1, end - 1);
                    rest = rest.Substring(end + 2);
                }
            }
            result.Body = rest;
            return result;
        }

        private static void ReadShortTime(string text, out int hour, out int minute)
        {
            hour = -1;
            minute = -1;
            var s = text.Trim();
            var i = 0;
            var h = 0;
            var digits = 0;
            while (i < s.Length && s[i] >= '0' && s[i] <= '9' && digits < 2) { h = h * 10 + (s[i] - '0'); i++; digits++; }
            if (digits == 0 || i >= s.Length || (s[i] != ':' && s[i] != '.')) return;
            i++;
            if (i + 2 > s.Length || s[i] < '0' || s[i] > '9' || s[i + 1] < '0' || s[i + 1] > '9') return;
            var m = (s[i] - '0') * 10 + (s[i + 1] - '0');
            i += 2;

            var suffix = s.Substring(i).Trim().ToUpperInvariant();
            if (suffix == "AM" || suffix == "PM")
            {
                if (h < 1 || h > 12) return;
                if (suffix == "AM" && h == 12) h = 0;
                else if (suffix == "PM" && h != 12) h += 12;
            }
            else if (suffix.Length != 0)
            {
                return;
            }

            if (h > 23 || m > 59) return;
            hour = h;
            minute = m;
        }

        // The local wall-clock time Oxide wrote, in UTC. A time the clock went
        // past twice (the hour DST repeats) or never showed (the hour it skips)
        // has no single answer, so there is no time.
        private static string LogLineUtc(DateTime fileDate, int hour, int minute, TimeZoneInfo zone)
        {
            if (hour < 0 || minute < 0 || fileDate == DateTime.MinValue) return null;
            var local = new DateTime(fileDate.Year, fileDate.Month, fileDate.Day, hour, minute, 0, DateTimeKind.Unspecified);
            if (zone.IsInvalidTime(local) || zone.IsAmbiguousTime(local)) return null;
            return TimeZoneInfo.ConvertTimeToUtc(local, zone).ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture);
        }

        // The line's shape, frozen by the contract: runs of ASCII digits become
        // "0", runs of ASCII letters "a", runs of anything else above ASCII "u";
        // then sha256 over the source, 0x1F and the result.
        private static string LogShape(string source, string body)
        {
            var sb = new StringBuilder(body.Length);
            var i = 0;
            while (i < body.Length)
            {
                var kind = ShapeClass(body[i]);
                if (kind == '\0')
                {
                    sb.Append(body[i]);
                    i++;
                    continue;
                }
                sb.Append(kind);
                while (i < body.Length && ShapeClass(body[i]) == kind) i++;
            }
            return "sha256:" + Sha256Hex((source ?? "") + "" + sb);
        }

        private static char ShapeClass(char c)
        {
            if (c >= '0' && c <= '9') return '0';
            if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) return 'a';
            return c > '' ? 'u' : '\0';
        }

        private static int CountTokens(string body)
        {
            var count = 0;
            var inToken = false;
            foreach (var c in body)
            {
                if (char.IsWhiteSpace(c)) { inToken = false; continue; }
                if (!inToken) count++;
                inToken = true;
            }
            return count;
        }

        // What a withheld line may hold, suspected from its shape alone:
        // identity (a Steam ID), position (three numbers in brackets), chat
        // (Oxide's chat level), network (an IPv4 address).
        private static List<string> SuspectedPii(string body, string level)
        {
            var classes = new List<string>();
            if (ContainsSteamId(body)) classes.Add("identity");
            if (ContainsPosition(body)) classes.Add("position");
            if (level == "chat") classes.Add("chat");
            if (ContainsIpv4(body)) classes.Add("network");
            return classes;
        }

        private static bool IsDigit(string s, int i) => i >= 0 && i < s.Length && s[i] >= '0' && s[i] <= '9';

        // Every Steam ID64 becomes [blocked:identity], the panel's own marker, so
        // the panel sees exactly what it would have removed itself.
        private static string BlockSteamIds(string s)
        {
            if (s.IndexOf("7656119", StringComparison.Ordinal) < 0) return s;
            var sb = new StringBuilder(s.Length);
            var i = 0;
            while (i < s.Length)
            {
                var at = s.IndexOf("7656119", i, StringComparison.Ordinal);
                if (at < 0) { sb.Append(s, i, s.Length - i); break; }
                var j = at + 7;
                var run = 0;
                while (IsDigit(s, j)) { j++; run++; }
                if (!IsDigit(s, at - 1) && run == 10)
                {
                    sb.Append(s, i, at - i).Append("[blocked:identity]");
                    i = j;
                }
                else
                {
                    sb.Append(s, i, at + 1 - i);
                    i = at + 1;
                }
            }
            return sb.ToString();
        }

        private static bool ContainsSteamId(string s)
        {
            var at = 0;
            while ((at = s.IndexOf("7656119", at, StringComparison.Ordinal)) >= 0)
            {
                if (!IsDigit(s, at - 1))
                {
                    var j = at + 7;
                    var run = 0;
                    while (IsDigit(s, j)) { j++; run++; }
                    if (run == 10) return true;
                }
                at++;
            }
            return false;
        }

        private static bool ContainsPosition(string s)
        {
            for (var i = s.IndexOf('('); i >= 0; i = s.IndexOf('(', i + 1))
            {
                var j = i + 1;
                var ok = true;
                for (var n = 0; n < 3 && ok; n++)
                {
                    while (j < s.Length && s[j] == ' ') j++;
                    if (j < s.Length && s[j] == '-') j++;
                    var start = j;
                    while (IsDigit(s, j) || (j < s.Length && s[j] == '.')) j++;
                    ok = j > start;
                    while (j < s.Length && s[j] == ' ') j++;
                    if (ok && n < 2) ok = j < s.Length && s[j++] == ',';
                }
                if (ok && j < s.Length && s[j] == ')') return true;
            }
            return false;
        }

        private static bool ContainsIpv4(string s)
        {
            for (var i = 0; i < s.Length; i++)
            {
                if (!IsDigit(s, i) || IsDigit(s, i - 1) || (i > 0 && s[i - 1] == '.')) continue;
                var j = i;
                var parts = 0;
                while (parts < 4)
                {
                    var start = j;
                    var value = 0;
                    while (IsDigit(s, j) && j - start < 3) { value = value * 10 + (s[j] - '0'); j++; }
                    if (j == start || IsDigit(s, j) || value > 255) break;
                    parts++;
                    if (parts == 4) break;
                    if (j >= s.Length || s[j] != '.') break;
                    j++;
                }
                if (parts == 4 && !(j < s.Length && s[j] == '.' && IsDigit(s, j + 1))) return true;
            }
            return false;
        }

        // A card number keeps its last four digits and its separators; a
        // hyphenated US SSN becomes ###-##-####. The panel checks again on
        // arrival; this keeps them off the wire in the first place.
        private static string MaskSourceGates(string body)
        {
            // A card has at least 13 digits and an SSN 9, joined at most by spaces
            // or hyphens: a line with no such run has nothing to mask, and most
            // lines have none. Checked without allocating.
            if (!HasLongDigitRun(body, 9)) return body;
            var chars = body.ToCharArray();
            for (var i = 0; i < chars.Length; i++)
            {
                if (chars[i] < '0' || chars[i] > '9') continue;
                if (i > 0 && (chars[i - 1] >= '0' && chars[i - 1] <= '9')) continue;
                if (i > 1 && (chars[i - 1] == ' ' || chars[i - 1] == '-') && chars[i - 2] >= '0' && chars[i - 2] <= '9') continue;

                var positions = new List<int>();
                var j = i;
                while (j < chars.Length && positions.Count <= 19)
                {
                    if (chars[j] >= '0' && chars[j] <= '9') { positions.Add(j); j++; continue; }
                    if ((chars[j] == ' ' || chars[j] == '-') && j + 1 < chars.Length && chars[j + 1] >= '0' && chars[j + 1] <= '9' && j > i) { j++; continue; }
                    break;
                }
                var digits = positions.Count;
                if (digits >= 13 && digits <= 19 && !(j < chars.Length && chars[j] >= '0' && chars[j] <= '9') &&
                    chars[positions[0]] >= '2' && chars[positions[0]] <= '6' && PassesLuhn(chars, positions))
                {
                    for (var k = 0; k < digits - 4; k++) chars[positions[k]] = '#';
                }
                i = j;
            }

            for (var i = 0; i + 11 <= chars.Length; i++)
            {
                if (!SsnAt(chars, i)) continue;
                for (var k = 0; k < 11; k++) if (chars[i + k] != '-') chars[i + k] = '#';
                i += 10;
            }
            return new string(chars);
        }

        private static bool HasLongDigitRun(string s, int digits)
        {
            if (string.IsNullOrEmpty(s)) return false;
            var run = 0;
            for (var i = 0; i < s.Length; i++)
            {
                var c = s[i];
                if (c >= '0' && c <= '9') { if (++run >= digits) return true; continue; }
                if ((c == ' ' || c == '-') && run > 0 && i + 1 < s.Length && s[i + 1] >= '0' && s[i + 1] <= '9') continue;
                run = 0;
            }
            return false;
        }

        private static bool PassesLuhn(char[] chars, List<int> positions)
        {
            var sum = 0;
            var doubleIt = false;
            for (var k = positions.Count - 1; k >= 0; k--)
            {
                var d = chars[positions[k]] - '0';
                if (doubleIt) { d *= 2; if (d > 9) d -= 9; }
                sum += d;
                doubleIt = !doubleIt;
            }
            return sum % 10 == 0;
        }

        private static bool SsnAt(char[] c, int i)
        {
            Func<int, bool> digit = k => k >= 0 && k < c.Length && c[k] >= '0' && c[k] <= '9';
            Func<int, bool> word = k => k >= 0 && k < c.Length && (char.IsLetterOrDigit(c[k]) || c[k] == '_');
            for (var k = 0; k < 11; k++)
            {
                var hyphen = k == 3 || k == 6;
                if (hyphen ? c[i + k] != '-' : !digit(i + k)) return false;
            }
            if (word(i - 1) || word(i + 11)) return false;
            if (i >= 2 && (c[i - 1] == '.' || c[i - 1] == ',' || c[i - 1] == '-') && digit(i - 2)) return false;
            if (i + 12 < c.Length && (c[i + 11] == '.' || c[i + 11] == ',' || c[i + 11] == '-') && digit(i + 12)) return false;
            return true;
        }

        // A UUID naming this server process, the same for every reload inside
        // it: the version-8 form of a sha256 over the process's start time and
        // the server's folder.
        private static string LogSessionKey(long processStartTicks, string root)
        {
            byte[] hash;
            using (var sha = System.Security.Cryptography.SHA256.Create())
                hash = sha.ComputeHash(Encoding.UTF8.GetBytes("hotwire-log-session" + processStartTicks.ToString(CultureInfo.InvariantCulture) + "" + root));
            var bytes = new byte[16];
            Array.Copy(hash, bytes, 16);
            bytes[6] = (byte)((bytes[6] & 0x0F) | 0x80);
            bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
            var h = Hex(bytes);
            return h.Substring(0, 8) + "-" + h.Substring(8, 4) + "-" + h.Substring(12, 4) + "-" + h.Substring(16, 4) + "-" + h.Substring(20);
        }

        #endregion

        #region Console log

        // No game or Oxide types: compiled and checked outside the game. No
        // regular expressions either; these run on the game thread.

        // Rust prints chat to its console as "[<channel>] <name> : <text>"
        // (ConVar.Chat, its ChatChannel names). Chat has its own setting and its
        // own gates, so it never travels as a log line.
        private static readonly string[] ChatChannels = { "Global", "Team", "Server", "Cards", "Local", "Clan", "ExternalDM" };

        private static bool IsChatLine(string text)
        {
            if (string.IsNullOrEmpty(text) || text[0] != '[') return false;
            var close = text.IndexOf("] ", 1, StringComparison.Ordinal);
            if (close < 2 || close > 12) return false;
            if (Array.IndexOf(ChatChannels, text.Substring(1, close - 1)) < 0) return false;
            return text.IndexOf(" : ", close + 2, StringComparison.Ordinal) >= 0;
        }

        // Unity's LogType by number (Error 0, Assert 1, Warning 2, Log 3,
        // Exception 4), named the way Oxide names its levels.
        private static string ConsoleLevel(int unityLogType)
        {
            switch (unityLogType)
            {
                case 2: return "warning";
                case 3: return "info";
                default: return "error";
            }
        }

        // A player's address is never needed to run a server from the panel, so
        // every IPv4 address, and every IPv6 address written with its colons,
        // becomes [blocked:network] -- the panel's own marker, as for a Steam ID
        // -- at every player data level. The port after one is kept.
        // A version number such as 2.1.3.4.5 is not an address and stays.
        private static string MaskIps(string s)
        {
            // Every address has a dot or a colon: most lines have neither to check.
            if (string.IsNullOrEmpty(s) || (s.IndexOf('.') < 0 && s.IndexOf(':') < 0)) return s;
            StringBuilder sb = null;
            var copied = 0;
            var i = 0;
            while (i < s.Length)
            {
                int end;
                var c = s[i];
                var found = false;
                if (c >= '0' && c <= '9' && !IsDigit(s, i - 1) && !(i > 0 && s[i - 1] == '.') && Ipv4At(s, i, out end)) found = true;
                else if ((IsHex(c) || c == ':') && (i == 0 || !(IsHex(s[i - 1]) || s[i - 1] == ':' || char.IsLetterOrDigit(s[i - 1]) || s[i - 1] == '_')) && Ipv6At(s, i, out end)) found = true;
                else end = i + 1;

                if (found)
                {
                    if (sb == null) sb = new StringBuilder(s.Length);
                    sb.Append(s, copied, i - copied).Append("[blocked:network]");
                    copied = end;
                }
                i = end;
            }
            if (sb == null) return s;
            sb.Append(s, copied, s.Length - copied);
            return sb.ToString();
        }

        private static bool IsHex(char c) => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');

        private static bool Ipv4At(string s, int i, out int end)
        {
            end = i;
            var j = i;
            for (var part = 0; part < 4; part++)
            {
                var start = j;
                var value = 0;
                while (IsDigit(s, j) && j - start < 3) { value = value * 10 + (s[j] - '0'); j++; }
                if (j == start || IsDigit(s, j) || value > 255) return false;
                if (part == 3) break;
                if (j >= s.Length || s[j] != '.') return false;
                j++;
            }
            if (j < s.Length && s[j] == '.' && IsDigit(s, j + 1)) return false;   // a longer dotted number
            end = j;
            return true;
        }

        // Hex groups of up to four digits between colons: all eight of them, or
        // fewer with "::". A time such as 12:34:56 has neither.
        private static bool Ipv6At(string s, int i, out int end)
        {
            end = i;
            var j = i;
            var colons = 0;
            while (j < s.Length && (IsHex(s[j]) || s[j] == ':')) { if (s[j] == ':') colons++; j++; }
            if (colons < 2) { end = j; return false; }
            // An IPv4 tail ("::ffff:10.0.0.1") is left to the IPv4 check.
            if (j < s.Length && s[j] == '.')
            {
                var colon = s.LastIndexOf(':', j - 1, j - i);
                if (colon < i) return false;
                j = colon + 1;
            }
            else if (j < s.Length && (char.IsLetterOrDigit(s[j]) || s[j] == '_')) return false;

            var text = s.Substring(i, j - i);
            colons = 0;
            foreach (var ch in text) if (ch == ':') colons++;
            var compressed = text.IndexOf("::", StringComparison.Ordinal) >= 0;
            if (colons < 2 || (!compressed && colons != 7) || text.IndexOf(":::", StringComparison.Ordinal) >= 0) return false;
            foreach (var group in text.Split(':'))
                if (group.Length > 4) return false;
            end = j;
            return true;
        }

        // Rust writes every RCON command into its console as it runs it:
        // "[RCON][<connection>] <command>", and "[rcon] <address>: <command>" when
        // rcon.print is on. A command that sets a password, a token or a key
        // would carry its value off the machine, so after such a command's name
        // the rest of the line becomes [blocked:credential], the panel's own
        // marker. The command's name stays, so the line still says what was run.
        private static readonly string[] CredentialWords = { "password", "passwd", "token", "secret", "apikey", "api_key", "api-key", "webhook", "key" };

        private static string MaskRconSecrets(string text)
        {
            if (string.IsNullOrEmpty(text) || text.Length < 8 || (text[0] != '[')) return text;
            int command;
            if (text.StartsWith("[RCON][", StringComparison.Ordinal))
            {
                var close = text.IndexOf("] ", 7, StringComparison.Ordinal);
                if (close < 0) return text;
                command = close + 2;
            }
            else if (text.StartsWith("[rcon] ", StringComparison.Ordinal))
            {
                var colon = text.IndexOf(": ", 7, StringComparison.Ordinal);
                if (colon < 0) return text;
                command = colon + 2;
            }
            else return text;

            while (command < text.Length && text[command] == ' ') command++;
            var nameEnd = command;
            while (nameEnd < text.Length && text[nameEnd] != ' ' && text[nameEnd] != '\t' && text[nameEnd] != '"') nameEnd++;
            if (nameEnd >= text.Length) return text;   // no value after the name
            var name = text.Substring(command, nameEnd - command).ToLowerInvariant();
            foreach (var word in CredentialWords)
                if (name.IndexOf(word, StringComparison.Ordinal) >= 0)
                    return text.Substring(0, nameEnd) + " [blocked:credential]";
            return text;
        }

        // One entry of the spool on one line: stream, time, level, source and
        // text, tab separated, with backslash, tab, CR and LF escaped.
        private sealed class SpooledLine
        {
            public char Stream;
            public string At;
            public string Level;
            public string Source;
            public string Text = "";
        }

        private static string SpoolLogLine(char stream, string at, string level, string source, string text)
        {
            return stream + "\t" + EscapeSpool(at) + "\t" + EscapeSpool(level) + "\t" + EscapeSpool(source) + "\t" + EscapeSpool(text);
        }

        private static SpooledLine ReadSpoolLogLine(string line)
        {
            if (line == null || line.Length < 5 || line[1] != '\t') return null;
            var fields = line.Split('\t');
            if (fields.Length != 5 || fields[0].Length != 1) return null;
            return new SpooledLine
            {
                Stream = fields[0][0],
                At = fields[1].Length == 0 ? null : UnescapeSpool(fields[1]),
                Level = fields[2].Length == 0 ? null : UnescapeSpool(fields[2]),
                Source = fields[3].Length == 0 ? null : UnescapeSpool(fields[3]),
                Text = UnescapeSpool(fields[4])
            };
        }

        private static string EscapeSpool(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            if (s.IndexOf('\\') < 0 && s.IndexOf('\t') < 0 && s.IndexOf('\n') < 0 && s.IndexOf('\r') < 0) return s;
            var sb = new StringBuilder(s.Length + 8);
            foreach (var c in s)
            {
                switch (c)
                {
                    case '\\': sb.Append("\\\\"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    default: sb.Append(c); break;
                }
            }
            return sb.ToString();
        }

        private static string UnescapeSpool(string s)
        {
            if (s.IndexOf('\\') < 0) return s;
            var sb = new StringBuilder(s.Length);
            for (var i = 0; i < s.Length; i++)
            {
                if (s[i] != '\\' || i + 1 >= s.Length) { sb.Append(s[i]); continue; }
                var next = s[++i];
                sb.Append(next == 't' ? '\t' : next == 'n' ? '\n' : next == 'r' ? '\r' : next);
            }
            return sb.ToString();
        }

        // The spool's file for a day, by the machine's own date, as Oxide names
        // its log files; and that date back from a name, or none.
        private static string LogSpoolName(DateTime localDate)
        {
            return "hotwire_log_" + localDate.ToString("yyyy'-'MM'-'dd", CultureInfo.InvariantCulture) + ".txt";
        }

        private static bool LogSpoolDate(string fileName, out DateTime date)
        {
            date = DateTime.MinValue;
            return fileName != null && fileName.Length == 26 && fileName.StartsWith("hotwire_log_", StringComparison.Ordinal)
                && DateTime.TryParseExact(fileName.Substring(12, 10), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out date);
        }

        // Oxide's own lines as it hands them to the console, kept a short while
        // to be recognised when the same text comes back through the game's log
        // callback: those are sent once, from Oxide's own log file. Bounded; a
        // flood past the bound forgets the oldest, which at worst lets an Oxide
        // line through twice.
        private sealed class EchoSet
        {
            private const int Max = 4096;
            private readonly Dictionary<string, Queue<long>> _seen = new Dictionary<string, Queue<long>>(StringComparer.Ordinal);
            private int _count;

            public int Count => _count;

            public void Add(string text, long ticks)
            {
                if (text == null) return;
                if (_count >= Max) Clear();
                Queue<long> times;
                if (!_seen.TryGetValue(text, out times)) _seen[text] = times = new Queue<long>();
                times.Enqueue(ticks);
                _count++;
            }

            public bool TryConsume(string text)
            {
                Queue<long> times;
                if (text == null || !_seen.TryGetValue(text, out times) || times.Count == 0) return false;
                times.Dequeue();
                _count--;
                if (times.Count == 0) _seen.Remove(text);
                return true;
            }

            public void Expire(long beforeTicks)
            {
                if (_count == 0) return;
                List<string> empty = null;
                foreach (var pair in _seen)
                {
                    while (pair.Value.Count > 0 && pair.Value.Peek() < beforeTicks) { pair.Value.Dequeue(); _count--; }
                    if (pair.Value.Count == 0) (empty ?? (empty = new List<string>())).Add(pair.Key);
                }
                if (empty != null) foreach (var key in empty) _seen.Remove(key);
            }

            public void Clear()
            {
                _seen.Clear();
                _count = 0;
            }
        }

        #endregion

        #region Panel signing

        // No game or Oxide types in this region: it is compiled and checked
        // outside the game against the panel's published signature vector, so
        // a mistake here is found before it reaches a server.

        private static readonly DateTime PanelEpoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);

        // The body is signed exactly as it is sent. Non-ASCII is escaped, so the
        // bytes on the wire are the same whatever encoding anything assumes.
        private static string PanelBody(string reportId, DateTime sentAtUtc, string sourceVersion, string kind, JObject payload)
        {
            var envelope = new JObject
            {
                ["contract"] = 1,
                ["report_id"] = reportId,
                ["sent_at"] = sentAtUtc.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", CultureInfo.InvariantCulture),
                ["source"] = "plugin",
                ["source_version"] = sourceVersion,
                ["kind"] = kind,
                ["payload"] = payload
            };
            return JsonConvert.SerializeObject(envelope, new JsonSerializerSettings
            {
                Formatting = Formatting.None,
                StringEscapeHandling = StringEscapeHandling.EscapeNonAscii
            });
        }

        //   <METHOD> <path>\n<timestamp>\n<nonce>\n<sha256 of the body, lowercase hex>
        private static string PanelCanonical(string method, string path, string timestamp, string nonce, string body)
        {
            return method.ToUpperInvariant() + " " + path + "\n" + timestamp + "\n" + nonce + "\n" + Sha256Hex(body);
        }

        private static string PanelSign(string secret, string method, string path, string timestamp, string nonce, string body)
        {
            using (var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(secret)))
                return Hex(hmac.ComputeHash(Encoding.UTF8.GetBytes(PanelCanonical(method, path, timestamp, nonce, body))));
        }

        private static string Sha256Hex(string text)
        {
            using (var sha = SHA256.Create())
                return Hex(sha.ComputeHash(Encoding.UTF8.GetBytes(text)));
        }

        // The panel signs the answers a plugin acts on, so a forged reply cannot
        // unload a plugin, ban players fleet-wide or raise the sharing level.
        // Oxide's webrequest callback cannot read a response header, so the
        // signature travels in the body: when the plugin opts in (X-Hotwire-Signed-Response),
        // the panel wraps the real answer as
        //     {"signed":"<the real body, verbatim>","sig":"<hex HMAC-SHA256>"}
        // and signs, with the SAME per-server secret, the canonical form below,
        // bound to the request's own nonce and timestamp so a captured reply cannot
        // be replayed against a later request.
        //
        //   <http status>\n<request timestamp>\n<request nonce>\n<sha256 of the signed string, lowercase hex>
        private static string PanelResponseCanonical(int status, string timestamp, string nonce, string signedBody)
        {
            return status.ToString(CultureInfo.InvariantCulture) + "\n" + timestamp + "\n" + nonce + "\n" + Sha256Hex(signedBody);
        }

        private static string PanelSignResponse(string secret, int status, string timestamp, string nonce, string signedBody)
        {
            using (var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(secret)))
                return Hex(hmac.ComputeHash(Encoding.UTF8.GetBytes(PanelResponseCanonical(status, timestamp, nonce, signedBody))));
        }

        // Verify a wrapped response and, only on success, hand back the real body.
        // The signed string is hashed exactly as received -- never re-serialised --
        // so the plugin verifies the same bytes the panel signed. Any failure (not
        // wrapped, no/short fields, or a signature that does not match) returns
        // false with realBody null, and the caller drops the answer without acting.
        private static bool PanelVerifyResponse(string secret, int status, string timestamp, string nonce, string outerBody, out string realBody)
        {
            realBody = null;
            if (string.IsNullOrEmpty(outerBody)) return false;

            JObject outer;
            try { outer = JObject.Parse(outerBody); }
            catch { return false; }

            var signed = outer["signed"];
            var sig = (string)outer["sig"];
            if (signed == null || signed.Type != JTokenType.String || string.IsNullOrEmpty(sig)) return false;

            var signedBody = (string)signed;
            var expected = PanelSignResponse(secret, status, timestamp, nonce, signedBody);
            if (!FixedTimeEquals(expected, sig)) return false;

            realBody = signedBody;
            return true;
        }

        // Constant-time comparison of two hex signatures: the time taken does not
        // reveal how many leading characters matched.
        private static bool FixedTimeEquals(string a, string b)
        {
            if (a == null || b == null) return false;
            var x = Encoding.UTF8.GetBytes(a);
            var y = Encoding.UTF8.GetBytes(b);
            var diff = x.Length ^ y.Length;
            for (var i = 0; i < x.Length; i++)
                diff |= x[i] ^ (i < y.Length ? y[i] : 0);
            return diff == 0;
        }

        // The plugin set's merge key, frozen by the contract: for each plugin
        // name, author, version and sha256 (without the prefix) joined by 0x1F,
        // the lines sorted byte-wise, joined by 0x1E, then sha256.
        private static string InventoryHash(IEnumerable<string[]> plugins)
        {
            var lines = plugins
                .Select(p => Encoding.UTF8.GetBytes(string.Join("\u001f", new[] { p[0] ?? "", p[1] ?? "", p[2] ?? "", p[3] ?? "" })))
                .ToList();
            lines.Sort(CompareBytes);

            var joined = new List<byte>();
            for (var i = 0; i < lines.Count; i++)
            {
                if (i > 0) joined.Add(0x1E);
                joined.AddRange(lines[i]);
            }
            using (var sha = SHA256.Create())
                return "sha256:" + Hex(sha.ComputeHash(joined.ToArray()));
        }

        private static int CompareBytes(byte[] a, byte[] b)
        {
            var n = Math.Min(a.Length, b.Length);
            for (var i = 0; i < n; i++)
                if (a[i] != b[i]) return a[i].CompareTo(b[i]);
            return a.Length.CompareTo(b.Length);
        }

        private static string Hex(byte[] bytes)
        {
            var sb = new StringBuilder(bytes.Length * 2);
            foreach (var b in bytes) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
            return sb.ToString();
        }

        private static string PanelNonce()
        {
            var bytes = new byte[16];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
            return Hex(bytes);
        }

        // A UUIDv7: the first 48 bits are milliseconds since 1970, so report
        // ids sort by the time they were made.
        private static string NewReportId()
        {
            var bytes = new byte[16];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
            var ms = (long)(DateTime.UtcNow - PanelEpoch).TotalMilliseconds;
            for (var i = 0; i < 6; i++) bytes[i] = (byte)(ms >> (8 * (5 - i)));
            bytes[6] = (byte)((bytes[6] & 0x0F) | 0x70);
            bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
            var h = Hex(bytes);
            return h.Substring(0, 8) + "-" + h.Substring(8, 4) + "-" + h.Substring(12, 4) + "-" + h.Substring(16, 4) + "-" + h.Substring(20);
        }

        #endregion

        #endregion

        #region Admin menu

        // The only part of this plugin that touches Facepunch types. Rust's UI
        // has no Covalence route -- CuiHelper.AddUi takes a BasePlayer -- so
        // building a panel means naming BasePlayer and the Cui* classes, which
        // knowingly gives up part of the no-Facepunch-types rule at the top.
        //
        // Everything the menu does, the chat commands already do. That is
        // the condition for having a menu at all, and it is load-bearing here: if this region
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

        // The panel is static text. Without this it shows whatever was true
        // when it was drawn, forever -- a menu left open through a countdown
        // read "in 12 minutes" while the status bar, which counts itself down,
        // read 5m. The banner that goes stale is the one offering to cancel
        // the restart, so the number an admin is deciding on was the wrong one.
        private Timer _menuTimer;
        private int _menuTick;

        // Colors are space-separated floats, not hex, and they must be
        // formatted with the invariant culture: on a server whose locale uses a
        // comma decimal separator, "0.35" becomes "0,35" and the whole panel
        // renders wrong. Same reason Anchor() exists below.
        private const string ColBackground = "0.10 0.10 0.11 0.96";
        private const string ColHeader = "0.16 0.16 0.18 1.00";
        private const string ColRow = "0.18 0.18 0.20 0.90";
        private const string ColButton = "0.28 0.28 0.31 1.00";
        private const string ColOn = "0.33 0.56 0.33 1.00";

        // OFF is a state, not a hazard. It was red, four inches from a red
        // Delete on the same row, and only the label told them apart. Recessed
        // neutral now: dimmer than a normal button, so the toggle column reads
        // as lit or unlit rather than as safe or dangerous.
        private const string ColOff = "0.24 0.24 0.27 1.00";

        // One red, for things that destroy or interrupt: Delete, and the
        // countdown banner. #C0392B, which is also the status bar's default
        // fill, so the panel and the HUD agree.
        private const string ColDanger = "0.753 0.224 0.169 1.00";

        // The same red lightened until it is legible as text on a dark row.
        // A fill color and a text color cannot be the same value; this is the
        // same hue, not a fourth red.
        private const string ColDangerText = "0.91 0.51 0.45 1.00";

        // Amber, and deliberately not in the red family. It means "this will
        // behave in a way you may not expect", not "this is broken".
        private const string ColWarnText = "0.85 0.65 0.40 1.00";
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
            EnsureMenuTimer();
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

        // Five seconds while something is counting down, because that is the
        // number being acted on. Thirty otherwise, where the text moves a
        // minute at a time and a redraw is just churn.
        //
        // Only MenuContent is replaced on a redraw -- MenuRoot, which owns the
        // cursor, is left alone. Recreating it per redraw is what used to throw
        // the cursor back to the middle of the screen on a fast click.
        private void EnsureMenuTimer()
        {
            if (_menuTimer != null) return;
            _menuTick = 0;
            _menuTimer = timer.Every(5f, RefreshOpenMenus);
        }

        private void RefreshOpenMenus()
        {
            if (_menus.Count == 0)
            {
                _menuTimer?.Destroy();
                _menuTimer = null;
                return;
            }

            _menuTick++;
            if (!_countdownActive && (_menuTick % 6) != 0) return;

            // Keys copied first: DrawMenu drops anyone whose BasePlayer has
            // gone, and that mutates the dictionary underneath us.
            foreach (var id in _menus.Keys.ToArray())
            {
                var player = players.FindPlayerById(id);
                if (player == null || !player.IsConnected) { _menus.Remove(id); continue; }
                DrawMenu(player);
            }
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
            _menuTimer?.Destroy();
            _menuTimer = null;
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
                      problem != null ? ColDangerText : ColMuted, TextAnchor.MiddleLeft);

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
                          T("MenuShortMonthWarning", player.Id), 11, ColWarnText,
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
            // reassurance that let a disabled entry restart a server.
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
                headlineColor = ColDangerText;
            }
            else if (!entry.Enabled)
            {
                var would = NextOccurrence(entry, DateTime.Now);
                headline = T("MenuDisabled", player.Id);
                detail = would == null
                    ? T("MenuNoOccurrence", player.Id, rule)
                    : T("MenuWouldRun", player.Id, rule, Friendly(would.Value, player.Id),
                        would.Value.ToString("dddd d MMMM yyyy 'at' HH:mm", CultureInfo.InvariantCulture));
                headlineColor = ColWarnText;
            }
            else if (next == null)
            {
                headline = T("MenuNeverRuns", player.Id);
                detail = T("MenuNoOccurrence", player.Id, rule);
                headlineColor = ColWarnText;
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

        // These are written first and must do everything an admin
        // menu would. A broken CUI panel must never mean a schedule cannot be
        // changed, so the panel -- when it exists -- will be a second way in,
        // never the only one.
        private void CmdHotwire(IPlayer player, string command, string[] args)
        {
            var sub = args.Length > 0 ? args[0].ToLowerInvariant() : "status";

            switch (sub)
            {
                case "status": CmdStatus(player); return;
                case "menu": CmdMenu(player); return;   // goes with the menu
                case "check": CmdCheck(player); return;
                case "connect": CmdConnect(player, args); return;
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
                        lines.Add($"  !! {_config.General.UpdateFlag} is present RIGHT NOW. The next restart will update.");
                    if (validatePath != null && File.Exists(validatePath))
                        lines.Add($"  !! {_config.General.ValidateFlag} is present RIGHT NOW. The next restart will validate.");
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

            lines.Add($"  panel        : {_panelState}");
            if (_panel != null)
            {
                lines.Add($"  plugins sent : {_inventoryState}");
                lines.Add($"  policy       : {PolicyDescription()}");
                lines.Add($"  commands     : {(_config.Panel.AcceptCommands && !PolicyAllowsCommands() ? "not checked: the account's plan does not include commands" : _commandsState)}");
                lines.Add($"  ban list     : {(_config.Panel.EnforceBans && !PolicyAllowsBans() ? "not checked: the account's plan does not include ban sync" : _bansState)}");
                lines.Add($"  map          : {_mapState}");
                lines.Add($"  map layout   : {_layoutState}");
                lines.Add($"  map image    : {_imageState}");
                lines.Add($"  schedule     : {_scheduleState}");
                lines.Add($"  player data  : {SharingDescription()}");
                lines.Add($"  log          : {LogDescription()}");
                lines.Add($"  console      : {ConsoleDescription()}");
                lines.Add($"  who's online : {_playersState}");
                lines.Add($"  joins & chat : {_eventsState}");
                lines.Add($"  plugin time  : {_pluginTimeState}");
                lines.Add($"  session      : {_sessionState}");
                lines.Add($"  held reports : {SpoolDescription()}");
            }

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

        // ---------------------------------------------------------------- connect

        // "hotwire connect <code> [panel address]" connects this server to the
        // panel from the server console, RCON, or the in-game console of an
        // admin: the same code hotwire-setup asks for, without leaving the game.
        // It connects the plugin only; the launcher is connected by setup. It
        // uses the install id setup keeps in hotwire/install_id, and writes one
        // there if there is none, so connecting either way adopts the same
        // server in the panel rather than making a second. The code is good
        // for one hour and one server, and is spent once it is used.

        private const string DefaultPanelUrl = "https://hotpanel.on-forge.com";
        private const string EnrollPath = "/api/v1/enroll";
        private bool _connecting;

        private void CmdConnect(IPlayer player, string[] args)
        {
            if (!player.IsServer && !player.IsAdmin)
            {
                player.Reply("Only the server console, RCON, or an admin can connect this server to the panel.");
                return;
            }

            if (args.Length < 2)
            {
                player.Reply("Usage: hotwire connect <code> [panel address]. Make a code in the panel: Servers, Connect a server.");
                return;
            }

            var code = args[1].Trim();
            if (code.Length < 4 || code.Length > 64)
            {
                player.Reply("That does not look like a connection code. It looks like HW-4K2P-9XQR.");
                return;
            }

            var url = (args.Length > 2 ? args[2] : DefaultPanelUrl).Trim().TrimEnd('/');
            if (!url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                player.Reply("The panel address must start with https://.");
                return;
            }

            var root = ServerRoot();
            if (root == null)
            {
                player.Reply("The server's folder cannot be determined, so the connection could not be tied to it. Set \"Server root\" in the config.");
                return;
            }

            if (_connecting)
            {
                player.Reply("A connection is already being made. Wait for its answer.");
                return;
            }

            var installId = ReadOrMakeInstallId(root);
            if (installId == null)
            {
                player.Reply($"Could not write {Path.Combine(root, "hotwire", "install_id")}. Check the server's folder is writable.");
                return;
            }

            var name = server.Name;
            if (string.IsNullOrWhiteSpace(name)) name = Path.GetFileName(root.TrimEnd('/', '\\'));
            if (name.Length > 255) name = name.Substring(0, 255);

            var body = new JObject
            {
                ["token"] = code,
                ["install_id"] = installId,
                ["identity"] = name,
                ["name"] = name,
                ["components"] = new JArray("plugin")
            }.ToString(Formatting.None);

            _connecting = true;
            player.Reply($"Connecting to {url} ...");
            var headers = new Dictionary<string, string> { { "Accept", "application/json" }, { "Content-Type", "application/json" } };
            webrequest.Enqueue(url + EnrollPath, body, (status, response) =>
            {
                _connecting = false;
                try
                {
                    FinishConnect(player, url, root, status, response);
                }
                catch (Exception ex)
                {
                    player.Reply($"The panel's answer could not be used ({ex.Message}). Nothing was changed.");
                }
            }, this, Oxide.Core.Libraries.RequestMethod.POST, headers, 30f);
        }

        private void FinishConnect(IPlayer player, string url, string root, int status, string response)
        {
            if (status != 201)
            {
                string message = null;
                try { message = (string)JObject.Parse(response)["message"]; } catch { }
                switch (status)
                {
                    case 0: player.Reply($"The panel at {url} could not be reached. Nothing was changed; the server is unaffected."); return;
                    case 422: player.Reply($"The panel refused the code: {message ?? "invalid or expired"}. Codes last an hour and work once; make a fresh one."); return;
                    case 429: player.Reply("The panel is limiting requests from this address. Wait a minute and try again."); return;
                    default: player.Reply($"The panel answered HTTP {status}: {message ?? "no message"}. Nothing was changed."); return;
                }
            }

            var data = JObject.Parse(response)["data"] as JObject;
            var keys = data == null ? null : data["keys"] as JArray;
            var key = keys == null ? null : keys.OfType<JObject>().FirstOrDefault(k => (string)k["component"] == "plugin");
            var keyId = key == null ? null : (string)key["key_id"];
            var secret = key == null ? null : (string)key["secret"];
            if (string.IsNullOrWhiteSpace(keyId) || string.IsNullOrWhiteSpace(secret))
            {
                player.Reply("The panel's answer has no key for the plugin. Nothing was changed.");
                return;
            }

            // The address the panel names is used only when it is the same
            // server that was asked, so an answer cannot send this server's
            // reports somewhere else.
            var said = data["panel_url"] == null ? null : ((string)data["panel_url"]).Trim().TrimEnd('/');
            if (!string.IsNullOrEmpty(said) && SameHost(said, url)) url = said;

            var path = PanelFile();
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            if (File.Exists(path))
                File.Copy(path, path + ".backup-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture), true);

            var file = new JObject { ["key_id"] = keyId, ["secret"] = secret, ["panel_url"] = url, ["folder"] = root };
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, file.ToString(Formatting.Indented) + "\n");
            if (File.Exists(path)) File.Delete(path);
            File.Move(tmp, path);

            var server = data["server"] as JObject;
            var adopted = server != null && server["adopted"] != null && server["adopted"].Type == JTokenType.Boolean && (bool)server["adopted"];
            player.Reply(adopted
                ? "Reconnected to the server the panel already knew. Its history is kept, and its old keys no longer work."
                : "Connected. This server appears in the panel within a minute.");
            player.Reply("Only the plugin is connected. hotwire-setup connects the launcher, if you use it.");
        }

        private static bool SameHost(string a, string b)
        {
            Uri ua, ub;
            return Uri.TryCreate(a, UriKind.Absolute, out ua) && Uri.TryCreate(b, UriKind.Absolute, out ub)
                && ua.Scheme == Uri.UriSchemeHttps && string.Equals(ua.Host, ub.Host, StringComparison.OrdinalIgnoreCase);
        }

        // The install id setup keeps in <root>/hotwire/install_id, as
        // {"install_id": "...", "folder": "..."}. One recorded for another
        // folder belongs to the server this was copied from, so a new one is
        // made. Null when it cannot be written.
        private static string ReadOrMakeInstallId(string root)
        {
            var dir = Path.Combine(root, "hotwire");
            var file = Path.Combine(dir, "install_id");
            try
            {
                if (File.Exists(file))
                {
                    var record = JObject.Parse(File.ReadAllText(file));
                    var id = (string)record["install_id"];
                    var folder = (string)record["folder"];
                    Guid parsed;
                    if (Guid.TryParse(id, out parsed) && (string.IsNullOrWhiteSpace(folder) || SameFolder(folder, root)))
                        return parsed.ToString();
                }
            }
            catch { }

            try
            {
                var made = Guid.NewGuid().ToString();
                Directory.CreateDirectory(dir);
                File.WriteAllText(file, new JObject { ["install_id"] = made, ["folder"] = root }.ToString(Formatting.Indented) + "\n");
                return made;
            }
            catch
            {
                return null;
            }
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

                ["Usage"] = "hotwire status | menu | check | connect <code> | list | now [update|validate] [seconds] | cancel | " +
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
