#!/usr/bin/env bash
#
# What a start's update did, as the session report says it: hotwire.update_mode as written and as followed, why a start
# did not update or what failed, whether a flag waits, and the launcher's own lines. Runs hotwire.sh's own start
# preparation (per_launch_prep) against a SteamCMD stand-in, with the parts that reach outside the server folder (the
# backup, hooks, wipes, settings files, reporting) switched off.
#
#   bash tests/launcher-update/run.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: got $2, want $3"; fail=1; fi; }
json() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]), end="")' "$1" "$2"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sed '/^# Main\.$/,$d' launcher/hotwire.sh > "$work/lib.sh"

# SteamCMD's stand-in: Steam's public build from STEAM_PUBLIC, and an update that exits with STEAM_RC and, when it
# succeeds, installs that build.
cat > "$work/steamcmd" <<'S'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q app_info_print; then
    printf '"258550"\n{\n"depots"\n{\n"branches"\n{\n"public"\n{\n"buildid"\t\t"%s"\n}\n}\n}\n}\n' "$STEAM_PUBLIC"; exit 0
fi
[ "${STEAM_RC:-0}" = "0" ] && printf '"AppState"\n{\n"buildid"\t\t"%s"\n"StateFlags"\t\t"4"\n}\n' "$STEAM_PUBLIC" > "$HW_ROOT/steamapps/appmanifest_258550.acf"
exit "${STEAM_RC:-0}"
S
chmod +x "$work/steamcmd"

# One start's preparation in a fresh folder: <mode> <installed build> <public build> <steam rc> <flag yes|no> [steamcmd path]
start() {
    local root="$work/server-$RANDOM$RANDOM"
    mkdir -p "$root/steamapps" "$root/logs"
    cp "$work/lib.sh" "$root/lib.sh"
    printf '"AppState"\n{\n"buildid"\t\t"%s"\n"StateFlags"\t\t"4"\n}\n' "$2" > "$root/steamapps/appmanifest_258550.acf"
    [ "$5" = yes ] && touch "$root/UPDATE.flag"
    # Updated today, so the days-without-an-update backstop stays out of it.
    printf 'Last update: today\n' > "$root/logs/last_update.txt"
    local mode="$1" public="$3" rc="$4" steamcmd="${6:-$work/steamcmd}"
    # The launcher reads its own arguments as it loads, so it is loaded with none.
    ( set +u; set --; source "$root/lib.sh" >/dev/null 2>&1
      export STEAM_PUBLIC="$public" STEAM_RC="$rc" HW_ROOT="$root"
      set_defaults; UPDATE_MODE="$mode"; STEAMCMD="$steamcmd"; MAX_STEAM_TRIES=1; STEAM_RETRY_SECONDS=0
      INSTALL_FRAMEWORK=0; BUILD_CHECK_HOURS=6; STEAM_LOCK="$root/steamcmd.lock"; CRASH_STREAK=0; CHECK_ONLY=""
      config_reload() { :; }; load_secrets() { :; }; init_reporting() { :; }; check_ionice() { :; }; check_stop_unit() { :; }
      backup_before_launch() { :; }; run_hook() { :; }; apply_wipe() { :; }; apply_convar_requests() { :; }
      build_args() { :; }; check_options() { :; }
      per_launch_prep >/dev/null 2>&1
      printf '{"x":0%s}' "$(update_json)" )
}

echo "hotwire.sh: an update asked for while updates are off"
r="$(start off 25670169 25823813 0 yes)"
check "not attempted" "$(json "$r" 'd["update"]["attempted"]')" "False"
check "says why" "$(json "$r" 'd["update"].get("reason")')" "mode_off"
check "the setting as written" "$(json "$r" 'd["update"]["mode"]')" "off"
check "the mode it followed" "$(json "$r" 'd["update"]["effective_mode"]')" "off"
check "the flag waits, and is reported" "$(json "$r" 'd["update"]["flag_kept"]')" "True"
check "the lines say the build is behind" "$(json "$r" 'any("A NEWER RUST BUILD IS AVAILABLE: installed 25670169, public 25823813." in l for l in d["update"]["log"])')" "True"
check "the lines say updates are off" "$(json "$r" 'any("hotwire.update_mode is off; leaving UPDATE.flag in place" in l for l in d["update"]["log"])')" "True"
check "the lines carry no colour codes" "$(json "$r" 'any(chr(27) in l for l in d["update"]["log"])')" "False"
check "each line starts with its time" "$(json "$r" 'all(__import__("re").match(r"^\[\d\d:\d\d:\d\d\] ", l) for l in d["update"]["log"])')" "True"
echo "$r" > "$work/mode-off.json"

echo "hotwire.sh: nothing asked for and Rust current"
r="$(start hotwire 25823813 25823813 0 no)"
check "not attempted" "$(json "$r" 'd["update"]["attempted"]')" "False"
check "nothing was due" "$(json "$r" 'd["update"].get("reason")')" "not_needed"
check "no flag waits" "$(json "$r" 'd["update"]["flag_kept"]')" "False"

echo "hotwire.sh: an update whose SteamCMD fails"
r="$(start hotwire 25670169 25823813 8 yes)"
check "attempted" "$(json "$r" 'd["update"]["attempted"]')" "True"
check "Steam failed" "$(json "$r" 'd["update"]["steam_ok"]')" "False"
check "says what failed" "$(json "$r" 'd["update"].get("reason")')" "steamcmd_failed"
check "the flag is kept for the next start" "$(json "$r" 'd["update"]["flag_kept"]')" "True"
check "the lines name the exit code" "$(json "$r" 'any("steamcmd exited 8." in l for l in d["update"]["log"])')" "True"
echo "$r" > "$work/steam-failed.json"

echo "hotwire.sh: an update that installs"
r="$(start always 25670169 25823813 0 yes)"
check "attempted" "$(json "$r" 'd["update"]["attempted"]')" "True"
check "Steam and Oxide done" "$(json "$r" '(d["update"]["steam_ok"], d["update"]["framework_ok"])')" "(True, True)"
check "no reason after a full success" "$(json "$r" '"reason" in d["update"]')" "False"
check "the flag is gone" "$(json "$r" 'd["update"]["flag_kept"]')" "False"

echo "hotwire.sh: SteamCMD missing"
r="$(start always 25670169 25823813 0 no "$work/no-such-steamcmd")"
check "says SteamCMD is missing" "$(json "$r" 'd["update"].get("reason")')" "steamcmd_missing"

echo "hotwire.sh: a second start does not carry the first one's answer"
root="$work/two"; mkdir -p "$root/steamapps" "$root/logs"; cp "$work/lib.sh" "$root/lib.sh"
printf '"AppState"\n{\n"buildid"\t\t"25823813"\n}\n' > "$root/steamapps/appmanifest_258550.acf"
r="$( set +u; set --; source "$root/lib.sh" >/dev/null 2>&1
      export STEAM_PUBLIC=25823813 STEAM_RC=0 HW_ROOT="$root"
      set_defaults; STEAMCMD="$work/steamcmd"; INSTALL_FRAMEWORK=0; BUILD_CHECK_HOURS=6; STEAM_LOCK="$root/steamcmd.lock"; CRASH_STREAK=0; CHECK_ONLY=""
      config_reload() { :; }; load_secrets() { :; }; init_reporting() { :; }; check_ionice() { :; }; check_stop_unit() { :; }
      backup_before_launch() { :; }; run_hook() { :; }; apply_wipe() { :; }; apply_convar_requests() { :; }
      build_args() { :; }; check_options() { :; }
      UPDATE_MODE=off; per_launch_prep >/dev/null 2>&1
      UPDATE_MODE=always; per_launch_prep >/dev/null 2>&1
      printf '{"x":0%s}' "$(update_json)" )"
check "the reason is this start's" "$(json "$r" '"reason" in d["update"]')" "False"
check "the lines are this start's" "$(json "$r" 'any("is off" in l for l in d["update"]["log"])')" "False"

# hotwire.ps1: the same reporting, read out of the file by the PowerShell parser.
ps="$(command -v pwsh || true)"
if [ -n "$ps" ]; then
    printf '#!/usr/bin/env bash\nexit 8\n' > "$work/steamcmd"; chmod +x "$work/steamcmd"
    got="$(HOTWIRE_TEST_WORK="$work" "$ps" -NoProfile -NonInteractive -File tests/launcher-update/ps1.ps1)"
    while IFS='|' read -r name have want; do [ -n "$name" ] && check "$name" "$have" "$want"; done <<< "$got"
else
    echo "  skip  hotwire.ps1: no pwsh on the PATH"
fi

# The payloads, for the panel's tests: what the launcher built, not a fixture written to agree with the panel.
if [ -n "${HOTWIRE_KEEP_PAYLOADS:-}" ]; then cp "$work/mode-off.json" "$work/steam-failed.json" "$HOTWIRE_KEEP_PAYLOADS/"; fi

exit $fail
