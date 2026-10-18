#!/usr/bin/env bash
#
# tools/sign-release.sh signing with a key on a token (the yubikey key): a software token stands in for a hardware one, its
# key is made inside the token, and the manifest.sig it produces must pass both launchers' own signature checks
# (hotwire-launcher.sh's su_verify and hotwire.ps1's Test-ReleaseSignature, the second under PowerShell 7).
# What this cannot prove: a hardware token's prompts, and Windows PowerShell 5.1.
#
#   bash tests/release-signing/run.sh        (needs softhsm2 and opensc; PWSH=<path> if pwsh is not on the PATH)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: got $2, want $3"; fail=1; fi; }

module=""
for m in /usr/lib/softhsm/libsofthsm2.so /usr/lib/x86_64-linux-gnu/softhsm/libsofthsm2.so; do [ -f "$m" ] && module="$m" && break; done
[ -n "$module" ] && command -v pkcs11-tool >/dev/null && command -v softhsm2-util >/dev/null \
    || { echo "  FAIL  softhsm2 and opensc are needed for this test"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tokens"
printf 'directories.tokendir = %s\nobjectstore.backend = file\n' "$work/tokens" > "$work/softhsm2.conf"
export SOFTHSM2_CONF="$work/softhsm2.conf"
softhsm2-util --init-token --free --label hwtest --pin 123456 --so-pin 12345678 >/dev/null
# The key is made inside the token, with id 02.
pkcs11-tool --module "$module" --token-label hwtest --login --pin 123456 --keypairgen --key-type EC:prime256v1 \
    --id 02 --label sign >/dev/null 2>&1
pkcs11-tool --module "$module" --token-label hwtest --read-object --type pubkey --id 02 --output-file "$work/pub.der" >/dev/null 2>&1
pub="$(tail -c 64 "$work/pub.der" | od -An -tx1 | tr -d ' \n')"
check "the token's public key is read" "${#pub}" 128

printf '{\n  "format": 1,\n  "tag": "release-test",\n  "files": {\n    "Hotwire.cs": "%064d"\n  }\n}\n' 0 > "$work/manifest.json"

sign() {  # sign <key-id> [token label]: run the tool as a release would, with the token instead of a file.
    HOTWIRE_PKCS11_MODULE="$module" HOTWIRE_PKCS11_TOKEN="${2:-hwtest}" HOTWIRE_PKCS11_PIN=123456 \
        bash tools/sign-release.sh file "$work/manifest.json" "$1" yubikey >/dev/null 2>"$work/err"; echo $?
}

check "signing with the token" "$(sign yk-test)" 0
check "manifest.sig has its two lines" "$(grep -c -E '^(key yk-test|sig [A-Za-z0-9+/=]{88})$' "$work/manifest.sig")" 2
check "a PIN prompt is not printed into the signature file" "$(grep -c -i pin "$work/manifest.sig")" 0
cp "$work/manifest.sig" "$work/good.sig"

# The Linux launcher's own check, with the token's public key as a trusted key.
sed '/^# Main\.$/,$d' launcher/hotwire-launcher.sh > "$work/lib.sh"
linux() {  # linux <manifest> <sig>: su_verify's answer
    local manifest="$1" sig="$2"
    ( set +u; set --; HOTWIRE_ROOT_OVERRIDE="$work" source "$work/lib.sh" >/dev/null 2>&1
      SU_KEYS=("yk-test:$pub"); su_verify "$manifest" "$sig"; echo $? )
}
check "Linux launcher accepts it" "$(linux "$work/manifest.json" "$work/good.sig")" 0
cp "$work/manifest.json" "$work/changed.json"; sed -i 's/release-test/release-tampered/' "$work/changed.json"
check "Linux launcher refuses a changed manifest" "$(linux "$work/changed.json" "$work/good.sig")" 1
sed 's/^key yk-test$/key yk-other/' "$work/good.sig" > "$work/other.sig"
check "Linux launcher refuses an untrusted key id" "$(linux "$work/manifest.json" "$work/other.sig")" 1

# The Windows launcher's own check, under PowerShell 7.
PWSH="${PWSH:-pwsh}"
if command -v "$PWSH" >/dev/null 2>&1; then
    win() {  # win <manifest> <sig>: Test-ReleaseSignature's answer, True or False
        "$PWSH" -NoProfile -NonInteractive -Command '
            $t = $null; $e = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "launcher/hotwire.ps1"), [ref]$t, [ref]$e)
            $want = @("Get-Env", "ConvertFrom-Hex", "Test-ReleaseSignature")
            foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
            $SuKeys = [ordered]@{ "yk-test" = $env:HW_PUB }
            Test-ReleaseSignature $env:HW_MANIFEST $env:HW_SIG' 2>/dev/null | tail -1
    }
    check "Windows launcher accepts it" "$(HW_PUB="$pub" HW_MANIFEST="$work/manifest.json" HW_SIG="$work/good.sig" win)" True
    check "Windows launcher refuses a changed manifest" "$(HW_PUB="$pub" HW_MANIFEST="$work/changed.json" HW_SIG="$work/good.sig" win)" False
else
    echo "  FAIL  PowerShell 7 ($PWSH) is needed for the Windows launcher's check"; fail=1
fi

# Both launchers ship the same release keys, and nothing else.
yk="yk-38628153:f1e8fe30f1201bf8ec8d856402f9113cf66a322be8b90907b89f28ff3f24fb005d5a86d99e58117499a561464e6cf96fa3ae4a7b54fdae086dc9e93fdb7357b9
yk-38628349:876f79ef6a2a50e64677a099245995cb9f787ca8eb77dde0ebcd615c8af9603a9e2551dfe21759d86be07be8e7627aef9a9f3345fe0fa3c353871b79d7ea147e"
linux_keys="$(sed -n 's/^SU_KEYS=(\(.*\))$/\1/p' launcher/hotwire-launcher.sh | tr ' ' '\n' | tr -d '"' | sort)"
windows_keys="$(sed -n "/^\$SuKeys = \[ordered\]@{$/,/^}$/s/^ *'\([^']*\)' = '\([0-9a-f]*\)'$/\1:\2/p" launcher/hotwire.ps1 | sort)"
check "the Linux launcher trusts only the release keys" "$linux_keys" "$yk"
check "the Windows launcher trusts only the release keys" "$windows_keys" "$yk"
check "no launcher still carries the test key" "$(grep -c -E 'test-2026-10-12|SU_TEST_KEY|SuTestKey' launcher/hotwire-launcher.sh launcher/hotwire.ps1 | awk -F: '{s+=$2} END {print s}')" 0

# Failing safely: a wrong token or a missing key writes no signature.
rm -f "$work/manifest.sig"
check "no such token: the tool fails" "$(sign yk-test nosuchtoken)" 1
check "no such token: no manifest.sig is written" "$([ -f "$work/manifest.sig" ] && echo yes || echo no)" no
check "an unknown key id is refused" "$(HOTWIRE_PKCS11_KEY=zz sign yk-test)" 2

[ "$fail" = 0 ] && echo "release signing: all ok" || echo "release signing: FAILED"
exit "$fail"
