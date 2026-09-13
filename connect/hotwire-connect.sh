#!/usr/bin/env bash
#
#  hotwire-connect -- connect a Rust server to Hotwire Panel, or check why it will not.
#
#  https://github.com/xman2000/hotwire            MIT (c) 2026 xman2000
#
#  Connecting is optional and reversible. Nothing here is required to run a Rust
#  server, and `detach` leaves the machine exactly as it was found.
#
#  THIS SCRIPT IS A GUEST ON SOMEONE ELSE'S MACHINE.
#
#  It never overwrites a file that already exists without being told to, never
#  touches anything outside the server directory, and says what it is about to
#  do before it does it. Where it cannot be certain, it stops and explains what
#  it looked for rather than guessing. Every error names three things: what was
#  attempted, what was found instead, and what you can do about it.
#
#  Requires: bash 4+, curl, openssl, and one of jq or python3 (to read JSON).
#
#  Usage:
#     hotwire-connect.sh doctor [--root DIR] [--panel URL]
#     hotwire-connect.sh connect --code HW-XXXX-XXXX --name "My server" [--root DIR] [--panel URL]
#     hotwire-connect.sh status  [--root DIR]
#     hotwire-connect.sh detach  [--root DIR]
#
set -uo pipefail

VERSION="0.1.0"
DEFAULT_PANEL="https://hotpanel.on-forge.com"

# ---------------------------------------------------------------- output ----
# Colour only when a human is looking; a log file or a pipe gets plain text.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
    C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""
fi

say()   { printf '%s\n' "$*"; }
note()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
ok()    { printf '  %s[ ok ]%s %s\n'   "$C_GRN" "$C_OFF" "$*"; }
warn()  { printf '  %s[warn]%s %s\n'   "$C_YEL" "$C_OFF" "$*"; }
bad()   { printf '  %s[fail]%s %s\n'   "$C_RED" "$C_OFF" "$*"; }
head_() { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_OFF"; }

# die <what we tried> <what we found> <what you can do>
# Three parts, always. "Failed to install" helps nobody at three in the morning.
die() {
    printf '\n%sCannot continue.%s\n\n' "$C_RED$C_BLD" "$C_OFF" >&2
    printf '  Tried : %s\n' "$1" >&2
    printf '  Found : %s\n' "$2" >&2
    printf '  Fix   : %s\n\n' "$3" >&2
    exit 1
}

# ------------------------------------------------------------ json input ----
# jq if it is here, python3 if it is not. Both are common; requiring a specific
# one would fail a minimal container for no reason. Path is dotted: data.server.id
JSON_TOOL=""
json_tool() {
    [ -n "$JSON_TOOL" ] && return 0
    if command -v jq >/dev/null 2>&1;      then JSON_TOOL="jq";      return 0; fi
    if command -v python3 >/dev/null 2>&1; then JSON_TOOL="python3"; return 0; fi
    die "reading the panel's JSON response" \
        "neither jq nor python3 is installed" \
        "install either one, e.g. 'sudo apt install jq'"
}

json_get() {  # json_get <json> <dotted.path>   -> value, or empty
    json_tool
    if [ "$JSON_TOOL" = "jq" ]; then
        printf '%s' "$1" | jq -r "try .$2 // empty" 2>/dev/null
    else
        printf '%s' "$1" | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for part in sys.argv[1].split("."):
    if isinstance(d, list):
        try: d = d[int(part)]
        except Exception: sys.exit(0)
    elif isinstance(d, dict) and part in d: d = d[part]
    else: sys.exit(0)
if d is not None and not isinstance(d, (dict, list)):
    print(d if not isinstance(d, bool) else str(d).lower())
' "$2" 2>/dev/null
    fi
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ------------------------------------------------------------- arguments ----
CMD="${1:-help}"; shift || true
ROOT=""; PANEL=""; CODE=""; NAME=""; ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --root)  ROOT="${2:-}";  shift 2 ;;
        --panel) PANEL="${2:-}"; shift 2 ;;
        --code)  CODE="${2:-}";  shift 2 ;;
        --name)  NAME="${2:-}";  shift 2 ;;
        --yes|-y) ASSUME_YES=1;  shift ;;
        -h|--help) CMD="help";   shift ;;
        *) die "reading the command line" "unrecognised option '$1'" \
               "run '$0 --help' for the options this version accepts" ;;
    esac
done

# ------------------------------------------------------------ discovery ----
# A Rust server root holds RustDedicated (Linux) or RustDedicated.exe. We look,
# we do not assume: a wrong guess here writes keys into the wrong directory.
find_root() {
    if [ -n "$ROOT" ]; then
        [ -d "$ROOT" ] || die "using the directory you gave with --root" \
            "'$ROOT' is not a directory" "check the path and try again"
        printf '%s' "$(cd "$ROOT" && pwd)"
        return 0
    fi
    local d; d="$(pwd)"
    for _ in 1 2 3 4 5; do
        if [ -f "$d/RustDedicated" ] || [ -f "$d/RustDedicated.exe" ]; then
            printf '%s' "$d"; return 0
        fi
        [ "$d" = "/" ] && break
        d="$(dirname "$d")"
    done
    die "finding your Rust server directory" \
        "no RustDedicated binary in $(pwd) or its parents" \
        "run this from the server directory, or pass --root /path/to/server"
}

state_dir()  { printf '%s/hotwire' "$1"; }
state_file() { printf '%s/hotwire/connect.json' "$1"; }
keys_file()  { printf '%s/hotwire/keys.json' "$1"; }
plugin_file(){ printf '%s/oxide/data/Hotwire/panel.json' "$1"; }

read_state() { [ -f "$(state_file "$1")" ] && cat "$(state_file "$1")" || printf '{}'; }

panel_url() {  # explicit flag > what we recorded at enrollment > the default
    local root="$1" recorded
    [ -n "$PANEL" ] && { printf '%s' "${PANEL%/}"; return; }
    recorded="$(json_get "$(read_state "$root")" panel_url)"
    printf '%s' "${recorded:-$DEFAULT_PANEL}"
}

# Reads one line from the terminal, whatever stdin is doing. Silent when there is no terminal at
# all (a cron, a pipe, a CI runner): the caller then sees an empty answer and says something useful,
# rather than bash printing "/dev/tty: No such device or address" at someone.
read_tty() {
    { read -r __tty_line </dev/tty && printf '%s' "$__tty_line"; } 2>/dev/null || true
}

confirm() {  # never proceed on silence; an unattended run must pass --yes
    [ "$ASSUME_YES" = "1" ] && { note "  (--yes) $1"; return 0; }
    printf '  %s [y/N] ' "$1"
    local a; a="$(read_tty)"
    case "$a" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------ signing ----
# The frozen canonical form (docs/CONTRACT.md in the panel repo):
#     <METHOD> <path>\n<timestamp>\n<nonce>\n<sha256 of the raw body>
# Verified byte-for-byte against tests/Fixtures/contract/signature/conformance.json.
sha256_hex() { printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.*= *//'; }
hmac_hex()   { printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" | sed 's/^.*= *//'; }

sign_request() {  # sign_request <secret> <METHOD> <path> <ts> <nonce> <body>
    local canon
    canon="$(printf '%s %s\n%s\n%s\n%s' "$2" "$3" "$4" "$5" "$(sha256_hex "$6")")"
    hmac_hex "$1" "$canon"
}

nonce() { openssl rand -hex 16; }

# --------------------------------------------------------------- checks ----
check_deps() {
    local missing=0
    for c in curl openssl; do
        if command -v "$c" >/dev/null 2>&1; then ok "$c is installed"
        else bad "$c is NOT installed -- try: sudo apt install $c"; missing=1; fi
    done
    if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
        ok "a JSON reader is available ($(command -v jq >/dev/null 2>&1 && echo jq || echo python3))"
    else
        bad "neither jq nor python3 -- try: sudo apt install jq"; missing=1
    fi
    return $missing
}

# The panel refuses a timestamp more than 300s from its own, and says only that
# the timestamp was outside the window. On a fresh VM with no NTP that is every
# request, forever, with no hint as to why -- so it is checked first and named.
check_clock() {
    local url="$1" remote local_ skew
    remote="$(curl -fsSI --max-time 10 "$url/up" 2>/dev/null | awk 'BEGIN{IGNORECASE=1}/^date:/{sub(/^[Dd]ate: */,""); print; exit}')"
    if [ -z "$remote" ]; then
        warn "could not read the panel's clock (it may be unreachable -- see above)"
        return 0
    fi
    remote="$(date -u -d "$remote" +%s 2>/dev/null)" || { warn "could not parse the panel's clock"; return 0; }
    local_="$(date -u +%s)"
    skew=$(( local_ > remote ? local_ - remote : remote - local_ ))

    if   [ "$skew" -le 30 ];  then ok   "clock agrees with the panel (${skew}s apart)"
    elif [ "$skew" -le 300 ]; then warn "clock is ${skew}s from the panel -- inside the 300s window, but drifting"
    else
        bad "clock is ${skew}s from the panel -- every signed request will be refused"
        note "        fix: sudo timedatectl set-ntp true   (then re-run doctor)"
        return 1
    fi
}

check_panel() {
    local url="$1" code
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "$url/up" 2>/dev/null)" || code=""
    if [ "$code" = "200" ]; then ok "panel is reachable at $url"; return 0; fi

    if curl -fsS -o /dev/null --max-time 10 --insecure "$url/up" 2>/dev/null; then
        bad "panel reachable but its TLS certificate was rejected"
        note "        fix: check the system CA bundle, or that the URL matches the certificate"
        return 1
    fi
    bad "panel did not answer at $url"
    note "        fix: check the URL, DNS, and that outbound HTTPS is allowed from this box"
    return 1
}

check_install() {
    local root="$1"
    if [ -f "$root/RustDedicated" ] || [ -f "$root/RustDedicated.exe" ]; then
        ok "Rust server found at $root"
    else
        bad "no RustDedicated binary in $root"; return 1
    fi
    if [ -d "$root/oxide" ]; then ok "Oxide is installed"
    elif [ -d "$root/carbon" ]; then ok "Carbon is installed"
    else warn "no Oxide or Carbon -- the plugin half cannot report until a framework is installed"; fi

    if [ -f "$(state_file "$root")" ]; then
        local ident; ident="$(json_get "$(read_state "$root")" identity)"
        ok "already connected as '${ident:-unknown}' -- 'status' shows the details"
    else
        note "        not connected yet (that is what 'connect' is for)"
    fi
}

# The published conformance vector, copied from the panel's
# tests/Fixtures/contract/signature/conformance.json. If this machine cannot reproduce the
# signature below, its canonicalisation is wrong -- not the panel's. Signing is the one thing that
# fails invisibly: a canonicalisation one byte out is a 401 with no useful message, on a machine
# nobody can reach inbound. So it is checked here rather than left to be discovered.
check_signing() {
    local secret body expected_hash expected_sig got_hash got_sig rc=0
    secret='hotwire-conformance-secret-do-not-use-in-production'
    body='{"contract":1,"report_id":"0193f2c1-8a4e-7c1a-9f3b-2d5e6a7b8c9d","sent_at":"2026-09-09T18:42:11Z","source":"plugin","source_version":"1.1.2","kind":"heartbeat","payload":{"players":34,"max_players":50}}'
    expected_hash='980c7522d9ba59d5fe8e677984234ef8eb9f48e8811bf4880c735ba21c4edb67'
    expected_sig='0018750ad887b85034deee8237784a18fc46f5bf3da6610ccab4794a696c5bb4'

    got_hash="$(sha256_hex "$body")"
    if [ "$got_hash" = "$expected_hash" ]; then
        ok "this machine hashes correctly"
    else
        bad "the body hash does not match the published vector"
        note "        expected $expected_hash"
        note "        got      $got_hash"
        rc=1
    fi

    got_sig="$(sign_request "$secret" POST /api/v1/report 1757533331 3f9a1c7e2b5d4086 "$body")"
    if [ "$got_sig" = "$expected_sig" ]; then
        ok "this machine signs correctly"
    else
        bad "the signature does not match the published vector"
        note "        expected $expected_sig"
        note "        got      $got_sig"
        note "        Do not connect this machine yet -- please report this."
        rc=1
    fi
    return $rc
}

# ------------------------------------------------------------- doctor ----
# Read-only. Touches nothing, changes nothing, and is safe to run at any time
# on any machine. Everything `connect` depends on is checked here first, so a
# failure is reported by a command that cannot have caused it.
cmd_doctor() {
    local root url rc=0
    root="$(find_root)"; url="$(panel_url "$root")"

    say "hotwire-connect $VERSION -- checking this machine"
    note "Nothing is written by this command."

    head_ "Tools"
    check_deps || rc=1
    check_signing || rc=1

    head_ "This server"
    check_install "$root" || rc=1

    head_ "The panel"
    check_panel "$url" || rc=1
    check_clock "$url" || rc=1

    head_ ""
    if [ "$rc" = "0" ]; then
        say "${C_GRN}Everything needed is in place.${C_OFF}"
        [ -f "$(state_file "$root")" ] \
            && note "This server is already connected. 'detach' disconnects it." \
            || note "Next: hotwire-connect.sh connect --code HW-XXXX-XXXX --name \"My server\""
    else
        say "${C_RED}Something above needs fixing first.${C_OFF}"
        note "Each [fail] line says what to do. Nothing was changed."
    fi
    return $rc
}

# ------------------------------------------------------------ connect ----
# The only command that writes. It asks before every file it touches, backs up
# anything it would replace, and prints a manifest of what it changed.
cmd_connect() {
    local root url install_id body resp http
    root="$(find_root)"; url="$(panel_url "$root")"

    # Asked for rather than demanded on the command line. A code typed as an argument ends up in
    # shell history and in the scrollback of whoever is watching; and making someone re-run a
    # command because they did not know a flag existed is a poor welcome.
    if [ -z "$CODE" ]; then
        say ""
        say "To connect this server you need a code from the panel."
        say ""
        say "  1. Open ${C_BLD}${url}${C_OFF} and sign in"
        say "  2. Go to Servers, and press \"Connect a server\""
        say "  3. Copy the code it shows you -- it looks like HW-4K2P-9XQR"
        say ""
        note "  It is good for one hour and one machine. Nothing is written until you confirm."
        say ""
        printf "  Paste the code here: "
        CODE="$(read_tty | tr -d '[:space:]')"
        say ""
    fi

    [ -n "$CODE" ] || die "connecting this server" "no code was given" \
        "run this again and paste the code from Servers -> Connect a server in the panel"

    # MEASURE TWICE. Everything connect relies on, verified before a byte is
    # written -- a half-connected server is worse than an unconnected one.
    head_ "Checking before changing anything"
    check_deps || die "connecting this server" "a required tool is missing" "see the [fail] lines above"
    check_panel "$url" || die "reaching the panel at $url" "it did not answer" "see the [fail] line above"
    check_clock "$url" || die "connecting this server" "this machine's clock is too far from the panel's" \
        "run 'sudo timedatectl set-ntp true', wait a moment, then try again"

    # The stable key for this install. Minted once and kept: re-running connect
    # from the same box adopts its existing server rather than creating a second
    # one, so a rename or a repair never splits its history.
    install_id="$(json_get "$(read_state "$root")" install_id)"
    if [ -z "$install_id" ]; then
        install_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')"
        note "  This install has no id yet; a new one was generated."
    else
        note "  This install is already known to the panel -- reconnecting will adopt it."
    fi

    [ -n "$NAME" ] || NAME="$(hostname 2>/dev/null || echo 'rust-server')"

    head_ "About to do this"
    say "  Panel        : $url"
    say "  Name         : $NAME"
    say "  Install id   : $install_id"
    say "  Write        : $(state_file "$root")"
    say "                 $(keys_file "$root")   (secrets, chmod 600)"
    say "                 $(plugin_file "$root")   (secrets, chmod 600)"
    say ""
    confirm "Connect this server to the panel?" || { say "  Nothing was changed."; exit 0; }

    body="$(printf '{"token":"%s","install_id":"%s","identity":"%s","name":"%s","components":["plugin","script"]}' \
        "$(json_escape "$CODE")" "$install_id" "$(json_escape "$NAME")" "$(json_escape "$NAME")")"

    resp="$(curl -sS --max-time 30 -w $'\n%{http_code}' \
        -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -X POST --data "$body" "$url/api/v1/enroll" 2>&1)" || \
        die "sending the enrollment request" "curl failed: $resp" "run 'doctor' to check the connection"

    http="$(printf '%s' "$resp" | tail -n1)"
    resp="$(printf '%s' "$resp" | sed '$d')"

    if [ "$http" != "201" ]; then
        local msg; msg="$(json_get "$resp" message)"
        case "$http" in
            422) die "enrolling with the code you gave" "the panel refused it: ${msg:-invalid or expired}" \
                     "codes are single-use and last 60 minutes -- mint a fresh one in the panel" ;;
            429) die "enrolling" "the panel is rate-limiting this address" "wait a minute and try again" ;;
            *)   die "enrolling" "the panel answered HTTP $http: ${msg:-no message}" \
                     "if this persists, run 'doctor' and check the panel is healthy" ;;
        esac
    fi

    local server_id adopted plugin_key plugin_secret script_key script_secret panel_said
    server_id="$(json_get "$resp" data.server.id)"
    adopted="$(json_get "$resp" data.server.adopted)"
    panel_said="$(json_get "$resp" data.panel_url)"; [ -n "$panel_said" ] && url="$panel_said"

    # Components come back in the order asked for, but never assume it: match.
    local i comp
    for i in 0 1; do
        comp="$(json_get "$resp" "data.keys.$i.component")"
        case "$comp" in
            plugin) plugin_key="$(json_get "$resp" "data.keys.$i.key_id")"
                    plugin_secret="$(json_get "$resp" "data.keys.$i.secret")" ;;
            script) script_key="$(json_get "$resp" "data.keys.$i.key_id")"
                    script_secret="$(json_get "$resp" "data.keys.$i.secret")" ;;
        esac
    done

    [ -n "$script_secret" ] || die "reading the panel's answer" \
        "it did not contain a key for the launcher component" \
        "this is a bug -- please report it with the panel's response"

    write_files "$root" "$install_id" "$server_id" "$url" \
        "$plugin_key" "$plugin_secret" "$script_key" "$script_secret"

    head_ "Connected"
    [ "$adopted" = "true" ] \
        && say "  Reconnected an install the panel already knew. Its history is intact, and its" \
        && say "  previous keys have been revoked." \
        || say "  This server is now connected as '$NAME'."
    say ""
    say "  Changed:"
    say "    $(state_file "$root")"
    say "    $(keys_file "$root")"
    [ -n "$plugin_secret" ] && say "    $(plugin_file "$root")"
    say ""
    note "  Nothing else on this machine was touched. 'detach' undoes all of it."
}

# Writes, politely: an existing file is backed up with a timestamp and the path
# is printed, never silently replaced.
write_files() {
    local root="$1" install_id="$2" server_id="$3" url="$4"
    local pkey="$5" psec="$6" skey="$7" ssec="$8"
    local dir; dir="$(state_dir "$root")"

    mkdir -p "$dir" || die "creating $dir" "permission denied" "run as the user that owns $root"

    back_up "$(state_file "$root")"
    printf '{\n  "install_id": "%s",\n  "server_id": "%s",\n  "identity": "%s",\n  "panel_url": "%s",\n  "connected_at": "%s"\n}\n' \
        "$install_id" "$server_id" "$(json_escape "$NAME")" "$url" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        > "$(state_file "$root")"

    back_up "$(keys_file "$root")"
    printf '{\n  "key_id": "%s",\n  "secret": "%s"\n}\n' "$skey" "$ssec" > "$(keys_file "$root")"
    chmod 600 "$(keys_file "$root")"

    if [ -n "$psec" ]; then
        # The plugin's key goes in oxide/data, NOT oxide/config: the plugin
        # rewrites its config constantly and the README tells people to delete
        # it to reset defaults, which would silently unenroll the server.
        mkdir -p "$(dirname "$(plugin_file "$root")")"
        back_up "$(plugin_file "$root")"
        printf '{\n  "key_id": "%s",\n  "secret": "%s",\n  "panel_url": "%s"\n}\n' "$pkey" "$psec" "$url" \
            > "$(plugin_file "$root")"
        chmod 600 "$(plugin_file "$root")"
    fi
}

back_up() {
    [ -f "$1" ] || return 0
    local b="$1.backup-$(date -u '+%Y%m%d-%H%M%S')"
    cp -p "$1" "$b" || die "backing up $1" "the copy failed" "check permissions on $(dirname "$1")"
    note "  kept the previous file as $b"
}

# -------------------------------------------------------------- status ----
cmd_status() {
    local root state; root="$(find_root)"; state="$(read_state "$root")"

    if [ ! -f "$(state_file "$root")" ]; then
        say "Not connected."
        note "Run 'doctor' to check this machine, then 'connect --code ...'."
        return 0
    fi

    say "Connected."
    say "  Name        : $(json_get "$state" identity)"
    say "  Panel       : $(json_get "$state" panel_url)"
    say "  Server id   : $(json_get "$state" server_id)"
    say "  Install id  : $(json_get "$state" install_id)"
    say "  Since       : $(json_get "$state" connected_at)"
    say ""
    note "'detach' disconnects and leaves this server running exactly as it is."
}

# -------------------------------------------------------------- detach ----
# Reversible means reversible. This removes what connect wrote and nothing else;
# the server keeps running, and the launcher and plugin carry on without a panel.
cmd_detach() {
    local root; root="$(find_root)"

    [ -f "$(state_file "$root")" ] || { say "Not connected -- nothing to detach."; return 0; }

    head_ "About to do this"
    say "  Remove : $(state_file "$root")"
    say "           $(keys_file "$root")"
    [ -f "$(plugin_file "$root")" ] && say "           $(plugin_file "$root")"
    say ""
    note "  Your server keeps running. Reporting stops. Nothing else changes."
    note "  Revoke the keys in the panel too -- this machine cannot do that for you."
    say ""
    confirm "Disconnect this server from the panel?" || { say "  Nothing was changed."; exit 0; }

    rm -f "$(state_file "$root")" "$(keys_file "$root")" "$(plugin_file "$root")"
    say ""
    say "Disconnected. This machine is as it was before it connected."
}

# ---------------------------------------------------------------- help ----
cmd_help() {
    cat <<'HELP'
hotwire-connect -- connect a Rust server to Hotwire Panel

  doctor    Check this machine: tools, signing, your server, the panel, the clock.
            Read-only, changes nothing, safe any time.
  connect   Connect to the panel. Asks for the code; no need to type it here.
  status    Show what this server is connected to.
  detach    Disconnect. Leaves the server running exactly as it is.

Options
  --root DIR    The Rust server directory (default: found from the current one)
  --panel URL   The panel to talk to (default: recorded at connect)
  --yes, -y     Do not ask for confirmation (for unattended runs)

Connecting is optional and reversible. Your server does not need a panel to run.
HELP
}

case "$CMD" in
    doctor)  cmd_doctor ;;
    connect) cmd_connect ;;
    status)  cmd_status ;;
    detach)  cmd_detach ;;
    help|--help|-h) cmd_help ;;
    *) cmd_help; exit 1 ;;
esac
