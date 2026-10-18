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
sed '/^# Main\.$/,$d' launcher/hotwire-launcher.sh > "$work/lib.sh"

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

# An update mode AFKPanel asked for: <request text> <mode in hotwire.cfg> [check] [broken|link]. Prints the update block, then the
# receipt, the hotwire.cfg line and whether the request is still there, each on its own line.
mode_request() {
    local root="$work/mode-$RANDOM$RANDOM"
    mkdir -p "$root/steamapps" "$root/logs"
    cp "$work/lib.sh" "$root/lib.sh"
    printf '"AppState"\n{\n"buildid"\t\t"25670169"\n"StateFlags"\t\t"4"\n}\n' > "$root/steamapps/appmanifest_258550.acf"
    printf 'Last update: today\n' > "$root/logs/last_update.txt"
    touch "$root/UPDATE.flag"
    printf 'server.hostname "Test"\nhotwire.update_mode         %s\n' "$2" > "$root/hotwire.cfg"
    printf '%s\n' "$1" > "$root/UPDATE_MODE.request"
    local cfg_mode="$2" check_only="${3:-}" how="${4:-}"
    if [ "$how" = link ]; then mv "$root/UPDATE_MODE.request" "$root/secret.txt"; ln -s "$root/secret.txt" "$root/UPDATE_MODE.request"; fi
    ( set +u; set --; source "$root/lib.sh" >/dev/null 2>&1
      export STEAM_PUBLIC=25823813 STEAM_RC=0 HW_ROOT="$root"
      set_defaults; CFG="$root/hotwire.cfg"; UPDATE_MODE="$cfg_mode"; STEAMCMD="$work/steamcmd"; MAX_STEAM_TRIES=1; STEAM_RETRY_SECONDS=0
      INSTALL_FRAMEWORK=0; BUILD_CHECK_HOURS=6; STEAM_LOCK="$root/steamcmd.lock"; CRASH_STREAK=0; CHECK_ONLY="$check_only"
      # The reader, as far as this setting goes: the last line that sets it.
      # "broken": hotwire.cfg cannot be used after the write, so the reader keeps the last start's settings.
      if [ "$how" = broken ]; then load_config() { return 1; }
      else load_config() { UPDATE_MODE="$(awk '$1=="hotwire.update_mode"{v=$2} END{print v}' "$CFG")"; }; fi
      config_reload() { :; }; load_secrets() { :; }; init_reporting() { :; }; check_ionice() { :; }; check_stop_unit() { :; }
      backup_before_launch() { :; }; run_hook() { :; }; apply_wipe() { :; }; apply_convar_requests() { :; }
      build_args() { :; }; check_options() { :; }
      per_launch_prep >/dev/null 2>&1
      printf '{"x":0%s}\n' "$(update_json)"
      cat "$root/UPDATE_MODE.result" 2>/dev/null || echo "no receipt"
      grep '^hotwire.update_mode' "$CFG"
      [ -e "$root/UPDATE_MODE.request" ] && echo "request kept" || echo "request removed" )
}

echo "hotwire.sh: AFKPanel sets updates to auto on a server that had them off"
out="$(mode_request auto off)"; r="$(sed -n 1p <<< "$out")"
check "the waiting update installs on this same start" "$(json "$r" 'd["update"]["attempted"]')" "True"
check "the start follows the new mode" "$(json "$r" 'd["update"]["mode"]')" "auto"
check "the lines say what changed" "$(json "$r" 'any("Update mode set to auto from AFKPanel (was off)" in l for l in d["update"]["log"])')" "True"
check "the receipt" "$(sed -n 2p <<< "$out")" "applied auto (was off)"
check "hotwire.cfg says auto" "$(sed -n 3p <<< "$out" | tr -s ' ')" "hotwire.update_mode auto"
check "the request is used up" "$(sed -n 4p <<< "$out")" "request removed"

echo "hotwire.sh: a request for off is refused"
out="$(mode_request off auto)"; r="$(sed -n 1p <<< "$out")"
check "the mode stays" "$(json "$r" 'd["update"]["mode"]')" "auto"
check "the receipt says why" "$(sed -n 2p <<< "$out")" "reject off : the panel sets auto or always only"
check "hotwire.cfg is unchanged" "$(sed -n 3p <<< "$out" | tr -s ' ')" "hotwire.update_mode auto"
check "the lines say it was refused" "$(json "$r" 'any("which is not auto or always" in l for l in d["update"]["log"])')" "True"

echo "hotwire.sh: a request that is not a mode is refused"
out="$(mode_request 'always; rm -rf /' off)"
check "the receipt" "$(sed -n 2p <<< "$out")" "reject always;rm-rf/ : the panel sets auto or always only"
check "hotwire.cfg is unchanged" "$(sed -n 3p <<< "$out" | tr -s ' ')" "hotwire.update_mode off"

echo "hotwire.sh: a request with Windows line ends is read"
out="$(mode_request $'always\r' off)"
check "the receipt" "$(sed -n 2p <<< "$out")" "applied always (was off)"

echo "hotwire.sh: hotwire.cfg cannot be used after the write"
out="$(mode_request auto off "" broken)"; r="$(sed -n 1p <<< "$out")"
check "the receipt does not claim it was applied" "$(sed -n 2p <<< "$out")" "reject auto : hotwire.cfg was written but cannot be used now, so the last start's settings stay"
check "the start keeps the last mode" "$(json "$r" 'd["update"]["mode"]')" "off"
check "the lines say so" "$(json "$r" 'any("cannot be used now" in l for l in d["update"]["log"])')" "True"

echo "hotwire.sh: a request that is a link is not followed"
out="$(mode_request auto off "" link)"; r="$(sed -n 1p <<< "$out")"
check "the receipt" "$(sed -n 2p <<< "$out")" "reject : UPDATE_MODE.request is a link, not a file"
check "hotwire.cfg is unchanged" "$(sed -n 3p <<< "$out" | tr -s ' ')" "hotwire.update_mode off"
check "the linked file's text is not echoed" "$(json "$r" 'any("auto" in l and "link" in l for l in d["update"]["log"])')" "False"

echo "hotwire.sh: check mode leaves the request for a real start"
out="$(mode_request auto off 1)"
check "no receipt" "$(sed -n 2p <<< "$out")" "no receipt"
check "hotwire.cfg is unchanged" "$(sed -n 3p <<< "$out" | tr -s ' ')" "hotwire.update_mode off"
check "the request waits" "$(sed -n 4p <<< "$out")" "request kept"

echo "hotwire.sh: the update reports each SteamCMD try while it runs"
root="$work/progress"; mkdir -p "$root/steamapps" "$root/logs"; cp "$work/lib.sh" "$root/lib.sh"
printf '"AppState"\n{\n"buildid"\t\t"25670169"\n}\n' > "$root/steamapps/appmanifest_258550.acf"
sent="$( set +u; set --; source "$root/lib.sh" >/dev/null 2>&1
      export STEAM_PUBLIC=25823813 STEAM_RC=8 HW_ROOT="$root"
      set_defaults; STEAMCMD="$work/steamcmd"; UPDATE_MODE=always; MAX_STEAM_TRIES=2; STEAM_RETRY_SECONDS=0
      INSTALL_FRAMEWORK=0; BUILD_CHECK_HOURS=6; STEAM_LOCK="$root/steamcmd.lock"; CRASH_STREAK=0; CHECK_ONLY=""
      config_reload() { :; }; load_secrets() { :; }; init_reporting() { REPORT_ENABLED=1; }; check_ionice() { :; }; check_stop_unit() { :; }
      backup_before_launch() { :; }; run_hook() { :; }; apply_wipe() { :; }; apply_convar_requests() { :; }
      build_args() { :; }; check_options() { :; }
      hw_send() { printf '%s %s\n' "$1" "$2" >> "$root/sent"; }; spool_kick() { :; }
      per_launch_prep >/dev/null 2>&1
      cat "$root/sent" )"
check "one report per try" "$(grep -c '^update ' <<< "$sent")" "2"
r="$(grep '^update ' <<< "$sent" | sed -n 2p | cut -d' ' -f2-)"
check "names the step and the try" "$(json "$r" '(d["step"], d["attempt"], d["of"])')" "('steamcmd', 2, 2)"
check "carries the mode and the builds" "$(json "$r" '(d["mode"], d["effective_mode"], d["rust_build_id"], d["rust_build_public"])')" "('always', 'always', '25670169', '25823813')"
echo "$r" > "$work/update-progress.json"

echo "hotwire.sh: a report written while the spool is being sent goes with that sender"
root="$work/spool"; mkdir -p "$root/hotwire/launcher-spool"; cp "$work/lib.sh" "$root/lib.sh"
got="$( set +u; set --; source "$root/lib.sh" >/dev/null 2>&1
      set_defaults; ROOT="$root"; SPOOL_DIR="$root/hotwire/launcher-spool"; REPORT_ENABLED=1; SPOOL_ORIGIN=""
      log() { :; }
      # The panel accepts everything; the first send is the last SteamCMD try's, and the start report is written meanwhile.
      _hw_post() { echo "$1" >> "$root/posted"; [ "$1" = update ] && _spool_write session '{"started_at":"x"}' rid-2 now; printf 200; }
      _spool_write update '{"step":"steamcmd"}' rid-1 now
      spool_drain_all
      cat "$root/posted"; ls -1 "$SPOOL_DIR" | wc -l )"
check "both reports sent" "$(head -2 <<< "$got" | tr '\n' ' ')" "update session "
check "nothing left in the spool" "$(tail -1 <<< "$got" | tr -d ' ')" "0"

echo "hotwire.sh: each step of a start is reported, with SteamCMD's progress"
# SteamCMD's stand-in for this test: Steam's build list, then a first try refused and a second that prints the progress
# lines SteamCMD printed on a test server on 2026-10-12 and finishes.
cat > "$work/steamcmd-steps" <<'S'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q app_info_print; then
    printf '"258550"\n{\n"depots"\n{\n"branches"\n{\n"public"\n{\n"buildid"\t\t"%s"\n}\n}\n}\n}\n' "$STEAM_PUBLIC"; exit 0
fi
n=$(( $(cat "$HW_ROOT/tries" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$HW_ROOT/tries"
[ "$n" = 1 ] && exit 8
printf ' Update state (0x61) downloading, progress: 12.50 (763970123 / 6111760987)\r\n'
printf ' Update state (0x81) verifying update, progress: 30.02 (1834950507 / 6111760987)\n'
printf ' Update state (0x0) unknown, progress: 0.00 (0 / 0)\n'
printf "Success! App '258550' fully installed.\n"
printf '"AppState"\n{\n"buildid"\t\t"%s"\n"StateFlags"\t\t"4"\n}\n' "$STEAM_PUBLIC" > "$HW_ROOT/steamapps/appmanifest_258550.acf"
exit 0
S
chmod +x "$work/steamcmd-steps"
root="$work/steps"; mkdir -p "$root/steamapps" "$root/logs"; cp "$work/lib.sh" "$root/lib.sh"
printf '"AppState"\n{\n"buildid"\t\t"25670169"\n}\n' > "$root/steamapps/appmanifest_258550.acf"
out="$( set +u; set --; source "$root/lib.sh" >/dev/null 2>&1
      export STEAM_PUBLIC=25877464 HW_ROOT="$root"
      set_defaults; STEAMCMD="$work/steamcmd-steps"; UPDATE_MODE=auto; MAX_STEAM_TRIES=5; STEAM_RETRY_SECONDS=0
      INSTALL_FRAMEWORK=0; BUILD_CHECK_HOURS=6; STEAM_LOCK="$root/steamcmd.lock"; CRASH_STREAK=0; CHECK_ONLY=""
      config_reload() { :; }; load_secrets() { :; }; init_reporting() { REPORT_ENABLED=1; }; check_ionice() { :; }; check_stop_unit() { :; }
      backup_before_launch() { :; }; run_hook() { :; }; apply_wipe() { :; }; apply_convar_requests() { :; }
      build_args() { :; }; check_options() { :; }
      hw_send() { printf '%s %s\n' "$1" "$2" >> "$root/sent"; }; spool_kick() { :; }
      per_launch_prep > "$root/console" 2>&1
      STARTED_AT=2026-10-12T13:47:09Z; report_session_start
      grep -c 'progress: 30.02' "$root/console"; cat "$root/sent" )"
check "SteamCMD's own lines still reach the console" "$(head -1 <<< "$out")" "1"
steps="$(grep '^start_step ' <<< "$out" | cut -d' ' -f2-)"
check "the steps in order" "$(while read -r r; do json "$r" 'd["step"]+":"+d["state"]'; echo -n ' '; done <<< "$steps")" "check:begun check:done steamcmd:begun steamcmd:failed steamcmd:waiting steamcmd:begun steamcmd:progress steamcmd:done "
check "one start_id for every step" "$(while read -r r; do json "$r" 'd["start_id"]'; echo; done <<< "$steps" | sort -u | wc -l | tr -d ' ')" "1"
r="$(sed -n 2p <<< "$steps")"
check "the check says what it decided" "$(json "$r" '(d["update"], d["mode"], d["rust_build_id"], d["rust_build_public"])')" "(True, 'auto', '25670169', '25877464')"
r="$(sed -n 4p <<< "$steps")"
check "a failed try names its exit code" "$(json "$r" '(d["attempt"], d["of"], d["exit_code"])')" "(1, 5, 8)"
r="$(sed -n 7p <<< "$steps")"
check "progress is SteamCMD's own numbers, the first line only" "$(json "$r" '(d["phase"], d["percent"], d["bytes"], d["total"])')" "('downloading', 12.5, 763970123, 6111760987)"
r="$(grep '^session ' <<< "$out" | cut -d' ' -f2-)"
check "the start report carries the start_id" "$(json "$r" 'd["start_id"] == d.get("start_id") and len(d["start_id"]) == 20')" "True"
echo "$(sed -n 7p <<< "$steps")" > "$work/start-step-progress.json"

echo "hotwire.sh: check mode sends no steps"
root="$work/steps-check"; mkdir -p "$root/steamapps" "$root/logs"; cp "$work/lib.sh" "$root/lib.sh"
printf '"AppState"\n{\n"buildid"\t\t"25670169"\n}\n' > "$root/steamapps/appmanifest_258550.acf"
out="$( set +u; set --; source "$root/lib.sh" >/dev/null 2>&1
      export STEAM_PUBLIC=25877464 HW_ROOT="$root"
      set_defaults; STEAMCMD="$work/steamcmd-steps"; UPDATE_MODE=auto; INSTALL_FRAMEWORK=0; BUILD_CHECK_HOURS=6; CRASH_STREAK=0; CHECK_ONLY=1
      config_reload() { :; }; load_secrets() { :; }; init_reporting() { REPORT_ENABLED=1; }; check_ionice() { :; }; check_stop_unit() { :; }
      backup_before_launch() { :; }; run_hook() { :; }; apply_wipe() { :; }; apply_convar_requests() { :; }
      build_args() { :; }; check_options() { :; }
      hw_send() { printf '%s\n' "$1" >> "$root/sent"; }; spool_kick() { :; }
      per_launch_prep >/dev/null 2>&1; cat "$root/sent" 2>/dev/null )"
check "nothing sent" "$(grep -c start_step <<< "$out")" "0"

echo "hotwire.sh: SteamCMD's progress is sent at most every 15 seconds"
out="$( set +u; set --; source "$work/lib.sh" >/dev/null 2>&1
      set_defaults; REPORT_ENABLED=1; START_ID=2026-10-12T13:44:43Z; CHECK_ONLY=""
      hw_send() { printf '%s\n' "$2" >> "$work/throttle"; }; spool_kick() { :; }
      printf ' Update state (0x61) downloading, progress: %s (%s / 100)\n' 1.00 1 2.00 2 3.00 3 | steam_progress 1 5 >/dev/null
      wc -l < "$work/throttle" )"
check "three lines in a moment, one report" "$(tr -d ' ' <<< "$out")" "1"

echo "hotwire.sh: Rust's boot is read from its log as it is written"
# Lines Rust printed on this boot (Rust release 167398, Oxide 2.0, 2026-10-12), in order, with a few around them.
cat > "$work/boot-lines" <<'L'
[Bootstrap] Opening Bundles
[Bootstrap] Opening Bundles done in 0.64s
Loading Oxide Core v2.0.4143...
Loaded plugin Rust v2.0.7820 by Oxide Team and Contributors
Loaded plugin Hotwire v1.1.72 by xman2000
Asset Warmup (1/8996)
Asset Warmup (8996/8996)
Generating procedural map of size 1000 with seed 12345
[1.4s] Spawning World
Spawning 1027 entities from save
[RustNav] Navmesh 'unnamed' is now fully built in 15.61 seconds (8836 tiles).
[RustNav] Navmesh 'assets/bundled/prefabs/autospawn/monument/offshore/oilrig_2.prefab' is now fully built in 5.04 seconds (289 tiles).
Server startup complete
SteamServer Connected
Saving complete
L
log="$work/boot/server_log.txt"; mkdir -p "$work/boot"
out="$( set +u; set --; source "$work/lib.sh" >/dev/null 2>&1
      set_defaults; REPORT_ENABLED=1; START_ID=2026-10-12T13:44:43Z; CHECK_ONLY=""
      hw_send() { printf '%s\n' "$2" >> "$work/boot/sent"; }; spool_kick() { :; }
      since=$(( $(date +%s) - 1 ))
      boot_watch "$log" "$since" & pid=$!
      sleep 1
      head -5 "$work/boot-lines" > "$log"; sleep 1
      tail -n +6 "$work/boot-lines" >> "$log"
      for i in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
      kill -0 "$pid" 2>/dev/null && echo "still running" || echo "ended"
      cat "$work/boot/sent" )"
check "it ends at Steam's connection" "$(head -1 <<< "$out")" "ended"
check "each milestone once, in Rust's order" "$(tail -n +2 <<< "$out" | while read -r r; do json "$r" 'd["step"]+":"+d.get("milestone", d["state"])'; echo -n ' '; done)" "boot:bundles boot:oxide boot:hotwire boot:warmup boot:map boot:world boot:entities boot:navmesh boot:done steam:done "
check "the entities count" "$(grep '"entities"' <<< "$out" | head -1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')" "1027"
check "no tail left behind" "$(pgrep -f -- "tail -n [+]1 -F $log" | wc -l | tr -d ' ')" "0"

echo "hotwire.sh: Rust exiting during its boot stops the reader"
log3="$work/boot3/server_log.txt"; mkdir -p "$work/boot3"
out="$( set +u; set --; source "$work/lib.sh" >/dev/null 2>&1
      set_defaults; REPORT_ENABLED=1; START_ID=2026-10-12T13:44:43Z; CHECK_ONLY=""
      hw_send() { printf '%s\n' "$2" >> "$work/boot3/sent"; }; spool_kick() { :; }
      BOOT_WATCH_PID=""; LOGFILE="$log3"; boot_watch_start
      sleep 1; head -6 "$work/boot-lines" > "$log3"; sleep 2
      boot_watch_stop; sleep 0.5
      wc -l < "$work/boot3/sent" )"
check "what it read is sent" "$(tr -d ' ' <<< "$out")" "3"
check "the reader's tail is gone with it" "$(pgrep -f -- "tail -n [+]1 -F $log3" | wc -l | tr -d ' ')" "0"

echo "hotwire.sh: an older log file is not this boot's"
log2="$work/boot2/server_log.txt"; mkdir -p "$work/boot2"; cp "$work/boot-lines" "$log2"; touch -d '2 hours ago' "$log2"
out="$( set +u; set --; source "$work/lib.sh" >/dev/null 2>&1
      set_defaults; REPORT_ENABLED=1; START_ID=2026-10-12T13:44:43Z; CHECK_ONLY=""
      hw_send() { printf '%s\n' "$2" >> "$work/boot2/sent"; }; spool_kick() { :; }
      BOOT_WATCH_PID=""; LOGFILE="$log2"; boot_watch_start; sleep 2; boot_watch_stop
      cat "$work/boot2/sent" 2>/dev/null | wc -l )"
check "nothing read from it" "$(tr -d ' ' <<< "$out")" "0"
check "the watcher and its tail are gone" "$(pgrep -f -- "tail -n [+]1 -F $log2" | wc -l | tr -d ' ')" "0"

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
if [ -n "${HOTWIRE_KEEP_PAYLOADS:-}" ]; then cp "$work/mode-off.json" "$work/steam-failed.json" "$work/update-progress.json" "$work/start-step-progress.json" "$HOTWIRE_KEEP_PAYLOADS/"; fi

exit $fail
