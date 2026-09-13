using System;
using System.IO;
using System.Text.RegularExpressions;
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

            var n = Extracted.PanelNonce();
            Check("nonce is 32 lowercase hex characters", Regex.IsMatch(n, "^[0-9a-f]{32}$"), n);

            Console.WriteLine(_failed == 0 ? "All checks passed." : _failed + " check(s) FAILED.");
            return _failed == 0 ? 0 : 1;
        }
    }
}
