using System;
using System.Collections.Generic;
using System.Linq;
using System.IO;
using System.Text.RegularExpressions;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace PluginSigning
{
    // Every check runs the plugin's own code, copied out of src/Hotwire.cs by run.sh.
    internal static class Program
    {
        private static int _failed;

        private static void Check(string name, bool ok, string detail = "")
        {
            Console.WriteLine((ok ? "  ok    " : "  FAIL  ") + name + (ok || detail == "" ? "" : " -- " + detail));
            if (!ok) _failed++;
        }

        private static int Main(string[] args)
        {
            var v = JObject.Parse(File.ReadAllText(args[0]));
            var secret = (string)v["secret"];
            var method = (string)v["method"];
            var path = (string)v["path"];
            var ts = (string)v["timestamp"];
            var nonce = (string)v["nonce"];
            var body = (string)v["body_utf8"];

            Check("body sha256 matches the vector", Extracted.Sha256Hex(body) == (string)v["body_sha256"]);
            Check("canonical string matches the vector", Extracted.PanelCanonical(method, path, ts, nonce, body) == (string)v["canonical_string"]);
            var sig = Extracted.PanelSign(secret, method, path, ts, nonce, body);
            Check("signature matches the vector", sig == (string)v["signature"], sig);
            Check("a trailing newline changes the signature", Extracted.PanelSign(secret, method, path, ts, nonce, body + "\n") != (string)v["signature"]);

            // The body the plugin builds for the vector's own envelope is byte-identical to the
            // vector's, so what is signed is what the panel hashes.
            var payload = new JObject { ["players"] = 34, ["max_players"] = 50 };
            var built = Extracted.PanelBody("0193f2c1-8a4e-7c1a-9f3b-2d5e6a7b8c9d",
                new DateTime(2026, 9, 9, 18, 42, 11, DateTimeKind.Utc), "1.1.2", "heartbeat", payload);
            Check("the plugin builds the vector's body byte for byte", built == body, built);

            var odd = Extracted.PanelBody("x", DateTime.UtcNow, "1", "heartbeat", new JObject { ["name"] = "Café ☃" });
            Check("non-ASCII is escaped, so the body is pure ASCII", Regex.IsMatch(odd, "^[\\x20-\\x7e]*$"), odd);

            var id = Extracted.NewReportId();
            Check("report id is a UUIDv7", Regex.IsMatch(id, "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"), id);
            var ms = Convert.ToInt64(id.Replace("-", "").Substring(0, 12), 16);
            var now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
            Check("report id carries the current time", Math.Abs(now - ms) < 5000, ms.ToString());
            Check("report ids differ", Extracted.NewReportId() != Extracted.NewReportId());

            // A GET is signed over an empty body.
            Check("an empty body hashes as sha256 of nothing",
                Extracted.Sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
            Check("a GET canonical string ends in the empty-body hash",
                Extracted.PanelCanonical("get", "/api/v1/commands", ts, nonce, "") == "GET /api/v1/commands\n" + ts + "\n" + nonce + "\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

            // The plugin list hash, against the panel's inventory fixture.
            var inv = JObject.Parse(File.ReadAllText(Path.Combine(Path.GetDirectoryName(args[0]), "inventory.full.json")))["payload"];
            var rows = new System.Collections.Generic.List<string[]>();
            foreach (var p in inv["plugins"])
                rows.Add(new[] { (string)p["name"], (string)p["author"], (string)p["version"], ((string)p["sha256"]).Substring(7) });
            var invHash = Extracted.InventoryHash(rows);
            Check("inventory_hash matches the panel's fixture", invHash == (string)inv["inventory_hash"], invHash);
            rows.Reverse();
            Check("inventory_hash does not depend on order", Extracted.InventoryHash(rows) == (string)inv["inventory_hash"]);
            rows[0][1] = null;
            var withNull = Extracted.InventoryHash(rows);
            rows[0][1] = "";
            Check("a missing author hashes as the empty string", withNull == Extracted.InventoryHash(rows));

            // ---- the Oxide log: the contract's shape vectors, the parser, the source gates.
            Check("shape matches the contract's first vector",
                Extracted.LogShape("Corpse Location", "Player (76561190000000000) died at (-268.23, 58.57, 841.06)") ==
                "sha256:8542895ac3fe9378400e1c05ea6ae55a0d7375611c8bf378adb42628ff244686");
            Check("shape matches the contract's non-ASCII vector",
                Extracted.LogShape(null, "★Игрок_7★ joined") ==
                "sha256:9b43be8af597db7b46a8e324653fe9cdcc57afe2da26e98ac4c063baa9689586");

            var ln = Extracted.ParseOxideLine("18:52 [Info] [Corpse Location] Someone died");
            Check("a 24-hour line parses", ln.Recognised && ln.Hour == 18 && ln.Minute == 52 && ln.Level == "info" && ln.Source == "Corpse Location" && ln.Body == "Someone died",
                $"{ln.Recognised} {ln.Hour}:{ln.Minute} {ln.Level} {ln.Source} {ln.Body}");
            ln = Extracted.ParseOxideLine("6:52 PM [Warning] Loaded plugin Kits v1.0.0 by x");
            Check("a 12-hour line parses, without a source", ln.Recognised && ln.Hour == 18 && ln.Minute == 52 && ln.Level == "warning" && ln.Source == null && ln.Body == "Loaded plugin Kits v1.0.0 by x");
            ln = Extracted.ParseOxideLine("12:05 AM [Error] x");
            Check("12 AM is hour 0", ln.Recognised && ln.Hour == 0 && ln.Minute == 5);
            ln = Extracted.ParseOxideLine("下午6:52 [Info] x");
            Check("an unreadable time is left out, the line still parses", ln.Recognised && ln.Hour == -1 && ln.Body == "x");
            Check("a stack trace line is not a new entry", !Extracted.ParseOxideLine("  at Oxide.Plugins.Kits.Foo () [0x00000] in <abc>:0").Recognised);
            Check("an unknown level is not a new entry", !Extracted.ParseOxideLine("18:52 [Verbose] x").Recognised);
            Check("an empty text parses", Extracted.ParseOxideLine("18:52 [Info]").Recognised);

            TimeZoneInfo london = null;
            try { london = TimeZoneInfo.FindSystemTimeZoneById("Europe/London"); } catch { }
            if (london == null) Check("Europe/London time zone available for the DST checks", false);
            else
            {
                Check("a summer time converts to UTC", Extracted.LogLineUtc(new DateTime(2026, 6, 1), 12, 0, london) == "2026-06-01T11:00:00Z");
                Check("the repeated DST hour has no time", Extracted.LogLineUtc(new DateTime(2026, 10, 25), 1, 30, london) == null);
                Check("the skipped DST hour has no time", Extracted.LogLineUtc(new DateTime(2026, 3, 29), 1, 30, london) == null);
            }
            Check("no hour, no time", Extracted.LogLineUtc(new DateTime(2026, 6, 1), -1, -1, TimeZoneInfo.Utc) == null);

            Check("a card number keeps its last four", Extracted.MaskSourceGates("card 4111 1111 1111 1111 end") == "card #### #### #### 1111 end",
                Extracted.MaskSourceGates("card 4111 1111 1111 1111 end"));
            Check("a failed Luhn check is left alone", Extracted.MaskSourceGates("4111 1111 1111 1112") == "4111 1111 1111 1112");
            Check("a Steam ID is not a card", Extracted.MaskSourceGates("id 76561198211375245") == "id 76561198211375245");
            Check("a hyphenated SSN is masked", Extracted.MaskSourceGates("ssn 123-45-6789.") == "ssn ###-##-####.");
            var blocked = Extracted.BlockSteamIds("Bob (76561198211375245) died at (-268.23, 58.57, 841.06); 76561198211375245x ok; 176561198211375245 kept");
            Check("a Steam ID is removed and the rest of the line kept", blocked == "Bob ([blocked:identity]) died at (-268.23, 58.57, 841.06); [blocked:identity]x ok; 176561198211375245 kept", blocked);
            Check("tokens are whitespace-separated", Extracted.CountTokens(" a  b\tc ") == 3);
            var pii = Extracted.SuspectedPii("Bob (76561198211375245) died at (-268.23, 58.57, 841.06) from 10.0.0.1", "info");
            Check("identity, position and network are suspected", string.Join(",", pii) == "identity,position,network", string.Join(",", pii));
            Check("chat is suspected from the level", Extracted.SuspectedPii("hello", "chat").Contains("chat"));
            Check("a version number is not an address", !Extracted.SuspectedPii("v2.1.3.4.5", "info").Contains("network"));

            // The server console.
            Check("Rust's global chat is chat", Extracted.IsChatLine("[Global] Bob : hello there"));
            Check("team, clan and card-table chat are chat", Extracted.IsChatLine("[Team] Bob : x") && Extracted.IsChatLine("[Clan] Bob : x") && Extracted.IsChatLine("[Cards] Bob : x"));
            Check("a plugin's bracketed line is not chat", !Extracted.IsChatLine("[RaidableBases] Easy_1 @ G5 : 12 items"));
            Check("a channel with no ' : ' is not chat", !Extracted.IsChatLine("[Server] started"));
            Check("the Unity log types map to levels", Extracted.ConsoleLevel(0) == "error" && Extracted.ConsoleLevel(1) == "error" && Extracted.ConsoleLevel(2) == "warning" && Extracted.ConsoleLevel(3) == "info" && Extracted.ConsoleLevel(4) == "error");

            var joined = Extracted.MaskIps("203.0.113.9:61234/76561198211375245/Bob joined [windows/76561198211375245]");
            Check("a player's IPv4 is masked and its port kept", joined == "[blocked:network]:61234/76561198211375245/Bob joined [windows/76561198211375245]", joined);
            Check("a version number is not an address", Extracted.MaskIps("Oxide 2.0.4149.1 and 1.2.3.4.5") == "Oxide 2.0.4149.1 and 1.2.3.4.5", Extracted.MaskIps("Oxide 2.0.4149.1 and 1.2.3.4.5"));
            Check("an octet over 255 is not an address", Extracted.MaskIps("999.1.1.1") == "999.1.1.1");
            Check("a time is not an IPv6 address", Extracted.MaskIps("at 12:34:56 and 01:02") == "at 12:34:56 and 01:02");
            Check("a full IPv6 address is masked", Extracted.MaskIps("from 2001:0db8:85a3:0000:0000:8a2e:0370:7334 ok") == "from [blocked:network] ok", Extracted.MaskIps("from 2001:0db8:85a3:0000:0000:8a2e:0370:7334 ok"));
            Check("a compressed IPv6 address is masked", Extracted.MaskIps("rcon from 2001:db8::1, ::1") == "rcon from [blocked:network], [blocked:network]", Extracted.MaskIps("rcon from 2001:db8::1, ::1"));
            Check("an IPv4-mapped IPv6 address leaves nothing of the address", !Extracted.MaskIps("::ffff:10.0.0.7").Contains("10.0"), Extracted.MaskIps("::ffff:10.0.0.7"));
            Check("a hex word is not an address", Extracted.MaskIps("0xdecafbad cafe:beef") == "0xdecafbad cafe:beef", Extracted.MaskIps("0xdecafbad cafe:beef"));
            Check("text with no address is returned as it was", ReferenceEquals(Extracted.MaskIps("Saved 77,765 ents"), "Saved 77,765 ents") || Extracted.MaskIps("Saved 77,765 ents") == "Saved 77,765 ents");

            Check("an RCON command that sets a password keeps its name, not its value",
                Extracted.MaskRconSecrets("[RCON][203.0.113.9:5678] rcon.password \"hunter2\"") == "[RCON][203.0.113.9:5678] rcon.password [blocked:credential]",
                Extracted.MaskRconSecrets("[RCON][203.0.113.9:5678] rcon.password \"hunter2\""));
            Check("the websocket form is masked too", Extracted.MaskRconSecrets("[rcon] 10.0.0.1:5000: discord.token abc123") == "[rcon] 10.0.0.1:5000: discord.token [blocked:credential]");
            Check("an ordinary RCON command is left as it was", Extracted.MaskRconSecrets("[RCON][x] server.writecfg") == "[RCON][x] server.writecfg" && Extracted.MaskRconSecrets("[RCON][x] say hello all") == "[RCON][x] say hello all");
            Check("a line that is not an RCON command is left as it was", Extracted.MaskRconSecrets("Saved 77,765 ents") == "Saved 77,765 ents" && Extracted.MaskRconSecrets("[Global] Bob : my password is x") == "[Global] Bob : my password is x");

            var spooled = Extracted.SpoolLogLine('e', "2026-09-19T21:10:05.123Z", "error", "a\tb", "first\nsecond\tthird \\ end\r");
            var back = Extracted.ReadSpoolLogLine(spooled);
            Check("a spool line is one line", spooled.IndexOf('\n') < 0 && spooled.IndexOf('\r') < 0);
            Check("a spool line reads back exactly", back != null && back.Stream == 'e' && back.At == "2026-09-19T21:10:05.123Z" && back.Level == "error" && back.Source == "a\tb" && back.Text == "first\nsecond\tthird \\ end\r");
            var bare = Extracted.ReadSpoolLogLine(Extracted.SpoolLogLine('o', null, null, null, ""));
            Check("missing fields read back as missing", bare != null && bare.At == null && bare.Level == null && bare.Source == null && bare.Text == "");
            Check("a line that is not a spool line is refused", Extracted.ReadSpoolLogLine("half a line") == null && Extracted.ReadSpoolLogLine("e\tx") == null);
            DateTime spoolDate;
            Check("the spool is named by the day", Extracted.LogSpoolName(new DateTime(2026, 9, 19)) == "hotwire_log_2026-09-19.txt"
                && Extracted.LogSpoolDate("hotwire_log_2026-09-19.txt", out spoolDate) && spoolDate == new DateTime(2026, 9, 19)
                && !Extracted.LogSpoolDate("oxide_2026-09-19.txt", out spoolDate) && !Extracted.LogSpoolDate("hotwire_log_2026-09-19.txt.bak", out spoolDate));

            var echo = new Extracted.EchoSet();
            echo.Add("Loaded plugin Kits", 100);
            echo.Add("Loaded plugin Kits", 200);
            Check("an Oxide line is recognised once for each time it was seen", echo.TryConsume("Loaded plugin Kits") && echo.TryConsume("Loaded plugin Kits") && !echo.TryConsume("Loaded plugin Kits"));
            echo.Add("old", 100);
            echo.Add("new", 500);
            echo.Expire(300);
            Check("old Oxide lines are forgotten", !echo.TryConsume("old") && echo.TryConsume("new") && echo.Count == 0);
            for (var i = 0; i < 5000; i++) echo.Add("flood " + i, i);
            Check("the echo set stays bounded in a flood", echo.Count <= 4096, echo.Count.ToString());

            // A real server console, when a file is given: every line survives the spool, and how long masking takes.
            var consoleLog = Environment.GetEnvironmentVariable("HOTWIRE_CONSOLE_LOG");
            if (!string.IsNullOrEmpty(consoleLog) && File.Exists(consoleLog))
            {
                var all = File.ReadAllLines(consoleLog);
                var bad = 0;
                foreach (var line in all)
                {
                    var r = Extracted.ReadSpoolLogLine(Extracted.SpoolLogLine('e', "2026-09-05T13:00:39.000Z", "info", null, line));
                    if (r == null || r.Text != line) bad++;
                }
                Check($"all {all.Length} real console lines survive the spool", bad == 0, bad + " changed");
                var watch = System.Diagnostics.Stopwatch.StartNew();
                foreach (var line in all) Extracted.MaskIps(Extracted.MaskSourceGates(line));
                watch.Stop();
                Console.WriteLine($"  masking {all.Length} real lines: {watch.Elapsed.TotalMilliseconds:F1} ms ({watch.Elapsed.TotalMilliseconds * 1e6 / all.Length:F0} ns a line)");
            }

            var sk = Extracted.LogSessionKey(638900000000000000, "/srv/rust");
            Check("the session key is a version-8 UUID", Regex.IsMatch(sk, "^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"), sk);
            Check("the session key is stable for one process", sk == Extracted.LogSessionKey(638900000000000000, "/srv/rust"));
            Check("another process gets another session key", sk != Extracted.LogSessionKey(638900000010000000, "/srv/rust"));

            // Real Oxide logs, when a folder is given: how many lines parse, and how many shapes they make.
            var logs = Environment.GetEnvironmentVariable("HOTWIRE_OXIDE_LOGS");
            if (!string.IsNullOrEmpty(logs) && Directory.Exists(logs))
            {
                int total = 0, recognised = 0, timed = 0;
                var shapes = new System.Collections.Generic.HashSet<string>();
                foreach (var file in Directory.GetFiles(logs, "oxide_????-??-??.txt"))
                    foreach (var line in File.ReadAllLines(file))
                    {
                        total++;
                        var parsed = Extracted.ParseOxideLine(line);
                        if (!parsed.Recognised) continue;
                        recognised++;
                        if (parsed.Hour >= 0) timed++;
                        shapes.Add(Extracted.LogShape(parsed.Source, parsed.Body));
                    }
                Console.WriteLine($"  real logs: {total} lines, {recognised} start an entry, {timed} with a time, {shapes.Count} distinct shapes");
            }

            // ---- the app manifest's branch, read as hotwire-setup reads it.
            const string acf = "\"AppState\"\n{\n\t\"appid\"\t\t\"258550\"\n\t\"buildid\"\t\t\"25272657\"\n\t\"UserConfig\"\n\t{\n\t\t\"BetaKey\"\t\t\"staging\"\n\t}\n\t\"MountedConfig\"\n\t{\n\t\t\"BetaKey\"\t\t\"staging\"\n\t}\n}";
            Check("a BetaKey names the branch", Extracted.ManifestBranch(acf) == "staging", Extracted.ManifestBranch(acf));
            Check("no BetaKey is the public branch", Extracted.ManifestBranch("\"AppState\"\n{\n\t\"buildid\"\t\t\"25230300\"\n\t\"UserConfig\"\n\t{\n\t\t\"language\"\t\t\"english\"\n\t}\n}") == "public");
            Check("an empty BetaKey is the public branch", Extracted.ManifestBranch("\"UserConfig\"\n{\n\t\"BetaKey\"\t\t\"\"\n}") == "public");
            Check("no manifest, no branch", Extracted.ManifestBranch("") == null);

            var n = Extracted.PanelNonce();
            Check("nonce is 32 lowercase hex characters", Regex.IsMatch(n, "^[0-9a-f]{32}$"), n);

            // ---- HW-1 / ADR-0085: the panel's signed response. The plugin must verify a wrapped
            // answer byte-for-byte with the panel (App\Support\HotwireSignature::responseCanonical /
            // signResponse), and fail closed on anything it cannot verify.
            var rv = (JObject)v["response"];
            var rSecret = (string)rv["secret"];
            var rStatus = (int)rv["status"];
            var rTs = (string)rv["request_timestamp"];
            var rNonce = (string)rv["request_nonce"];
            var rSigned = (string)rv["signed_body_utf8"];

            Check("signed body sha256 matches the vector", Extracted.Sha256Hex(rSigned) == (string)rv["signed_body_sha256"]);
            Check("response canonical string matches the vector",
                Extracted.PanelResponseCanonical(rStatus, rTs, rNonce, rSigned) == (string)rv["response_canonical_string"]);
            var rSig = Extracted.PanelSignResponse(rSecret, rStatus, rTs, rNonce, rSigned);
            Check("response signature matches the vector", rSig == (string)rv["response_signature"], rSig);

            // The full wrapper the panel sends verifies, and hands back the real body verbatim.
            string real;
            var okWrap = Extracted.PanelVerifyResponse(rSecret, rStatus, rTs, rNonce, (string)rv["wrapper"], out real);
            Check("a correctly wrapped response verifies", okWrap);
            Check("verification returns the real body verbatim, not re-serialised", real == rSigned, real);

            // Fail-closed cases: each must be rejected with a null body.
            string dropped;
            Check("a plain (unwrapped) body is rejected",
                !Extracted.PanelVerifyResponse(rSecret, rStatus, rTs, rNonce, rSigned, out dropped) && dropped == null);
            var forged = "{\"signed\":" + JsonConvert.SerializeObject(rSigned) + ",\"sig\":\"" + new string('0', 64) + "\"}";
            Check("a wrapper with a forged signature is rejected",
                !Extracted.PanelVerifyResponse(rSecret, rStatus, rTs, rNonce, forged, out dropped) && dropped == null);
            Check("a wrapper verified against a different nonce is rejected (no replay)",
                !Extracted.PanelVerifyResponse(rSecret, rStatus, rTs, "a-different-nonce", (string)rv["wrapper"], out dropped) && dropped == null);
            Check("a wrapper verified with the wrong secret is rejected",
                !Extracted.PanelVerifyResponse("the-wrong-secret", rStatus, rTs, rNonce, (string)rv["wrapper"], out dropped) && dropped == null);
            var tampered = "{\"signed\":" + JsonConvert.SerializeObject("{\"ok\":true,\"message\":\"OK\",\"data\":{\"sharing_level\":3}}") +
                           ",\"sig\":\"" + rSig + "\"}";
            Check("a wrapper whose signed body was swapped is rejected",
                !Extracted.PanelVerifyResponse(rSecret, rStatus, rTs, rNonce, tampered, out dropped) && dropped == null);
            Check("a wrapper missing its sig is rejected",
                !Extracted.PanelVerifyResponse(rSecret, rStatus, rTs, rNonce, "{\"signed\":\"x\"}", out dropped) && dropped == null);
            Check("empty/garbage is rejected", !Extracted.PanelVerifyResponse(rSecret, rStatus, rTs, rNonce, "not json", out dropped) && dropped == null);

            // ---- the report policy, as GET /api/v1/policy answers it.
            var free = Extracted.ReadPolicy("{\"ok\":true,\"message\":\"OK\",\"data\":{\"policy\":\"free\",\"heartbeat_seconds\":60,\"plugin_time_seconds\":300,\"log_levels\":[\"warning\",\"error\"],\"commands\":false,\"bans\":false,\"policy_hash\":\"sha256:aa\"}}");
            Check("the free policy is read", free != null && free.Name == "free" && free.HeartbeatSeconds == 60 && free.PluginTimeSeconds == 300
                && free.Commands == false && free.Bans == false && free.Hash == "sha256:aa");
            Check("free sends warnings and errors, whatever their case", Extracted.PolicyAllowsLevel(free, "warning") && Extracted.PolicyAllowsLevel(free, "Error"));
            Check("free keeps info and chat here", !Extracted.PolicyAllowsLevel(free, "info") && !Extracted.PolicyAllowsLevel(free, "chat"));
            Check("a line with no level is sent", Extracted.PolicyAllowsLevel(free, null));
            var pro = Extracted.ReadPolicy("{\"ok\":true,\"message\":\"OK\",\"data\":{\"policy\":\"pro\",\"heartbeat_seconds\":30,\"plugin_time_seconds\":60,\"log_levels\":null,\"commands\":true,\"bans\":true,\"policy_hash\":\"sha256:bb\"}}");
            Check("pro sends every level", pro != null && pro.LogLevels == null && Extracted.PolicyAllowsLevel(pro, "info") && pro.Commands == true);
            Check("no policy sends every level", Extracted.PolicyAllowsLevel(null, "info"));
            var odd2 = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"heartbeat_seconds\":\"60\",\"plugin_time_seconds\":-5,\"log_levels\":[\"warning\",3],\"commands\":\"no\"}}");
            Check("a mistyped field leaves that aspect to the config", odd2 != null && odd2.HeartbeatSeconds == 0 && odd2.PluginTimeSeconds == 0
                && odd2.LogLevels == null && odd2.Commands == null && odd2.Bans == null);
            var big = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"heartbeat_seconds\":99999999999999999999999,\"bans\":false}}");
            Check("a number too large for a long is ignored, not the whole answer", big != null && big.HeartbeatSeconds == 0 && big.Bans == false);
            Check("an answer with ok false cannot be read", Extracted.ReadPolicy("{\"ok\":false,\"data\":{\"commands\":false}}") == null);
            Check("an answer without data cannot be read", Extracted.ReadPolicy("{\"ok\":true}") == null);
            Check("garbage cannot be read", Extracted.ReadPolicy("not json") == null && Extracted.ReadPolicy("") == null);

            // ---- which report kinds may be sent (a paused server sends only its heartbeat).
            Check("no kinds field sends every kind", free.Kinds == null && Extracted.PolicyAllowsKindOf(free, "inventory") && Extracted.PolicyAllowsKindOf(free, "log"));
            Check("no policy sends every kind", Extracted.PolicyAllowsKindOf(null, "players"));
            var paused = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"policy\":\"paused\",\"heartbeat_seconds\":240,\"plugin_time_seconds\":3600,\"log_levels\":[],\"commands\":false,\"bans\":false,\"kinds\":[\"heartbeat\"],\"policy_hash\":\"sha256:cc\"}}");
            Check("the paused policy is read", paused != null && paused.Name == "paused" && paused.Kinds != null && paused.Kinds.Count == 1 && paused.HeartbeatSeconds == 240);
            Check("paused sends its heartbeat", Extracted.PolicyAllowsKindOf(paused, "heartbeat"));
            Check("paused sends nothing else", !Extracted.PolicyAllowsKindOf(paused, "inventory") && !Extracted.PolicyAllowsKindOf(paused, "log")
                && !Extracted.PolicyAllowsKindOf(paused, "map_render") && !Extracted.PolicyAllowsKindOf(paused, "command_result"));
            Check("kinds are matched exactly", !Extracted.PolicyAllowsKindOf(paused, "Heartbeat"));
            var none = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"kinds\":[]}}");
            Check("an empty kinds list sends no reports at all", none != null && none.Kinds != null && none.Kinds.Count == 0 && !Extracted.PolicyAllowsKindOf(none, "heartbeat"));
            var nullKinds = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"kinds\":null}}");
            Check("kinds null sends every kind", nullKinds != null && nullKinds.Kinds == null && Extracted.PolicyAllowsKindOf(nullKinds, "players"));
            var mistyped = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"kinds\":\"heartbeat\"}}");
            Check("kinds that is not a list sends every kind", mistyped != null && mistyped.Kinds == null && Extracted.PolicyAllowsKindOf(mistyped, "log"));
            var mixed = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"kinds\":[\"heartbeat\",3]}}");
            Check("a kinds list with a non-string sends every kind", mixed != null && mixed.Kinds == null && Extracted.PolicyAllowsKindOf(mixed, "log"));

            // ---- hold: a paused server keeps what it may not send.
            var held = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"policy\":\"paused\",\"kinds\":[\"heartbeat\"],\"hold\":true}}");
            Check("hold true is read", held != null && Extracted.PolicyHolds(held));
            Check("no hold field does not hold", !Extracted.PolicyHolds(free) && !Extracted.PolicyHolds(paused));
            var holdMistyped = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"hold\":\"yes\"}}");
            Check("a hold that is not a boolean does not hold", holdMistyped != null && !Extracted.PolicyHolds(holdMistyped));
            Check("no policy does not hold", !Extracted.PolicyHolds(null));

            // Player positions are sent only when the panel says true in so many words.
            var positions = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"policy\":\"pro\",\"positions\":true}}");
            Check("positions true is read", positions != null && positions.Positions);
            Check("no positions field sends no positions", !free.Positions && !pro.Positions && !paused.Positions);
            var positionsMistyped = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"positions\":\"yes\"}}");
            Check("positions that are not a boolean send no positions", positionsMistyped != null && !positionsMistyped.Positions);
            var positionsFalse = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"positions\":false}}");
            Check("positions false sends no positions", positionsFalse != null && !positionsFalse.Positions);

            // ---- intervals the panel sets: only ever longer than the config's, never past a cap.
            var slow = Extracted.ReadPolicy("{\"ok\":true,\"data\":{\"command_seconds\":60,\"ban_seconds\":600,\"log_seconds\":120,\"event_seconds\":90,\"marker_seconds\":300,\"policy_seconds\":900}}");
            Check("every interval is read", slow != null && slow.CommandSeconds == 60 && slow.BanSeconds == 600 && slow.LogSeconds == 120
                && slow.EventSeconds == 90 && slow.MarkerSeconds == 300 && slow.PolicySeconds == 900);
            Check("an interval missing from the answer is as the config says", free.CommandSeconds == 0 && free.PolicySeconds == 0);
            Check("the panel's longer interval wins", Extracted.PolicyInterval(30, 10, 60, 300) == 60);
            Check("the admin's longer interval wins", Extracted.PolicyInterval(120, 10, 60, 300) == 120);
            Check("the panel cannot make it more often", Extracted.PolicyInterval(30, 10, 5, 300) == 30);
            Check("the panel's interval is capped", Extracted.PolicyInterval(30, 10, 86400, 300) == 300);
            Check("the config's floor holds", Extracted.PolicyInterval(1, 10, 0, 300) == 10);
            Check("no answer from the panel leaves the config", Extracted.PolicyInterval(45, 10, 0, 300) == 45);
            Check("the policy poll is never more often than five minutes", Extracted.PolicyInterval(300, 300, 60, 3600) == 300);

            // ---- the spool: what is kept, for how long, within what.
            Check("session, events and command answers are kept", Extracted.SpoolKeepsKind("session") && Extracted.SpoolKeepsKind("events") && Extracted.SpoolKeepsKind("command_result"));
            Check("current-state kinds are not kept", !Extracted.SpoolKeepsKind("heartbeat") && !Extracted.SpoolKeepsKind("inventory")
                && !Extracted.SpoolKeepsKind("log") && !Extracted.SpoolKeepsKind("players") && !Extracted.SpoolKeepsKind("plugin_time") && !Extracted.SpoolKeepsKind("schedule"));
            Check("no answer, 429 and 5xx are kept", Extracted.SpoolKeepsStatus(0) && Extracted.SpoolKeepsStatus(-1) && Extracted.SpoolKeepsStatus(429)
                && Extracted.SpoolKeepsStatus(500) && Extracted.SpoolKeepsStatus(503) && Extracted.SpoolKeepsStatus(599));
            Check("other refusals are not kept", !Extracted.SpoolKeepsStatus(400) && !Extracted.SpoolKeepsStatus(401) && !Extracted.SpoolKeepsStatus(413)
                && !Extracted.SpoolKeepsStatus(422) && !Extracted.SpoolKeepsStatus(200) && !Extracted.SpoolKeepsStatus(600));
            var sent = new DateTime(2026, 9, 18, 4, 11, 0, 123, DateTimeKind.Utc);
            var fileName = Extracted.SpoolFileName(sent, "0193f2c1-8a4e-7c1a-9f3b-2d5e6a7b8c9d");
            Check("a spool file name carries when the report was made", Extracted.SpoolFileTime(fileName) == sent, fileName);
            Check("spool file names sort oldest first", string.CompareOrdinal(Extracted.SpoolFileName(sent, "b"), Extracted.SpoolFileName(sent.AddMilliseconds(1), "a")) < 0);
            Check("a name that is not ours has no time", Extracted.SpoolFileTime("notes.json") == null && Extracted.SpoolFileTime(null) == null);

            var spoolNow = new DateTime(2026, 9, 18, 12, 0, 0, DateTimeKind.Utc);
            var entries = new List<Extracted.SpoolEntry>
            {
                new Extracted.SpoolEntry { Path = "a", SentUtc = spoolNow.AddDays(-31), Bytes = 10 },
                new Extracted.SpoolEntry { Path = "b", SentUtc = spoolNow.AddDays(-30).AddMinutes(1), Bytes = 10 },
                new Extracted.SpoolEntry { Path = "c", SentUtc = spoolNow.AddDays(-1), Bytes = 10 },
            };
            List<Extracted.SpoolEntry> expired, overflowed;
            Extracted.SpoolPrune(entries, spoolNow, 30, out expired, out overflowed);
            Check("older than 30 days is let go unsent", expired.Count == 1 && expired[0].Path == "a" && overflowed.Count == 0);
            var bigSpool = new List<Extracted.SpoolEntry>
            {
                new Extracted.SpoolEntry { Path = "old", SentUtc = spoolNow.AddDays(-3), Bytes = 30L * 1024 * 1024 },
                new Extracted.SpoolEntry { Path = "mid", SentUtc = spoolNow.AddDays(-2), Bytes = 15L * 1024 * 1024 },
                new Extracted.SpoolEntry { Path = "new", SentUtc = spoolNow.AddDays(-1), Bytes = 15L * 1024 * 1024 },
            };
            Extracted.SpoolPrune(bigSpool, spoolNow, 30, out expired, out overflowed);
            Check("over 50 MB, the oldest go until it fits", expired.Count == 0 && overflowed.Count == 1 && overflowed[0].Path == "old");
            var many = Enumerable.Range(0, 5003).Select(i => new Extracted.SpoolEntry { Path = i.ToString("D5"), SentUtc = spoolNow.AddMinutes(-6000 + i), Bytes = 100 }).ToList();
            Extracted.SpoolPrune(many, spoolNow, 30, out expired, out overflowed);
            Check("over 5,000 files, the oldest go", overflowed.Count == 3 && overflowed[0].Path == "00000" && overflowed[2].Path == "00002");

            var today = new DateTime(2026, 9, 18);
            Check("a log file from 31 days ago is skipped when 30 days are kept", Extracted.LogFileTooOld("oxide_2026-08-18.txt", today, 30));
            Check("a log file from 30 days ago is read when 30 days are kept", !Extracted.LogFileTooOld("oxide_2026-08-19.txt", today, 30));
            Check("today's log file is read", !Extracted.LogFileTooOld("oxide_2026-09-18.txt", today, 30));
            Check("a file name that is not a date is never skipped", !Extracted.LogFileTooOld("oxide_latest.txt", today, 30) && !Extracted.LogFileTooOld(null, today, 30));
            // The default is a week (the owner: "if the server hasn't connected in seven days, they have other issues").
            Check("a log file from 8 days ago is skipped when a week is kept", Extracted.LogFileTooOld("oxide_2026-09-10.txt", today, 7));
            Check("a log file from 6 days ago is read when a week is kept", !Extracted.LogFileTooOld("oxide_2026-09-12.txt", today, 7));
            var weekOld = new System.Collections.Generic.List<Extracted.SpoolEntry> {
                new Extracted.SpoolEntry { Path = "old.json", SentUtc = spoolNow.AddDays(-8), Bytes = 10 },
                new Extracted.SpoolEntry { Path = "new.json", SentUtc = spoolNow.AddDays(-6), Bytes = 10 },
            };
            Extracted.SpoolPrune(weekOld, spoolNow, 7, out expired, out overflowed);
            Check("a report older than the kept days is let go", expired.Count == 1 && expired[0].Path == "old.json" && overflowed.Count == 0);

            Console.WriteLine(_failed == 0 ? "All checks passed." : _failed + " check(s) FAILED.");
            return _failed == 0 ? 0 : 1;
        }
    }
}
