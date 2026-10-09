#!/usr/bin/env bash
#
# The launchers' wipe-permission check against shared vectors signed with a test-only key (never AFKPanel's key), the
# same vectors AFKPanel checks. A permission must verify for its own server, wipe and map, and for nothing else. Also
# checks that the two launchers carry the same public key. Runs hotwire.ps1's check when pwsh is on the PATH.
#
#   bash tests/wipe-permit/run.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
dir=tests/wipe-permit
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: got $2, want $3"; fail=1; fi; }
field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["vectors"][int(sys.argv[2])]; print(v[sys.argv[3]], end="")' "$dir/vector.json" "$1" "$2"; }
count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["vectors"]))' "$dir/vector.json")"
testkey="$(cat "$dir/test-public.pem")"

# hotwire.sh: its functions, without its main part.
lib="$(mktemp)"; trap 'rm -f "$lib"' EXIT
sed '/^# Main\.$/,$d' launcher/hotwire.sh > "$lib"
# The launcher reads its own arguments when it loads, so the check's arguments are kept aside first.
sh_ok() { local args=("$@"); ( set --; source "$lib" >/dev/null 2>&1; wipe_permit_ok "${args[@]}" && echo yes || echo no ); }
for i in $(seq 0 $((count - 1))); do
    s="$(field "$i" server)"; c="$(field "$i" cycle)"; seed="$(field "$i" seed)"; size="$(field "$i" size)"
    url="$(field "$i" levelurl)"; e="$(field "$i" expires)"; p="$(field "$i" permit)"
    check "hotwire.sh verifies vector $i" "$(sh_ok "$testkey" "$s" "$c" "$seed" "$size" "$url" "$e" "$p")" yes
    check "hotwire.sh refuses vector $i on another server" "$(sh_ok "$testkey" "$((s + 1))" "$c" "$seed" "$size" "$url" "$e" "$p")" no
    check "hotwire.sh refuses vector $i with another seed" "$(sh_ok "$testkey" "$s" "$c" "9${seed}" "$size" "$url" "$e" "$p")" no
    check "hotwire.sh refuses vector $i with a later expiry" "$(sh_ok "$testkey" "$s" "$c" "$seed" "$size" "$url" "$((e + 1))" "$p")" no
    check "hotwire.sh refuses vector $i against AFKPanel's key" "$( ( source "$lib" >/dev/null 2>&1; wipe_permit_ok "$WIPE_PERMIT_PUBKEY" "$s" "$c" "$seed" "$size" "$url" "$e" "$p" && echo yes || echo no ) )" no
done

# Version 2 signs the blueprints too: it verifies with its own, not with another, and not as version 1. A version 1
# permission still verifies when the flag names blueprints (the fallback for one signed before the update).
field2() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["vectors_v2"][int(sys.argv[2])]; print(v[sys.argv[3]], end="")' "$dir/vector.json" "$1" "$2"; }
count2="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("vectors_v2", [])))' "$dir/vector.json")"
for i in $(seq 0 $((count2 - 1))); do
    s="$(field2 "$i" server)"; c="$(field2 "$i" cycle)"; seed="$(field2 "$i" seed)"; size="$(field2 "$i" size)"
    url="$(field2 "$i" levelurl)"; e="$(field2 "$i" expires)"; p="$(field2 "$i" permit)"; bp="$(field2 "$i" blueprints)"
    other=keep; [ "$bp" = keep ] && other=delete
    check "hotwire.sh verifies v2 vector $i" "$(sh_ok "$testkey" "$s" "$c" "$seed" "$size" "$url" "$e" "$p" "$bp")" yes
    check "hotwire.sh refuses v2 vector $i with blueprints $other" "$(sh_ok "$testkey" "$s" "$c" "$seed" "$size" "$url" "$e" "$p" "$other")" no
    check "hotwire.sh refuses v2 vector $i read as version 1" "$(sh_ok "$testkey" "$s" "$c" "$seed" "$size" "$url" "$e" "$p")" no
done
s="$(field 0 server)"; c="$(field 0 cycle)"; seed="$(field 0 seed)"; size="$(field 0 size)"; url="$(field 0 levelurl)"; e="$(field 0 expires)"; p="$(field 0 permit)"
check "hotwire.sh still verifies a version 1 permission when the flag names blueprints" "$(sh_ok "$testkey" "$s" "$c" "$seed" "$size" "$url" "$e" "$p" delete)" yes
grep -q 'wipe_permit_blueprints' launcher/hotwire.sh && grep -q 'wipe_permit_blueprints' launcher/hotwire.ps1; check "both launchers advertise wipe_permit_blueprints" "$?" 0

# Both launchers carry the same public key.
sh_mod="$( ( source "$lib" >/dev/null 2>&1; printf '%s\n' "$WIPE_PERMIT_PUBKEY" | openssl rsa -pubin -noout -modulus 2>/dev/null | cut -d= -f2 ) )"
ps_mod="$(grep -m1 '^\$WipePermitModulus = ' launcher/hotwire.ps1 | cut -d"'" -f2 | base64 -d | od -An -tx1 -v | tr -d ' \n' | tr 'a-f' 'A-F')"
check "hotwire.sh and hotwire.ps1 carry the same key" "$ps_mod" "$sh_mod"
check "the key is 3072 bits" "$(( ${#sh_mod} * 4 ))" 3072

# hotwire.ps1: its check, read out of the file by the PowerShell parser.
ps="$(command -v pwsh || command -v powershell || true)"
if [ -n "$ps" ]; then
    mod="$(openssl rsa -pubin -in "$dir/test-public.pem" -noout -modulus | cut -d= -f2 | xxd -r -p | base64 -w0)"
    exp="$(printf '\x01\x00\x01' | base64)"
    for i in $(seq 0 $((count - 1))); do
        for case in own other; do
            got="$("$ps" -NoProfile -NonInteractive -Command '
                param()
                $t = $null; $e = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "launcher/hotwire.ps1"), [ref]$t, [ref]$e)
                foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Test-WipePermit" }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
                $v = (Get-Content -Raw "tests/wipe-permit/vector.json" | ConvertFrom-Json).vectors['"$i"']
                $server = [string]$v.server; if ("'"$case"'" -eq "other") { $server = [string]($v.server + 1) }
                if (Test-WipePermit $server $v.cycle $v.seed $v.size $v.levelurl ([string]$v.expires) $v.permit "'"$mod"'" "'"$exp"'") { "yes" } else { "no" }')"
            want=yes; [ "$case" = other ] && want=no
            check "hotwire.ps1 vector $i, $case server" "$got" "$want"
        done
    done
    for i in $(seq 0 $((count2 - 1))); do
        for case in own other v1; do
            got="$("$ps" -NoProfile -NonInteractive -Command '
                $t = $null; $e = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "launcher/hotwire.ps1"), [ref]$t, [ref]$e)
                foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Test-WipePermit" }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
                $v = (Get-Content -Raw "tests/wipe-permit/vector.json" | ConvertFrom-Json).vectors_v2['"$i"']
                $bp = $v.blueprints; if ("'"$case"'" -eq "other") { $bp = if ($bp -eq "keep") { "delete" } else { "keep" } }; if ("'"$case"'" -eq "v1") { $bp = "" }
                if (Test-WipePermit ([string]$v.server) $v.cycle $v.seed $v.size $v.levelurl ([string]$v.expires) $v.permit "'"$mod"'" "'"$exp"'" $bp) { "yes" } else { "no" }')"
            want=no; [ "$case" = own ] && want=yes
            check "hotwire.ps1 v2 vector $i, $case" "$got" "$want"
        done
    done
elif [ -n "${CI:-}" ]; then
    check "pwsh is on the PATH in CI" "no" "yes"
else
    echo "  skip  hotwire.ps1: no pwsh or powershell on the PATH"
fi

exit $fail
