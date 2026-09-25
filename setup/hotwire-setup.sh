#!/usr/bin/env bash
#
#  hotwire-setup -- install a Rust server on Ubuntu, connect it to Hotwire Panel, or check
#  why it will not connect. The Linux sibling of hotwire-setup.ps1.
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
#  Requires: bash 4+, curl, openssl, and one of jq or python3 (to read JSON). install also
#  needs Ubuntu, root (sudo) and python3, and installs the rest itself.
#
#  Usage:
#     sudo hotwire-setup.sh install [--root DIR] [--user NAME] [--panel URL]
#     hotwire-setup.sh doctor  [--root DIR] [--panel URL]
#     hotwire-setup.sh connect [--root DIR] [--panel URL]     # asks for the code
#     hotwire-setup.sh status  [--root DIR]
#     hotwire-setup.sh detach  [--root DIR]
#
set -uo pipefail

VERSION="0.2.1"
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
        # jq indexes arrays as keys[0]; the dotted form keys.0 is a syntax error it reports only to the
        # stderr hidden below, which made every lookup into an array come back empty.
        local filter
        filter="$(printf '%s' "$2" | sed -E 's/\.([0-9]+)(\.|$)/[\1]\2/g; s/\.([0-9]+)(\.|$)/[\1]\2/g')"
        printf '%s' "$1" | jq -r "try .$filter // empty" 2>/dev/null
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
ROOT=""; PANEL=""; CODE=""; NAME=""; ASSUME_YES=0; USER_OPT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --root)  ROOT="${2:-}";  shift 2 ;;
        --panel) PANEL="${2:-}"; shift 2 ;;
        --code)  CODE="${2:-}";  shift 2 ;;
        --name)  NAME="${2:-}";  shift 2 ;;
        --user)  USER_OPT="${2:-}"; shift 2 ;;
        --yes|-y) ASSUME_YES=1;  shift ;;
        -h|--help) CMD="help";   shift ;;
        *) die "reading the command line" "unrecognised option '$1'" \
               "run '$0 --help' for the options this version accepts" ;;
    esac
done

# ------------------------------------------------------------ discovery ----
# A Rust server root holds RustDedicated (Linux) or RustDedicated.exe. We look,
# we do not assume: a wrong guess here writes keys into the wrong directory.
# Sets FOUND_ROOT. Always called directly, never inside a command substitution: there its die would end
# only the subshell, and the command would carry on with an empty root -- writing keys under / if run
# with sudo.
FOUND_ROOT=""
find_root() {
    if [ -n "$ROOT" ]; then
        [ -d "$ROOT" ] || die "using the directory you gave with --root" \
            "'$ROOT' is not a directory" "check the path and try again"
        FOUND_ROOT="$(cd "$ROOT" && pwd)"
        [ -n "$FOUND_ROOT" ] || die "using the directory you gave with --root" "'$ROOT' could not be entered" "check its permissions"
        return 0
    fi
    local d; d="$(pwd)"
    for _ in 1 2 3 4 5; do
        if [ -f "$d/RustDedicated" ] || [ -f "$d/RustDedicated.exe" ]; then
            FOUND_ROOT="$d"; return 0
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

# The panel address must be https: over http the connection code and both of this server's signing secrets
# would cross the network in the clear, and anything on the path could answer in the panel's place. The default
# is already https, so this only ever trips an address someone typed. (The Windows installer has always checked
# this; this one did not.)
#
# It validates and prints NOTHING, and it is deliberately not called from inside panel_url. `die` runs `exit`, and
# `url="$(panel_url ...)"` is a command substitution -- a subshell -- so exiting there killed the subshell and left
# the script running with an empty url. Caught by running it on a real machine: the refusal printed and `doctor`
# carried on underneath it. So the check belongs in the caller, where exit means exit.
assert_https_panel() {
    case "$1" in
        https://*) return 0 ;;
        http://*)  die "using the panel address $1" "it is http://, which is not encrypted and cannot be trusted" \
                       "use your panel's https:// address (the default is $DEFAULT_PANEL)" ;;
        *)         die "using the panel address $1" "it is not an https:// web address" \
                       "pass --panel with your panel's https:// address (the default is $DEFAULT_PANEL)" ;;
    esac
}

# Whether an address the panel named is the same https host that was just asked. Same rule as the plugin's own
# connect (Hotwire.cs, SameHost).
same_panel_host() {
    local said="$1" asked="$2" said_host asked_host
    case "$said" in https://*) ;; *) return 1 ;; esac
    said_host="${said#https://}";   said_host="${said_host%%/*}";   said_host="${said_host%%:*}"
    asked_host="${asked#https://}"; asked_host="${asked_host#http://}"
    asked_host="${asked_host%%/*}"; asked_host="${asked_host%%:*}"
    [ -n "$said_host" ] && [ "$(lower "$said_host")" = "$(lower "$asked_host")" ]
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

panel_url() {  # explicit flag > what we recorded at enrollment > the default. Validated by the caller.
    local root="$1" recorded
    [ -n "$PANEL" ] && { printf '%s' "${PANEL%/}"; return; }
    recorded="$(json_get "$(read_state "$root")" panel_url)"
    printf '%s' "${recorded:-$DEFAULT_PANEL}"
}

# Reads one line from the terminal, whatever stdin is doing. Silent when there is no terminal at
# all (a cron, a pipe, a CI runner): the caller then sees an empty answer and says something useful,
# rather than bash printing "/dev/tty: No such device or address" at someone.
read_tty() {  # sets TTY_LINE
    # Read here, in this shell, never inside $( ): run as 'curl ... | sudo bash', a read from a command
    # substitution is stopped by the terminal (seen with Ubuntu's sudo-rs) and install hangs at its first question.
    TTY_LINE=""
    { IFS= read -r TTY_LINE </dev/tty; } 2>/dev/null || TTY_LINE=""
}

# For installing or connecting what someone downloaded this for: Enter means yes. No terminal at all
# means no, so a cron or a pipe never connects anything by default.
confirm_default_yes() {
    [ "$ASSUME_YES" = "1" ] && { note "  (--yes) $1"; return 0; }
    printf '  %s [Y/n] ' "$1"
    local a
    if ! { read -r a </dev/tty; } 2>/dev/null; then say ""; return 1; fi
    case "$a" in [nN]*) return 1 ;; *) return 0 ;; esac
}

confirm() {  # never proceed on silence; an unattended run must pass --yes
    [ "$ASSUME_YES" = "1" ] && { note "  (--yes) $1"; return 0; }
    printf '  %s [y/N] ' "$1"
    local a; read_tty; a="$TTY_LINE"
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

    # S1: this probe DOWNLOADS NOTHING and installs nothing -- '-o /dev/null' discards the body.
    # '--insecure' is used ONLY to tell "the panel is reachable but its TLS certificate was rejected"
    # apart from "the panel is unreachable", so the fix message can be precise. It never fetches code
    # and never relaxes TLS for any real request; the reachability check above uses full verification.
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
    find_root; root="$FOUND_ROOT"; url="$(panel_url "$root")"; assert_https_panel "$url"

    say "hotwire-setup $VERSION -- checking this machine"
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
            || note "Next: ./hotwire-setup.sh connect"
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
    find_root; root="$FOUND_ROOT"; url="$(panel_url "$root")"; assert_https_panel "$url"

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
        read_tty; CODE="$(printf '%s' "$TTY_LINE" | tr -d '[:space:]')"
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
    # A connection belongs to the folder it was made in. A copied server folder carries the original's,
    # and reusing it would take over the original's place in the panel and leave the original silent.
    local made_in copied=0 id_json id_folder
    made_in="$(json_get "$(read_state "$root")" folder)"
    if [ -n "$made_in" ] && [ "${made_in%/}" != "${root%/}" ]; then
        warn "this folder's panel connection was made in $made_in"
        note "        It looks like a copy of that server. Reusing the connection would take over that"
        note "        server's place in the panel, and that server would stop reporting."
        confirm "Connect this folder as a new, separate server?" || die "connecting $root" \
            "its panel connection belongs to $made_in" "connect from $made_in instead, or run connect here again and answer yes"
        copied=1
    fi
    install_id=""
    [ "$copied" = 1 ] || install_id="$(json_get "$(read_state "$root")" install_id)"
    # A connect that stopped after the panel answered left its install id behind; using it again makes
    # the panel adopt that server rather than create a second one -- unless it was made in another folder.
    if [ -z "$install_id" ] && [ "$copied" = 0 ] && [ -f "$(state_dir "$root")/install_id" ]; then
        id_json="$(cat "$(state_dir "$root")/install_id")"
        id_folder="$(json_get "$id_json" folder)"
        if [ -z "$id_folder" ] || [ "${id_folder%/}" = "${root%/}" ]; then
            install_id="$(json_get "$id_json" install_id)"
            [ -n "$install_id" ] || install_id="$(printf '%s' "$id_json" | tr -d '[:space:]')"
        fi
        case "$install_id" in *[!0-9a-fA-F-]*) install_id="" ;; esac
        [ -n "$install_id" ] && note "  An earlier connect did not finish; the same install id is used."
    fi
    if [ -z "$install_id" ]; then
        install_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')"
        note "  This install has no id yet; a new one was generated."
    else
        note "  This install is already known to the panel -- reconnecting will adopt it."
    fi

    # The machine's name and the server's folder: two servers on one machine are otherwise identical in the panel.
    [ -n "$NAME" ] || NAME="$(hostname 2>/dev/null || echo 'rust-server')-$(basename "$root")"

    head_ "About to do this"
    say "  Panel        : $url"
    say "  Name         : $NAME"
    say "  Install id   : $install_id"
    say "  Write        : $(state_file "$root")"
    say "                 $(keys_file "$root")   (secrets, chmod 600)"
    say "                 $(plugin_file "$root")   (secrets, chmod 600)"
    say ""
    confirm_default_yes "Connect this server to the panel?" || { say "  Nothing was changed."; exit 0; }

    # Kept before the request, so an interrupted connect adopts the same server on the next try.
    mkdir -p "$(state_dir "$root")" && write_atomic "$(state_dir "$root")/install_id" \
        "$(printf '{"install_id": "%s", "folder": "%s"}' "$install_id" "$(json_escape "$root")")"$'\n' \
        || die "saving the install id in $(state_dir "$root")" "the write failed" "check permissions on $root"

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
    # Taken only when it names the same https host that was just asked. The enrollment answer is the one response
    # that cannot be authenticated -- there is no key yet -- so an answer free to name any address would let
    # whoever answered this single request keep this server reporting to them forever.
    panel_said="$(json_get "$resp" data.panel_url)"; panel_said="${panel_said%/}"
    if [ -n "$panel_said" ]; then
        if same_panel_host "$panel_said" "$url"; then
            url="$panel_said"
        else
            warn "the panel answered with a different address ($panel_said); keeping $url"
        fi
    fi

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
# Writes a file whole or not at all: to a temporary name beside it, then renamed over it. A secret is
# created under umask 077, so it is never readable by anyone else, even for a moment.
write_atomic() {  # write_atomic <path> <content> [secret]
    local tmp="$1.hotwire-tmp"
    if [ "${3:-}" = "secret" ]; then
        ( umask 077; printf '%s' "$2" > "$tmp" ) || return 1
    else
        printf '%s' "$2" > "$tmp" || return 1
    fi
    mv -f "$tmp" "$1"
}

# Writes, politely: an existing file is backed up with a timestamp and the path is printed, never
# silently replaced. The keys first and connect.json last: connect.json is what every check reads as
# "connected", so until it exists a stopped connect reads as not connected, and running it again finishes.
write_files() {
    local root="$1" install_id="$2" server_id="$3" url="$4"
    local pkey="$5" psec="$6" skey="$7" ssec="$8"
    local dir; dir="$(state_dir "$root")"

    mkdir -p "$dir" || die "creating $dir" "permission denied" "run as the user that owns $root"

    if [ -n "$psec" ]; then
        # The plugin's key goes in oxide/data, NOT oxide/config: the plugin
        # rewrites its config constantly and the README tells people to delete
        # it to reset defaults, which would silently unenroll the server.
        mkdir -p "$(dirname "$(plugin_file "$root")")"
        back_up "$(plugin_file "$root")"
        write_atomic "$(plugin_file "$root")" \
            "$(printf '{\n  "key_id": "%s",\n  "secret": "%s",\n  "panel_url": "%s",\n  "folder": "%s"\n}' "$pkey" "$psec" "$url" "$(json_escape "$root")")"$'\n' secret \
            || die "writing $(plugin_file "$root")" "the write failed" "check free space and permissions on $root"
    fi

    back_up "$(keys_file "$root")"
    write_atomic "$(keys_file "$root")" \
        "$(printf '{\n  "key_id": "%s",\n  "secret": "%s"\n}' "$skey" "$ssec")"$'\n' secret \
        || die "writing $(keys_file "$root")" "the write failed" "check free space and permissions on $root"

    back_up "$(state_file "$root")"
    write_atomic "$(state_file "$root")" \
        "$(printf '{\n  "install_id": "%s",\n  "server_id": "%s",\n  "identity": "%s",\n  "panel_url": "%s",\n  "connected_at": "%s",\n  "folder": "%s"\n}' \
            "$install_id" "$server_id" "$(json_escape "$NAME")" "$url" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(json_escape "$root")")"$'\n' \
        || die "writing $(state_file "$root")" "the write failed" "check free space and permissions on $root"
}

back_up() {
    [ -f "$1" ] || return 0
    local b="$1.backup-$(date -u '+%Y%m%d-%H%M%S')"
    cp -p "$1" "$b" || die "backing up $1" "the copy failed" "check permissions on $(dirname "$1")"
    note "  kept the previous file as $b"
}

# -------------------------------------------------------------- status ----
cmd_status() {
    local root state; find_root; root="$FOUND_ROOT"; state="$(read_state "$root")"

    if [ ! -f "$(state_file "$root")" ]; then
        say "Not connected."
        note "Run 'doctor' to check this machine, then 'connect'."
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
    local root; find_root; root="$FOUND_ROOT"

    local leftovers
    leftovers="$(ls -1 "$(state_file "$root")" "$(keys_file "$root")" "$(plugin_file "$root")" \
        "$(state_dir "$root")/install_id" "$(state_file "$root")".backup-* "$(keys_file "$root")".backup-* \
        "$(plugin_file "$root")".backup-* 2>/dev/null)"
    [ -n "$leftovers" ] || { say "Not connected -- nothing to detach."; return 0; }

    head_ "About to do this"
    say "  Remove : $(state_file "$root")"
    say "           $(keys_file "$root")"
    [ -f "$(plugin_file "$root")" ] && say "           $(plugin_file "$root")"
    say "           and the install id and .backup- copies connect kept, if any"
    say ""
    note "  Your server keeps running. Reporting stops. Nothing else changes."
    note "  Revoke the keys in the panel too -- this machine cannot do that for you."
    say ""
    confirm "Disconnect this server from the panel?" || { say "  Nothing was changed."; exit 0; }

    # connect.json first: once it is gone every check reads "not connected", even if this stops part-way.
    rm -f "$(state_file "$root")"
    rm -f "$(keys_file "$root")" "$(plugin_file "$root")" "$(state_dir "$root")/install_id" \
        "$(state_file "$root")".backup-* "$(keys_file "$root")".backup-* "$(plugin_file "$root")".backup-*
    say ""
    say "Disconnected. Everything connect wrote has been removed."
}

# ------------------------------------------------------------- install ----
# A bare Ubuntu machine to a Rust server that starts, the Linux sibling of hotwire-setup.ps1's install.
# The same shape and the same rules: a read-only pre-flight, a flight plan of only what is missing, the
# steps (each says what it will do and asks), and a post-flight that runs the checks again. Stopping at
# any moment is safe and running it again carries on: every file is written whole or not at all, and
# the record in hotwire/install.json says which steps finished. A folder holding a Rust server this
# script did not install is refused, never adopted.
#
# It runs as root, because it installs packages, adds a user and a service; the server itself never
# runs as root. Everything it creates in the server folder belongs to that user.

REPO_RAW="https://raw.githubusercontent.com/xman2000/hotwire/connect-and-report"
LAUNCHER_URL="$REPO_RAW/launcher/hotwire.sh"
PLUGIN_URL="$REPO_RAW/src/Hotwire.cs"
SETUP_URL="$REPO_RAW/setup/hotwire-setup.sh"
GUIDE_URL="https://github.com/xman2000/hotwire/blob/connect-and-report/docs/INSTALL-LINUX.md"
OXIDE_URL="https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust-linux.zip"
OXIDE_RELEASES="https://api.github.com/repos/OxideMod/Oxide.Rust/releases/latest"
OXIDE_ASSET="Oxide.Rust-linux.zip"
STEAMCMD_BIN="/usr/games/steamcmd"
RUST_APPID="258550"

# SHA-256 of launcher/hotwire.sh and src/Hotwire.cs AS SERVED from the branch above (the git blob, LF):
#     git show HEAD:launcher/hotwire.sh | sha256sum
# !! REGENERATED AT RELEASE TIME -- NO AUTOMATION EXISTS YET !! Whenever either file changes on that
# branch, these change in the same commit (and so does $PinnedHashes in hotwire-setup.ps1 for Hotwire.cs),
# or every install stops at a hash mismatch. Third-party downloads (SteamCMD from Ubuntu's archive, Oxide
# from GitHub) are not pinned: Oxide is checked against the SHA-256 GitHub publishes for it instead.
PIN_LAUNCHER="aa001f6e222e7c676293a9d86f5edd8291c61d19fad5b76920f2163cb1f0e5cb"
PIN_PLUGIN="886ba405512e30ce633891a3fb8e73bce3e68be8694e804fadd1ed4e03de0472"

# Rust's own floor (wiki.facepunch.com/rust/Creating-a-server), warned about and never enforced. A small
# test server runs on less, and refusing would be guessing at what the reader wants.
MIN_FREE_GB=15
MIN_RAM_GB=12
SWAP_GB=4

IUSER="rust"            # the account the server runs as; --user changes it
IROOT=""                # the server folder; --root, or /home/<user>/server
REGISTRY="/etc/hotwire/installs"   # every folder this script has installed on this machine, one per line

# ---------------------------------------------------------- look and feel --
# Plain ASCII, like the Windows installer, so it reads the same over any terminal and in a log.
banner() {
    local y="" o="" r="" d="" c=""
    if [ -n "$C_OFF" ]; then y=$'\033[93m'; o=$'\033[33m'; r=$'\033[91m'; d=$'\033[31m'; c=$'\033[96m'; fi
    say ""
    say "              ${C_DIM}W E L C O M E    T O${C_OFF}"
    say ""
    say "            ${y} ____   _   _  ____   _____ ${C_OFF}"
    say "            ${y}|  _ \\ | | | |/ ___| |_   _|${C_OFF}"
    say "            ${o}| |_) || | | |\\___ \\   | |  ${C_OFF}"
    say "            ${r}|  _ < | |_| | ___) |  | |  ${C_OFF}"
    say "            ${d}|_| \\_\\ \\___/ |____/   |_|  ${C_OFF}"
    say ""
    say "        ${C_DIM}-=[${C_OFF} supported by ${c}H O T W I R E${C_OFF} ${C_DIM}]=-${C_OFF}"
    say "                 ${C_DIM}setup $VERSION${C_OFF}"
    say ""
}

STEP_NO=0; STEP_TOTAL=0
step() {
    STEP_NO=$((STEP_NO + 1))
    local label="STEP $STEP_NO"; [ "$STEP_TOTAL" -gt 0 ] && label="STEP $STEP_NO OF $STEP_TOTAL"
    say ""
    say "  ${C_BLD}========================================================================${C_OFF}"
    say "  ${C_YEL}>>${C_OFF} $label   ${C_BLD}$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')${C_OFF}"
    say "  ${C_BLD}========================================================================${C_OFF}"
    say ""
}

frame() { say ""; say "  ${C_BLD}.--[ $(printf '%s' "$1" | tr '[:lower:]' '[:upper:]') ]----------------------------------------------${C_OFF}"; }
group() { say ""; say "  ${C_BLD}$1${C_OFF}"; }
why()   { local l; for l in "$@"; do say "  $l"; done; say ""; }

# One pre-flight line: a status tag, what was checked, what was found.
check_line() {  # check_line ok|no|warn|fail|info <label> <detail>
    local tag col
    case "$1" in
        ok)   tag="[ ok ]"; col="$C_GRN" ;;
        no)   tag="[ -- ]"; col="" ;;
        warn) tag="[warn]"; col="$C_YEL" ;;
        fail) tag="[FAIL]"; col="$C_RED" ;;
        *)    tag="[ .. ]"; col="$C_DIM" ;;
    esac
    printf '    %s%s%s %-17s %s%s%s\n' "$col" "$tag" "$C_OFF" "$2" "$col" "$3" "$C_OFF"
}

box() {  # box <colour> <line>...
    local col="$1"; shift
    local w=0 l
    for l in "$@"; do [ "${#l}" -gt "$w" ] && w="${#l}"; done
    w=$((w + 4))
    say ""
    printf '  %s+%s+%s\n' "$col" "$(printf '%*s' "$w" '' | tr ' ' '=')" "$C_OFF"
    for l in "$@"; do printf '  %s|  %-*s|%s\n' "$col" "$((w - 2))" "$l" "$C_OFF"; done
    printf '  %s+%s+%s\n' "$col" "$(printf '%*s' "$w" '' | tr ' ' '=')" "$C_OFF"
}

# The last moment to change your mind, visible. Ctrl+C during it stops with nothing begun.
countdown() {  # countdown <seconds> <what>
    local n="$1" i bar
    [ -t 1 ] || return 0
    say ""
    for ((i = n; i >= 1; i--)); do
        bar="$(printf '%*s' $((n - i + 1)) '' | tr ' ' '#')$(printf '%*s' $((i - 1)) '' | tr ' ' '.')"
        printf '\r  %s[%s]  %s in %s...   Ctrl+C stops it %s' "$C_YEL" "$bar" "$2" "$i" "$C_OFF"
        sleep 1
    done
    printf '\r  %s[%s]  %s now.%30s%s\n' "$C_GRN" "$(printf '%*s' "$n" '' | tr ' ' '#')" "$2" '' "$C_OFF"
}

# SteamCMD can print nothing for minutes, and a quiet screen looks frozen. Shown immediately before it
# runs, as the last thing on screen, because a warning scrolled away is a warning nobody sees.
slow_warning() {
    box "$C_YEL" "PLEASE WAIT -- $1 can look frozen." "" \
        "SteamCMD may print nothing for a while before it starts, and its progress" \
        "can sit still for minutes at a time. That is normal: it is still working." "" \
        "If it does get interrupted, run install again. The download carries on" \
        "from where it stopped."
    say ""
}

# ------------------------------------------------------- record and undo --
rec_file()    { printf '%s/hotwire/install.json' "$IROOT"; }
changes_log() { printf '%s/hotwire/changes.log' "$IROOT"; }

# The record is JSON, read and changed with python3 (always on Ubuntu, and checked by the pre-flight),
# and written whole or not at all. Lists: done, declined, created. Values: folder, user, branch, ports.
rec_py() {  # rec_py <python taking r (the record) and a (the arguments)>
    python3 - "$(rec_file)" "$@" <<'PY'
import json, os, sys
path, code, args = sys.argv[1], sys.argv[2], sys.argv[3:]
try:
    with open(path) as f: r = json.load(f)
except Exception:
    r = {}
out = {}
exec(code, {"r": r, "a": args, "out": out})
if out.get("write"):
    tmp = path + ".hotwire-tmp"
    with open(tmp, "w") as f: json.dump(r, f, indent=2); f.write("\n")
    os.replace(tmp, path)
if "print" in out and out["print"] is not None: print(out["print"])
PY
}

rec_get()      { rec_py 'v = r.get(a[0]); out["print"] = v if isinstance(v, (str, int)) else None' "$1" 2>/dev/null; }
rec_has()      { [ "$(rec_py 'out["print"] = "1" if a[1] in r.get(a[0], []) else "0"' "$1" "$2" 2>/dev/null)" = "1" ]; }
done_step()    { rec_has done "$1"; }
declined()     { rec_has declined "$1"; }
created()      { rec_has created "$1"; }
rec_add()      { rec_py 'l = r.setdefault(a[0], []); (a[1] in l) or l.append(a[1]); out["write"] = 1' "$1" "$2" && own "$(rec_file)"; }
rec_remove()   { rec_py 'r[a[0]] = [x for x in r.get(a[0], []) if x != a[1]]; out["write"] = 1' "$1" "$2" && own "$(rec_file)"; }
rec_set()      { rec_py 'r[a[0]] = a[1]; out["write"] = 1' "$1" "$2" && own "$(rec_file)"; }
save_step()    { rec_add done "$1"; }

# A no is remembered, so the next run does not ask again one Enter away from yes; the pre-flight
# shows it as "as you chose" and offers to ask about those again.
offer() {  # offer <key> <question>   -- [Y/n]; a no is recorded
    if confirm_default_yes "$2"; then rec_remove declined "$1"; return 0; fi
    rec_add declined "$1"; return 1
}

# Every change as it happens, with its exact undo. It outlives the terminal. Until the server's
# folder exists (the packages and the account come first) the lines are held here, because creating
# the folder as root before its user exists would leave that user's home belonging to root.
PENDING_CHANGES=""
change() {  # change <what> <undo>
    local line; line="$(printf '%s  %s\n    undo: %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2")"
    if [ ! -d "$IROOT/hotwire" ]; then PENDING_CHANGES+="$line"$'\n'; return 0; fi
    printf '%s\n' "$line" >> "$(changes_log)"
    own "$(changes_log)"
}
flush_changes() {
    [ -n "$PENDING_CHANGES" ] || return 0
    printf '%s' "$PENDING_CHANGES" >> "$(changes_log)"; own "$(changes_log)"; PENDING_CHANGES=""
}

# Everything in the server folder belongs to the server's user, never to root.
own() { [ -e "$1" ] && chown "$IUSER:$IUSER" "$1" 2>/dev/null; return 0; }
own_tree() { [ -e "$1" ] && chown -R "$IUSER:$IUSER" "$1" 2>/dev/null; return 0; }

as_user() { sudo -u "$IUSER" -H -- "$@"; }

# ------------------------------------------------------------- the machine --
os_ok() {
    [ -r /etc/os-release ] || return 1
    # shellcheck disable=SC1091
    ( . /etc/os-release; [ "${ID:-}" = "ubuntu" ] )
}
os_name() { ( . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}" ); }
ram_gb()  { awk '/^MemTotal:/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null; }
swap_gb() { awk '/^SwapTotal:/{printf "%.1f", $2/1048576}' /proc/meminfo 2>/dev/null; }
free_gb() {  # the nearest existing folder at or above the path
    local p="$1"; while [ ! -d "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
    df -Pk "$p" 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}'
}
ntp_synced() { [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; }

# Measured against Valve's own server, the same reference the Windows installer uses, so opening the
# installer contacts nobody at Hotwire. Seconds this machine is ahead (negative: behind); empty if unknown.
clock_skew() {
    local remote; remote="$(curl -fsSI --max-time 10 https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1}/^date:/{sub(/^[Dd]ate: */,""); sub(/\r$/,""); print; exit}')"
    [ -n "$remote" ] || return 0
    remote="$(date -u -d "$remote" +%s 2>/dev/null)" || return 0
    printf '%s' $(( $(date -u +%s) - remote ))
}

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
PACKAGES=(steamcmd lib32gcc-s1 curl jq unzip zstd ca-certificates)
missing_packages() {
    local p out=()
    for p in "${PACKAGES[@]}"; do
        case "$p" in steamcmd) [ -x "$STEAMCMD_BIN" ] || out+=("$p") ;; *) pkg_installed "$p" || out+=("$p") ;; esac
    done
    printf '%s' "${out[*]}"
}

ufw_state() {  # active | inactive | absent
    command -v ufw >/dev/null 2>&1 || { printf 'absent'; return; }
    ufw status 2>/dev/null | grep -q '^Status: active' && printf 'active' || printf 'inactive'
}
# Whether ufw lets a port in from anywhere: "28015/udp ALLOW Anywhere", or a range that covers it.
ufw_allows() {  # ufw_allows <port> <proto>
    ufw status 2>/dev/null | awk -v p="$1" -v pr="$2" '
        $0 ~ /ALLOW/ {
            split($1, a, "/"); ports = a[1]; proto = a[2]
            if (proto != "" && proto != pr) next
            n = split(ports, list, ",")
            for (i = 1; i <= n; i++) {
                if (split(list[i], r, ":") == 2) { if (p >= r[1] && p <= r[2]) { found = 1 } }
                else if (list[i] == p) { found = 1 }
            }
        }
        END { exit found ? 0 : 1 }'
}

# The Rust server running from this folder, if any: its executable's real path is this folder's binary.
server_running_here() {
    local pid exe
    for pid in $(pgrep -x RustDedicated 2>/dev/null); do
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
        [ "$exe" = "$(readlink -f "$IROOT/RustDedicated" 2>/dev/null)" ] && return 0
    done
    return 1
}

# ------------------------------------------------------------------ rust --
manifest() { printf '%s/steamapps/appmanifest_%s.acf' "$IROOT" "$RUST_APPID"; }
manifest_value() {  # the first "key" "value" pair with that key
    [ -f "$(manifest)" ] || return 0
    awk -v k="\"$1\"" '$1 == k { gsub(/"/, "", $2); print $2; exit }' "$(manifest)"
}
rust_build()  { manifest_value buildid; }
# The branch Steam keeps this install on: UserConfig's BetaKey; none means public.
rust_branch() {
    [ -f "$(manifest)" ] || return 0
    local b; b="$(awk '/"UserConfig"/{u=1} u && $1 == "\"BetaKey\"" { gsub(/"/, "", $2); print $2; exit } u && /}/{u=0}' "$(manifest)")"
    printf '%s' "${b:-public}"
}
rust_complete() { [ -x "$IROOT/RustDedicated" ] && [ "$(manifest_value StateFlags)" = "4" ]; }

oxide_dll() { printf '%s/RustDedicated_Data/Managed/Oxide.Rust.dll' "$IROOT"; }

# ------------------------------------------------------------------ ports --
# Each server on a machine gets its own ports. The first set free of every other install's and of
# anything listening, in steps of 100 from 28015: game, RCON game+1, query game+2.
ports_in_use() {
    local f
    {
        ss -Hlnu 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}'
        ss -Hlnt 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}'
        if [ -f "$REGISTRY" ]; then
            while IFS= read -r f; do
                [ -n "$f" ] && [ "${f%/}" != "${IROOT%/}" ] && [ -f "$f/hotwire/install.json" ] || continue
                python3 -c 'import json,sys; p=json.load(open(sys.argv[1])).get("ports",{}); print("\n".join(str(p[k]) for k in ("game","query","rcon") if k in p))' \
                    "$f/hotwire/install.json" 2>/dev/null
            done < "$REGISTRY"
        fi
    } | sort -un
}
choose_ports() {
    local used game
    if [ -n "$(rec_get game_port)" ]; then
        PORT_GAME="$(rec_get game_port)"; PORT_QUERY="$(rec_get query_port)"; PORT_RCON="$(rec_get rcon_port)"
        return 0
    fi
    used=" $(ports_in_use | tr '\n' ' ') "
    for ((game = 28015; game < 29015; game += 100)); do
        case "$used" in *" $game "*|*" $((game + 1)) "*|*" $((game + 2)) "*) continue ;; esac
        PORT_GAME="$game"; PORT_RCON=$((game + 1)); PORT_QUERY=$((game + 2)); break
    done
    [ -n "${PORT_GAME:-}" ] || die "choosing ports for this server" "every set from 28015 to 28915 is in use" \
        "set SERVER_PORT, SERVER_QUERYPORT and RCON_PORT in hotwire.sh by hand"
    if [ "$PORT_GAME" != "28015" ]; then
        note "  Another server here already uses the usual ports, so this one gets its own:"
    fi
    say "  Ports: game ${PORT_GAME}/udp, query ${PORT_QUERY}/udp, RCON ${PORT_RCON}/tcp"
    rec_set game_port "$PORT_GAME"; rec_set query_port "$PORT_QUERY"; rec_set rcon_port "$PORT_RCON"
    rec_py 'r["ports"] = {"game": int(a[0]), "query": int(a[1]), "rcon": int(a[2])}; out["write"] = 1' \
        "$PORT_GAME" "$PORT_QUERY" "$PORT_RCON" && own "$(rec_file)"
}
PORT_GAME=""; PORT_QUERY=""; PORT_RCON=""

# ------------------------------------------------------------ downloads --
# Downloads beside where the file goes, under a name nothing loads, and checks it before it is used.
fetch() {  # fetch <url> <out> <what>
    curl -fsSL --retry 2 --max-time 300 -o "$2" "$1" 2>/dev/null \
        || { rm -f "$2"; die "downloading $3" "the download from $1 failed" "check this machine can reach github.com, then run install again"; }
}
check_pin() {  # check_pin <file> <expected sha256> <what>
    local got; got="$(sha256sum "$1" | cut -d' ' -f1)"
    if [ "$got" != "$2" ]; then
        rm -f "$1"
        die "checking the downloaded $3" "its SHA-256 is $got, not the $2 this setup expects" \
            "nothing was written; download this setup script again (it is probably older than $3), then run install again"
    fi
    ok "$3 matches its published SHA-256"
}

# ------------------------------------------------------------ pre-flight --
declare -A S
gather() {
    S=()
    S[os]="$(os_name)"; os_ok && S[os_ok]=1 || S[os_ok]=0
    S[ram]="$(ram_gb)"; S[swap]="$(swap_gb)"; S[free]="$(free_gb "$IROOT")"
    S[skew]="$(clock_skew)"; ntp_synced && S[ntp]=1 || S[ntp]=0
    S[packages]="$(missing_packages)"
    id "$IUSER" >/dev/null 2>&1 && S[user]=1 || S[user]=0
    [ -x "$IROOT/RustDedicated" ] && S[rust]=1 || S[rust]=0
    S[rust_done]=0; rust_complete && done_step rust && S[rust_done]=1
    S[build]="$(rust_build)"; S[branch]="$(rust_branch)"; S[chosen]="$(rec_get branch)"
    server_running_here && S[running]=1 || S[running]=0
    [ -f "$(oxide_dll)" ] && S[oxide]=1 || S[oxide]=0
    S[oxide_done]=0; [ "${S[oxide]}" = 1 ] && done_step oxide && S[oxide_done]=1
    declined oxide && S[oxide_no]=1 || S[oxide_no]=0
    [ -f "$IROOT/hotwire.sh" ] && S[launcher]=1 || S[launcher]=0
    declined launcher && S[launcher_no]=1 || S[launcher_no]=0
    S[vanilla]=0; [ "${S[launcher]}" = 1 ] && grep -qx 'INSTALL_FRAMEWORK="0"' "$IROOT/hotwire.sh" && S[vanilla]=1
    [ -f "$IROOT/oxide/plugins/Hotwire.cs" ] && S[plugin]=1 || S[plugin]=0
    declined plugin && S[plugin_no]=1 || S[plugin_no]=0
    S[plugin_version]=""; [ "${S[plugin]}" = 1 ] && S[plugin_version]="$(grep -oE '\[Info\("Hotwire", *"[^"]*", *"[^"]+"\)\]' "$IROOT/oxide/plugins/Hotwire.cs" | grep -oE '"[0-9][^"]*"\)' | tr -d '")')"
    S[rcon]=""; [ "${S[launcher]}" = 1 ] && S[rcon]="$(secrets_problem)"
    S[unit]="$(unit_name)"; [ -f "/etc/systemd/system/${S[unit]}" ] && S[service]=1 || S[service]=0
    declined service && S[service_no]=1 || S[service_no]=0
    [ -f "$(state_file "$IROOT")" ] && S[connected]=1 || S[connected]=0
    declined panel && S[panel_no]=1 || S[panel_no]=0
    S[ufw]="$(ufw_state)"
    local g q r
    g="$(rec_get game_port)"; q="$(rec_get query_port)"; r="$(rec_get rcon_port)"
    S[ports_chosen]=0; [ -n "$g" ] && S[ports_chosen]=1
    S[game]="${g:-28015}"; S[query]="${q:-28017}"; S[rcon_port]="${r:-28016}"
    S[game_open]=0; S[query_open]=0; S[rcon_open]=0
    if [ "${S[ufw]}" = active ]; then
        ufw_allows "${S[game]}" udp && S[game_open]=1
        ufw_allows "${S[query]}" udp && S[query_open]=1
        ufw_allows "${S[rcon_port]}" tcp && S[rcon_open]=1
    fi
}

show_state() {  # show_state <title>
    frame "$1"
    note "    folder: $IROOT   user: $IUSER"

    group "This machine"
    if [ "${S[os_ok]}" = 1 ]; then check_line ok "System" "${S[os]}"; else check_line fail "System" "${S[os]} -- this installer is for Ubuntu"; fi
    awk -v r="${S[ram]:-0}" -v m="$MIN_RAM_GB" 'BEGIN{exit !(r >= m)}' \
        && check_line ok "Memory" "${S[ram]} GB" || check_line warn "Memory" "${S[ram]} GB -- Rust recommends $MIN_RAM_GB GB"
    if awk -v s="${S[swap]:-0}" 'BEGIN{exit !(s > 0)}'; then check_line ok "Swap" "${S[swap]} GB"
    else check_line no "Swap" "none -- running out of memory then kills the server outright"; fi
    if [ -z "${S[free]}" ]; then check_line warn "Disk" "free space could not be read -- Rust recommends $MIN_FREE_GB GB"
    elif [ "${S[free]}" -ge "$MIN_FREE_GB" ]; then check_line ok "Disk" "${S[free]} GB free"
    else check_line warn "Disk" "${S[free]} GB free -- Rust recommends $MIN_FREE_GB GB"; fi
    if [ -z "${S[skew]}" ]; then check_line warn "Clock" "could not be compared with Steam's servers"
    else
        local abs="${S[skew]#-}" sync="kept in time automatically"
        [ "${S[ntp]}" = 1 ] || sync="NOT kept in time automatically"
        if   [ "$abs" -le 30 ];  then check_line ok "Clock" "right (${abs}s from Steam's servers), $sync"
        elif [ "$abs" -le 300 ]; then check_line warn "Clock" "${abs}s out -- drifting, $sync"
        else check_line fail "Clock" "${abs}s out -- Hotwire Panel would refuse every request"; fi
    fi

    group "Rust"
    if [ -z "${S[packages]}" ]; then check_line ok "SteamCMD" "$STEAMCMD_BIN"
    else check_line no "SteamCMD" "missing: ${S[packages]}"; fi
    if [ "${S[user]}" = 1 ]; then check_line ok "User" "$IUSER"; else check_line no "User" "no '$IUSER' account yet"; fi
    if [ "${S[rust_done]}" = 1 ]; then
        local b=""; [ "${S[branch]}" != public ] && b=", branch '${S[branch]}'"
        check_line ok "Rust server" "build ${S[build]}$b"
    elif [ "${S[rust]}" = 1 ]; then check_line warn "Rust server" "download not finished -- install finishes it"
    else check_line no "Rust server" "not installed"; fi
    if [ "${S[running]}" = 1 ]; then
        # Only a problem while Rust or Oxide still has to be put in place under it.
        if [ "${S[rust_done]}" = 1 ] && { [ "${S[oxide_done]}" = 1 ] || [ "${S[oxide_no]}" = 1 ]; }; then
            check_line ok "Running" "yes"
        else
            check_line fail "Running" "the server in this folder is running -- stop it before installing"
        fi
    fi
    if [ "${S[oxide_done]}" = 1 ]; then check_line ok "Oxide" "installed"
    elif [ "${S[oxide]}" = 1 ]; then check_line warn "Oxide" "partly installed -- install finishes it"
    elif [ "${S[oxide_no]}" = 1 ]; then check_line info "Oxide" "not installed -- a vanilla server, as you chose"
    else check_line no "Oxide" "not installed -- without it, a vanilla server"; fi

    group "Hotwire"
    if [ "${S[launcher]}" = 1 ]; then check_line ok "Start script" "hotwire.sh$([ "${S[vanilla]}" = 1 ] && printf ' (vanilla)')"
    elif [ "${S[launcher_no]}" = 1 ]; then check_line info "Start script" "no hotwire.sh -- you chose your own start script"
    else check_line no "Start script" "no hotwire.sh"; fi
    if [ "${S[launcher]}" != 1 ]; then check_line info "RCON password" "set with the start script"
    elif [ -n "${S[rcon]}" ]; then check_line fail "RCON password" "${S[rcon]} -- hotwire.sh will not start"
    else check_line ok "RCON password" "set, and hotwire.sh will accept it"; fi
    if [ "${S[service]}" = 1 ]; then check_line ok "Service" "${S[unit]} -- starts with the machine"
    elif [ "${S[service_no]}" = 1 ]; then check_line info "Service" "none -- you start the server yourself, as you chose"
    else check_line no "Service" "not set up -- the server would not come back after a reboot"; fi
    if [ "${S[plugin]}" = 1 ]; then check_line ok "Plugin" "Hotwire ${S[plugin_version]:-(version unread)}"
    elif [ "${S[plugin_no]}" = 1 ]; then check_line info "Plugin" "not installed -- you said no"
    else check_line no "Plugin" "not installed"; fi
    if [ "${S[connected]}" = 1 ]; then check_line ok "Hotwire Panel" "connected as '$(json_get "$(read_state "$IROOT")" identity)'"
    elif [ "${S[panel_no]}" = 1 ]; then check_line info "Hotwire Panel" "not connected -- you said no"
    else check_line no "Hotwire Panel" "not connected"; fi

    group "Firewall"
    if [ "${S[ports_chosen]}" = 1 ]; then check_line ok "Ports" "game ${S[game]}, query ${S[query]}, RCON ${S[rcon_port]}"
    else check_line info "Ports" "not chosen yet -- install picks free ones; checked here at the usual ones"; fi
    case "${S[ufw]}" in
        active)
            check_line ok "ufw" "on"
            [ "${S[game_open]}" = 1 ]  && check_line ok "Game  UDP ${S[game]}" "open"  || check_line no "Game  UDP ${S[game]}" "closed"
            [ "${S[query]}" ] && { [ "${S[query_open]}" = 1 ] && check_line ok "Query UDP ${S[query]}" "open" || check_line no "Query UDP ${S[query]}" "closed"; }
            [ "${S[rcon_open]}" = 1 ] && check_line warn "RCON  TCP ${S[rcon_port]}" "OPEN to the internet -- RCON is remote control of this server" \
                                      || check_line ok "RCON  TCP ${S[rcon_port]}" "closed, as it should be" ;;
        inactive) check_line info "ufw" "installed but off -- every port is reachable unless your host filters them, RCON included" ;;
        *)        check_line info "ufw" "not installed -- check your host's firewall instead" ;;
    esac
}

# What the pre-flight found missing, in the order it has to be done. Each line: key|title|why
plan() {
    PLAN=()
    local abs="${S[skew]#-}"
    { [ "${S[ntp]}" = 0 ] || { [ -n "$abs" ] && [ "$abs" -gt 30 ]; }; } && PLAN+=("clock|Clock|keep it in time automatically")
    [ -n "${S[packages]}" ] && PLAN+=("packages|SteamCMD|install it from Ubuntu's archive -- Rust downloads through it")
    [ "${S[user]}" = 0 ] && PLAN+=("user|User|create '$IUSER' -- the server never runs as root")
    awk -v s="${S[swap]:-0}" 'BEGIN{exit !(s == 0)}' && ! declined swap && PLAN+=("swap|Swap|add a ${SWAP_GB} GB swap file")
    [ "${S[rust_done]}" = 0 ] && PLAN+=("rust|Rust server|$([ "${S[rust]}" = 1 ] && echo 'finish the download' || echo 'download it, about 6 GB')")
    if [ "${S[oxide_no]}" = 0 ] && { [ "${S[oxide_done]}" = 0 ] || [ "${S[rust_done]}" = 0 ]; }; then
        PLAN+=("oxide|Oxide|$([ "${S[oxide]}" = 1 ] && echo 'finish installing it' || echo 'install it, or say no for a vanilla server')")
    fi
    [ "${S[launcher]}" = 0 ] && [ "${S[launcher_no]}" = 0 ] && PLAN+=("launcher|Start script|install hotwire.sh, or say no to use your own")
    { [ -n "${S[rcon]}" ] || { [ "${S[launcher]}" = 0 ] && [ "${S[launcher_no]}" = 0 ]; }; } \
        && PLAN+=("rcon|RCON password|$([ -n "${S[rcon]}" ] && echo "fix it: ${S[rcon]}" || echo 'set it, for hotwire.sh')")
    [ "${S[plugin]}" = 0 ] && [ "${S[plugin_no]}" = 0 ] && [ "${S[oxide_no]}" = 0 ] && PLAN+=("plugin|Hotwire plugin|install it -- needs Oxide")
    [ "${S[service]}" = 0 ] && [ "${S[service_no]}" = 0 ] && [ "${S[launcher_no]}" = 0 ] && PLAN+=("service|Service|start the server with the machine")
    [ "${S[ufw]}" = active ] && { [ "${S[game_open]}" = 0 ] || [ "${S[query_open]}" = 0 ] || [ "${S[ports_chosen]}" = 0 ]; } \
        && PLAN+=("firewall|Firewall|open this server's game and query ports in ufw")
    [ "${S[connected]}" = 0 ] && [ "${S[panel_no]}" = 0 ] && PLAN+=("panel|Hotwire Panel|connect this server")
    return 0
}
PLAN=()

show_plan() {
    frame "Flight plan"
    [ "${#PLAN[@]}" -eq 0 ] && return 0
    say ""
    local n=0 item key title reason
    for item in "${PLAN[@]}"; do
        n=$((n + 1)); IFS='|' read -r key title reason <<< "$item"
        printf '    %s%2d.%s  %s%-16s%s %s\n' "$C_YEL" "$n" "$C_OFF" "$C_BLD" "$title" "$C_OFF" "$reason"
    done
    if printf '%s\n' "${PLAN[@]}" | grep -q '^rust|' && [ -n "${S[free]}" ] && [ "${S[free]}" -lt "$MIN_FREE_GB" ]; then
        say ""; warn "only ${S[free]} GB free for a download of about 6 GB that grows with every update"
    fi
    say ""
    note "  Every step still says what it will do and asks first."
}

in_plan() { printf '%s\n' "${PLAN[@]}" | grep -q "^$1|"; }

declined_names() {
    local n=()
    [ "${S[oxide_no]}" = 1 ] && [ "${S[oxide_done]}" = 0 ] && n+=("Oxide")
    [ "${S[launcher_no]}" = 1 ] && [ "${S[launcher]}" = 0 ] && n+=("the start script")
    [ "${S[plugin_no]}" = 1 ] && [ "${S[plugin]}" = 0 ] && n+=("the Hotwire plugin")
    [ "${S[service_no]}" = 1 ] && [ "${S[service]}" = 0 ] && n+=("the service")
    declined swap && awk -v s="${S[swap]:-0}" 'BEGIN{exit !(s == 0)}' && n+=("swap")
    [ "${S[panel_no]}" = 1 ] && [ "${S[connected]}" = 0 ] && n+=("Hotwire Panel")
    local IFS=','; printf '%s' "${n[*]}" | sed 's/,/, /g'
}

# ------------------------------------------------------------- the steps --
step_clock() {
    step "Clock"
    why "Hotwire Panel refuses a signed request more than five minutes from its own clock, and says only" \
        "that the time was wrong. Ubuntu keeps the clock right by itself once time sync is on."
    if ntp_synced; then ok "the clock is kept in time automatically"; return 0; fi
    confirm "Turn on automatic time sync (timedatectl set-ntp true)?" || { note "Left as it is."; return 0; }
    if timedatectl set-ntp true 2>/dev/null; then
        ok "time sync is on; the clock settles within a minute or two"
        change "turned on time sync (timedatectl set-ntp true)" "sudo timedatectl set-ntp false"
    else
        warn "timedatectl could not turn it on -- see 'timedatectl status'"
    fi
}

step_packages() {
    step "SteamCMD"
    local missing; missing="$(missing_packages)"
    if [ -z "$missing" ]; then ok "SteamCMD and the tools Rust needs are installed"; return 0; fi
    why "SteamCMD is Valve's tool for downloading game servers. Rust's server is free and needs no" \
        "Steam account. Ubuntu packages it in 'multiverse', and it needs 32-bit libraries (i386)." "" \
        "This installs: $missing" \
        "It changes: the multiverse archive is switched on, and the i386 architecture is added." "" \
        "Valve's licence for SteamCMD comes up on screen during the install, and you accept or" \
        "decline it there. Declining stops here: Rust downloads through SteamCMD." "" \
        "More: https://developer.valvesoftware.com/wiki/SteamCMD"
    confirm_default_yes "Install SteamCMD?" || die "installing SteamCMD" "you said no" \
        "Rust downloads through SteamCMD; run install again when you want it"

    if ! grep -rqsE '^[^#]*\bmultiverse\b' /etc/apt/sources.list /etc/apt/sources.list.d/; then
        command -v add-apt-repository >/dev/null 2>&1 || apt-get install -y software-properties-common
        add-apt-repository -y multiverse || die "switching on Ubuntu's multiverse archive" "add-apt-repository failed" \
            "run 'sudo add-apt-repository multiverse' yourself, then run install again"
        change "switched on Ubuntu's multiverse archive" "sudo add-apt-repository --remove multiverse"
    fi
    if ! dpkg --print-foreign-architectures | grep -qx i386; then
        dpkg --add-architecture i386 || die "adding the i386 architecture" "dpkg refused" "run 'sudo dpkg --add-architecture i386', then install again"
        change "added the i386 architecture" "sudo dpkg --remove-architecture i386 (only once no i386 package is left)"
    fi
    apt-get update || die "reading Ubuntu's package lists" "apt-get update failed" "check this machine's internet connection, then run install again"
    # The licence is Valve's to show and the owner's to accept (its terms require that it is displayed and
    # accepted by the person installing), so apt is given the terminal and nothing is pre-answered.
    # shellcheck disable=SC2086
    apt-get install -y $missing </dev/tty || die "installing $missing" "apt-get install failed (declining Valve's licence also ends here)" \
        "run install again; to install by hand: sudo apt install $missing"
    [ -x "$STEAMCMD_BIN" ] || die "installing SteamCMD" "$STEAMCMD_BIN is not there after the install" \
        "run 'sudo apt install steamcmd' yourself and read what it says"
    ok "installed: $missing"
    change "installed packages: $missing" "sudo apt remove $missing"
}

step_user() {
    step "User"
    if id "$IUSER" >/dev/null 2>&1; then ok "the '$IUSER' account exists"; return 0; fi
    why "The game server should never run as root: anything it can be made to do, it could then do" \
        "to the whole machine. This makes an account for it, '$IUSER', with no password -- nobody logs" \
        "in as it; you reach it with 'sudo -iu $IUSER'."
    confirm_default_yes "Create the '$IUSER' account?" || die "creating the '$IUSER' account" "you said no" \
        "run install again with --user NAME to use an account that already exists"
    adduser --disabled-password --gecos "" "$IUSER" >/dev/null || die "creating the '$IUSER' account" "adduser failed" \
        "run 'sudo adduser --disabled-password $IUSER' and read what it says"
    ok "created the '$IUSER' account"
    change "created the account $IUSER" "sudo deluser --remove-home $IUSER (this deletes the server folder too)"
}

step_swap() {
    step "Swap"
    if awk -v s="$(swap_gb)" 'BEGIN{exit !(s > 0)}'; then ok "swap is on ($(swap_gb) GB)"; return 0; fi
    why "Rust uses a lot of memory, and with no swap a short spike gets the server killed outright." \
        "That looks exactly like a crash nobody can explain. A ${SWAP_GB} GB swap file at /swapfile is a" \
        "cushion, not extra memory: a server that lives in swap is slow."
    if [ -e /swapfile ]; then warn "/swapfile already exists and is not in use -- left alone"; return 0; fi
    local free; free="$(free_gb /)"
    if [ -n "$free" ] && [ "$free" -lt $((SWAP_GB + MIN_FREE_GB)) ]; then
        warn "only $free GB free on / -- a swap file would take ${SWAP_GB} GB of the room Rust needs"
    fi
    if ! confirm "Add a ${SWAP_GB} GB swap file?"; then rec_add declined swap; note "Left as it is."; return 0; fi
    rec_remove declined swap
    { fallocate -l "${SWAP_GB}G" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; } \
        || { swapoff /swapfile 2>/dev/null; rm -f /swapfile; die "adding a swap file" "one of fallocate, mkswap or swapon failed" \
             "nothing was kept; add swap by hand, or run install again and say no to it"; }
    grep -qE '^/swapfile[[:space:]]' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    ok "${SWAP_GB} GB of swap is on, and stays on after a reboot"
    change "added a ${SWAP_GB} GB swap file at /swapfile, and its line in /etc/fstab" \
        "sudo swapoff /swapfile && sudo rm /swapfile, then delete the /swapfile line from /etc/fstab"
}

choose_branch() {
    local chosen; chosen="$(rec_get branch)"
    [ -n "$chosen" ] && { BRANCH="$chosen"; return 0; }
    say "  Which Steam branch? ${C_BLD}public${C_OFF} is the live game; 'staging' is Facepunch's test build."
    printf '  Branch [public]: '
    local a; read_tty; a="$(printf '%s' "$TTY_LINE" | tr -d '[:space:]')"
    BRANCH="${a:-public}"
    [[ "$BRANCH" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "choosing a Steam branch" "'$BRANCH' is not a branch name" "run install again and press Enter for public"
    rec_set branch "$BRANCH"
}
BRANCH="public"

steamcmd_locked() {  # the same lock hotwire.sh takes, so two servers' SteamCMD runs take turns
    local lock="/home/$IUSER/.hotwire/steamcmd.lock"
    as_user mkdir -p "/home/$IUSER/.hotwire" || die "preparing SteamCMD's lock in /home/$IUSER/.hotwire" \
        "$IUSER could not create it" "check that /home/$IUSER belongs to $IUSER: sudo chown $IUSER:$IUSER /home/$IUSER"
    as_user flock -w 3600 "$lock" "$STEAMCMD_BIN" "$@"
}

link_steamclient() {
    # RustDedicated loads Steam's client library from a path it does not create; without it the server
    # builds its whole map and then fails with an error that names nothing. hotwire.sh links it at every
    # start too; this covers a server started any other way.
    local h="/home/$IUSER" arch
    for arch in 64 32; do
        local src="$h/.local/share/Steam/steamcmd/linux$arch/steamclient.so" dst="$h/.steam/sdk$arch/steamclient.so"
        [ -e "$dst" ] && continue
        [ -e "$src" ] || continue
        as_user mkdir -p "$h/.steam/sdk$arch" && as_user ln -s "$src" "$dst" && ok "linked steamclient.so (sdk$arch)"
    done
}

step_rust() {
    step "Rust server"
    if rust_complete && done_step rust; then ok "Rust is installed (build $(rust_build))"; link_steamclient; return 0; fi
    why "Rust's dedicated server is Steam app $RUST_APPID. It is free, and 'anonymous' is a real Steam" \
        "login, not a placeholder. About 6 GB now; it grows with every update." "" \
        "It goes into $IROOT, owned by $IUSER." "" \
        "More: https://wiki.facepunch.com/rust/Creating-a-server"
    choose_branch
    local free; free="$(free_gb "$IROOT")"
    if [ -n "$free" ] && [ "$free" -lt "$MIN_FREE_GB" ]; then
        warn "only $free GB free -- a full disk stops the download and can upset the whole machine"
        confirm "Download anyway?" || die "downloading Rust" "there is too little free space" "free some space, then run install again"
    else
        confirm_default_yes "Download the Rust server ($BRANCH)?" || die "downloading Rust" "you said no" "run install again when you are ready"
    fi
    as_user mkdir -p "$IROOT" || die "creating $IROOT" "it could not be created as $IUSER" "check the folder above it belongs to $IUSER"

    slow_warning "the download"
    countdown 5 "Downloading Rust"
    local tries=0
    while :; do
        tries=$((tries + 1))
        # -beta names the branch every time: Steam otherwise keeps an install on whatever it last had.
        steamcmd_locked +force_install_dir "$IROOT" +login anonymous +app_update "$RUST_APPID" -beta "$BRANCH" validate +quit
        local rc=$?
        # Ctrl+C. sudo runs the command in a terminal of its own (Ubuntu's sudo-rs does by default), so
        # the interrupt reaches SteamCMD and comes back as its exit status, never as a signal to this
        # script; without this, the retry below started the download again under the person stopping it.
        if [ "$rc" = 130 ] || [ "$rc" = 143 ]; then
            say ""; warn "Stopped. Nothing is half-written: run install again and the download carries on."; exit 130
        fi
        [ "$rc" = 0 ] && rust_complete && break
        [ "$tries" -ge 3 ] && die "downloading Rust" "SteamCMD did not finish after $tries tries" \
            "run install again: the download carries on from where it stopped"
        warn "SteamCMD stopped before the download finished (SteamCMD often does on its first run); trying again"
        sleep 5
    done
    ok "Rust build $(rust_build) is installed ($BRANCH)"
    change "downloaded Rust (app $RUST_APPID, $BRANCH) into $IROOT" "delete $IROOT (everything in it)"
    save_step rust
    link_steamclient
}

oxide_entries_ok() {  # every entry under RustDedicated_Data/, none escaping it
    local bad
    bad="$(unzip -Z1 "$1" 2>/dev/null | grep -vE '^RustDedicated_Data/' ; unzip -Z1 "$1" 2>/dev/null | grep -E '(^|/)\.\.(/|$)|^/|\\')"
    [ -z "$bad" ] && [ -n "$(unzip -Z1 "$1" 2>/dev/null)" ]
}

step_oxide() {
    step "Oxide"
    if done_step oxide && [ -f "$(oxide_dll)" ]; then ok "Oxide is installed"; return 0; fi
    if ! done_step rust; then note "Skipped: Oxide goes on top of a finished Rust download, and this one is not finished."; return 0; fi
    why "Oxide (uMod) lets a Rust server run plugins. Hotwire's plugin needs it." "" \
        "This downloads Oxide's Linux build from GitHub, checks it against the SHA-256 GitHub publishes" \
        "for it, and puts its files over the server's RustDedicated_Data. The game files it replaces are" \
        "copied to hotwire/backups first. Every Rust update puts the originals back, so hotwire.sh" \
        "installs Oxide again after each one." "" \
        "More: https://umod.org/games/rust"
    [ -f "$(oxide_dll)" ] && note "  An earlier attempt did not finish. This puts every Oxide file in place again."
    if ! offer oxide "Install Oxide?"; then warn "Skipped: this is a vanilla server, and it cannot run plugins."; return 0; fi

    local work="$IROOT/hotwire/oxide-unpack" zip="$IROOT/hotwire/oxide.zip.hotwire-tmp" rel sha from
    as_user mkdir -p "$IROOT/hotwire"
    rel="$(curl -fsSL --max-time 25 -H 'Accept: application/vnd.github+json' "$OXIDE_RELEASES" 2>/dev/null || true)"
    from="$(printf '%s' "$rel" | jq -r --arg n "$OXIDE_ASSET" '.assets[]?|select(.name==$n)|.browser_download_url' 2>/dev/null | head -1)"
    sha="$(printf '%s' "$rel" | jq -r --arg n "$OXIDE_ASSET" '.assets[]?|select(.name==$n)|.digest' 2>/dev/null | head -1)"; sha="${sha#sha256:}"
    case "$from" in https://github.com/*) ;; *) from="$OXIDE_URL"; sha="" ;; esac
    fetch "$from" "$zip" "Oxide for Rust (Linux)"
    if [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]]; then
        [ "$(sha256sum "$zip" | cut -d' ' -f1)" = "${sha,,}" ] || { rm -f "$zip"; die "checking the Oxide download" \
            "its SHA-256 does not match the one GitHub publishes" "nothing was unpacked; run install again later"; }
        ok "Oxide matches the SHA-256 GitHub publishes"
    else
        warn "GitHub did not say what Oxide's SHA-256 should be; it is used unverified (third-party)"
    fi
    oxide_entries_ok "$zip" || { rm -f "$zip"; die "checking the Oxide download" \
        "it is not a zip of files under RustDedicated_Data/" "nothing was unpacked; run install again later"; }

    # The game's own files, copied once, before Oxide first replaces them.
    if ! ls -d "$IROOT"/hotwire/backups/*-before-oxide >/dev/null 2>&1; then
        local backup="$IROOT/hotwire/backups/$(date '+%Y%m%d-%H%M%S')-before-oxide" saved=0 f
        while IFS= read -r f; do
            [ -f "$IROOT/$f" ] || continue
            mkdir -p "$backup/$(dirname "$f")" && cp -p "$IROOT/$f" "$backup/$f" && saved=$((saved + 1))
        done < <(unzip -Z1 "$zip" | grep -v '/$')
        own_tree "$IROOT/hotwire/backups"
        [ "$saved" -gt 0 ] && { ok "copied $saved game file(s) Oxide replaces to $backup"; change "copied $saved game file(s) that Oxide replaces to $backup" "nothing needed; this is the backup"; }
    fi

    # Unpacked beside the server, then each file renamed into place, so none is ever half-written.
    rm -rf "$work"; mkdir -p "$work"
    unzip -q "$zip" -d "$work" || { rm -rf "$work" "$zip"; die "unpacking Oxide" "unzip failed" "run install again"; }
    local f
    while IFS= read -r f; do
        mkdir -p "$IROOT/$(dirname "$f")"
        mv -f "$work/$f" "$IROOT/$f" || die "putting $f in place" "the move failed" "run install again: it puts every Oxide file in place again"
    done < <(cd "$work" && find . -type f | sed 's|^\./||')
    rm -rf "$work" "$zip"
    own_tree "$IROOT/RustDedicated_Data"
    [ -f "$(oxide_dll)" ] || die "installing Oxide" "no Oxide.Rust.dll after unpacking" "run install again"
    ok "Oxide installed"
    change "installed Oxide into $IROOT" "copy the files from $IROOT/hotwire/backups/*-before-oxide back into $IROOT"
    save_step oxide
    sync_launcher_framework
}

# hotwire.sh installs Oxide on every update unless told the server is vanilla. When install wrote the
# launcher, its INSTALL_FRAMEWORK follows Oxide; anyone else's launcher gets the line to change instead.
sync_launcher_framework() {
    local l="$IROOT/hotwire.sh" want
    [ -f "$l" ] || return 0
    want=1; { done_step oxide && [ -f "$(oxide_dll)" ]; } || want=0
    grep -qx "INSTALL_FRAMEWORK=\"$want\"" "$l" && return 0
    if created "$l"; then
        cp -p "$l" "$l.backup-$(date '+%Y%m%d-%H%M%S')"
        sed "s/^INSTALL_FRAMEWORK=\"[01]\"\$/INSTALL_FRAMEWORK=\"$want\"/" "$l" > "$l.hotwire-tmp" && chmod 755 "$l.hotwire-tmp" && mv -f "$l.hotwire-tmp" "$l"
        own "$l"; ok "hotwire.sh set to INSTALL_FRAMEWORK=\"$want\""
        change "set INSTALL_FRAMEWORK=\"$want\" in $l" "put back the .backup- copy beside it"
    else
        warn "hotwire.sh is not one install wrote: set INSTALL_FRAMEWORK=\"$want\" in it yourself"
    fi
}

# A saved map means the server has been played: a seed now would start a different map, which is a wipe.
has_saves() { find "$IROOT/server" -type f \( -name '*.sav' -o -name '*.sav.*' -o -name '*.map' \) 2>/dev/null | grep -q .; }

# Sets one KEY="value" line in the launcher's SETTINGS block. The line must appear exactly once, or
# nothing is written: a launcher this script does not recognise is left for a person.
set_setting() {  # set_setting <text> <KEY> <value>   -> prints the new text
    local n; n="$(printf '%s\n' "$1" | grep -c "^$2=\"[^\"]*\"")"
    [ "$n" = 1 ] || return 1
    printf '%s\n' "$1" | KEY="$2" VAL="$3" awk '{ if (index($0, ENVIRON["KEY"] "=\"") == 1 && $0 ~ /^[A-Z_]+="[^"]*"/) { sub(/"[^"]*"/, "\"" ENVIRON["VAL"] "\"") } print }'
}

step_launcher() {
    step "Start script"
    local l="$IROOT/hotwire.sh"
    if [ -f "$l" ]; then ok "hotwire.sh is already here -- kept"; sync_launcher_framework; save_step launcher; return 0; fi
    local vanilla=0; { done_step oxide && [ -f "$(oxide_dll)" ]; } || vanilla=1
    local seed=""; has_saves || seed="$(python3 -c 'import secrets; print(secrets.randbelow(2147483647) + 1)')"
    why "hotwire.sh is Hotwire's start script: it starts the server, brings it back when it stops," \
        "installs Rust and Oxide updates, and stops trying if the server crashes over and over. Every" \
        "schedule ships switched off, so it cannot restart anything by surprise." "" \
        "This downloads it from the public repository and sets it up for this server:" \
        "  STEAM_BRANCH      = $(rec_get branch || true)" \
        "  ports             = its own game, query and RCON ports (next)"
    [ "$vanilla" = 1 ] && say "    INSTALL_FRAMEWORK = 0     no Oxide here, so it runs a vanilla server"
    if [ -n "$seed" ]; then say "    SERVER_SEED       = $seed   a random map, picked once; restarts keep it"
    else say "    SERVER_SEED       = left empty: this server already has a saved map, and a seed would start a new one"; fi
    say ""
    note "  Say no to start the server with a script of your own instead."
    say ""
    if ! offer launcher "Install hotwire.sh as the start script?"; then
        note "Skipped: you start the server your own way. The RCON password step is skipped too, because"
        note "your start script is what sets it."
        return 0
    fi
    choose_ports

    local tmp="$l.hotwire-tmp" text
    fetch "$LAUNCHER_URL" "$tmp" "the Hotwire launcher"
    check_pin "$tmp" "$PIN_LAUNCHER" "the Hotwire launcher"
    text="$(cat "$tmp")"; rm -f "$tmp"
    local key val
    for key in STEAM_BRANCH SERVER_PORT SERVER_QUERYPORT RCON_PORT INSTALL_FRAMEWORK SERVER_SEED; do
        case "$key" in
            STEAM_BRANCH)      val="$(rec_get branch)"; val="${val:-public}" ;;
            SERVER_PORT)       val="$PORT_GAME" ;;
            SERVER_QUERYPORT)  val="$PORT_QUERY" ;;
            RCON_PORT)         val="$PORT_RCON" ;;
            INSTALL_FRAMEWORK) val=$((1 - vanilla)) ;;
            SERVER_SEED)       val="$seed" ;;
        esac
        text="$(set_setting "$text" "$key" "$val")" || die "setting $key in the downloaded hotwire.sh" \
            "the line $key=\"...\" is not there exactly once" "nothing was written; please report this"
    done
    ( umask 022; printf '%s\n' "$text" > "$tmp" ) && chmod 755 "$tmp" && mv -f "$tmp" "$l" \
        || die "writing $l" "the write failed" "check free space, then run install again"
    own "$l"
    rec_add created "$l"
    ok "hotwire.sh written$([ "$vanilla" = 1 ] && printf ' for a vanilla server'), ports ${PORT_GAME}/${PORT_QUERY}/${PORT_RCON}"
    [ -n "$seed" ] && { ok "the map is seed $seed, picked at random for this server"; note "        To play a particular map, change SERVER_SEED in hotwire.sh BEFORE the first start."; }
    change "created $l (branch, ports$([ -n "$seed" ] && printf ', SERVER_SEED=%s' "$seed")$([ "$vanilla" = 1 ] && printf ', INSTALL_FRAMEWORK=0'))" "delete $l"
    save_step launcher
}

# The launcher's own refusals (hotwire.sh: empty, under 8, change_me, a double quote), and what a
# single-quoted line in a sourced file cannot hold: a single quote, a line break, anything non-ASCII.
password_problem() {
    local p="$1"
    [ -n "$p" ] || { printf 'it is empty'; return; }
    local LC_ALL=C; [[ "$p" =~ [^\ -~] ]] && { printf 'it has a character that is not a plain letter, digit or keyboard symbol'; return; }
    [ "$p" != "${p#[[:space:]]}" ] || [ "$p" != "${p%[[:space:]]}" ] && { printf 'it starts or ends with a space'; return; }
    [ "${#p}" -ge 8 ] || { printf 'it is under 8 characters'; return; }
    [ "$p" != "change_me" ] || { printf 'it is still the example value, change_me'; return; }
    [[ "$p" != *'"'* ]] || { printf 'it contains a double quote'; return; }
    [[ "$p" != *"'"* ]] || { printf 'it contains a single quote'; return; }
    return 0
}

# Reads secrets.sh rather than running it: this script is root, and the file belongs to the server's user.
secrets_problem() {
    local f="$IROOT/secrets.sh" line val
    [ -f "$f" ] || { printf 'there is no secrets.sh'; return; }
    line="$(grep -E '^[[:space:]]*RCON_PASSWORD=' "$f" | tail -1)"
    [ -n "$line" ] || { printf 'secrets.sh has no RCON_PASSWORD= line'; return; }
    val="${line#*=}"
    case "$val" in \'*\') val="${val#\'}"; val="${val%\'}" ;; \"*\") val="${val#\"}"; val="${val%\"}" ;;
        *'$'*|*'`'*) printf 'secrets.sh works its password out when it runs, which this cannot check'; return ;; esac
    password_problem "$val"
}

new_password() {  # 32 of 56 letters and digits without look-alikes: about 185 bits
    python3 -c 'import secrets; a="ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"; print("".join(secrets.choice(a) for _ in range(32)))'
}

read_secret() {  # sets TTY_LINE, not echoed; in this shell for the same reason as read_tty
    TTY_LINE=""
    { IFS= read -rs TTY_LINE </dev/tty; } 2>/dev/null || TTY_LINE=""
    printf '\n' >/dev/tty 2>/dev/null
}

step_rcon() {
    step "RCON password"
    local f="$IROOT/secrets.sh" replacing=0 problem
    if [ ! -f "$IROOT/hotwire.sh" ]; then note "Skipped: there is no hotwire.sh, so your own start script sets the RCON password."; return 0; fi
    if [ -f "$f" ]; then
        problem="$(secrets_problem)"
        if [ -z "$problem" ]; then ok "secrets.sh is already here, and hotwire.sh will accept its password -- left as it is"; save_step rcon; return 0; fi
        bad "secrets.sh is here, but $problem -- hotwire.sh will not start the server"
        confirm "Set a new RCON password in its place?" || { note "Left as it is. Fix $f before starting the server."; return 0; }
        replacing=1
    fi
    why "RCON is remote control of your server: anyone with this password can run commands on it," \
        "so treat it like this machine's root password. hotwire.sh reads it from secrets.sh, readable" \
        "only by $IUSER, and it never goes on a command line you type." "" \
        "Press Enter and a strong one is made for you: 32 random letters and digits, shown once." \
        "Or type your own -- it is not shown as you type, and you type it twice."
    local pw first second generated=0
    while :; do
        printf '  RCON password (Enter to generate one): '
        read_secret; first="$TTY_LINE"
        if [ -z "$first" ]; then pw="$(new_password)"; generated=1; break; fi
        problem="$(password_problem "$first")"
        [ -z "$problem" ] || { bad "that will not work: $problem. Try another, or press Enter to generate one."; continue; }
        printf '  Type it again: '
        read_secret; second="$TTY_LINE"
        [ "$first" = "$second" ] || { bad "the two did not match. Try again."; continue; }
        pw="$first"; break
    done
    local previous=""
    if [ "$replacing" = 1 ]; then previous="$f.backup-$(date '+%Y%m%d-%H%M%S')"; cp -p "$f" "$previous"; fi
    ( umask 077
      printf '# The RCON password for this server. RCON is remote control of the machine: treat this\n# like a root password. Never share this file, and never commit it anywhere.\nRCON_PASSWORD='"'"'%s'"'"'\n' "$pw" > "$f.hotwire-tmp" ) \
        && chmod 600 "$f.hotwire-tmp" && chown "$IUSER:$IUSER" "$f.hotwire-tmp" && mv -f "$f.hotwire-tmp" "$f" \
        || { rm -f "$f.hotwire-tmp"; die "writing $f" "the write failed" "run install again"; }
    rec_add created "$f"
    ok "secrets.sh written, readable only by $IUSER"
    if [ -n "$previous" ]; then change "replaced $f (the RCON password)" "copy $previous back over it"
    else change "created $f (the RCON password)" "delete it; hotwire.sh will not start without one"; fi
    if [ "$generated" = 1 ]; then
        say ""; say "  Your RCON password:"; say ""; say "      ${C_YEL}$pw${C_OFF}"; say ""
        note "  It is also in $f, which only $IUSER and root can read."
        printf '  Save it somewhere safe, then press Enter '; read_tty; say ""
    else
        note "  Your password was not shown."
    fi
    save_step rcon
}

step_plugin() {
    step "Hotwire plugin"
    local dir="$IROOT/oxide/plugins" p="$IROOT/oxide/plugins/Hotwire.cs"
    if [ -f "$p" ]; then ok "oxide/plugins/Hotwire.cs is already here -- kept"; save_step plugin; return 0; fi
    if ! { done_step oxide && [ -f "$(oxide_dll)" ]; }; then note "Skipped: the plugin runs on Oxide, which is not installed."; return 0; fi
    why "The Hotwire plugin adds scheduled, announced restarts: it counts down in game, saves, and hands" \
        "over to hotwire.sh. It is also what reports to Hotwire Panel, once you connect. Every schedule" \
        "ships switched off."
    [ -f "$IROOT/hotwire.sh" ] || { warn "there is no hotwire.sh: a scheduled restart quits the server, and your own start"; note "        script has to start it again."; }
    offer plugin "Install the Hotwire plugin?" || { note "Skipped. Run install again any time to add it."; return 0; }
    as_user mkdir -p "$dir"
    fetch "$PLUGIN_URL" "$p.hotwire-tmp" "the Hotwire plugin"
    check_pin "$p.hotwire-tmp" "$PIN_PLUGIN" "the Hotwire plugin"
    local v; v="$(grep -oE '\[Info\("Hotwire", *"[^"]*", *"[^"]+"\)\]' "$p.hotwire-tmp" | grep -oE '"[0-9][^"]*"\)' | tr -d '")')"
    [ -n "$v" ] || { rm -f "$p.hotwire-tmp"; die "checking the downloaded Hotwire.cs" "it is not the Hotwire plugin" "nothing was written; please report this"; }
    mv -f "$p.hotwire-tmp" "$p"; own "$p"
    rec_add created "$p"
    ok "Hotwire plugin $v written to oxide/plugins"
    note "        Oxide compiles it the first time the server starts."
    change "created $p (Hotwire $v)" "delete $p"
    save_step plugin
}

# One unit per server folder, so two servers on one machine are two services.
unit_name() { printf 'rust-%s.service' "$(basename "$IROOT" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/-*$//')"; }

step_service() {
    step "Service"
    local unit; unit="$(unit_name)"
    local path="/etc/systemd/system/$unit"
    if [ -f "$path" ]; then ok "$unit is already set up -- kept"; save_step service; return 0; fi
    if [ ! -f "$IROOT/hotwire.sh" ]; then note "Skipped: there is no hotwire.sh for a service to start."; return 0; fi
    why "A systemd service starts hotwire.sh when this machine boots, as $IUSER, and keeps its output in" \
        "the journal. It is switched on for boot, and NOT started now." "" \
        "  start:  sudo systemctl start ${unit%.service}" \
        "  stop:   sudo systemctl stop ${unit%.service}" \
        "  watch:  sudo journalctl -u ${unit%.service} -f" "" \
        "Restart=on-failure, not always: hotwire.sh restarts the server itself, and stops on purpose" \
        "after a crash streak -- 'always' would undo that protection."
    offer service "Start this server with the machine?" || { note "Skipped. Start it with: sudo -u $IUSER $IROOT/hotwire.sh"; return 0; }
    cat > "$path.hotwire-tmp" <<UNIT
# Written by hotwire-setup for the Rust server in $IROOT.
[Unit]
Description=Rust dedicated server ($IROOT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$IUSER
WorkingDirectory=$IROOT
ExecStart=$IROOT/hotwire.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65535
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
UNIT
    mv -f "$path.hotwire-tmp" "$path"
    systemctl daemon-reload && systemctl enable "$unit" >/dev/null 2>&1 \
        || die "switching on $unit" "systemctl could not enable it" "see 'systemctl status $unit'"
    ok "$unit is set up and switched on for boot (not started)"
    change "created $path and enabled it" "sudo systemctl disable --now ${unit%.service} && sudo rm $path && sudo systemctl daemon-reload"
    save_step service
}

step_firewall() {
    step "Firewall"
    if [ "$(ufw_state)" != active ]; then note "ufw is not on; nothing to open here. If your host has a firewall, open UDP ${PORT_GAME:-28015} and ${PORT_QUERY:-28017} there."; return 0; fi
    [ -n "$PORT_GAME" ] || choose_ports
    why "ufw is on, so players reach this server only through ports it lets in:" \
        "  UDP $PORT_GAME   the game" \
        "  UDP $PORT_QUERY   the server browser -- without it the server is invisible" \
        "" "RCON (TCP $PORT_RCON) is deliberately not opened: it is remote control of the server. Reach it" \
        "over SSH, or allow only your own address: sudo ufw allow from YOUR.IP to any port $PORT_RCON proto tcp"
    local need=()
    ufw_allows "$PORT_GAME" udp || need+=("$PORT_GAME")
    ufw_allows "$PORT_QUERY" udp || need+=("$PORT_QUERY")
    [ "${#need[@]}" -gt 0 ] || { ok "both ports are already open"; return 0; }
    confirm "Open UDP ${need[*]} in ufw?" || { note "Left as it is. Players cannot reach the server until they are open."; return 0; }
    local p
    for p in "${need[@]}"; do
        ufw allow "$p/udp" comment "Rust ($IROOT)" >/dev/null && ok "opened UDP $p" \
            && change "opened UDP $p in ufw" "sudo ufw delete allow $p/udp"
    done
}

step_panel() {
    step "Hotwire Panel"
    if [ -f "$(state_file "$IROOT")" ]; then ok "connected already -- 'status' shows the details"; return 0; fi
    why "Hotwire Panel shows this server from anywhere: whether it is up, its players, its logs, and the" \
        "restarts and updates it has done. The server never needs it -- if the panel is slow or gone," \
        "the server still starts, restarts and updates." "" \
        "You need a free account and a code from it; this waits while you get one."
    offer panel "Connect this server to Hotwire Panel?" || { note "Skipped. Connect any time: sudo -u $IUSER $IROOT/hotwire-setup.sh connect"; return 0; }
    # connect is its own run, as the server's user, so a mistyped or expired code ends only that run and
    # never the finished install around it.
    local args=(connect --root "$IROOT" --yes)
    [ -n "$PANEL" ] && args+=(--panel "$PANEL")
    # 8>&- : the install's machine-wide lock stays with the install, not with a connect left waiting for a code.
    if as_user bash "$IROOT/hotwire-setup.sh" "${args[@]}" 8>&-; then save_step panel
    else warn "not connected this time. Try again any time: sudo -u $IUSER $IROOT/hotwire-setup.sh connect"; fi
}

# The setup script stays in the server folder, for doctor, connect, status and detach later.
place_setup() {
    local dst="$IROOT/hotwire-setup.sh" src="${BASH_SOURCE[0]:-}"
    [ -f "$dst" ] && return 0
    if [ -n "$src" ] && [ -f "$src" ] && head -c 4096 "$src" | grep -q 'hotwire-setup'; then
        cp "$src" "$dst.hotwire-tmp"
    else
        # Run through a pipe (curl | bash): there is no file to copy, so the same script is fetched.
        fetch "$SETUP_URL" "$dst.hotwire-tmp" "hotwire-setup.sh"
        head -c 4096 "$dst.hotwire-tmp" | grep -q 'hotwire-setup' || { rm -f "$dst.hotwire-tmp"; warn "the fetched hotwire-setup.sh is not this script; not kept"; return 0; }
    fi
    chmod 755 "$dst.hotwire-tmp" && mv -f "$dst.hotwire-tmp" "$dst" && own "$dst" && rec_add created "$dst"
    ok "hotwire-setup.sh kept in $IROOT, for doctor, connect and detach later"
    change "created $dst" "delete it"
}

show_finish() {
    local ready=0
    if [ "${S[rust_done]}" = 1 ] && { { [ "${S[launcher]}" = 1 ] && [ -z "${S[rcon]}" ]; } || [ "${S[launcher_no]}" = 1 ]; }; then ready=1; fi
    if [ "$ready" = 1 ]; then box "$C_GRN" "A L L   S Y S T E M S   G O" "" "This Rust server is ready to start."
    else box "$C_YEL" "N O T   R E A D Y   Y E T" "" "The pre-flight lines above say what is left."; fi
    say ""
    if [ "${S[launcher]}" = 1 ]; then
        say "  ${C_BLD}Next:${C_OFF}"
        say "    1. Name your server. Open hotwire.sh and fill in SERVER_HOSTNAME and SERVER_DESCRIPTION"
        say "       (and SERVER_MAXPLAYERS if you want); each setting is explained beside it:"
        say "         sudo -u $IUSER nano $IROOT/hotwire.sh"
        if [ "${S[service]}" = 1 ]; then
            say "    2. Start it:   sudo systemctl start ${S[unit]%.service}"
            say "       Watch it:   sudo journalctl -u ${S[unit]%.service} -f"
        else
            say "    2. Start it:   sudo -u $IUSER $IROOT/hotwire.sh"
        fi
        say ""
        note "  The first start takes several minutes while the map generates."
    elif [ "${S[rust]}" = 1 ]; then
        say "  Start the server with your own start script. hotwire.sh is here any time: run install again."
    fi
    note "  Run install again any time; the pre-flight decides what is left to do."
    [ -f "$(changes_log)" ] && note "  Every change install has made, and how to undo it: $(changes_log)"
}

# ------------------------------------------------------------- the folder --
choose_folder() {
    if [ -n "$ROOT" ]; then IROOT="$ROOT"
    elif [ -f "$(pwd)/hotwire/install.json" ] || [ -x "$(pwd)/RustDedicated" ]; then IROOT="$(pwd)"
    else IROOT="/home/$IUSER/server"; fi
    case "$IROOT" in /*) ;; *) IROOT="$(pwd)/$IROOT" ;; esac
    IROOT="${IROOT%/}"
    # Somewhere a server belongs: not the system's own folders, and never a path the launcher's
    # settings or a unit file could misread.
    case "$IROOT" in
        /|/bin*|/boot*|/dev*|/etc*|/lib*|/proc*|/root|/run*|/sbin*|/sys*|/tmp*|/usr*|/var/lib*|/home)
            die "installing into $IROOT" "that is one of the system's own folders" "choose a folder of its own, for example /home/$IUSER/server" ;;
    esac
    [[ "$IROOT" =~ ^[A-Za-z0-9_./-]+$ ]] || die "installing into $IROOT" "the path has a space or a symbol in it" \
        "choose a folder whose name is only letters, digits, dot, dash and underscore"
    # A guest does not touch the resident's server: a Rust server this script did not install is refused.
    if [ -e "$IROOT/RustDedicated" ] && [ ! -f "$IROOT/hotwire/install.json" ]; then
        die "installing into $IROOT" "a Rust server is already there, installed some other way" \
            "this installer never changes a server it did not install. To connect that one: $0 connect --root $IROOT"
    fi
    if [ -d "$IROOT" ] && [ ! -f "$IROOT/hotwire/install.json" ] && [ -n "$(ls -A "$IROOT" 2>/dev/null)" ]; then
        warn "$IROOT is not empty, and nothing here was installed by this script"
        confirm "Install into it anyway? Nothing already in it is changed or removed." \
            || die "installing into $IROOT" "you chose not to use a folder with other things in it" "run install again with --root and an empty folder"
    fi
}

registry_add() {
    mkdir -p "$(dirname "$REGISTRY")"
    grep -qx "$IROOT" "$REGISTRY" 2>/dev/null || printf '%s\n' "$IROOT" >> "$REGISTRY"
}

cmd_install() {
    [ "$(id -u)" = 0 ] || die "installing a Rust server" "this is not running as root" \
        "run it with sudo: it installs packages, adds a user and a service. The server itself never runs as root."
    ASSUME_YES=0   # install asks at every step; --yes is for connect and detach
    [ -n "$USER_OPT" ] && IUSER="$USER_OPT"
    [[ "$IUSER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [ "$IUSER" != root ] || die "choosing the account the server runs as" \
        "'$IUSER' is not a usable account name" "pass --user with a lower-case name, not root"
    command -v python3 >/dev/null 2>&1 || die "starting install" "python3 is not installed" "sudo apt install python3, then run install again"
    command -v flock >/dev/null 2>&1 || die "starting install" "flock (util-linux) is not installed" "sudo apt install util-linux, then run install again"
    os_ok || die "installing on $(os_name)" "this installer is written for Ubuntu" "follow the guide by hand: $GUIDE_URL"

    # One install at a time on a machine: two would run two SteamCMDs over the same files.
    exec 8>/run/lock/hotwire-setup.lock
    flock -n 8 || die "starting install" "another hotwire-setup install is running on this machine" "wait for it to finish, then run install again"

    # Ctrl+C stops the install, and says so. Without this, stopping SteamCMD mid-download read as
    # SteamCMD failing, and the retry started the download again under the person trying to stop it.
    trap 'printf "\n"; warn "Stopped. Nothing is half-written: run install again to carry on from here."; exit 130' INT TERM

    banner
    choose_folder
    # The record lives in the folder; until the user exists, a first run keeps nothing there.
    if id "$IUSER" >/dev/null 2>&1; then as_user mkdir -p "$IROOT/hotwire" 2>/dev/null || true; fi
    find "$IROOT" -maxdepth 4 -name '*.hotwire-tmp' -delete 2>/dev/null

    gather
    show_state "Pre-flight"
    plan
    local names; names="$(declined_names)"
    if [ -n "$names" ]; then
        say ""; note "  Left out, as you chose: $names"
        if confirm "Ask about those again?"; then
            rec_py 'r["declined"] = []; out["write"] = 1' >/dev/null 2>&1; gather; plan
        fi
    fi
    show_plan
    if [ "${#PLAN[@]}" -eq 0 ]; then
        say ""; ok "Nothing to do: this server is installed."; say ""; show_finish; return 0
    fi
    [ "${S[running]}" = 1 ] && { in_plan rust || in_plan oxide; } && die "installing into $IROOT" "the server in this folder is running" "stop it first: sudo systemctl stop $(unit_name)"
    say ""
    confirm_default_yes "Go ahead?" || { say "  Nothing was changed."; return 0; }
    countdown 5 "Starting"

    STEP_TOTAL="${#PLAN[@]}"
    in_plan clock    && step_clock
    in_plan packages && step_packages
    in_plan user     && step_user
    # From here the folder exists and belongs to the server's user, so the record can be kept.
    as_user mkdir -p "$IROOT/hotwire" || die "creating $IROOT as $IUSER" "$IUSER could not create it" \
        "check that $(dirname "$IROOT") belongs to $IUSER: sudo chown $IUSER:$IUSER $(dirname "$IROOT")"
    [ -f "$(rec_file)" ] || { rec_set folder "$IROOT"; rec_set user "$IUSER"; }
    flush_changes
    registry_add
    in_plan swap     && step_swap
    in_plan rust     && step_rust
    in_plan oxide    && step_oxide
    in_plan launcher && step_launcher
    in_plan rcon     && step_rcon
    in_plan plugin   && step_plugin
    place_setup
    in_plan service  && step_service
    in_plan firewall && step_firewall
    in_plan panel    && step_panel

    gather
    show_state "Post-flight"
    show_finish
}

# ---------------------------------------------------------------- help ----
cmd_help() {
    cat <<'HELP'
hotwire-setup -- install a Rust server, and connect it to Hotwire Panel

  install   A Rust server on Ubuntu, from nothing: SteamCMD, Rust, Oxide, the start
            script, the RCON password, the plugin, a service, and the panel last.
            Run with sudo. Checks first, asks before every step, safe to run again.
  doctor    Check this machine: tools, signing, your server, the panel, the clock.
            Read-only, changes nothing, safe any time.
  connect   Connect to the panel. Asks for the code; no need to type it here.
  status    Show what this server is connected to.
  detach    Disconnect. Leaves the server running exactly as it is.

Options
  --root DIR    The Rust server directory (default: found from the current one;
                for install, /home/<user>/server)
  --user NAME   install: the account the server runs as (default: rust)
  --panel URL   The panel to talk to (default: recorded at connect)
  --yes, -y     connect and detach: do not ask for confirmation (install always asks)

Connecting is optional and reversible. Your server does not need a panel to run.
HELP
}

case "$CMD" in
    install) cmd_install ;;
    doctor)  cmd_doctor ;;
    connect) cmd_connect ;;
    status)  cmd_status ;;
    detach)  cmd_detach ;;
    help|--help|-h) cmd_help ;;
    *) cmd_help; exit 1 ;;
esac
