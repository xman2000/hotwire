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

namespace Oxide.Plugins
{
    [Info("Hotwire", "xman2000", "0.1.0")]
    [Description("Scheduled restarts and updates. Announces, counts down, writes a flag, quits.")]
    internal class Hotwire : CovalencePlugin
    {
        // =================================================================
        //  WHAT THIS PLUGIN DELIBERATELY DOES NOT DO
        //
        //  It does not touch Assembly-CSharp. Every game interaction goes
        //  through Covalence, which is a stable Oxide interface rather than
        //  a moving Facepunch one.
        //
        //  That is a safety decision, not a style one (ADR-0014). A wrong
        //  guess at a Facepunch signature -- ConVar.Global.quit's argument
        //  shape, say -- is a COMPILE error, and a plugin that does not
        //  compile is a plugin that never restarts the server. try/catch
        //  cannot save you from that. server.Command("quit") runs the same
        //  console command with none of the exposure.
        //
        //  It does not spawn processes, write scheduled tasks or shell out.
        //  It writes a flag file and quits; the launcher does the rest
        //  (ADR-0001).
        //
        //  Two runtime assumptions remain, both marked VERIFY below, both
        //  wrapped so that being wrong disables one cosmetic feature rather
        //  than the schedule: the AdvancedStatus call shape, and the
        //  umod.org release-feed response shape.
        // =================================================================

        #region Configuration

        private HotwireConfig _config;

        private class HotwireConfig
        {
            [JsonProperty("Restarts")]
            public List<ScheduleEntry> Restarts = new List<ScheduleEntry>
            {
                new ScheduleEntry { Time = "05:00", Days = "Daily", Enabled = false }
            };

            [JsonProperty("Updates")]
            public List<UpdateEntry> Updates = new List<UpdateEntry>
            {
                new UpdateEntry { Time = "05:00", Days = "Thursday", Validate = false, Enabled = false }
            };

            [JsonProperty("Countdown")]
            public CountdownSettings Countdown = new CountdownSettings();

            [JsonProperty("Framework update check")]
            public FrameworkSettings Framework = new FrameworkSettings();

            [JsonProperty("General")]
            public GeneralSettings General = new GeneralSettings();
        }

        private class ScheduleEntry
        {
            [JsonProperty("Time (HH:mm, server local time)")]
            public string Time = "05:00";

            // "Daily", "Weekdays", "Weekends", or a comma-separated list of
            // day names: "Monday,Thursday". Short forms work: "Mon,Thu".
            [JsonProperty("Days")]
            public string Days = "Daily";

            [JsonProperty("Enabled")]
            public bool Enabled = true;

            [JsonIgnore]
            public virtual bool IsUpdate => false;

            [JsonIgnore]
            public virtual bool IsValidate => false;

            // Stable across reordering and editing, so the fired-recently
            // guard survives someone rearranging the config.
            [JsonIgnore]
            public string Key => $"{(IsValidate ? "validate" : IsUpdate ? "update" : "restart")}|{Time}|{Days}";
        }

        private class UpdateEntry : ScheduleEntry
        {
            // Validate re-checksums the whole install. Slow -- six to eight
            // minutes on a large one. Weekly at most, or after a crash.
            [JsonProperty("Validate")]
            public bool Validate = false;

            [JsonIgnore]
            public override bool IsUpdate => true;

            [JsonIgnore]
            public override bool IsValidate => Validate;
        }

        private class CountdownSettings
        {
            [JsonProperty("Start the countdown this many seconds before")]
            public int StartSeconds = 600;

            [JsonProperty("Announce when this many seconds remain")]
            public List<int> AnnounceAt = new List<int> { 600, 300, 180, 60, 30, 10, 5, 4, 3, 2, 1 };

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

            // ADR-0003 says render through a status plugin where one exists.
            // Default off because the call shape below is UNVERIFIED -- turn
            // it on once you have checked it against your AdvancedStatus.
            [JsonProperty("Render the countdown through AdvancedStatus (unverified -- see docs)")]
            public bool UseStatusPlugin = false;

            [JsonProperty("Chat prefix")]
            public string ChatPrefix = "<color=#e0995e>Hotwire</color>: ";
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
                if (_config == null) throw new JsonException("configuration deserialised to null");
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

        protected override void SaveConfig() => Config.WriteObject(_config, true);

        #endregion

        #region State

        private const string PermStatus = "hotwire.status";
        private const string PermRestart = "hotwire.restart";
        private const string PermCancel = "hotwire.cancel";
        private const string PermEdit = "hotwire.edit";

        private const string LastFiredFile = "Hotwire/last_fired";
        private const string StatusId = "hotwire_countdown";

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

            var next = DescribeNext();
            Puts(next == null ? "No schedule is enabled. Nothing will restart." : $"Next: {next}");
        }

        private void Unload()
        {
            _scanTimer?.Destroy();
            _countdownTimer?.Destroy();
            _frameworkTimer?.Destroy();

            if (_countdownActive && !_shuttingDown)
            {
                // Say so. A countdown that vanishes silently is the "restarts
                // unannounced" half of the safety envelope in reverse: players
                // brace for a restart that never comes.
                Broadcast("Cancelled");
                ClearStatus();
                Puts("Unloaded mid-countdown. The restart was cancelled.");
            }
        }

        #endregion

        #region Schedule scanning

        private void ValidateSchedule()
        {
            var changed = false;
            foreach (var e in AllEntries())
            {
                if (!e.Enabled) continue;
                if (ParseTime(e.Time) == null)
                {
                    e.Enabled = false;
                    changed = true;
                    PrintError($"Schedule entry \"{e.Time}\" is not a valid HH:mm time. Entry DISABLED.");
                    continue;
                }
                if (ParseDays(e.Days) == null)
                {
                    e.Enabled = false;
                    changed = true;
                    PrintError($"Schedule entry \"{e.Time}\" has unreadable Days \"{e.Days}\". Entry DISABLED.");
                }
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

        private DateTime? NextOccurrence(ScheduleEntry e, DateTime now)
        {
            var time = ParseTime(e.Time);
            if (time == null) return null;
            var days = ParseDays(e.Days);
            if (days == null) return null;

            for (var i = 0; i <= 7; i++)
            {
                var candidate = now.Date.AddDays(i).Add(time.Value);
                if (candidate <= now) continue;
                if (!days.Contains(candidate.DayOfWeek)) continue;
                return candidate;
            }
            return null;
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

        private static HashSet<DayOfWeek> ParseDays(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return null;
            var s = raw.Trim();

            if (s.Equals("daily", StringComparison.OrdinalIgnoreCase) ||
                s.Equals("everyday", StringComparison.OrdinalIgnoreCase) ||
                s.Equals("every day", StringComparison.OrdinalIgnoreCase))
                return new HashSet<DayOfWeek>((DayOfWeek[])Enum.GetValues(typeof(DayOfWeek)));

            if (s.Equals("weekdays", StringComparison.OrdinalIgnoreCase))
                return new HashSet<DayOfWeek>
                {
                    DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday,
                    DayOfWeek.Thursday, DayOfWeek.Friday
                };

            if (s.Equals("weekends", StringComparison.OrdinalIgnoreCase))
                return new HashSet<DayOfWeek> { DayOfWeek.Saturday, DayOfWeek.Sunday };

            var set = new HashSet<DayOfWeek>();
            foreach (var part in s.Split(','))
            {
                var token = part.Trim();
                if (token.Length == 0) continue;
                if (!DayNames.TryGetValue(token, out var day)) return null;
                set.Add(day);
            }
            return set.Count == 0 ? null : set;
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

            // Everything at or above the time actually remaining has already
            // been said by the line below, or is in the past. Without this the
            // first tick repeats the opening announcement a second later.
            foreach (var point in _config.Countdown.AnnounceAt)
                if (point >= remaining) _announced.Add(point);
            Puts($"Countdown started: {KindWord()} in {remaining}s (entry {key}).");
            Broadcast("CountdownStart", KindWord(), FormatRemaining(remaining));

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

            UpdateStatus(remaining);

            foreach (var point in _config.Countdown.AnnounceAt)
            {
                if (remaining > point) continue;
                if (!_announced.Add(point)) continue;
                Broadcast("CountdownTick", KindWord(), FormatRemaining(remaining));
                break;
            }
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
            _announced.Clear();
            ClearStatus();

            Broadcast("Cancelled");
            Puts($"Countdown cancelled by {by}.");
        }

        private void Execute()
        {
            if (_shuttingDown) return;
            _shuttingDown = true;
            _countdownActive = false;
            ClearStatus();

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

            // Flags first, while a failure can still be reported and while the
            // server is still up. A failed flag write downgrades an update to
            // a plain restart, which is the safe direction to fail in.
            if (_countdownIsUpdate)
                WriteFlags(_countdownIsValidate);

            Broadcast("Now", KindWord());

            var reason = lang.GetMessage("KickReason", this, null);
            var kicked = 0;
            foreach (var p in players.Connected.ToArray())
            {
                // Rule 4: never trust a reference across a frame. This list was
                // built this frame, but Kick can disconnect players as it goes.
                if (p == null || !p.IsConnected) continue;
                try
                {
                    p.Kick(reason);
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
                // that this file has no compile-time dependency on
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

        private string KindWord()
        {
            var key = _countdownIsValidate ? "KindValidate" : _countdownIsUpdate ? "KindUpdate" : "KindRestart";
            return lang.GetMessage(key, this, null);
        }

        private static string FormatRemaining(int seconds)
        {
            // ADR-0004: plain strings. Upstream ships a regex template
            // mini-language to render this, which is a large surface for
            // "5 minutes left".
            if (seconds >= 120) return $"{seconds / 60} minutes";
            if (seconds >= 60) return "1 minute";
            if (seconds == 1) return "1 second";
            return $"{seconds} seconds";
        }

        #endregion

        #region Status surface

        // ADR-0003 renders the countdown through a status plugin players
        // already read rather than adding a fifth thing fighting for a screen
        // corner. VERIFY: the AdvancedStatus call shape below has NOT been
        // checked against the plugin. That is why it is off by default and
        // why it disables itself permanently on the first exception -- a
        // cosmetic feature must never be able to interrupt a countdown.
        private void UpdateStatus(int remaining)
        {
            if (!_config.General.UseStatusPlugin || _statusDisabled) return;
            if (AdvancedStatus == null) return;

            try
            {
                var text = string.Format(lang.GetMessage("StatusBar", this, null), KindWord(), FormatRemaining(remaining));
                foreach (var p in players.Connected.ToArray())
                {
                    if (p == null || !p.IsConnected) continue;
                    AdvancedStatus.Call("SetStatus", p.Id, StatusId, text, remaining);
                }
            }
            catch (Exception ex)
            {
                _statusDisabled = true;
                PrintWarning($"The status-plugin call failed ({ex.Message}). " +
                             "Falling back to chat for the rest of this session. The countdown is unaffected.");
            }
        }

        private void ClearStatus()
        {
            if (!_config.General.UseStatusPlugin || _statusDisabled) return;
            if (AdvancedStatus == null) return;
            try
            {
                foreach (var p in players.Connected.ToArray())
                {
                    if (p == null || !p.IsConnected) continue;
                    AdvancedStatus.Call("DeleteStatus", p.Id, StatusId);
                }
            }
            catch
            {
                _statusDisabled = true;
            }
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
                _oneShotReason = $"framework {latest}";

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
                case "list": CmdList(player); return;
                case "now": CmdNow(player, args); return;
                case "cancel": CmdCancel(player); return;
                case "add": CmdAdd(player, args); return;
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
                var remaining = (int)Math.Ceiling((_countdownTarget - DateTime.Now).TotalSeconds);
                Reply(player, "StatusCounting", KindWord(), FormatRemaining(Math.Max(0, remaining)));
                return;
            }

            var next = DescribeNext();
            if (next == null) Reply(player, "StatusNone");
            else Reply(player, "StatusNext", next);
        }

        private string DescribeNext()
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
                var word = _oneShotValidate ? "validate" : "update";
                return $"{word} at {_oneShotTarget.Value:yyyy-MM-dd HH:mm} ({_oneShotReason})";
            }

            if (best == null) return null;
            var kind = best.IsValidate ? "validate" : best.IsUpdate ? "update" : "restart";
            return $"{kind} at {bestTarget:yyyy-MM-dd HH:mm}";
        }

        private void CmdList(IPlayer player)
        {
            if (!Allowed(player, PermStatus)) return;

            var lines = new List<string>();
            for (var i = 0; i < _config.Restarts.Count; i++)
            {
                var e = _config.Restarts[i];
                lines.Add($"restart {i}: {e.Time} {e.Days} {(e.Enabled ? "enabled" : "disabled")}");
            }
            for (var i = 0; i < _config.Updates.Count; i++)
            {
                var e = _config.Updates[i];
                lines.Add($"update {i}: {e.Time} {e.Days} {(e.Validate ? "validate " : "")}{(e.Enabled ? "enabled" : "disabled")}");
            }

            if (lines.Count == 0)
            {
                Reply(player, "ListEmpty");
                return;
            }
            player.Reply(_config.General.ChatPrefix + string.Join("\n", lines.ToArray()));
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
            Puts($"Manual {KindWord()} started by {player.Name} ({seconds}s).");
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

            var days = args.Length > 3 ? string.Join(",", args.Skip(3).ToArray()) : "Daily";
            if (ParseDays(days) == null) { Reply(player, "BadDays", days); return; }

            if (kind == "restart")
                _config.Restarts.Add(new ScheduleEntry { Time = time, Days = days, Enabled = true });
            else
                _config.Updates.Add(new UpdateEntry { Time = time, Days = days, Validate = kind == "validate", Enabled = true });

            SaveConfig();
            Reply(player, "Added", kind, time, days);
            Puts($"{player.Name} added {kind} {time} {days}.");
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
            list.RemoveAt(index);
            SaveConfig();
            Reply(player, "Removed", args[1].ToLowerInvariant(), removed.Time, removed.Days);
            Puts($"{player.Name} removed {args[1]} {index} ({removed.Time} {removed.Days}).");
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

            list[index].Enabled = enable;
            if (enable) ValidateSchedule();
            SaveConfig();
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

        private void Reply(IPlayer player, string key, params string[] args)
        {
            var msg = lang.GetMessage(key, this, player.Id);
            player.Reply(_config.General.ChatPrefix + (args.Length == 0 ? msg : string.Format(msg, args)));
        }

        private void Broadcast(string key, params string[] args)
        {
            foreach (var p in players.Connected.ToArray())
            {
                if (p == null || !p.IsConnected) continue;
                var msg = lang.GetMessage(key, this, p.Id);
                p.Message(_config.General.ChatPrefix + (args.Length == 0 ? msg : string.Format(msg, args)));
            }
        }

        #endregion

        #region Messages

        protected override void LoadDefaultMessages()
        {
            lang.RegisterMessages(new Dictionary<string, string>
            {
                ["KindRestart"] = "restart",
                ["KindUpdate"] = "update and restart",
                ["KindValidate"] = "validate and restart",

                ["CountdownStart"] = "Scheduled {0} in {1}. The server will save before it goes down.",
                ["CountdownTick"] = "{0} in {1}.",
                ["Now"] = "{0} now. See you in a few minutes.",
                ["Cancelled"] = "The scheduled restart has been cancelled.",
                ["KickReason"] = "Scheduled restart. Back shortly.",
                ["StatusBar"] = "{0} in {1}",

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
                ["BadDays"] = "\"{0}\" is not a valid day list. Use Daily, Weekdays, Weekends, or Monday,Thursday.",
                ["BadIndex"] = "\"{0}\" is not a valid index. Run: hotwire list",
                ["Added"] = "Added {0} at {1} on {2}.",
                ["Removed"] = "Removed {0} at {1} on {2}.",
                ["Enabled"] = "Enabled {0} {1}.",
                ["Disabled"] = "Disabled {0} {1}.",

                ["Usage"] = "hotwire status | list | now [update|validate] [seconds] | cancel | " +
                            "add <restart|update|validate> <HH:mm> [days] | remove <restart|update> <index> | " +
                            "enable|disable <restart|update> <index>",
                ["UsageNow"] = "hotwire now [update|validate] [seconds]",
                ["UsageAdd"] = "hotwire add <restart|update|validate> <HH:mm> [days]",
                ["UsageRemove"] = "hotwire remove <restart|update> <index>",
                ["UsageToggle"] = "hotwire enable|disable <restart|update> <index>"
            }, this);
        }

        #endregion
    }
}
