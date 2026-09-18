using System;
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

            Console.WriteLine(_failed == 0 ? "All checks passed." : _failed + " check(s) FAILED.");
            return _failed == 0 ? 0 : 1;
        }
    }
}
