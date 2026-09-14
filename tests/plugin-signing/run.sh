#!/usr/bin/env bash
# Checks the plugin's panel signing against the panel's published conformance vector.
# Needs the .NET 8 SDK. Usage: tests/plugin-signing/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../src/Hotwire.cs"

extract() { awk -v name="#region $1" 'index($0, name){on=1; next} on && /#endregion/{exit} on{print}' "$src"; }
signing="$(extract "Panel signing")"
loglines="$(extract "Log lines")"
manifest="$(extract "Manifest")"
[ -n "$manifest" ] || { echo "Could not find the Manifest region in $src" >&2; exit 1; }
[ -n "$signing" ] || { echo "Could not find the Panel signing region in $src" >&2; exit 1; }
[ -n "$loglines" ] || { echo "Could not find the Log lines region in $src" >&2; exit 1; }

{
  echo 'using System; using System.Collections.Generic; using System.Globalization; using System.Linq; using System.Security.Cryptography; using System.Text;'
  echo 'using Newtonsoft.Json; using Newtonsoft.Json.Linq;'
  echo 'namespace PluginSigning { internal static class Extracted {'
  printf '%s\n%s\n%s\n' "$signing" "$loglines" "$manifest" | sed -E 's/^([[:space:]]*)private (static|sealed class)/\1internal \2/'
  echo '} }'
} > "$here/Extracted.cs"

dotnet run --project "$here/PluginSigning.csproj" -- "$here/conformance.json"
