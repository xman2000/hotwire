#!/usr/bin/env bash
#
# The launchers' hooks: a hook past hotwire.hook_timeout_minutes is stopped with everything it started and the start
# carries on; each hook's time, exit code and timeout go into the session report's "launcher_hooks"; a session report
# is written as the server starts. Runs hotwire.sh's own functions, and hotwire.ps1's when pwsh is on the PATH.
#
#   bash tests/launcher-hooks/run.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: got $2, want $3"; fail=1; fi; }
json() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]), end="")' "$1" "$2"; }

work="$(mktemp -d)"; lib="$work/lib.sh"
trap 'c="$(cat "$work/child.pid" 2>/dev/null)"; [ -n "$c" ] && kill -KILL "$c" 2>/dev/null; rm -rf "$work"' EXIT
sed '/^# Main\.$/,$d' launcher/hotwire.sh > "$lib"

# A hook that runs too long, and starts a child of its own that would outlive it.
cat > "$work/slow.sh" <<'H'
sleep 300 &
echo $! > "$(dirname "$0")/child.pid"
wait
H
cat > "$work/quick.sh" <<'H'
exit 3
H

out="$( ( source "$lib" >/dev/null 2>&1; ROOT="$work"; HOOK_LIMIT_SECONDS=2
    run_hook "$work/slow.sh" "the before-start hook" before >/dev/null 2>&1
    run_hook "$work/quick.sh" "the after-update hook" after >/dev/null 2>&1
    launcher_hooks_json ) )"
payload="{\"x\":0${out}}"
check "hotwire.sh stops a hook at the limit" "$(json "$payload" 'd["launcher_hooks"]["before"]["timed_out"]')" "True"
check "hotwire.sh sends no exit code for a stopped hook" "$(json "$payload" 'd["launcher_hooks"]["before"]["exit_code"]')" "None"
check "hotwire.sh times a stopped hook near the limit" "$(json "$payload" '2 <= d["launcher_hooks"]["before"]["seconds"] < 14')" "True"
check "hotwire.sh records a finished hook's exit code" "$(json "$payload" 'd["launcher_hooks"]["after"]["exit_code"]')" "3"
check "hotwire.sh records a finished hook as not timed out" "$(json "$payload" 'd["launcher_hooks"]["after"]["timed_out"]')" "False"
child="$(cat "$work/child.pid" 2>/dev/null)"
if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then check "hotwire.sh stops what a hook started" "running" "stopped"
else check "hotwire.sh stops what a hook started" "stopped" "stopped"; fi

none="$( ( source "$lib" >/dev/null 2>&1; HOOK_RUN_BEFORE=""; HOOK_RUN_AFTER=""; launcher_hooks_json ) )"
check "hotwire.sh leaves launcher_hooks out when no hook ran" "$none" ""

# The start-time session report: started_at, update and launcher_hooks, through the spool.
start="$( ( source "$lib" >/dev/null 2>&1; REPORT_ENABLED=1; STARTED_AT="2026-10-08T12:00:00Z"
    UPDATE_ATTEMPTED=1; STEAM_OK=1; FRAMEWORK_OK=1; UPDATE_FLAG_KEPT=0; UPDATE_STAMP="$work/none"
    HOOK_RUN_BEFORE='{"seconds":1.5,"exit_code":0,"timed_out":false}'; HOOK_RUN_AFTER=""
    hw_send() { printf '%s|%s' "$1" "$2"; }
    report_session_start ) )"
check "hotwire.sh writes a session report at the start" "${start%%|*}" "session"
body="${start#*|}"
check "hotwire.sh's start report carries started_at" "$(json "$body" 'd["started_at"]')" "2026-10-08T12:00:00Z"
check "hotwire.sh's start report carries the update" "$(json "$body" 'd["update"]["steam_ok"]')" "True"
check "hotwire.sh's start report carries the hooks" "$(json "$body" 'd["launcher_hooks"]["before"]["seconds"]')" "1.5"

# hotwire.ps1: the same functions, read out of the file by the PowerShell parser.
ps="$(command -v pwsh || true)"
if [ -n "$ps" ]; then
    got="$(HOTWIRE_TEST_WORK="$work" "$ps" -NoProfile -NonInteractive -File tests/launcher-hooks/ps1.ps1)"
    while IFS='|' read -r name have want; do [ -n "$name" ] && check "$name" "$have" "$want"; done <<< "$got"
else
    echo "  skip  hotwire.ps1: no pwsh on the PATH"
fi

[ "$fail" = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
