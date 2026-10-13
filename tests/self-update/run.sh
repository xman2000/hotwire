#!/usr/bin/env bash
#
# Hotwire updating itself on Linux: hotwire-launcher.sh's own self_update_step and probation, and hotwire.sh's rollback,
# against a release feed and downloads served from files (file:// URLs), signed with a key made for the test. The test
# key's public half is put in place of the launcher's test key, so nothing here depends on the real keys.
#
#   bash tests/self-update/run.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: got $2, want $3"; fail=1; fi; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A key for the test, and the launcher with its public half as the test key.
openssl ecparam -name prime256v1 -genkey -noout -out "$work/key.pem" 2>/dev/null
pub="$(openssl ec -in "$work/key.pem" -pubout -outform DER 2>/dev/null | tail -c 64 | od -An -tx1 | tr -d ' \n')"
sed -E -e "s/^SU_TEST_KEY=\"test-2026-10-12:[0-9a-f]{128}\"$/SU_TEST_KEY=\"test-2026-10-12:$pub\"/" -e "s/^HOTWIRE_LAUNCHER_VERSION=\".*\"$/HOTWIRE_LAUNCHER_VERSION=\"1.1.24-linux\"/" launcher/hotwire-launcher.sh > "$work/hotwire-launcher.sh"
grep -q "$pub" "$work/hotwire-launcher.sh" || { echo "could not put the test key in place"; exit 1; }
printf '#!/bin/sh\nexit 0\n' > "$work/steamcmd"; chmod +x "$work/steamcmd"
other="$work/other.pem"; openssl ecparam -name prime256v1 -genkey -noout -out "$other" 2>/dev/null

# release <tag> <plugin> <launcher> <days old> [key] [prerelease]: a release in the feed, with its files and signed manifest.
feed_items=()
release() {
    local tag="$1" plugin="$2" launcher="$3" days="$4" key="${5:-$work/key.pem}" pre="${6:-false}" win="${7:-9.9.9}" d="$work/dl/$1"
    mkdir -p "$d"
    sed -E "s/^HOTWIRE_LAUNCHER_VERSION=\".*\"$/HOTWIRE_LAUNCHER_VERSION=\"$launcher\"/" "$work/hotwire-launcher.sh" > "$d/hotwire-launcher.sh"
    printf '// plugin\n[Info("Hotwire", "xman2000", "%s")]\nclass Hotwire {}\n' "$plugin" > "$d/Hotwire.cs"
    printf "\$LauncherVersion = '%s'\r\n" "$win" > "$d/hotwire.ps1"
    printf '{\n  "format": 1,\n  "tag": "%s",\n  "plugin": "%s",\n  "launcher_windows": "%s",\n  "launcher_linux": "%s",\n  "files": {\n    "Hotwire.cs": "%s",\n    "hotwire.ps1": "%s",\n    "hotwire-launcher.sh": "%s"\n  }\n}\n' \
        "$tag" "$plugin" "$win" "$launcher" "$(sha256sum < "$d/Hotwire.cs" | cut -c1-64)" "$(sha256sum < "$d/hotwire.ps1" | cut -c1-64)" \
        "$(sha256sum < "$d/hotwire-launcher.sh" | cut -c1-64)" > "$d/manifest.json"
    bash tools/sign-release.sh file "$d/manifest.json" test-2026-10-12 "$key" >/dev/null
    feed_items=("{\"tag_name\": \"$tag\", \"prerelease\": $pre, \"published_at\": \"$(date -u -d "-$days days" +%Y-%m-%dT%H:%M:%SZ)\"}" "${feed_items[@]}")
    { printf '['; local IFS=,; printf '%s' "${feed_items[*]}"; printf ']\n'; } > "$work/feed.json"
}

# A server folder running launcher 1.1.24-linux and plugin 1.1.74, with hotwire.cfg.
server() {
    local root="$work/server-$RANDOM$RANDOM"
    mkdir -p "$root/oxide/plugins" "$root/oxide/data/Hotwire" "$root/hotwire" "$root/steamapps"
    # Enough of a server for the launcher's check: Rust's binary and its manifest, and SteamCMD a stand-in.
    printf '#!/bin/sh\nexit 0\n' > "$root/RustDedicated"; chmod +x "$root/RustDedicated"
    printf '"AppState"\n{\n"buildid"\t\t"1"\n"StateFlags"\t\t"4"\n}\n' > "$root/steamapps/appmanifest_258550.acf"
    cp launcher/hotwire.sh "$root/hotwire.sh"
    cp "$work/hotwire-launcher.sh" "$root/hotwire-launcher.sh"
    printf '// plugin\n[Info("Hotwire", "xman2000", "1.1.74")]\nclass Hotwire {}\n' > "$root/oxide/plugins/Hotwire.cs"
    printf 'hotwire.self_update %s\nhotwire.self_update_days %s\nhotwire.self_update_test_key 1\nhotwire.update_mode off\nhotwire.steamcmd %s\n' "${1:-auto}" "${2:-3}" "$work/steamcmd" > "$root/hotwire.cfg"
    printf '%s' "$root"
}

# step <root>: run self_update_step there and print its return code.
step() {
    local dir="$1"
    ( set +u; set --; export HOTWIRE_SELF_UPDATE_FEED="file://$work/feed.json" HOTWIRE_SELF_UPDATE_DOWNLOAD="file://$work/dl"
      [ "${NO_STARTER:-}" = 1 ] || export HOTWIRE_STARTER=1
      sed '/^# Main\.$/,$d' "$dir/hotwire-launcher.sh" > "$dir/.lib.sh"
      HOTWIRE_ROOT_OVERRIDE="$dir" source "$dir/.lib.sh" >/dev/null 2>&1
      CHECK_ONLY=""; REPORT_ENABLED=0; START_ID=""; spool_flush() { :; }
      load_config >/dev/null 2>&1
      self_update_step >"$dir/step.log" 2>&1; echo $? )
}
pv() { sed -n -E 's/.*\[Info\("Hotwire", "[^"]*", "([0-9.]+)"\)\].*/\1/p' "$1/oxide/plugins/Hotwire.cs"; }
lv() { sed -n -E 's/^HOTWIRE_LAUNCHER_VERSION="(.*)"$/\1/p' "$1/hotwire-launcher.sh"; }
st() { sed -n "s/^$2=//p" "$1/hotwire/self-update/state" 2>/dev/null | head -1; }

release release-old 1.1.70 1.1.20-linux 30 "$work/key.pem" false 1.1.30
release release-new 1.1.75 1.1.25-linux 5 "$work/key.pem" false 1.1.40

echo "off: nothing is installed"
r="$(server off)"; check "returns 0" "$(step "$r")" 0; check "plugin unchanged" "$(pv "$r")" 1.1.74

echo "auto: a signed release 5 days old installs, and the new launcher takes over"
r="$(server auto 3)"; check "returns 75" "$(step "$r")" 75
check "plugin" "$(pv "$r")" 1.1.75; check "launcher" "$(lv "$r")" 1.1.25-linux
check "previous plugin kept" "$(pv "$r/hotwire/previous/.." 2>/dev/null; sed -n -E 's/.*"([0-9.]+)"\)\].*/\1/p' "$r/hotwire/previous/Hotwire.cs")" 1.1.74
check "on probation" "$(sed -n 's/^tag //p' "$r/hotwire/self-update/applied")" release-new
check "state says installed" "$(st "$r" last_result)" installed

echo "run without hotwire.sh, only the plugin updates"
r="$(server auto 3)"; check "returns 0" "$(NO_STARTER=1 step "$r")" 0; check "plugin" "$(pv "$r")" 1.1.75; check "launcher unchanged" "$(lv "$r")" 1.1.24-linux

echo "auto: too young for the server's wait"
r="$(server auto 7)"; check "returns 0" "$(step "$r")" 0; check "plugin unchanged" "$(pv "$r")" 1.1.74

echo "early release (0 days) takes a release published today"
release release-today 1.1.76 1.1.26-linux 0 "$work/key.pem" false 1.1.41
r="$(server auto 0)"; step "$r" >/dev/null; check "plugin" "$(pv "$r")" 1.1.76
r="$(server auto 3)"; step "$r" >/dev/null; check "3 days still takes the older one" "$(pv "$r")" 1.1.75

echo "a pre-release is not on the release channel"
release dev-pre 1.1.80 1.1.30-linux 9 "$work/key.pem" true
r="$(server auto 0)"; step "$r" >/dev/null; check "plugin" "$(pv "$r")" 1.1.76

echo "a server newer than every release installs nothing"
r="$(server auto 0)"; sed -i 's/"1.1.74"/"1.1.99"/' "$r/oxide/plugins/Hotwire.cs"; sed -i 's/^HOTWIRE_LAUNCHER_VERSION=.*/HOTWIRE_LAUNCHER_VERSION="1.1.99-linux"/' "$r/hotwire-launcher.sh"
check "returns 0" "$(step "$r")" 0; check "plugin unchanged" "$(pv "$r")" 1.1.99; check "launcher unchanged" "$(lv "$r")" 1.1.99-linux

echo "a plugin-only update installs the plugin and keeps the launcher running"
r="$(server auto 0)"; sed -i 's/^HOTWIRE_LAUNCHER_VERSION=.*/HOTWIRE_LAUNCHER_VERSION="1.1.99-linux"/' "$r/hotwire-launcher.sh"
check "returns 0" "$(step "$r")" 0; check "plugin" "$(pv "$r")" 1.1.76; check "launcher unchanged" "$(lv "$r")" 1.1.99-linux
check "on probation for the plugin" "$(grep -c '^plugin 1.1.74 1.1.76$' "$r/hotwire/self-update/applied")" 1

echo "a release signed with another key is refused"
release release-forged 1.1.90 1.1.40-linux 9 "$other"
r="$(server auto 0)"; check "returns 0" "$(step "$r")" 0; check "plugin unchanged" "$(pv "$r")" 1.1.74
check "says why" "$(grep -c 'not signed by a key this launcher trusts' "$r/step.log")" 1
# Take the forged one out of the feed.
feed_items=("${feed_items[@]:1}"); { printf '['; IFS=,; printf '%s' "${feed_items[*]}"; unset IFS; printf ']\n'; } > "$work/feed.json"

echo "a file that is not the one the manifest names is refused"
release release-swap 1.1.91 1.1.41-linux 9
printf 'tampered\n' >> "$work/dl/release-swap/Hotwire.cs"
r="$(server auto 0)"; check "returns 0" "$(step "$r")" 0; check "plugin unchanged" "$(pv "$r")" 1.1.74
check "says why" "$(grep -c 'is not the file the signed manifest names' "$r/step.log")" 1
feed_items=("${feed_items[@]:1}"); { printf '['; IFS=,; printf '%s' "${feed_items[*]}"; unset IFS; printf ']\n'; } > "$work/feed.json"

echo "without the test key trusted, nothing installs"
r="$(server auto 0)"; sed -i 's/^hotwire.self_update_test_key 1$/hotwire.self_update_test_key 0/' "$r/hotwire.cfg"
check "returns 0" "$(step "$r")" 0; check "plugin unchanged" "$(pv "$r")" 1.1.74

echo "a new launcher that refuses this server's settings is not installed, and updates stop"
release release-badcheck 1.1.92 1.1.42-linux 9
sed -i '1a exit 1' "$work/dl/release-badcheck/hotwire-launcher.sh"
sed -i "s/\"hotwire-launcher.sh\": \"[0-9a-f]*\"/\"hotwire-launcher.sh\": \"$(sha256sum < "$work/dl/release-badcheck/hotwire-launcher.sh" | cut -c1-64)\"/" "$work/dl/release-badcheck/manifest.json"
bash tools/sign-release.sh file "$work/dl/release-badcheck/manifest.json" test-2026-10-12 "$work/key.pem" >/dev/null
r="$(server auto 0)"; check "returns 0" "$(step "$r")" 0; check "launcher unchanged" "$(lv "$r")" 1.1.24-linux
check "blocked" "$(st "$r" blocked)" 1; check "reason" "$(st "$r" reason)" check_failed
feed_items=("${feed_items[@]:1}"); { printf '['; IFS=,; printf '%s' "${feed_items[*]}"; unset IFS; printf ']\n'; } > "$work/feed.json"
echo "  ...and a blocked server takes no automatic update, though a good release is offered"
rm -f "$r/hotwire/self-update/feed.json"   # the server's cached list still had the bad release first
check "returns 0" "$(step "$r")" 0; check "still unchanged" "$(lv "$r")" 1.1.24-linux
echo "  ...until AFKPanel's Update Hotwire, which clears the pause and installs"
touch "$r/HOTWIRE_UPDATE.request"; check "returns 75" "$(step "$r")" 75
check "request taken" "$([ -e "$r/HOTWIRE_UPDATE.request" ] && echo left || echo taken)" taken
check "installed" "$(pv "$r")" 1.1.76; check "unblocked" "$(st "$r" blocked)" 0

echo "AFKPanel's requests"
r="$(server off)"
printf 'auto 0\n' > "$r/SELF_UPDATE.request"; step "$r" >/dev/null
check "auto 0 written" "$(grep -c '^hotwire.self_update[[:space:]]\+auto$' "$r/hotwire.cfg")$(grep -c '^hotwire.self_update_days[[:space:]]\+0$' "$r/hotwire.cfg")" 11
check "and it installed" "$(pv "$r")" 1.1.76
printf 'off\n' > "$r/SELF_UPDATE.request"; step "$r" >/dev/null; check "off written" "$(grep -c '^hotwire.self_update[[:space:]]\+off$' "$r/hotwire.cfg")" 1
printf 'auto 3; reboot\n' > "$r/SELF_UPDATE.request"; step "$r" >/dev/null; check "nonsense refused" "$(cut -c1-6 "$r/SELF_UPDATE.result")" reject
ln -s /etc/hostname "$r/SELF_UPDATE.request"; step "$r" >/dev/null; check "a link is not read" "$(cut -c1-6 "$r/SELF_UPDATE.result")" reject

echo "probation: the new plugin says it loaded"
r="$(server auto 3)"; step "$r" >/dev/null
( set +u; set --; sed '/^# Main\.$/,$d' "$r/hotwire-launcher.sh" > "$r/.lib.sh"; HOTWIRE_ROOT_OVERRIDE="$r" source "$r/.lib.sh" >/dev/null 2>&1; REPORT_ENABLED=0; SU_PROBATION_SECONDS=30
  since=$(( $(date +%s) - 1 )); printf '{"version": "1.1.75"}' > "$r/oxide/data/Hotwire/loaded.json"
  su_watch "$since" >/dev/null 2>&1 )
check "probation over" "$([ -f "$r/hotwire/self-update/applied" ] && echo still || echo over)" over
check "state" "$(st "$r" last_result)" loaded

echo "probation: the new plugin never loads, so the previous one goes back and updates stop"
r="$(server auto 3)"; step "$r" >/dev/null
( set +u; set --; sed '/^# Main\.$/,$d' "$r/hotwire-launcher.sh" > "$r/.lib.sh"; HOTWIRE_ROOT_OVERRIDE="$r" source "$r/.lib.sh" >/dev/null 2>&1; REPORT_ENABLED=0; SU_PROBATION_SECONDS=1
  su_watch "$(date +%s)" >/dev/null 2>&1 )
check "plugin back" "$(pv "$r")" 1.1.74; check "launcher back" "$(lv "$r")" 1.1.24-linux
check "blocked" "$(st "$r" reason)" plugin_not_loaded

echo "a crash on probation puts both back"
r="$(server auto 3)"; step "$r" >/dev/null
( set +u; set --; sed '/^# Main\.$/,$d' "$r/hotwire-launcher.sh" > "$r/.lib.sh"; HOTWIRE_ROOT_OVERRIDE="$r" source "$r/.lib.sh" >/dev/null 2>&1; REPORT_ENABLED=0
  su_after_failed_probation crashed >/dev/null 2>&1 )
check "plugin back" "$(pv "$r")" 1.1.74; check "launcher back" "$(lv "$r")" 1.1.24-linux; check "reason" "$(st "$r" reason)" crashed

echo "hotwire.sh: a new launcher that fails to start puts the previous one back, and the previous one finishes the job"
r="$(server auto 3)"; step "$r" >/dev/null
cp "$r/hotwire/previous/hotwire-launcher.sh" "$work/good.sh"
# The new launcher dies at once; the previous one, run again, does only its update step and stops.
printf '#!/usr/bin/env bash\nexit 1\n' > "$r/hotwire-launcher.sh"
{ sed '/^# Main\.$/,$d' "$work/good.sh"; printf '# Main.\nCHECK_ONLY=""; REPORT_ENABLED=0; START_ID=""\nload_config >/dev/null 2>&1\nself_update_step\nexit 0\n'; } > "$r/hotwire/previous/hotwire-launcher.sh"
( cd "$r" && bash ./hotwire.sh > "$r/starter.log" 2>&1 ); rc=$?
check "starter exits 0" "$rc" 0
check "said so" "$(grep -c 'The previous launcher is back' "$r/starter.log")" 1
check "plugin back too" "$(pv "$r")" 1.1.74
check "blocked" "$(st "$r" reason)" launcher_failed
check "rolled-back note handled" "$([ -e "$r/hotwire/self-update/rolled-back" ] && echo left || echo handled)" handled

echo "hotwire.sh: a second launcher refused (exit 3) is never rolled back"
r="$(server auto 3)"; step "$r" >/dev/null
printf '#!/usr/bin/env bash\nexit 3\n' > "$r/hotwire-launcher.sh"
( cd "$r" && bash ./hotwire.sh > /dev/null 2>&1 ); rc=$?
check "exits 3" "$rc" 3; check "not rolled back" "$(head -2 "$r/hotwire-launcher.sh" | tail -1)" "exit 3"

echo "hotwire.sh: exit 75 runs the launcher again"
r="$(server off)"; printf '#!/usr/bin/env bash\nif [ -f once ]; then exit 0; fi; touch once; exit 75\n' > "$r/hotwire-launcher.sh"
( cd "$r" && bash ./hotwire.sh > /dev/null 2>&1 ); check "ran twice" "$([ -f "$r/once" ] && echo yes)" yes

# hotwire.ps1, when pwsh is here: the same feed and files over a local web server, as Invoke-WebRequest reads no file://.
ps="$(command -v pwsh || true)"
if [ -n "$ps" ]; then
    # The Windows run sees only the releases that are still good.
    { printf '['; IFS=,; printf '%s' "${feed_items[*]}"; unset IFS; printf ']\n'; } > "$work/feed.json"
    port=$(( 20000 + RANDOM % 20000 ))
    ( cd "$work" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 ) & server_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do curl -fsS "http://127.0.0.1:$port/feed.json" >/dev/null 2>&1 && break; sleep 0.3; done
    mkdir -p "$work/bin"; printf '#!/bin/sh\nexit "${HOTWIRE_TEST_CHECK_RC:-0}"\n' > "$work/bin/powershell.exe"; chmod +x "$work/bin/powershell.exe"
    while IFS='|' read -r name have want; do check "$name" "$have" "$want"; done < <(
        PATH="$work/bin:$PATH" HOTWIRE_TEST_WORK="$work" HOTWIRE_TEST_URL="http://127.0.0.1:$port" HOTWIRE_TEST_PUB="$pub" \
            "$ps" -NoProfile -NonInteractive -File tests/self-update/ps1.ps1 2>&1 | grep '|')
    kill "$server_pid" 2>/dev/null
else
    echo "  skip  hotwire.ps1: no pwsh here"
fi

[ "$fail" = 0 ] && echo "All checks passed." || echo "Some checks FAILED."
exit "$fail"
