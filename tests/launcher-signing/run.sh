#!/usr/bin/env bash
#
# The launchers' report signature against the shared conformance vector (tests/plugin-signing/conformance.json), the
# same vector the plugin and AFKPanel check. Runs hotwire.sh's own signing function, and hotwire.ps1's when pwsh (or
# Windows PowerShell) is on the PATH. Also checks that the launchers' JSON text escaping round-trips.
#
#   bash tests/launcher-signing/run.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
vector=tests/plugin-signing/conformance.json
get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]], end="")' "$vector" "$1"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: got $2, want $3"; fail=1; fi; }

secret="$(get secret)"; ts="$(get timestamp)"; nonce="$(get nonce)"; body="$(get body_utf8)"; want="$(get signature)"

# hotwire.sh: its functions, without its main part.
lib="$(mktemp)"; trap 'rm -f "$lib"' EXIT
sed '/^# Main\.$/,$d' launcher/hotwire.sh > "$lib"
got="$( ( source "$lib" >/dev/null 2>&1; _report_sig "$secret" "$ts" "$nonce" "$body" ) )"
check "hotwire.sh signs the conformance vector" "$got" "$want"
for s in 'plain' 'a "quote" and \back' $'two\nlines\tand a tab'; do
    out="$( ( source "$lib" >/dev/null 2>&1; json_text "$s" ) )"
    back="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()), end="")')"
    check "hotwire.sh json_text round-trips $(printf '%q' "$s")" "$back" "$s"
done

# hotwire.ps1: its signing functions, read out of the file by the PowerShell parser.
ps="$(command -v pwsh || command -v powershell || true)"
if [ -n "$ps" ]; then
    got="$("$ps" -NoProfile -NonInteractive -Command '
        $t = $null; $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "launcher/hotwire.ps1"), [ref]$t, [ref]$e)
        foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and @("Get-HexSha256", "Get-HexHmac", "Get-ReportSignature") -contains $n.Name }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
        $v = Get-Content -Raw "tests/plugin-signing/conformance.json" | ConvertFrom-Json
        Get-ReportSignature $v.secret $v.timestamp $v.nonce ((New-Object Text.UTF8Encoding($false)).GetBytes($v.body_utf8))')"
    check "hotwire.ps1 signs the conformance vector" "$got" "$want"
else
    echo "  skip  hotwire.ps1: no pwsh or powershell on the PATH"
fi

[ "$fail" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
