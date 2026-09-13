#!/usr/bin/env bash
# Checks the plugin's panel signing against the panel's published conformance vector.
# Needs the .NET 8 SDK. Usage: tests/plugin-signing/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../src/Hotwire.cs"

region="$(awk '/#region Panel signing/{on=1; next} on && /#endregion/{exit} on{print}' "$src")"
[ -n "$region" ] || { echo "Could not find the Panel signing region in $src" >&2; exit 1; }

{
  echo 'using System; using System.Globalization; using System.Security.Cryptography; using System.Text;'
  echo 'using Newtonsoft.Json; using Newtonsoft.Json.Linq;'
  echo 'namespace PluginSigning { internal static class Extracted {'
  printf '%s\n' "$region" | sed -E 's/^([[:space:]]*)private static/\1internal static/'
  echo '} }'
} > "$here/Extracted.cs"

dotnet run --project "$here/PluginSigning.csproj" -- "$here/conformance.json"
