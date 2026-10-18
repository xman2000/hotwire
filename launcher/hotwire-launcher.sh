#!/usr/bin/env bash
#
# ==[ H O T W I R E ]===================================================
#  Hotwire launcher for Linux. Its version is HOTWIRE_LAUNCHER_VERSION below.
#  Built by xman2000 and Claude.  MIT License.
#  https://github.com/xman2000/hotwire
#
#  Your settings are in hotwire.cfg, beside this file, and an RCON
#  password, if you use RCON, in hotwire-secrets.cfg. This file holds no settings:
#  replace it with a newer release and nothing of yours changes.
#
#  Usage:
#    ./hotwire.sh          start (or resume) the supervised server
#    ./hotwire.sh check    check everything and report, but do not start
# ======================================================================

# --- Launcher identity. Not settings; do not edit.
#     The plugin reads these from oxide/data/Hotwire/launcher.json, which the
#     launcher writes before every start. The capability list decides which
#     features the plugin offers; settings_file says the settings are read from
#     hotwire.cfg. The plugin works out this file's code hash itself, and
#     AFKPanel compares it with the released launchers'; nothing waits on that
#     answer.
HOTWIRE_LAUNCHER_VERSION="1.1.27-linux"
HOTWIRE_LAUNCHER_CAPABILITIES="supervise,update,framework_verify,crash_backstop,log_rotate,convar_persist,wipe,wipe_same_map,wipe_custom_map,backup,settings_file,rcon_optional,stop_saves,wipe_permit,wipe_permit_blueprints,update_mode_set,update_progress,start_steps,self_update"

# ======================================================================
#  HOW THIS LAUNCHER WORKS
# ======================================================================
#
#   It keeps a Rust dedicated server running: it updates the game and
#   Oxide when told to, starts the server, restarts it when it exits,
#   and stops trying only when a server crashes over and over (so a
#   broken server does not thrash forever).
#
#   YOUR SETTINGS ARE DATA. hotwire.cfg and hotwire-secrets.cfg are read,
#   one "name value" line at a time, and never run: a line that is not a
#   setting is ignored and named by "./hotwire.sh check". Values reach Rust
#   as separate arguments, never through a shell, so no character in one
#   can break anything. The start-script converter on afkpanel.com makes a
#   hotwire.cfg from an old start script; it can never make code.
#
#   YOUR OWN COMMANDS go in hotwire-before.sh (run before every start) and
#   hotwire-after.sh (run after an update), beside this file. Copy the
#   .example files to begin. A hook that fails is logged, and the server
#   starts anyway; check mode runs no hook.
#
#   AFKPANEL NEVER REACHES IN. There is no inbound path: the plugin and the
#   launcher speak only through local files (UPDATE.flag / VALIDATE.flag,
#   WIPE.flag, CONVAR.request, BACKUP.flag). Once the server is connected, the
#   launcher also reports outward, signed with its own key: how a run ended,
#   the update outcome, and a crash-streak stop. A report that cannot be sent
#   waits on disk for the next try, and nothing about reporting can delay or
#   stop the server. Facts travel; files never do.
#
#   Requires: bash 4+, curl, unzip, and flock (util-linux); zstd for backups.
#   jq is used for the Oxide SHA-256 verification when present; without it
#   the download is taken unverified, with a warning.
#
#   Setup:
#     1. Copy hotwire.example.cfg to hotwire.cfg and fill in sections 1 and 2.
#     2. Only if you use an RCON tool: copy hotwire-secrets.example.cfg to
#        hotwire-secrets.cfg and set the RCON password. Without it RCON is off.
#     3. Keep hotwire.sh beside RustDedicated: its own folder is the server's.
#     4. Run ./hotwire.sh check, then ./hotwire.sh.
#
# ======================================================================

# ------------------------------------------------------ fixed, not settings ----
# Where code comes from is never a setting: hotwire.cfg is data that other tools
# may write, and data must never be able to say what gets downloaded or run.
# HOTWIRE_ROOT_OVERRIDE is set only by the launcher itself, when it checks a downloaded update against this server's
# settings before installing it (self_update_step): the copy runs from hotwire/self-update/stage/.
ROOT="${HOTWIRE_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
APPID="258550"
UPDATE_FLAG="UPDATE.flag"
VALIDATE_FLAG="VALIDATE.flag"
WIPE_FLAG="WIPE.flag"
FRAMEWORK_RELEASES="https://api.github.com/repos/OxideMod/Oxide.Rust/releases/latest"
FRAMEWORK_ASSET="Oxide.Rust-linux.zip"
FRAMEWORK_URL="https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust-linux.zip"
CFG="$ROOT/hotwire.cfg"
SECRETS_CFG="$ROOT/hotwire-secrets.cfg"
HOOK_BEFORE="$ROOT/hotwire-before.sh"
HOOK_AFTER="$ROOT/hotwire-after.sh"

# ---------------------------------------------- the defaults hotwire.cfg changes ----
# Every value here is what the launcher uses when hotwire.cfg leaves it out. They
# are set again before every read of the file, so a setting removed from it goes
# back to its default on the next start.
set_defaults() {
    SERVER_HOSTNAME=""; SERVER_DESCRIPTION=""; SERVER_TAGS=""; SERVER_MAXPLAYERS=""
    SERVER_IDENTITY=""; SERVER_SEED=""; SERVER_WORLDSIZE=""
    SERVER_PORT="28015"; SERVER_QUERYPORT="28017"; RCON_PORT="28016"
    SERVER_LEVEL="Procedural Map"; SERVER_LEVELURL=""; RCON_WEB="1"
    UPDATE_MODE="auto"
    STEAMCMD="/usr/games/steamcmd"; STEAM_BRANCH="public"
    MAX_DAYS_WITHOUT_UPDATE="14"; MAX_STEAM_TRIES="5"; STEAM_RETRY_SECONDS="60"; STEAMCMD_WAIT_MINUTES="60"; STEAMCMD_UPDATE_MINUTES="60"; FORCED_WIPE_STEAM_MINUTES="15"
    BUILD_CHECK_HOURS="6"; UPDATE_ON_NEW_BUILD="1"; FAST_RUST_UPDATES="0"; RECOVER_REFUSED_UPDATE="1"
    INSTALL_FRAMEWORK="1"; SKIP_UNCHANGED_FRAMEWORK="1"; VERIFY_FRAMEWORK="1"
    STOP_ASK_SECONDS="5"; STOP_SAVE_SECONDS="90"
    RESTART_ON_EXIT="1"; RESTART_DELAY="15"; CRASH_SECONDS="60"; MAX_CRASH_STREAK="10"; CRASH_BACKOFF="1"
    ROTATE_LOGS="1"; LOG_KEEP="14"; RCON_PASSWORD_MIN="8"; CHECK_OPTIONS="1"; BACKUPS="1"
    HOOK_TIMEOUT_MINUTES="30"
    SELF_UPDATE="off"; SELF_UPDATE_DAYS="3"; SELF_UPDATE_CHANNEL="release"
    EXTRA_CONVARS=()
}
set_defaults

set -uo pipefail

# ---------------------------------------------------------------- output ----
# Colour only when a human is looking; a log file, a pipe or systemd gets plain.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
    C_YEL=$'\033[33m'; C_CYN=$'\033[36m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BLD=""; C_OFF=""
fi

# Every runtime line carries a timestamp, as the .bat's "[%date% %time%]" does.
log()  { printf '%s[%s]%s %s\n' "$C_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_OFF" "$*"; update_line "$*"; }
ok()   { printf '%s[%s]%s %s[ ok ]%s %s\n'  "$C_DIM" "$(date '+%H:%M:%S')" "$C_OFF" "$C_GRN" "$C_OFF" "$*"; update_line "$*"; }
warn() { printf '%s[%s]%s %s[warn]%s %s\n'  "$C_DIM" "$(date '+%H:%M:%S')" "$C_OFF" "$C_YEL" "$C_OFF" "$*"; update_line "$*"; }
bad()  { printf '%s[%s]%s %s[fail]%s %s\n'  "$C_DIM" "$(date '+%H:%M:%S')" "$C_OFF" "$C_RED" "$C_OFF" "$*"; update_line "$*"; }
# What this start said about its update, for the session report, so AFKPanel can show why a start did or did not update.
# Only the launcher's own lines between the update decision and the end of the update; SteamCMD's output is not kept.
UPDATE_CAPTURE=0; UPDATE_LOG=(); UPDATE_REASON=""
update_line() {
    [ "$UPDATE_CAPTURE" = "1" ] && [ "${#UPDATE_LOG[@]}" -lt 40 ] || return 0
    local line; line="$(printf '%s' "$1" | LC_ALL=C sed 's/\x1b\[[0-9;]*m//g')"
    UPDATE_LOG+=( "$(printf '[%s] %s' "$(date '+%H:%M:%S')" "${line:0:300}")" )
}
# Why this start did not update, or the first thing that failed. The panel shows its own words for each code.
update_reason() { [ -z "$UPDATE_REASON" ] && UPDATE_REASON="$1"; return 0; }
rule() { printf '%s========================================================%s\n' "$C_BLD" "$C_OFF"; }

# A fatal stop. Under a service there is no keypress to wait for, so we do not
# pause; we print, and exit non-zero so the supervisor sees the failure.
die() {
    echo >&2
    rule >&2
    bad "$*" >&2
    rule >&2
    exit 1
}

# ------------------------------------------------------------- arguments ----
CHECK_ONLY=""
case "${1:-}" in
    check|--check) CHECK_ONLY=1 ;;
    "" ) ;;
    * ) die "Unknown argument '$1'. Use no argument to start, or 'check' to check without starting." ;;
esac



# ----------------------------------------------------- derived paths ----
LOGDIR="$ROOT/logs"
LOGFILE="$LOGDIR/server_log.txt"
UPDATE_STAMP="$LOGDIR/last_update.txt"
BUILD_CACHE="$LOGDIR/build_check.txt"
OXIDE_STAMP="$LOGDIR/oxide_installed.txt"
CONVAR_REQUEST="$ROOT/CONVAR.request"
CONVAR_RESULT="$ROOT/CONVAR.result"
UPDATE_MODE_REQUEST="$ROOT/UPDATE_MODE.request"
UPDATE_MODE_RESULT="$ROOT/UPDATE_MODE.result"
WIPE_STATE="$ROOT/hotwire/wipe-cycle"
WIPE_RESULT="$ROOT/WIPE.result"
BACKUP_FLAG="$ROOT/BACKUP.flag"
BACKUP_CONF="$ROOT/hotwire/backup.conf"
KEYS_FILE="$ROOT/hotwire/keys.json"
CONNECT_FILE="$ROOT/hotwire/connect.json"
SPOOL_DIR="$ROOT/hotwire/launcher-spool"
SPOOL_MAX=500
UPDATE_ATTEMPTED=0
UPDATE_FLAG_KEPT=0
STARTED_AT=""
# The SteamCMD lock coordinates servers that share one steamcmd. It must be
# writable by the server user and shared across that user's servers; /usr/games
# (beside steamcmd) is not writable, unlike Windows. Override for a box whose
# servers run as different users by pointing all of them at one shared path.
STEAM_LOCK="${HOTWIRE_STEAMCMD_LOCK:-$HOME/.hotwire/steamcmd.lock}"
RUST_BIN="$ROOT/RustDedicated"
APPMANIFEST="$ROOT/steamapps/appmanifest_${APPID}.acf"
LAUNCHER_STATE="$ROOT/oxide/data/Hotwire/launcher.json"

CRASH_STREAK=0

# ======================================================================
# Reading hotwire.cfg and hotwire-secrets.cfg.
#
# Read as data, one line at a time, and never run. A line is a name, spaces,
# then a value; a value with spaces is in double quotes and holds none inside;
# no control characters. Each value is checked for what it sets before it is
# used: a line that fails is ignored and named by check, and the default stays.
# The few settings a wrong default would turn into a different server -- the
# save folder, the map and the ports -- are not defaulted: a bad one stops the
# first start, and on a later restart the last good settings are kept.
# ======================================================================

# hotwire.<name> -> "<VARIABLE> <kind>"
declare -A HW_SETTINGS=(
    [hotwire.update_mode]="UPDATE_MODE mode"
    [hotwire.steamcmd]="STEAMCMD steamcmd"
    [hotwire.steam_branch]="STEAM_BRANCH word"
    [hotwire.max_days_without_update]="MAX_DAYS_WITHOUT_UPDATE int"
    [hotwire.update_on_new_build]="UPDATE_ON_NEW_BUILD bool"
    [hotwire.fast_rust_updates]="FAST_RUST_UPDATES bool"
    [hotwire.recover_refused_update]="RECOVER_REFUSED_UPDATE bool"
    [hotwire.build_check_hours]="BUILD_CHECK_HOURS int"
    [hotwire.steam_tries]="MAX_STEAM_TRIES int1"
    [hotwire.steam_retry_seconds]="STEAM_RETRY_SECONDS int"
    [hotwire.steamcmd_wait_minutes]="STEAMCMD_WAIT_MINUTES int"
    [hotwire.steamcmd_update_minutes]="STEAMCMD_UPDATE_MINUTES int"
    [hotwire.stop_ask_seconds]="STOP_ASK_SECONDS int"
    [hotwire.stop_save_seconds]="STOP_SAVE_SECONDS int"
    [hotwire.forced_wipe_steam_minutes]="FORCED_WIPE_STEAM_MINUTES int"
    [hotwire.install_framework]="INSTALL_FRAMEWORK bool"
    [hotwire.skip_unchanged_framework]="SKIP_UNCHANGED_FRAMEWORK bool"
    [hotwire.verify_framework]="VERIFY_FRAMEWORK bool"
    [hotwire.restart_on_exit]="RESTART_ON_EXIT bool"
    [hotwire.restart_delay]="RESTART_DELAY int"
    [hotwire.crash_seconds]="CRASH_SECONDS int"
    [hotwire.max_crash_streak]="MAX_CRASH_STREAK int"
    [hotwire.crash_backoff]="CRASH_BACKOFF bool"
    [hotwire.rotate_logs]="ROTATE_LOGS bool"
    [hotwire.log_keep]="LOG_KEEP int1"
    [hotwire.rcon_password_min]="RCON_PASSWORD_MIN int1"
    [hotwire.check_options]="CHECK_OPTIONS bool"
    [hotwire.backups]="BACKUPS bool"
    [hotwire.hook_timeout_minutes]="HOOK_TIMEOUT_MINUTES int1"
    [hotwire.self_update]="SELF_UPDATE selfupdate"
    [hotwire.self_update_days]="SELF_UPDATE_DAYS int"
    [hotwire.self_update_channel]="SELF_UPDATE_CHANNEL channel"
)
# Rust convars the launcher itself reads -> "<VARIABLE> <kind>". "critical" kinds
# are never defaulted when a line fails (see above).
declare -A CV_SETTINGS=(
    [server.hostname]="SERVER_HOSTNAME text"
    [server.description]="SERVER_DESCRIPTION text"
    [server.tags]="SERVER_TAGS tags"
    [server.maxplayers]="SERVER_MAXPLAYERS int"
    [server.identity]="SERVER_IDENTITY identity"
    [server.seed]="SERVER_SEED seed"
    [server.worldsize]="SERVER_WORLDSIZE worldsize"
    [server.port]="SERVER_PORT port"
    [server.queryport]="SERVER_QUERYPORT port"
    [rcon.port]="RCON_PORT port"
    [server.level]="SERVER_LEVEL text"
    [server.levelurl]="SERVER_LEVELURL url"
    [rcon.web]="RCON_WEB bool"
)

CFG_PROBLEMS=()   # "line N: name: why" for every line that was not used
CFG_FATAL=()      # the ones that stop a start
CFG_UNKNOWN=()    # convar names not in the file's own list, for the option check
CFG_REPORT=()     # the same problems for AFKPanel: "line<TAB>setting<TAB>critical 0|1<TAB>what", in launcher.json

# cfg_line <text> -> CFG_NAME, CFG_VALUE; or CFG_WHY and a non-zero return.
cfg_line() {
    local l="$1" v
    CFG_NAME=""; CFG_VALUE=""; CFG_WHY=""
    if ! [[ "$l" =~ ^([A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+)([[:space:]]+(.*))?$ ]]; then
        CFG_WHY="not a setting: a name, a space, then a value"; return 1
    fi
    CFG_NAME="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[4]}"
    v="${v%"${v##*[![:space:]]}"}"
    if [[ "$v" == '"'* ]]; then
        if [[ "$v" =~ ^\"([^\"]*)\"$ ]]; then v="${BASH_REMATCH[1]}"
        else CFG_WHY="a quoted value must start and end with a double quote, and hold none inside"; return 1; fi
    elif [[ "$v" == *[[:space:]]* ]]; then CFG_WHY="a value with spaces must be in double quotes"; return 1
    elif [[ "$v" == *'"'* ]]; then CFG_WHY="a double quote inside the value"; return 1
    fi
    if [[ "$v" =~ [[:cntrl:]] ]]; then CFG_WHY="a control character in the value"; return 1; fi
    [ "${#v}" -gt 1024 ] && { CFG_WHY="longer than 1024 characters"; return 1; }
    CFG_VALUE="$v"; return 0
}

# cfg_check <kind> <value> -> 0, or CFG_WHY and a non-zero return. An empty value
# always passes: it means "the default".
cfg_check() {
    local kind="$1" v="$2"
    CFG_WHY=""
    [ -z "$v" ] && return 0
    case "$kind" in
        int)   [[ "$v" =~ ^[0-9]{1,9}$ ]] || CFG_WHY="must be a whole number" ;;
        int1)  { [[ "$v" =~ ^[0-9]{1,9}$ ]] && [ "$v" -ge 1 ]; } || CFG_WHY="must be a whole number of 1 or more" ;;
        bool)  [[ "$v" =~ ^[01]$ ]] || CFG_WHY="must be 0 or 1" ;;
        mode)  [[ "$v" =~ ^(auto|always|hotwire|off)$ ]] || CFG_WHY="must be auto, always, hotwire or off" ;;
        selfupdate) [[ "$v" =~ ^(auto|off)$ ]] || CFG_WHY="must be auto or off" ;;
        channel) [[ "$v" =~ ^(release|dev)$ ]] || CFG_WHY="must be release or dev" ;;
        word)  [[ "$v" =~ ^[A-Za-z0-9_.-]+$ ]] || CFG_WHY="letters, digits, _ . - only" ;;
        steamcmd) { [[ "$v" == /* ]] && [[ "$(basename "$v")" =~ ^steamcmd(\.sh)?$ ]]; } || CFG_WHY="must be a full path to steamcmd or steamcmd.sh" ;;
        text)  : ;;
        tags)  [[ "$v" =~ ^[A-Za-z0-9,_-]+$ ]] || CFG_WHY="tags separated by commas, with no spaces" ;;
        identity) [[ "$v" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || CFG_WHY="letters, digits, _ and - only: it names a folder" ;;
        seed)  { [[ "$v" =~ ^[0-9]{1,10}$ ]] && [ "$v" -le 2147483647 ]; } || CFG_WHY="must be a whole number from 0 to 2147483647" ;;
        worldsize) { [[ "$v" =~ ^[0-9]{4}$ ]] && [ "$v" -ge 1000 ] && [ "$v" -le 6000 ]; } || CFG_WHY="must be a whole number from 1000 to 6000" ;;
        port)  { [[ "$v" =~ ^[0-9]{1,5}$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ]; } || CFG_WHY="must be a port number from 1 to 65535" ;;
        url)   [[ "$v" =~ ^https?://[^[:space:]]+$ ]] || CFG_WHY="must be an http:// or https:// address" ;;
        *)     CFG_WHY="unknown kind $kind" ;;
    esac
    [ -z "$CFG_WHY" ]
}

# The settings that turn into a different server when defaulted.
cfg_critical() { case "$1" in identity|seed|worldsize|port|url) return 0 ;; esac; return 1; }

# cfg_note <line> <setting> <critical 0|1> <what>: one line that is not used as written, for check and for AFKPanel.
cfg_note() {
    CFG_PROBLEMS+=("line $1: ${2:+$2: }$4")
    CFG_REPORT+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4")
}

# load_config: read hotwire.cfg into the settings. Returns non-zero when a
# critical line failed (CFG_FATAL), in which case nothing is changed.
load_config() {
    CFG_PROBLEMS=(); CFG_FATAL=(); CFG_UNKNOWN=(); CFG_REPORT=()
    if [ ! -f "$CFG" ]; then
        CFG_FATAL+=("hotwire.cfg is missing")
        return 1
    fi
    local -A staged=() extra=() known=() used=()
    local -a order=()
    local n=0 raw line name lower spec var kind listed=1 crit
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n+1))
        line="${raw%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        # The file's own list is every name above its OTHER CONVARS heading, on or
        # off (#name value): what the option check knows as spelled right. Names
        # added below it are the ones worth a second look.
        [[ "$line" == '#'*'OTHER CONVARS'* ]] && listed=0
        if [[ "$line" =~ ^#([A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+)[[:space:]] ]]; then
            [ "$listed" = 1 ] && known[${BASH_REMATCH[1],,}]=1; continue
        fi
        [ -z "$line" ] && continue
        [[ "$line" == '#'* ]] && continue
        if ! cfg_line "$line"; then
            # A line whose value cannot be read is not used, so a setting it names keeps its default. For the settings
            # that decide which server this is (save folder, map, ports) that is a different server, so it is marked.
            crit=0; spec=""
            [ -n "$CFG_NAME" ] && spec="${HW_SETTINGS[${CFG_NAME,,}]:-${CV_SETTINGS[${CFG_NAME,,}]:-}}"
            if [ -n "$spec" ]; then
                cfg_critical "${spec#* }" && crit=1
                cfg_note "$n" "$CFG_NAME" "$crit" "$CFG_WHY; the line is not used, so the default is"
            else
                cfg_note "$n" "$CFG_NAME" 0 "$CFG_WHY"
            fi
            continue
        fi
        name="$CFG_NAME"; lower="${name,,}"
        [ "$listed" = 1 ] && known[$lower]=1
        if [ "$lower" = "rcon.password" ]; then
            cfg_note "$n" rcon.password 0 "belongs in hotwire-secrets.cfg, never here; ignored"; continue
        fi
        spec="${HW_SETTINGS[$lower]:-${CV_SETTINGS[$lower]:-}}"
        if [ -n "$spec" ]; then
            var="${spec%% *}"; kind="${spec#* }"
            if ! cfg_check "$kind" "$CFG_VALUE"; then
                if cfg_critical "$kind"; then
                    CFG_FATAL+=("line $n: $name: $CFG_WHY")
                    CFG_REPORT+=("$n"$'\t'"$name"$'\t'1$'\t'"$CFG_WHY; the settings from the last good read are used")
                else cfg_note "$n" "$name" 0 "$CFG_WHY; the default is used"; fi
                continue
            fi
            # A number goes on in base 10: bash reads a leading zero as octal, so "08" would stop the launcher.
            case "$kind" in int|int1|seed|worldsize|port) [ -n "$CFG_VALUE" ] && CFG_VALUE="$((10#$CFG_VALUE))" ;; esac
            # For a launcher setting an empty value is its default, except the Steam branch, where empty means
            # "let Steam keep the last one". A server convar's empty value is the game's default, as the file says.
            if [ -z "$CFG_VALUE" ] && [ -n "${HW_SETTINGS[$lower]:-}" ] && [ "$kind" != word ]; then continue; fi
            # Set twice: the later line is the one used, and the one a wipe or a saved convar edits.
            if [ -n "${used[$lower]:-}" ]; then
                crit=0; cfg_critical "$kind" && crit=1
                cfg_note "$n" "$name" "$crit" "also set on line ${used[$lower]}; line $n is used"
            fi
            used[$lower]=$n
            staged[$var]="$CFG_VALUE"
            continue
        fi
        if [[ "$lower" == hotwire.* ]]; then
            cfg_note "$n" "$name" 0 "not a launcher setting; ignored"; continue
        fi
        # Any other Rust convar, passed through as it is. Empty means the default.
        [ -z "$CFG_VALUE" ] && continue
        [ -z "${extra[$lower]+x}" ] && order+=("$lower")
        [ -n "${used[$lower]:-}" ] && cfg_note "$n" "$name" 0 "also set on line ${used[$lower]}; line $n is used"
        used[$lower]=$n
        extra[$lower]="$name"$'\t'"$CFG_VALUE"
    done < "$CFG"
    [ "${#CFG_FATAL[@]}" -gt 0 ] && return 1

    set_defaults
    for var in "${!staged[@]}"; do printf -v "$var" '%s' "${staged[$var]}"; done
    EXTRA_CONVARS=()
    for lower in "${order[@]}"; do
        EXTRA_CONVARS+=( "+${extra[$lower]%%$'\t'*}" "${extra[$lower]#*$'\t'}" )
        [ -z "${known[$lower]+x}" ] && CFG_UNKNOWN+=("${extra[$lower]%%$'\t'*}")
    done
    ROOT="${ROOT%/}"; STEAMCMD="${STEAMCMD%/}"
    return 0
}

# What check prints, and what a start logs in one line.
report_config() {
    local p
    if [ "${#CFG_PROBLEMS[@]}" -eq 0 ]; then
        ok "hotwire.cfg read: every line is a setting."
    else
        warn "hotwire.cfg: ${#CFG_PROBLEMS[@]} line(s) not used:"
        for p in "${CFG_PROBLEMS[@]}"; do warn "  $p"; done
    fi
}

# First start: a missing file or a bad critical line stops here, with what to do.
config_or_die() {
    if load_config; then report_config; return 0; fi
    if [ ! -f "$CFG" ]; then
        die "No hotwire.cfg beside the launcher ($CFG).
  A new server: copy hotwire.example.cfg to hotwire.cfg and fill in sections 1 and 2.
  A server you already run: the start-script converter at https://afkpanel.com/get-started
  makes one from your old start script.
  Hotwire does not start without it: on the defaults it would open an empty save folder,
  which looks like a wipe."
    fi
    local p msg="hotwire.cfg has settings that would change which server this is, so it does not start:"
    for p in "${CFG_FATAL[@]}"; do msg+=$'\n'"  $p"; done
    die "$msg"
}

# A later restart: keep the last good settings rather than stop a server that ran.
# load_config changes nothing when it fails, so the last good values are still set.
config_reload() {
    if load_config; then
        [ "${#CFG_PROBLEMS[@]}" -gt 0 ] && warn "hotwire.cfg: ${#CFG_PROBLEMS[@]} line(s) not used; ./hotwire.sh check lists them."
        return 0
    fi
    rule
    bad "hotwire.cfg changed and is not usable now; starting with the settings from the last start:"
    local p; for p in "${CFG_FATAL[@]}"; do bad "  $p"; done
    rule
    return 0
}

# ======================================================================
# The RCON password, from hotwire-secrets.cfg. Read as data, like
# hotwire.cfg; only rcon.password is taken from it. Read before every start.
# It is optional: Hotwire does not use RCON, and Rust runs with RCON off when
# it is given no password. A password that is set but unusable (the example
# value, too short) leaves RCON off, or keeps the last good one, and says so;
# it never stops a start.
# ======================================================================
RCON_PASSWORD=""
load_secrets() {
    local raw line n=0 password="" why=""
    if [ ! -f "$SECRETS_CFG" ]; then
        RCON_PASSWORD=""
        log "RCON is off: no hotwire-secrets.cfg. Hotwire does not need RCON; set rcon.password there to turn it on."
        return 0
    else
        while IFS= read -r raw || [ -n "$raw" ]; do
            n=$((n+1))
            line="${raw%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"
            [ -z "$line" ] && continue
            [[ "$line" == '#'* ]] && continue
            if ! cfg_line "$line"; then warn "hotwire-secrets.cfg line $n: $CFG_WHY; ignored."; continue; fi
            if [ "${CFG_NAME,,}" = "rcon.password" ]; then password="$CFG_VALUE"
            else warn "hotwire-secrets.cfg line $n: $CFG_NAME: only rcon.password belongs here; ignored."; fi
        done < "$SECRETS_CFG"
        if [ -z "$password" ]; then
            RCON_PASSWORD=""
            log "RCON is off: hotwire-secrets.cfg sets no rcon.password."
            return 0
        elif [ "$password" = "change_me" ]; then why="rcon.password is still the example 'change_me'. Set a real one in hotwire-secrets.cfg."
        elif [ "${#password}" -lt "$RCON_PASSWORD_MIN" ]; then why="rcon.password is shorter than hotwire.rcon_password_min ($RCON_PASSWORD_MIN)."
        fi
    fi
    if [ -n "$why" ]; then
        rule; bad "$why"
        if [ -n "$RCON_PASSWORD" ]; then bad "Starting with the RCON password from the last start."
        else bad "Starting with RCON off until it is fixed."; fi
        rule
        return 0
    fi
    RCON_PASSWORD="$password"
    if [ -n "$(find "$SECRETS_CFG" -perm /o+r 2>/dev/null)" ]; then
        warn "hotwire-secrets.cfg can be read by every user on this machine. chmod 600 it."
    fi
}

# ======================================================================
# Pre-flight -- the server binary, the logs dir, and (Linux-only) the
# steamclient.so symlink the server needs to initialise Steam. Without
# it the server generates its map and then aborts with a Steam error
# that names nothing useful; hotwire.bat needs no equivalent because
# Windows resolves steamclient itself.
# ======================================================================
preflight() {
    [ -f "$RUST_BIN" ] || die "RustDedicated not found at $RUST_BIN. Install the server first (see INSTALL-LINUX)."
    mkdir -p "$LOGDIR" || die "Could not create $LOGDIR."
    mkdir -p "$(dirname "$STEAM_LOCK")" 2>/dev/null || true

    local home64="$HOME/.steam/sdk64/steamclient.so"
    local home32="$HOME/.steam/sdk32/steamclient.so"
    if [ ! -e "$home64" ] || [ ! -e "$home32" ]; then
        local src64="" src32=""
        for c in "$HOME/.local/share/Steam/steamcmd/linux64/steamclient.so" \
                 "$ROOT/steamclient.so" \
                 "$ROOT/RustDedicated_Data/Plugins/x86_64/steamclient.so"; do
            [ -f "$c" ] && { src64="$c"; break; }
        done
        src32="$HOME/.local/share/Steam/steamcmd/linux32/steamclient.so"
        mkdir -p "$HOME/.steam/sdk64" "$HOME/.steam/sdk32" 2>/dev/null || true
        [ -n "$src64" ] && [ ! -e "$home64" ] && ln -sf "$src64" "$home64" 2>/dev/null && ok "Linked steamclient.so (sdk64)."
        [ -f "$src32" ] && [ ! -e "$home32" ] && ln -sf "$src32" "$home32" 2>/dev/null && ok "Linked steamclient.so (sdk32)."
        if [ ! -e "$home64" ]; then
            warn "steamclient.so (64-bit) not found to link; the server may fail Steam init. Reinstall via steamcmd if boot aborts."
        fi
    fi
}

# ======================================================================
# The build check: is this install behind Steam? Reads the installed build
# id from the appmanifest, and the public build id from steamcmd (behind
# a non-blocking lock, cached). Any failure leaves both empty and decides
# nothing on its own -- fail toward starting the server.
# ======================================================================
INSTALLED_BUILD=""; PUBLIC_BUILD=""
read_installed_build() {
    INSTALLED_BUILD=""
    [ -f "$APPMANIFEST" ] || return 0
    # The first "buildid" "<n>" in the manifest is the installed build.
    INSTALLED_BUILD="$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$APPMANIFEST" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
}
read_public_build() {
    PUBLIC_BUILD=""
    [ "$BUILD_CHECK_HOURS" = "0" ] && return 0
    # Fresh cache wins -- except when flags decide updates outside a crash streak. Then the answer must be
    # today's: a cached "current" from before a Rust release would start the old build.
    local use_cache=1
    if [ "$UPDATE_EFFECTIVE" = "hotwire" ] && [ "$CRASH_STREAK" -eq 0 ] 2>/dev/null; then use_cache=0; fi
    if [ "$use_cache" = "1" ] && [ -f "$BUILD_CACHE" ]; then
        local age_h; age_h=$(( ( $(date +%s) - $(stat -c %Y "$BUILD_CACHE") ) / 3600 ))
        if [ "$age_h" -lt "$BUILD_CHECK_HOURS" ]; then
            PUBLIC_BUILD="$(tr -dc '0-9' < "$BUILD_CACHE" 2>/dev/null || true)"
            return 0
        fi
    fi
    [ -x "$STEAMCMD" ] || return 0
    # Non-blocking lock: if another server is using steamcmd, skip -- do not wait here.
    exec 9>"$STEAM_LOCK" || return 0
    if ! flock -n 9; then exec 9>&-; return 0; fi
    local out; out="$(timeout 180 "$STEAMCMD" +login anonymous +app_info_update 1 +app_info_print "$APPID" +quit 2>/dev/null || true)"
    exec 9>&-
    # Walk to the "branches" block, then our branch, then the FIRST buildid after it
    # (not the first buildid in the whole dump).
    local branch="${STEAM_BRANCH:-public}"
    PUBLIC_BUILD="$(printf '%s' "$out" | awk -v br="\"$branch\"" '
        idx==0 && /"branches"/ { idx=1 }
        idx==1 && $0 ~ br      { idx=2 }
        idx==2 && /"buildid"/  { if (match($0, /"buildid"[[:space:]]+"[0-9]+"/)) {
                                    s=substr($0, RSTART, RLENGTH); gsub(/[^0-9]/,"",s); print s; exit } }
    ')"
    [ -n "$PUBLIC_BUILD" ] && printf '%s' "$PUBLIC_BUILD" > "$BUILD_CACHE" 2>/dev/null || true
}
build_check() {
    read_installed_build
    read_public_build
    if [ -n "$INSTALLED_BUILD" ] && [ -n "$PUBLIC_BUILD" ]; then
        if [ "$INSTALLED_BUILD" = "$PUBLIC_BUILD" ]; then
            log "Rust build: installed $INSTALLED_BUILD, ${STEAM_BRANCH:-public} $PUBLIC_BUILD -- current."
        elif [ "$STEAM_BRANCH" = "public" ] && [ "$INSTALLED_BUILD" -gt "$PUBLIC_BUILD" ] 2>/dev/null; then
            # SteamCMD has answered with a build older than the installed public one (measured on Windows,
            # 2026-10-07), so an answer older than the install is not believed: it counts as not knowing.
            log "Rust build: installed $INSTALLED_BUILD, public $PUBLIC_BUILD. Steam's answer is older than this install,"
            log "and SteamCMD can answer with an old build, so whether this install is current is not known."
        elif [ "$INSTALLED_BUILD" -gt "$PUBLIC_BUILD" ] 2>/dev/null; then
            log "Rust build: installed $INSTALLED_BUILD is newer than ${STEAM_BRANCH:-public} $PUBLIC_BUILD (test branch?)."
        else
            rule; log "${C_YEL}A NEWER RUST BUILD IS AVAILABLE${C_OFF}: installed $INSTALLED_BUILD, ${STEAM_BRANCH:-public} $PUBLIC_BUILD."; rule
        fi
    elif [ -z "$INSTALLED_BUILD" ]; then
        log "Rust build: could not read the installed build id."
    else
        log "Rust build: Steam did not answer; continuing."
    fi
}

# ======================================================================
# Whether this start also updates.
# ======================================================================
DO_UPDATE=0; DO_VALIDATE=0
# Who decides updates on this pass. auto follows the Hotwire plugin: while it has an update scheduled it keeps
# UPDATE.schedule in the server's folder, rewritten every 15 minutes. A marker that is missing or over two hours
# old means nobody is scheduling updates, so this pass updates as always does: the direction that keeps a server
# joinable.
UPDATE_EFFECTIVE="always"
decide_update_mode() {
    UPDATE_EFFECTIVE="$UPDATE_MODE"
    [ "$UPDATE_MODE" = "auto" ] || return 0
    UPDATE_EFFECTIVE="always"
    local marker="$ROOT/UPDATE.schedule" age
    if [ -f "$marker" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$marker" 2>/dev/null || echo 0) ))
        [ "$age" -ge 0 ] && [ "$age" -lt 7200 ] && UPDATE_EFFECTIVE="hotwire"
    fi
    if [ "$UPDATE_EFFECTIVE" = "hotwire" ]; then
        log "hotwire.update_mode is auto: the Hotwire plugin schedules updates."
    else
        log "hotwire.update_mode is auto: no update schedule from the Hotwire plugin."
    fi
}

update_decision() {
    DO_UPDATE=0; DO_VALIDATE=0
    if [ "$UPDATE_EFFECTIVE" = "off" ]; then
        [ -e "$ROOT/$UPDATE_FLAG" ] && log "hotwire.update_mode is off; leaving $UPDATE_FLAG in place, not acting on it."
        update_reason mode_off
        return 0
    fi
    # A validate asked for (VALIDATE.flag) is carried out in every mode that updates.
    if [ -e "$ROOT/$VALIDATE_FLAG" ]; then log "$VALIDATE_FLAG found: updating and validating."; DO_UPDATE=1; DO_VALIDATE=1; return 0; fi
    [ "$UPDATE_EFFECTIVE" = "always" ] && { log "hotwire.update_mode is $UPDATE_MODE -- updating before launch."; DO_UPDATE=1; return 0; }

    # hotwire mode:
    if [ -e "$ROOT/$UPDATE_FLAG" ]; then DO_UPDATE=1; return 0; fi

    # Not knowing is not the same as current: a server left on an old build turns every player away after a
    # Rust release, so an unanswered question costs an update, never the server.
    if [ "$UPDATE_ON_NEW_BUILD" = "1" ] && { [ -z "$INSTALLED_BUILD" ] || [ -z "$PUBLIC_BUILD" ]; }; then
        log "Updating: the launcher could not tell whether this install is on Steam's current build."
        DO_UPDATE=1; return 0
    fi
    # A server set to public (not left empty) cannot be ahead of public: an older answer from Steam counts as not knowing.
    if [ "$UPDATE_ON_NEW_BUILD" = "1" ] && [ "$STEAM_BRANCH" = "public" ] \
       && [ "$INSTALLED_BUILD" -gt "$PUBLIC_BUILD" ] 2>/dev/null; then
        log "Updating: Steam answered public $PUBLIC_BUILD, older than installed $INSTALLED_BUILD, so the answer is not trusted."
        DO_UPDATE=1; return 0
    fi
    # New-build trigger.
    if [ "$UPDATE_ON_NEW_BUILD" = "1" ] && [ -n "$INSTALLED_BUILD" ] && [ -n "$PUBLIC_BUILD" ] \
       && [ "$INSTALLED_BUILD" != "$PUBLIC_BUILD" ] && [ "$INSTALLED_BUILD" -lt "$PUBLIC_BUILD" ] 2>/dev/null; then
        log "A newer build is available; updating."
        DO_UPDATE=1; return 0
    fi
    # Calendar backstop.
    if [ "$MAX_DAYS_WITHOUT_UPDATE" != "0" ]; then
        local days=9999
        [ -f "$UPDATE_STAMP" ] && days=$(( ( $(date +%s) - $(stat -c %Y "$UPDATE_STAMP") ) / 86400 ))
        if [ "$days" -ge "$MAX_DAYS_WITHOUT_UPDATE" ]; then
            rule; log "It has been $days days since the last update (backstop $MAX_DAYS_WITHOUT_UPDATE); updating."; rule
            DO_UPDATE=1
        fi
    fi
    [ "$DO_UPDATE" = "1" ] || update_reason not_needed
}

# ======================================================================
# SteamCMD, under a lock shared with every server on this machine, with a deadline.
# ======================================================================
STEAM_OK=0
# A forced wipe waits on this update: WIPE.flag says forced, its cycle is not done and it has not expired.
forced_wipe_waiting() {
    local flag="$ROOT/$WIPE_FLAG" cycle expires
    [ -f "$flag" ] && grep -q '^forced 1' "$flag" 2>/dev/null || return 1
    cycle="$(grep -m1 '^cycle ' "$flag" | awk '{print $2}')"; expires="$(grep -m1 '^expires ' "$flag" | awk '{print $2}')"
    [ -n "$cycle" ] && [ "$(cat "$WIPE_STATE" 2>/dev/null)" = "$cycle" ] && return 1
    [ -n "$expires" ] && [ "$expires" -lt "$(date +%s)" ] 2>/dev/null && return 1
    return 0
}
# Fast Rust updates. Steam updates a game by patching the files on disk, and Oxide has replaced some of them, so on
# a modded server Steam's first try at a new build stops with "Corrupt game files" (state 0x486). Steam then marks
# the install Files Corrupt in steamapps/appmanifest_<appid>.acf ("StateFlags", bit 128), and its next run checks
# every file first and succeeds. Marking it before the first run saves the failed try. The manifest is Steam's own
# and undocumented: only one exact line is changed, the edit is checked before it is used, a copy is kept, and if
# Steam ever ignores the mark the update simply takes its usual second try (manifest_marked_corrupt below).
mark_manifest_for_check() {
    [ "$FAST_RUST_UPDATES" = "1" ] || return 0
    [ "$INSTALL_FRAMEWORK" = "1" ] || return 0                     # nothing of Oxide's to trip over
    [ -n "$INSTALLED_BUILD" ] && [ -n "$PUBLIC_BUILD" ] || return 0
    [ "$INSTALLED_BUILD" -lt "$PUBLIC_BUILD" ] 2>/dev/null || return 0   # only an update that changes the build
    [ -f "$APPMANIFEST" ] || return 0
    local pattern='^[[:space:]]*"StateFlags"[[:space:]]+"4"[[:space:]]*$'
    if [ "$(grep -cE "$pattern" "$APPMANIFEST")" != "1" ]; then
        log "Fast Rust updates: Steam's install record is not in the expected form; leaving it to Steam."
        return 0
    fi
    local tmp="$APPMANIFEST.hotwire-tmp"
    sed -E 's/^([[:space:]]*"StateFlags"[[:space:]]+")4("[[:space:]]*)$/\1132\2/' "$APPMANIFEST" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    # Exactly one line may differ, and it must be the one meant.
    if [ "$(diff "$APPMANIFEST" "$tmp" | grep -c '^[<>]')" != "2" ] || ! grep -qE '^[[:space:]]*"StateFlags"[[:space:]]+"132"[[:space:]]*$' "$tmp"; then
        rm -f "$tmp"; log "Fast Rust updates: Steam's install record could not be changed; leaving it to Steam."
        return 0
    fi
    mkdir -p "$ROOT/hotwire" 2>/dev/null; cp -p "$APPMANIFEST" "$ROOT/hotwire/appmanifest-before-update.acf" 2>/dev/null || true   # outside steamapps, where Steam never reads it
    mv -f "$tmp" "$APPMANIFEST" || { rm -f "$tmp"; return 0; }
    log "Fast Rust updates: Steam will check every game file before this update, so it finishes in one try."
}
# Steam itself marks the install Files Corrupt after a failed try; its next try checks every file and succeeds.
manifest_marked_corrupt() {
    local flags
    flags="$(grep -oE '"StateFlags"[[:space:]]+"[0-9]+"' "$APPMANIFEST" 2>/dev/null | head -1 | grep -oE '"[0-9]+"' | tr -d '"' || true)"
    [ -n "$flags" ] && [ $(( flags & 128 )) -ne 0 ] 2>/dev/null
}
# A refused update. To patch, SteamCMD needs the file lists (depot manifests) of the build installed. It reads them from
# its cache and asks Steam only on a miss, and Steam refuses an old Rust build's lists to an anonymous login ("Failed to
# get manifest request code, 'Access Denied'", then "No connection"). The cache is shared by every server that uses this
# SteamCMD, so one server's update can leave another, still on the old build, unable to update. Without Steam's install
# record SteamCMD checks the files on disk against the new build and downloads what differs (about 0.8 GB and 133 s,
# measured on one server). Only SteamCMD's own log says why a run failed, so the part one run added to it is read while
# this launcher still holds the SteamCMD lock: no other server's run is in it.
STEAM_LOG_SIZES=(); INSTALLED_MANIFESTS=""; RECOVERY_SAVED=""
steam_content_logs() {
    printf '%s\n' "$HOME/.local/share/Steam/logs/content_log.txt" "$HOME/Steam/logs/content_log.txt" \
        "$(dirname "$STEAMCMD")/logs/content_log.txt"
}
note_steam_logs() {
    STEAM_LOG_SIZES=()
    local f
    while IFS= read -r f; do STEAM_LOG_SIZES+=( "$(stat -c %s "$f" 2>/dev/null || echo 0)" ); done < <(steam_content_logs)
    INSTALLED_MANIFESTS="$(grep -oE '"manifest"[[:space:]]+"[0-9]+"' "$APPMANIFEST" 2>/dev/null | grep -oE '[0-9]+' | sort -u | tr '\n' ' ' || true)"
}
# True when the run just finished was refused a file list of the build installed: the case a missing record mends.
update_refused_installed() {
    [ -n "$INSTALLED_MANIFESTS" ] || return 1
    local f i=0 before size denied m
    while IFS= read -r f; do
        before="${STEAM_LOG_SIZES[$i]:-0}"; i=$((i+1))
        size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        [ "$size" -gt 0 ] 2>/dev/null || continue
        [ "$size" -lt "$before" ] 2>/dev/null && before=0              # Steam started a new log
        [ "$size" -gt "$before" ] 2>/dev/null || continue
        denied="$(tail -c +"$((before+1))" "$f" 2>/dev/null | head -c 4194304 \
            | grep -F "Failed to get manifest request code, 'Access Denied'" \
            | grep -oE 'Manifest: [0-9]+' | grep -oE '[0-9]+' | sort -u || true)"
        for m in $denied; do
            case " $INSTALLED_MANIFESTS " in *" $m "*) return 0 ;; esac
        done
    done < <(steam_content_logs)
    return 1
}
set_record_aside() {
    [ "$RECOVER_REFUSED_UPDATE" = "1" ] && [ -f "$APPMANIFEST" ] || return 1
    mkdir -p "$ROOT/hotwire" 2>/dev/null || return 1
    mv -f "$APPMANIFEST" "$ROOT/hotwire/appmanifest-refused.acf" 2>/dev/null || return 1
    RECOVERY_SAVED="$ROOT/hotwire/appmanifest-refused.acf"
    log "Steam no longer serves the installed Rust build's file list, so this update cannot patch it."
    log "Setting Steam's install record aside and updating again: Steam checks the files on disk and downloads what changed."
}
# After the update: keep Steam's new record when it finished, put the old one back when Steam left none it can use.
settle_record() {
    [ -n "$RECOVERY_SAVED" ] && [ -f "$RECOVERY_SAVED" ] || return 0
    if [ "$STEAM_OK" = "1" ]; then
        ok "The update finished without the old file list. The old install record is kept in hotwire/appmanifest-refused.acf."
        return 0
    fi
    local b; b="$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$APPMANIFEST" 2>/dev/null | head -1 | grep -oE '"[0-9]+"' | tr -d '"' || true)"
    if [ -z "$b" ] || [ "$b" = "0" ]; then
        cp -p "$RECOVERY_SAVED" "$APPMANIFEST" 2>/dev/null && warn "The update did not finish. Steam's install record is put back as it was."
    fi
}
steam_update() {
    RECOVERY_SAVED=""
    steam_update_attempts
    settle_record
    return 0
}
steam_update_attempts() {
    STEAM_OK=0
    if [ ! -x "$STEAMCMD" ]; then
        bad "SteamCMD is not at $STEAMCMD. Set hotwire.steamcmd in hotwire.cfg. Starting what is on disk."
        update_reason steamcmd_missing
        report_step steamcmd failed ",\"detail\":$(json_text "SteamCMD is not where hotwire.steamcmd says; the server starts on what is installed.")"
        return 0
    fi
    mark_manifest_for_check
    local quick_retry_used=0 recovery_used=0 refused=0
    # A forced wipe rides this update, and the old build cannot take players once their game has updated: keep trying
    # for hotwire.forced_wipe_steam_minutes before starting what is on disk (the server always starts in the end).
    local deadline=0
    if [ "${FORCED_WIPE_STEAM_MINUTES:-0}" -gt 0 ] 2>/dev/null && forced_wipe_waiting; then
        deadline=$(( $(date +%s) + FORCED_WIPE_STEAM_MINUTES * 60 ))
        log "A forced wipe waits on this update: trying SteamCMD for up to $FORCED_WIPE_STEAM_MINUTES min if it fails."
    fi
    local args=( +force_install_dir "$ROOT" +login anonymous +app_update "$APPID" )
    [ -n "$STEAM_BRANCH" ] && args+=( -beta "$STEAM_BRANCH" )
    [ "$DO_VALIDATE" = "1" ] && args+=( validate )
    args+=( +quit )

    local tries=0 of=""
    while :; do
        tries=$((tries+1))
        if [ "$deadline" -gt 0 ] && [ "$tries" -gt "$MAX_STEAM_TRIES" ]; then
            log "steamcmd update, attempt $tries (a forced wipe waits: trying until $(date -d "@$deadline" +%H:%M))..."
            report_update_progress steamcmd "$tries"
            of=""
        else
            log "steamcmd update, attempt $tries of $MAX_STEAM_TRIES..."
            report_update_progress steamcmd "$tries" "$MAX_STEAM_TRIES"
            of="$MAX_STEAM_TRIES"
        fi
        report_step steamcmd begun ",\"attempt\":$tries${of:+,\"of\":$of}"
        # Blocking lock, but bounded by STEAMCMD_WAIT_MINUTES so a stuck sibling
        # never holds this server down: past the deadline we start what we have.
        exec 8>"$STEAM_LOCK" || { warn "Could not open the steamcmd lock."; update_reason steamcmd_lock; return 0; }
        if flock -w $(( STEAMCMD_WAIT_MINUTES * 60 )) 8; then
            note_steam_logs
            # Bounded by hotwire.steamcmd_update_minutes (0: no limit): a SteamCMD that hangs would otherwise keep this
            # server down and hold the lock every other server on the machine waits for. timeout stops SteamCMD and the
            # program it starts (the whole process group).
            local rc limited=0
            if [ "${STEAMCMD_UPDATE_MINUTES:-0}" -gt 0 ] 2>/dev/null && command -v timeout >/dev/null 2>&1; then
                limited=1
                timeout --kill-after=30 $(( STEAMCMD_UPDATE_MINUTES * 60 )) "$STEAMCMD" "${args[@]}" | steam_progress "$tries" "$of"; rc=${PIPESTATUS[0]}
            else
                "$STEAMCMD" "${args[@]}" | steam_progress "$tries" "$of"; rc=${PIPESTATUS[0]}
            fi
            # timeout answers 124 when it stopped SteamCMD, 137 when SteamCMD needed killing after that.
            if [ "$limited" = 1 ] && { [ "$rc" = "124" ] || [ "$rc" = "137" ]; }; then
                exec 8>&-
                bad "SteamCMD did not finish within $STEAMCMD_UPDATE_MINUTES min (hotwire.steamcmd_update_minutes) and was stopped."
                warn "Starting what is on disk. The next update carries on from what was downloaded."
                update_reason steamcmd_timeout
                report_step steamcmd failed ",\"attempt\":$tries${of:+,\"of\":$of},\"detail\":$(json_text "SteamCMD did not finish within $STEAMCMD_UPDATE_MINUTES min and was stopped; the server starts on what is installed.")"
                return 0
            fi
            refused=0; [ "$rc" != "0" ] && update_refused_installed && refused=1
            exec 8>&-
            if [ "$rc" = "0" ]; then STEAM_OK=1; ok "steamcmd finished."; report_step steamcmd done ",\"attempt\":$tries${of:+,\"of\":$of}"; return 0; fi
            bad "steamcmd exited $rc."
            report_step steamcmd failed ",\"attempt\":$tries${of:+,\"of\":$of},\"exit_code\":$rc$( [ "$refused" = 1 ] && printf ',"detail":%s' "$(json_text "Steam no longer serves the installed Rust build's file list.")")"
        else
            exec 8>&-
            warn "Waited $STEAMCMD_WAIT_MINUTES min for another server's steamcmd; starting with what is on disk."
            update_reason steamcmd_busy
            report_step steamcmd failed ",\"attempt\":$tries${of:+,\"of\":$of},\"detail\":$(json_text "Another server on this machine used SteamCMD for $STEAMCMD_WAIT_MINUTES min; the server starts on what is installed.")"
            return 0
        fi
        # Once per update, a refusal of the installed build's file list is mended at once, whatever the try count:
        # every further try would be refused the same way.
        if [ "$refused" = "1" ] && [ "$recovery_used" = "0" ] && set_record_aside; then
            recovery_used=1
            report_step steamcmd progress ",\"attempt\":$tries${of:+,\"of\":$of},\"detail\":$(json_text "Steam's install record set aside: the next try checks the files on disk and downloads what changed.")"
            continue
        fi
        if [ "$tries" -ge "$MAX_STEAM_TRIES" ] && [ "$(date +%s)" -ge "$deadline" ]; then
            warn "steamcmd gave up after $tries attempts; starting what is on disk."
            update_reason steamcmd_failed
            report_step steamcmd failed ",\"attempt\":$tries${of:+,\"of\":$of},\"detail\":$(json_text "SteamCMD failed on every try; the server starts on what is installed.")"
            return 0
        fi
        # Once per update, a try that left the install marked Files Corrupt is retried at once: Steam checks every
        # file on that next run, so waiting changes nothing.
        if [ "$quick_retry_used" = "0" ] && manifest_marked_corrupt; then
            quick_retry_used=1
            log "Steam marked the game files for a full check; trying again now."
            report_step steamcmd progress ",\"attempt\":$tries${of:+,\"of\":$of},\"detail\":$(json_text "Steam marked the game files for a full check; trying again now.")"
            continue
        fi
        log "Retrying in $STEAM_RETRY_SECONDS s..."
        report_step steamcmd waiting ",\"attempt\":$tries${of:+,\"of\":$of},\"seconds\":$STEAM_RETRY_SECONDS"
        sleep "$STEAM_RETRY_SECONDS"
    done
}
# ======================================================================
# Oxide: install or refresh the Linux build, with a
# skip-when-unchanged optimisation and a GitHub SHA-256 verification.
# ======================================================================
FRAMEWORK_OK=0
have_json() { command -v jq >/dev/null 2>&1; }
framework_update() {
    FRAMEWORK_OK=0
    if [ "$INSTALL_FRAMEWORK" = "0" ]; then log "Vanilla: Oxide is not managed here."; FRAMEWORK_OK=1; return 0; fi
    report_update_progress oxide
    report_step oxide begun

    local build_after; read_installed_build; build_after="$INSTALLED_BUILD"

    # One look at GitHub's latest release: its tag is the version we compare and record, and it is the file we download
    # and check. uMod's feed is not asked: on 2026-10-01 it still named the old Oxide an hour after GitHub had the new one,
    # and a skip on its word left a freshly updated server without Oxide.
    local from="$FRAMEWORK_URL" sha="" tag="" rel=""
    rel="$(curl -fsSL --max-time 25 -H 'Accept: application/vnd.github+json' "$FRAMEWORK_RELEASES" 2>/dev/null || true)"
    if [ -n "$rel" ]; then
        if have_json; then
            tag="$(printf '%s' "$rel" | jq -r '.tag_name // empty' 2>/dev/null)"
            if [ "$VERIFY_FRAMEWORK" = "1" ]; then
                from="$(printf '%s' "$rel" | jq -r --arg n "$FRAMEWORK_ASSET" '.assets[]?|select(.name==$n)|.browser_download_url' 2>/dev/null | head -1)"
                sha="$(printf '%s' "$rel" | jq -r --arg n "$FRAMEWORK_ASSET" '.assets[]?|select(.name==$n)|.digest' 2>/dev/null | head -1)"
                sha="${sha#sha256:}"
                case "$from" in https://github.com/*) ;; *) from="$FRAMEWORK_URL"; sha="" ;; esac
                [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || sha=""
            fi
        else
            tag="$(printf '%s' "$rel" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
        fi
        [[ "$tag" =~ ^v?[0-9]+(\.[0-9]+)+$ ]] || tag=""
        tag="${tag#v}"
    fi
    if [ "$VERIFY_FRAMEWORK" = "1" ]; then
        if ! have_json; then warn "jq is not installed; taking the Oxide download unverified."
        elif [ -z "$sha" ]; then warn "Could not read a verified SHA-256 from GitHub; taking the download unverified."; fi
    fi

    # Skip only when neither the game nor Oxide moved. An update that changed the game's build has just written the
    # game's own assemblies over Oxide's, so Oxide goes back on whatever its version says (as hotwire.bat does).
    if [ "$SKIP_UNCHANGED_FRAMEWORK" = "1" ] && [ -f "$OXIDE_STAMP" ]; then
        local have; have="$(cat "$OXIDE_STAMP" 2>/dev/null || true)"
        if [ "${DO_VALIDATE:-0}" = "1" ]; then
            log "A validate put the game's own files back, so Oxide goes back over them."
        elif [ -n "${BUILD_BEFORE:-}" ] && [ -n "$build_after" ] && [ "$BUILD_BEFORE" != "$build_after" ]; then
            log "The game moved from $BUILD_BEFORE to $build_after, so Oxide goes back over it."
        elif [ -n "$tag" ] && [ "$tag" = "$have" ] && [ -n "$build_after" ]; then
            log "Oxide $have and the game ($build_after) are unchanged; skipping the framework refresh."
            report_step oxide done ",\"version\":$(json_text "$have"),\"detail\":$(json_text "Oxide and the game are unchanged, so nothing was downloaded.")"
            FRAMEWORK_OK=1; return 0
        fi
    fi

    local zip="$ROOT/OxideMod.zip"
    [ -n "$sha" ] && log "Downloading Oxide ${tag:-latest} (will verify SHA-256)..." || log "Downloading Oxide (unverified)..."
    # A stalled download gives up (under 1 byte a second for 2 minutes); a slow one carries on, for at most 30 minutes in
    # all, so a connection that trickles can never hold the start.
    if ! curl -fSL -A "Mozilla/5.0" --connect-timeout 30 --speed-limit 1 --speed-time 120 --max-time 1800 "$from" --output "$zip" 2>/dev/null; then
        warn "Oxide download failed; keeping the current install."
        update_reason oxide_download_failed
        report_step oxide failed ",\"detail\":$(json_text "The download from GitHub failed; the installed Oxide is kept.")"
        rm -f "$zip"; return 0
    fi
    if [ -n "$sha" ]; then
        local got; got="$(sha256sum "$zip" | cut -d' ' -f1)"
        if [ "${got,,}" != "${sha,,}" ]; then
            bad "Oxide SHA-256 does not match; NOT extracting."; update_reason oxide_hash_mismatch
            report_step oxide failed ",\"detail\":$(json_text "The download did not match the SHA-256 GitHub lists, so it was not installed.")"
            rm -f "$zip"; return 0
        fi
        ok "Oxide SHA-256 matches."
    fi
    # Every entry under RustDedicated_Data/ and none climbing out of it, as setup checks: on the unverified path a
    # changed zip could otherwise write anywhere the server's user can.
    local strays; strays="$(unzip -Z1 "$zip" 2>/dev/null | grep -vE '^RustDedicated_Data/'; unzip -Z1 "$zip" 2>/dev/null | grep -E '(^|/)\.\.(/|$)|^/|\\')"
    if [ -n "$strays" ] || [ -z "$(unzip -Z1 "$zip" 2>/dev/null)" ]; then
        bad "The Oxide download is not a zip of files under RustDedicated_Data/; NOT extracting."; update_reason oxide_not_a_zip
        report_step oxide failed ",\"detail\":$(json_text "The download was not the expected zip, so it was not installed.")"
        rm -f "$zip"; return 0
    fi
    if unzip -o "$zip" -d "$ROOT" >/dev/null 2>&1; then
        FRAMEWORK_OK=1
        # Record the version we just installed for the next skip check: the release we downloaded, or nothing when it
        # could not be read (the next update then extracts again, the safe direction).
        if [ -n "$tag" ]; then printf '%s' "$tag" > "$OXIDE_STAMP" 2>/dev/null || true; else rm -f "$OXIDE_STAMP"; fi
        ok "Oxide extracted."
        report_step oxide done "${tag:+,\"version\":$(json_text "$tag")},\"detail\":$(json_text "$( [ -n "$sha" ] && echo "SHA-256 matches GitHub's." || echo "Installed without a SHA-256 check.")")"
    else
        warn "Could not extract Oxide; keeping the current install."
        update_reason oxide_extract_failed
        report_step oxide failed ",\"detail\":$(json_text "Oxide could not be unpacked into the server folder; the installed one is kept.")"
    fi
    rm -f "$zip"
}

# ======================================================================
# Consume the flags and stamp the clock -- only after a full success.
# ======================================================================
finalize_update() {
    local update_ok=0
    [ "$STEAM_OK" = "1" ] && [ "$FRAMEWORK_OK" = "1" ] && update_ok=1
    if [ "$update_ok" = "1" ]; then
        rm -f "$ROOT/$UPDATE_FLAG" "$ROOT/$VALIDATE_FLAG"
        printf 'Last update: %s\n' "$(date)" > "$UPDATE_STAMP" 2>/dev/null || warn "Could not write the update stamp."
        [ -e "$ROOT/$UPDATE_FLAG" ]   && warn "$UPDATE_FLAG is still present after a successful update."
        [ -e "$ROOT/$VALIDATE_FLAG" ] && warn "$VALIDATE_FLAG is still present after a successful update."
    else
        rule; warn "The update did NOT complete; the flags are KEPT and the clock is NOT reset. It will retry next start."; rule
    fi
    # For the session report's update block: a flag still on disk means "tried and failed".
    if [ -e "$ROOT/$UPDATE_FLAG" ] || [ -e "$ROOT/$VALIDATE_FLAG" ]; then UPDATE_FLAG_KEPT=1; else UPDATE_FLAG_KEPT=0; fi
}

# ======================================================================
# The server's arguments, and the option check.
# ======================================================================
ARGS=()
build_args() {
    ARGS=( -batchmode -nographics )
    [ -n "$SERVER_IDENTITY" ]    && ARGS+=( +server.identity "$SERVER_IDENTITY" )
    if [ -n "$SERVER_LEVELURL" ]; then
        ARGS+=( +server.levelurl "$SERVER_LEVELURL" )
    else
        [ -n "$SERVER_LEVEL" ]     && ARGS+=( +server.level "$SERVER_LEVEL" )
        [ -n "$SERVER_SEED" ]      && ARGS+=( +server.seed "$SERVER_SEED" )
        [ -n "$SERVER_WORLDSIZE" ] && ARGS+=( +server.worldsize "$SERVER_WORLDSIZE" )
    fi
    [ -n "$SERVER_PORT" ]        && ARGS+=( +server.port "$SERVER_PORT" )
    [ -n "$SERVER_QUERYPORT" ]   && ARGS+=( +server.queryport "$SERVER_QUERYPORT" )
    [ -n "$RCON_PORT" ]          && ARGS+=( +rcon.port "$RCON_PORT" )
    [ -n "$SERVER_MAXPLAYERS" ]  && ARGS+=( +server.maxplayers "$SERVER_MAXPLAYERS" )
    [ -n "$SERVER_HOSTNAME" ]    && ARGS+=( +server.hostname "$SERVER_HOSTNAME" )
    [ -n "$SERVER_DESCRIPTION" ] && ARGS+=( +server.description "$SERVER_DESCRIPTION" )
    [ -n "$SERVER_TAGS" ]        && ARGS+=( +server.tags "$SERVER_TAGS" )
    # No password, no RCON: Rust starts no RCON listener when it is given none.
    [ -n "$RCON_PASSWORD" ] && ARGS+=( +rcon.password "$RCON_PASSWORD" )
    [ -n "$RCON_WEB" ]           && ARGS+=( +rcon.web "$RCON_WEB" )
    [ "${#EXTRA_CONVARS[@]}" -gt 0 ] && ARGS+=( "${EXTRA_CONVARS[@]}" )
}

# The option check: a convar name that is not in hotwire.cfg's own list is
# probably misspelled. A warning, never a stop: Rust ignores a name it does not
# know, and the list is not every convar Rust has.
check_options() {
    [ "$CHECK_OPTIONS" = "0" ] && { log "Option check skipped (hotwire.check_options 0)."; return 0; }
    local u
    if [ "${#CFG_UNKNOWN[@]}" -eq 0 ]; then ok "Options look right."; return 0; fi
    for u in "${CFG_UNKNOWN[@]}"; do warn "$u is not in hotwire.cfg's list of convars. Is it spelled right?"; done
}

# ======================================================================
# Log rotation -- rotate the PREVIOUS run's log before this launch, since
# Rust truncates -logfile on start. A first-crash log gets a name the
# cull never matches, so the log that explains a crash is preserved.
# ======================================================================
rotate_log() {
    [ "$ROTATE_LOGS" = "0" ] && return 0
    [ -f "$LOGFILE" ] || return 0
    local stamp; stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo "unstamped-$RANDOM")"
    local dest="$LOGDIR/server_log_${stamp}.txt"
    [ "$CRASH_STREAK" = "1" ] && dest="$LOGDIR/server_crash_${stamp}.txt"
    mv -f "$LOGFILE" "$dest" 2>/dev/null || true
    # Cull only server_log_* (never server_crash_*), keeping the newest LOG_KEEP.
    ls -1t "$LOGDIR"/server_log_*.txt 2>/dev/null | tail -n +$((LOG_KEEP+1)) | while read -r old; do rm -f "$old"; done
}

# ======================================================================
# The launcher's identity file, for the plugin to read. The plugin works out
# the code hash from this launcher's bytes, and reads the capability list to
# know what features it may offer. Written before each launch; harmless if no plugin reads it yet.
# ======================================================================
write_launcher_state() {
    local dir; dir="$(dirname "$LAUNCHER_STATE")"
    mkdir -p "$dir" 2>/dev/null || return 0
    # The plugin works out the code hash from hotwire.sh, which names this file as its part.
    local self="$ROOT/hotwire.sh"
    cat > "$LAUNCHER_STATE" 2>/dev/null <<JSON || true
{
  "version": "$HOTWIRE_LAUNCHER_VERSION",
  "capabilities": "$HOTWIRE_LAUNCHER_CAPABILITIES",
  "platform": "linux",
  "update_mode": $(json_text "$UPDATE_MODE"),
  "path": $(json_text "$self"),
  "config_problems": [$(config_problems_json)],
  "notices": [$(launcher_notices_json)],
  "self_update": $(self_update_json)
}
JSON
}

# hotwire.cfg's lines that are not used as written, as JSON for launcher.json: the plugin passes them to AFKPanel, which
# raises them as a problem. The setting's name and what is wrong, never its value. At most 20.
json_text() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/\\t}"; printf '"%s"' "$s"; }
# What the launcher wants the admin to know but that stops nothing, such as ionice missing: code and words, at most 10.
LAUNCHER_NOTICES=()
launcher_notices_json() {
    local entry code what sep="" i=0
    for entry in "${LAUNCHER_NOTICES[@]}"; do
        [ "$i" -ge 10 ] && break
        IFS=$'\t' read -r code what <<< "$entry"
        printf '%s{"code": %s, "message": %s}' "$sep" "$(json_text "$code")" "$(json_text "$what")"
        sep=", "; i=$((i+1))
    done
}
config_problems_json() {
    local entry line name crit what sep="" i=0
    for entry in "${CFG_REPORT[@]}"; do
        [ "$i" -ge 20 ] && break
        IFS=$'\t' read -r line name crit what <<< "$entry"
        printf '%s{"line": %d, "setting": %s, "critical": %s, "problem": %s}' "$sep" "$line" "$(json_text "$name")" \
            "$([ "$crit" = 1 ] && echo true || echo false)" "$(json_text "$what")"
        sep=", "; i=$((i+1))
    done
}

# ======================================================================
# Reporting to AFKPanel: the session report after each run and the launcher
# report when a crash streak stops it. Signed with the launcher's own key,
# which connect wrote to hotwire/keys.json. The launcher reports only what
# only it knows: how a run ended, the update outcome, and a crash-streak stop.
# The plugin reports the boot itself. A report that cannot be sent waits in
# the spool for a later try, and nothing here delays or stops the server.
# ======================================================================
_json_str() {  # a flat JSON string value: _json_str <file> <key>
    [ -f "$1" ] || return 0
    grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
}
_json_val() {  # a flat JSON string or number: setup writes the server id quoted, the plugin as a number
    [ -f "$1" ] || return 0
    grep -oE "\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+)" "$1" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"?([^"]*)"?/\1/'
}
_sha256() { printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.*= *//'; }
_hmac() {  # <key> <message>: HMAC-SHA256 hex, built from two SHA-256 passes (RFC 2104) so the key never goes on a command
    # line, where any local user can read it in the process list; `openssl dgst -hmac <key>` put it there.
    local hex i b ipad="" opad="" dir
    hex="$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')"
    [ "${#hex}" -gt 128 ] && hex="$(printf '%s' "$1" | openssl dgst -sha256 -binary | od -An -v -tx1 | tr -d ' \n')"
    while [ "${#hex}" -lt 128 ]; do hex="${hex}00"; done
    for ((i = 0; i < 128; i += 2)); do
        b=$((16#${hex:i:2}))
        ipad+="$(printf '\\x%02x' $((b ^ 0x36)))"; opad+="$(printf '\\x%02x' $((b ^ 0x5c)))"
    done
    dir="$(umask 077; mktemp -d)" || return 1
    printf "$ipad" > "$dir/i"; printf "$opad" > "$dir/o"
    { cat "$dir/i"; printf '%s' "$2"; } | openssl dgst -sha256 -binary > "$dir/inner"
    cat "$dir/o" "$dir/inner" | openssl dgst -sha256 | sed 's/^.*= *//'
    rm -rf "$dir"
}
_bool()   { [ "$1" = "1" ] && printf 'true' || printf 'false'; }
# The signature AFKPanel checks: HMAC-SHA256 over "POST /api/v1/report", the timestamp, the nonce and the body's SHA-256,
# one per line. tests/launcher-signing checks it against the shared conformance vector.
_report_sig() {  # <secret> <timestamp> <nonce> <body>
    _hmac "$1" "$(printf '%s %s\n%s\n%s\n%s' POST /api/v1/report "$2" "$3" "$(_sha256 "$4")")"
}

REPORT_ENABLED=0; PANEL_URL=""; SCRIPT_KEY=""; SCRIPT_SECRET=""; REPORT_STATE=""
# Read again before every start, not once: a connect made while the launcher runs (hotwire-setup connect, or
# "hotwire connect" in the game, which writes the same files) replaces the keys, and the old ones stop working.
# It says so only when the state changes, so an unconnected server does not log it on every restart.
init_reporting() {
    PANEL_URL="$(_json_str "$CONNECT_FILE" panel_url)"
    SCRIPT_KEY="$(_json_str "$KEYS_FILE" key_id)"
    SCRIPT_SECRET="$(_json_str "$KEYS_FILE" secret)"
    # Which panel, and which server on it, a held report was made for. A report is
    # never sent to another: a server connected to a different panel, or as a
    # different server, drops what it held for the old one. A new key for the same
    # server keeps it. No secret is in it.
    SPOOL_ORIGIN="${PANEL_URL%/}|$(_json_val "$CONNECT_FILE" server_id)"
    local state
    if [ -n "$PANEL_URL" ] && [ -n "$SCRIPT_KEY" ] && [ -n "$SCRIPT_SECRET" ]; then
        REPORT_ENABLED=1; state="connected $SCRIPT_KEY"
    else
        REPORT_ENABLED=0; state="none"
    fi
    if [ "$state" != "$REPORT_STATE" ]; then
        if [ "$REPORT_ENABLED" = "1" ]; then
            [ -n "$REPORT_STATE" ] && log "Connected to a panel; the launcher reports with its new key."
        else
            log "Not connected to a panel (no keys); the launcher will not report."
        fi
        REPORT_STATE="$state"
    fi
}

# Build a signed envelope for a payload and POST it. Echoes the HTTP status (000
# on no answer). Re-signs with a fresh timestamp/nonce but keeps the given
# report_id and sent_at, so a spooled report is the same report on resend.
_hw_post() {  # <kind> <payload-json> <report_id> <sent_at>
    local kind="$1" payload="$2" rid="$3" sent_at="$4" body ts nonce sig code
    body="{\"contract\":1,\"report_id\":\"$rid\",\"sent_at\":\"$sent_at\",\"source\":\"script\",\"source_version\":\"$HOTWIRE_LAUNCHER_VERSION\",\"kind\":\"$kind\",\"payload\":$payload}"
    ts="$(date +%s)"; nonce="$(openssl rand -hex 16)"
    sig="$(_report_sig "$SCRIPT_SECRET" "$ts" "$nonce" "$body")"
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X POST "$PANEL_URL/api/v1/report" \
        -H 'Content-Type: application/json' -H "X-Hotwire-Key: $SCRIPT_KEY" -H "X-Hotwire-Timestamp: $ts" \
        -H "X-Hotwire-Nonce: $nonce" -H "X-Hotwire-Signature: $sig" --data-binary "$body" 2>/dev/null)" || code="000"
    printf '%s' "${code:-000}"
}

_spool_write() {  # <kind> <payload> <rid> <sent_at>
    mkdir -p "$SPOOL_DIR" 2>/dev/null || return 0
    # Line 5 is the connection it was made for (SPOOL_ORIGIN). A file of four lines
    # is from an older launcher and is sent as it always was.
    printf '%s\n%s\n%s\n%s\n%s\n' "$1" "$3" "$4" "$2" "$SPOOL_ORIGIN" > "$SPOOL_DIR/$(date +%s)-$3" 2>/dev/null || true
    local n; n="$(ls -1 "$SPOOL_DIR" 2>/dev/null | wc -l)"
    if [ "$n" -gt "$SPOOL_MAX" ]; then
        ls -1tr "$SPOOL_DIR" 2>/dev/null | head -n "$((n - SPOOL_MAX))" | while read -r o; do rm -f "$SPOOL_DIR/$o"; done
    fi
}

# A report is written to the spool and sent from there, never on the way to a
# start: the server never waits on AFKPanel. spool_kick sends in
# the background; spool_flush sends now, only where the launcher is about to stop
# for good and nothing is waiting to start.
hw_send() {  # <kind> <payload-json>
    [ "$REPORT_ENABLED" = "1" ] || return 0
    local rid sent_at
    rid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)"
    sent_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    _spool_write "$1" "$2" "$rid" "$sent_at"
}

# How long a held report is kept unsent, as the contract's spool keeps it by default.
SPOOL_DAYS=7

# Send what the spool holds, oldest first, at most 50 a pass: delete what was
# accepted; stop at no answer, 429 or 5xx (the panel is away or busy, try again
# later); drop any other refusal, which the same bytes would get again; drop what
# is older than SPOOL_DAYS or was made for another connection.
spool_drain() {
    SPOOL_STOPPED=0
    [ "$REPORT_ENABLED" = "1" ] || return 0
    [ -d "$SPOOL_DIR" ] || return 0
    local sent=0 dropped=0 expired=0 elsewhere=0 f p kind rid sent_at payload origin code made now
    now="$(date +%s)"
    for f in $(ls -1tr "$SPOOL_DIR" 2>/dev/null); do
        [ "$sent" -ge 50 ] && break
        p="$SPOOL_DIR/$f"
        kind="$(sed -n 1p "$p")"; rid="$(sed -n 2p "$p")"; sent_at="$(sed -n 3p "$p")"; payload="$(sed -n 4p "$p")"
        origin="$(sed -n 5p "$p")"
        [ -z "$kind" ] && { rm -f "$p"; continue; }
        made="${f%%-*}"
        if [ -n "$made" ] && [ "$made" -eq "$made" ] 2>/dev/null && [ $(( now - made )) -gt $(( SPOOL_DAYS * 86400 )) ]; then
            rm -f "$p"; expired=$((expired + 1)); continue
        fi
        if [ -n "$origin" ] && [ "$origin" != "$SPOOL_ORIGIN" ]; then
            rm -f "$p"; elsewhere=$((elsewhere + 1)); continue
        fi
        code="$(_hw_post "$kind" "$payload" "$rid" "$sent_at")"
        case "$code" in
            2*) rm -f "$p"; sent=$((sent + 1)) ;;
            429|5*|000) SPOOL_STOPPED=1; break ;;
            *) rm -f "$p"; dropped=$((dropped + 1)); log "Spool: a held $kind report was refused (HTTP $code) and is dropped: sent again it would be refused again." ;;
        esac
    done
    [ "$sent" -gt 0 ] && log "Spool: sent $sent held report(s)."
    [ "$expired" -gt 0 ] && log "Spool: dropped $expired report(s) held more than $SPOOL_DAYS days."
    [ "$elsewhere" -gt 0 ] && log "Spool: dropped $elsewhere report(s) made for another panel or another server."
    return 0
}

# One sender at a time, in the background: the start never waits for it. A
# sender that hangs or dies costs nothing but the reports it had not sent yet,
# which stay in the spool for the next.
#
# A report written while another sender runs must not wait for the next stop: a
# new sender waits up to 30 s for the running one, and a sender goes round again
# (at most 5 passes) while reports remain and the panel is answering. Without
# that, the start report written as the last SteamCMD try's report was being
# sent stayed in the spool until the server next stopped.
spool_kick() {
    [ "$REPORT_ENABLED" = "1" ] || return 0
    [ -d "$SPOOL_DIR" ] || return 0
    # Its own descriptor (6), and none of the launcher's locks (7 backup, 8 and 9
    # SteamCMD) kept open in it: a sender still running must not hold them.
    ( exec 7>&- 8>&- 9>&- 6>"$SPOOL_DIR/.sending"; flock -w 30 6 || exit 0; spool_drain_all ) </dev/null &
}

spool_drain_all() {
    local pass
    for pass in 1 2 3 4 5; do
        spool_drain
        [ "$SPOOL_STOPPED" = "1" ] && return 0
        [ -n "$(ls -1 "$SPOOL_DIR" 2>/dev/null)" ] || return 0
    done
    return 0
}

# Before the launcher stops for good: the last reports go now, while there is a
# launcher to send them. Waits for a background sender first, at most a minute.
spool_flush() {
    [ "$REPORT_ENABLED" = "1" ] || return 0
    [ -d "$SPOOL_DIR" ] || return 0
    ( exec 7>&- 8>&- 9>&- 6>"$SPOOL_DIR/.sending"; flock -w 60 6 || exit 0; spool_drain_all ) </dev/null
}

# One session report per run, sent after the server exits: what only the script
# knows about this lifetime -- when it ended, the exit code, whether it crashed
# (a run under CRASH_SECONDS), and the update outcome. The panel merges it with
# the plugin's report for the same started_at.
report_session() {  # <exit_code> <crashed true|false>
    [ "$REPORT_ENABLED" = "1" ] || return 0
    read_installed_build
    local p="{\"started_at\":\"$STARTED_AT\",\"ended_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"exit_code\":$1,\"crashed\":$2"
    [ -n "$INSTALLED_BUILD" ] && p="$p,\"rust_build_id\":\"$INSTALLED_BUILD\""
    # The build Steam has on this branch, from the launcher's last build check; left out when it is not known.
    # An answer older than the install on public is not believed (build_check), so it is not sent as Steam's build.
    if [[ "$PUBLIC_BUILD" =~ ^[0-9]+$ ]] && ! { [ "$STEAM_BRANCH" = "public" ] && [[ "$INSTALLED_BUILD" =~ ^[0-9]+$ ]] \
          && [ "$INSTALLED_BUILD" -gt "$PUBLIC_BUILD" ]; }; then
        p="$p,\"rust_build_public\":\"$PUBLIC_BUILD\""
    fi
    # Runs in a row that ended under hotwire.crash_seconds, this one included.
    p="$p,\"fast_fail_count\":$CRASH_STREAK"
    # From this run's log: Oxide's "Failed to call hook" lines, and, when the plugin never loaded (so it never sent the
    # log itself), the last 40 lines, at most 8 KB. AFKPanel masks card numbers, IP addresses and Steam IDs before
    # storing them, as it does every log line.
    if [ -f "$LOGFILE" ]; then
        local hooks; hooks="$(grep -ac 'Failed to call hook ' "$LOGFILE" 2>/dev/null)"
        [[ "$hooks" =~ ^[0-9]+$ ]] || hooks=0
        p="$p,\"hook_errors\":$hooks"
        if ! grep -aq 'Loaded plugin Hotwire' "$LOGFILE" 2>/dev/null; then
            # A byte cut can start inside a character; its leftover bytes are dropped, or the panel refuses the
            # report as broken text and the spool lets it go.
            p="$p,\"log_tail\":$(json_text "$(tail -n 40 "$LOGFILE" 2>/dev/null | tail -c 8000 | LC_ALL=C sed '1s/^[\x80-\xBF]*//' | tr -d '\000-\010\013\014\016-\037')")"
        fi
    fi
    p="$p$(update_json)$(launcher_hooks_json)}"
    hw_send session "$p"
}

# The session report's "update" field: what this start's update did.
update_json() {
    local days=""
    if [ -f "$UPDATE_STAMP" ]; then days=$(( ( $(date +%s) - $(stat -c %Y "$UPDATE_STAMP" 2>/dev/null || date +%s) ) / 86400 )); fi
    local extra="" line sep=""
    extra=",\"mode\":$(json_text "$UPDATE_MODE"),\"effective_mode\":$(json_text "${UPDATE_EFFECTIVE:-}")"
    [ -n "$UPDATE_REASON" ] && extra="$extra,\"reason\":$(json_text "$UPDATE_REASON")"
    if [ "${#UPDATE_LOG[@]}" -gt 0 ]; then
        extra="$extra,\"log\":["
        for line in "${UPDATE_LOG[@]}"; do
            extra="$extra$sep$(json_text "$(printf '%s' "$line" | tr -d '\000-\010\013\014\016-\037')")"; sep=","
        done
        extra="$extra]"
    fi
    printf ',"update":{"attempted":%s,"steam_ok":%s,"framework_ok":%s,"flag_kept":%s%s%s}' \
        "$(_bool "$UPDATE_ATTEMPTED")" "$(_bool "$STEAM_OK")" "$(_bool "$FRAMEWORK_OK")" "$(_bool "$UPDATE_FLAG_KEPT")" "${days:+,\"days_since_success\":$days}" "$extra"
}

# A session report as the server starts, keyed by the same started_at as the one
# after it exits, so AFKPanel shows where a slow start went while the server runs.
report_session_start() {
    [ "$REPORT_ENABLED" = "1" ] || return 0
    hw_send session "{\"started_at\":\"$STARTED_AT\"${START_ID:+,\"start_id\":\"$START_ID\"}$(update_json)$(launcher_hooks_json)}"
}

# An update report while the update runs (capability: update_progress): which step,
# and for SteamCMD which try. Between server runs the plugin is not running, so
# without it AFKPanel hears nothing until the server starts, however long SteamCMD
# retries. Sent in the background like every report; the update never waits on it.
report_update_progress() {  # <step steamcmd|oxide> [attempt] [of]
    [ "$REPORT_ENABLED" = "1" ] || return 0
    local p="{\"step\":$(json_text "$1"),\"mode\":$(json_text "$UPDATE_MODE"),\"effective_mode\":$(json_text "${UPDATE_EFFECTIVE:-}")"
    [[ "${2:-}" =~ ^[0-9]+$ ]] && p="$p,\"attempt\":$2"
    [[ "${3:-}" =~ ^[0-9]+$ ]] && p="$p,\"of\":$3"
    [[ "${INSTALLED_BUILD:-}" =~ ^[0-9]+$ ]] && p="$p,\"rust_build_id\":\"$INSTALLED_BUILD\""
    [[ "${PUBLIC_BUILD:-}" =~ ^[0-9]+$ ]] && p="$p,\"rust_build_public\":\"$PUBLIC_BUILD\""
    hw_send update "$p}"
    spool_kick
}

# Each step of this start for AFKPanel's run page (start_step, capability: start_steps): the update check, the backup,
# the hooks, each SteamCMD try and how far it has got, Oxide, a wipe, the launch and Rust's boot. START_ID is the time
# this start began preparing, the same on every step of it. Sent in the background like every report; no step waits on
# it, and nothing is sent in check mode.
START_ID=""
report_step() {  # <step> <state> [more fields, each ,"key":value]
    [ "$REPORT_ENABLED" = "1" ] && [ -n "$START_ID" ] && [ -z "$CHECK_ONLY" ] || return 0
    hw_send start_step "{\"start_id\":\"$START_ID\",\"step\":$(json_text "$1"),\"state\":$(json_text "$2")${3:-}}"
    spool_kick
}

# The update decision: whether this start updates, and why not when it does not.
report_check_step() {
    local p=",\"update\":$( [ "$DO_UPDATE" = "1" ] && echo true || echo false ),\"mode\":$(json_text "$UPDATE_MODE")"
    [ -n "${UPDATE_EFFECTIVE:-}" ] && p="$p,\"effective_mode\":$(json_text "$UPDATE_EFFECTIVE")"
    [[ "${INSTALLED_BUILD:-}" =~ ^[0-9]+$ ]] && p="$p,\"rust_build_id\":\"$INSTALLED_BUILD\""
    [[ "${PUBLIC_BUILD:-}" =~ ^[0-9]+$ ]] && p="$p,\"rust_build_public\":\"$PUBLIC_BUILD\""
    [ "$DO_UPDATE" != "1" ] && [ -n "$UPDATE_REASON" ] && p="$p,\"reason\":$(json_text "$UPDATE_REASON")"
    report_step check done "$p"
}

# SteamCMD's output passes through unchanged; its progress line ("Update state (0x61) downloading, progress: 45.12
# (2758000000 / 6111760987)") is reported at most every 15 seconds. It reads to the end whatever happens, so SteamCMD
# never meets a closed pipe.
steam_progress() {  # <try> [of]
    local line last=-15 phase pct bytes total
    while IFS= read -r line || [ -n "$line" ]; do
        printf '%s\n' "$line"
        line="${line//$'\r'/}"
        if [[ "$line" =~ Update\ state\ \(0x[0-9a-fA-F]+\)\ ([a-z]+)[a-z\ ]*,\ progress:\ ([0-9]+(\.[0-9]+)?)\ \(([0-9]+)\ /\ ([0-9]+)\) ]] \
            && [ $(( SECONDS - last )) -ge 15 ] && [ "${BASH_REMATCH[5]}" != "0" ]; then
            last=$SECONDS
            phase="${BASH_REMATCH[1]}"; pct="${BASH_REMATCH[2]}"; bytes="${BASH_REMATCH[4]}"; total="${BASH_REMATCH[5]}"
            report_step steamcmd progress ",\"attempt\":$1${2:+,\"of\":$2},\"phase\":$(json_text "$phase"),\"percent\":$pct,\"bytes\":$bytes,\"total\":$total" || true
        fi
    done
    return 0
}

# Rust's boot, read from its own log file while it runs: each milestone once, then "Server startup complete" and
# "SteamServer Connected". A separate process: the server never waits on it, and it stops when Rust exits, at Steam's
# connection, or after an hour. A line a Rust build no longer prints is simply not reported.
BOOT_WATCH_PID=""
boot_watch_start() {
    BOOT_WATCH_PID=""
    [ "$REPORT_ENABLED" = "1" ] && [ -n "$START_ID" ] && [ -z "$CHECK_ONLY" ] || return 0
    boot_watch "$LOGFILE" "$(date +%s)" & BOOT_WATCH_PID=$!
}
boot_watch_stop() {
    [ -n "$BOOT_WATCH_PID" ] || return 0
    kill -TERM "$BOOT_WATCH_PID" 2>/dev/null; wait "$BOOT_WATCH_PID" 2>/dev/null
    BOOT_WATCH_PID=""
}
boot_watch() {  # <logfile> <launch epoch>
    local file="$1" since="$2" line seen=" " m tailpid=""
    local deadline=$(( SECONDS + 3600 ))
    trap '[ -n "$tailpid" ] && kill "$tailpid" 2>/dev/null; exit 0' TERM
    # Rust writes its log from the start; an older file left in place (hotwire.rotate_logs 0) is not this boot's.
    while [ ! -f "$file" ] || [ "$(stat -c %Y "$file" 2>/dev/null || echo 0)" -lt "$since" ]; do
        [ "$SECONDS" -ge "$deadline" ] && return 0
        sleep 1
    done
    exec 3< <(exec tail -n +1 -F "$file" 2>/dev/null); tailpid=$!
    while [ "$SECONDS" -lt "$deadline" ]; do
        IFS= read -r -t 5 line <&3 || { [ $? -gt 128 ] && continue; break; }
        line="${line//$'\r'/}"
        m=""; local extra=""
        case "$line" in
            *"[Bootstrap] Opening Bundles done"*) m=bundles ;;
            *"Loading Oxide Core"*) m=oxide ;;
            *"Loaded plugin Hotwire "*) m=hotwire ;;
            *"Generating procedural map"*) m=map ;;
            *"Spawning World"*) m=world ;;
            *"is now fully built"*) m=navmesh ;;
            *"Server startup complete"*)
                case "$seen" in *" startup "*) ;; *) seen="$seen startup "; report_step boot done ;; esac; continue ;;
            *"SteamServer Connected"*)
                report_step steam done; break ;;
            *)
                if [[ "$line" =~ Asset\ Warmup\ \(([0-9]+)/([0-9]+)\) ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; then m=warmup
                elif [[ "$line" =~ Spawning\ ([0-9]+)\ entities\ from\ save ]]; then m=entities; extra=",\"count\":${BASH_REMATCH[1]}"
                fi ;;
        esac
        [ -n "$m" ] || continue
        case "$seen" in *" $m "*) continue ;; esac
        seen="$seen$m "
        report_step boot progress ",\"milestone\":\"$m\"$extra"
    done
    [ -n "$tailpid" ] && kill "$tailpid" 2>/dev/null
    return 0
}

# The launcher report: sent when the crash-streak backstop stops the server for
# good. Absence of a heartbeat cannot tell "stopped, needs a human" from "the
# network is out"; this can.
report_launcher_stopped() {  # <detail>
    [ "$REPORT_ENABLED" = "1" ] || return 0
    local plog; plog="$(ls -1t "$LOGDIR" 2>/dev/null | grep server_crash_ | head -1)"
    [ -n "$plog" ] && plog="logs/$plog"
    hw_send launcher "{\"state\":\"stopped\",\"reason\":\"crash_streak\",\"detail\":$(json_text "$1"),\"crash_streak\":$CRASH_STREAK,\"preserved_log\":$(json_text "$plog")}"
}

# ======================================================================
# Wipe (capability: wipe). A wipe is a restart with a flag, exactly as an update
# is. The plugin announces, counts down, optionally backs up (Rust's own
# server.backup), writes WIPE.flag and quits; the launcher reads the flag between
# runs and changes the map by writing a new seed (and size) into hotwire.cfg --
# Rust then finds no save by that name and generates a new world, and the old
# save is simply left on disk. Blueprints are the admin's choice: kept, renamed
# (recoverable), or deleted; player.tokens.db (Rust+ pairings) is never touched.
#
# Safety: seed/size are validated as plain integers before they are written; a stale flag (past its expiry) or one already
# carried out this cycle never fires (the double-wipe guard); and if the new seed
# cannot be written the wipe is CANCELLED and the server boots unchanged -- a
# wipe that half-happened is worse than one that did not. This is why seed and
# size live with wipe and are fenced out of the convar editor: a routine convar
# edit must never be able to wipe a map.
# ======================================================================
# cfg_set <name> <value> [<name> <value>...]: write settings into hotwire.cfg,
# all of them or none. The line that sets each is changed where it is; a setting
# that is off in the list (#name value) is switched on in its place; anything
# else is added at the end. A value is written in double quotes when it has
# spaces or is empty. The caller has already checked every name and value; a
# double quote or a control character never reaches here. The file is written
# whole and moved into place, keeping its permissions.
cfg_set() {
    local tmp next
    [ -f "$CFG" ] && [ $(( $# % 2 )) -eq 0 ] || return 1
    tmp="$(mktemp "$ROOT/.hotwire.cfg.XXXXXX")" || return 1
    next="$tmp.next"
    cp "$CFG" "$tmp" || { rm -f "$tmp"; return 1; }
    while [ $# -gt 0 ]; do
        if ! _cfg_set_one "$1" "$2" < "$tmp" > "$next" || ! mv -f "$next" "$tmp"; then rm -f "$tmp" "$next"; return 1; fi
        shift 2
    done
    chmod --reference="$CFG" "$tmp" 2>/dev/null
    if [ -s "$tmp" ] && mv -f "$tmp" "$CFG"; then return 0; fi
    rm -f "$tmp"; return 1
}
_cfg_set_one() {  # <name> <value>: stdin to stdout
    local name="$1" value="$2" shown
    if [ -z "$value" ] || [[ "$value" == *[[:space:]]* ]]; then shown="\"$value\""; else shown="$value"; fi
    # Through the environment, not -v: awk -v would read a backslash in the value
    # (\n in a description) as an escape.
    HW_NAME="$name" HW_LINE="$(printf '%-27s %s' "$name" "$shown")" awk '
        BEGIN { ln = tolower(ENVIRON["HW_NAME"]); line = ENVIRON["HW_LINE"]; done = 0; off = 0 }
        { rows[NR] = $0 }
        {
            # The LAST line that sets it, as the reader takes the last: with a name set twice, changing the first
            # left the old value in force.
            s = $0; sub(/\r$/, "", s); sub(/^[ \t]+/, "", s)
            split(s, f, /[ \t]+/)
            if (tolower(f[1]) == ln) { done = NR }
            else if (!off && substr(f[1], 1, 1) == "#" && tolower(substr(f[1], 2)) == ln) { off = NR }
        }
        END {
            at = done ? done : off
            for (i = 1; i <= NR; i++) print (i == at ? line : rows[i])
            if (!at) print line
        }
    '
}

# AFKPanel's public key for wipe permissions. Wipes are part of AFKPanel Pro: a wipe runs only with AFKPanel's signed
# permission for this server, this wipe and this map, checked here against this key. The private half is AFKPanel's alone.
WIPE_PERMIT_PUBKEY="-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAotv0GyyUvwmrVHLcq+1y
FZHmZbxBIr+coTcMKK2trfccv/9i/k8+7SjO1k/TnP0qRkOn7swCfYYovTvxeFB/
7DYAMCzdPOM74ZZ+KPfCAjdv+hQ7F57VooZd+/nCdbc6UK/2Md5obkocKveFsZDG
DXTS4b3P1wt9VlV6x/VlObVqmWSBPAyhLHaS3xiaC7jjr2x9HZk5aGXxNvk/xgt8
W8Tt26vAr1xc3INBmfK49fFgCYQrj+rKOtnRkTbEd0/f/TY8qg5uUgOC6cSQkt2U
S0WRrC6izC/8cBt8WXH6JNHs3+Rqogrbl76AMQjvQTZ5swNbZvxZEo+LRdcAKJdj
VQWnxfmBLc/4tlbfeCh4NoLpLqcgAttxRLqom6/6xNRVbB2eWUlx8qYFIecxknGL
++ylOpnqKbNtA3KziFvH+GVqvsf1kSW8dDAeRQLwdY3JoIybQNKkd3DZBk8a4HVs
/HzyrC8U7xraCdmG2FqxQY/WKnYFvvz0u8CFAebxRukhAgMBAAE=
-----END PUBLIC KEY-----"

# Whether a wipe permission verifies: RSA, SHA-256, over the lines AFKPanel signed, rebuilt from the flag. Version 2
# signs the blueprints too and is tried first; version 1 (seven lines) is what AFKPanel signed before this launcher said
# it checks version 2, so a permission made then still wipes. Once version 2 is signed, a changed blueprints line fails.
wipe_permit_ok() {  # <public key pem> <server> <cycle> <seed> <size> <levelurl> <expires> <permit base64> [blueprints]
    local dir rc=1
    dir="$(mktemp -d)" || return 1
    printf '%s\n' "$1" > "$dir/key.pem"
    printf '%s' "$8" | openssl base64 -d -A > "$dir/sig" 2>/dev/null
    if [ -n "${9:-}" ]; then
        printf 'hotwire-wipe-permit 2\nserver %s\ncycle %s\nseed %s\nsize %s\nlevelurl %s\nblueprints %s\nexpires %s\n' "$2" "$3" "$4" "$5" "$6" "$9" "$7" > "$dir/text"
        openssl dgst -sha256 -verify "$dir/key.pem" -signature "$dir/sig" "$dir/text" >/dev/null 2>&1; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        printf 'hotwire-wipe-permit 1\nserver %s\ncycle %s\nseed %s\nsize %s\nlevelurl %s\nexpires %s\n' "$2" "$3" "$4" "$5" "$6" "$7" > "$dir/text"
        openssl dgst -sha256 -verify "$dir/key.pem" -signature "$dir/sig" "$dir/text" >/dev/null 2>&1; rc=$?
    fi
    rm -rf "$dir"
    return $rc
}

# Whether a wipe flag carries AFKPanel's permission for this server that verifies: the same test apply_wipe makes,
# asked first by the backup before a wipe, so a wipe that will be cancelled costs no backup.
flag_permit_ok() {  # <flag>
    local f="$1" permit pexp pserver my bp
    permit="$(grep -m1 '^permit ' "$f" | awk '{print $2}')"
    pexp="$(grep -m1 '^permit_expires ' "$f" | awk '{print $2}')"
    pserver="$(grep -m1 '^server ' "$f" | awk '{print $2}')"
    my="$(_json_val "$CONNECT_FILE" server_id)"
    bp="$(grep -m1 '^blueprints ' "$f" | awk '{print $2}')"; [ -z "$bp" ] && bp=keep
    [ -n "$permit" ] && [[ "$pexp" =~ ^[0-9]+$ ]] && [ "$pexp" -gt "$(date +%s)" ] && [ -n "$my" ] && [ "$pserver" = "$my" ] \
        && wipe_permit_ok "$WIPE_PERMIT_PUBKEY" "$pserver" "$(grep -m1 '^cycle ' "$f" | awk '{print $2}')" \
            "$(grep -m1 '^seed ' "$f" | awk '{print $2}')" "$(grep -m1 '^size ' "$f" | awk '{print $2}')" \
            "$(grep -m1 '^levelurl ' "$f" | awk '{print $2}')" "$pexp" "$permit" "$bp"
}

apply_wipe() {
    local flag="$ROOT/$WIPE_FLAG"
    [ -f "$flag" ] || return 0
    local seed size bp cycle expires now
    local forced armed_build levelurl
    seed="$(grep -m1  '^seed '       "$flag" | awk '{print $2}')"
    levelurl="$(grep -m1 '^levelurl ' "$flag" | awk '{print $2}')"
    size="$(grep -m1  '^size '       "$flag" | awk '{print $2}')"
    bp="$(grep -m1    '^blueprints ' "$flag" | awk '{print $2}')"
    cycle="$(grep -m1 '^cycle '      "$flag" | awk '{print $2}')"
    expires="$(grep -m1 '^expires '  "$flag" | awk '{print $2}')"
    forced="$(grep -m1 '^forced '    "$flag" | awk '{print $2}')"
    armed_build="$(grep -m1 '^armed_build ' "$flag" | awk '{print $2}')"
    local permit permit_expires permit_server
    permit="$(grep -m1 '^permit ' "$flag" | awk '{print $2}')"
    permit_expires="$(grep -m1 '^permit_expires ' "$flag" | awk '{print $2}')"
    permit_server="$(grep -m1 '^server ' "$flag" | awk '{print $2}')"
    now="$(date +%s)"
    [ -z "$bp" ] && bp="keep"

    # Already carried out this cycle: clear and do nothing (the double-wipe guard).
    if [ -n "$cycle" ] && [ "$(cat "$WIPE_STATE" 2>/dev/null)" = "$cycle" ]; then
        rm -f "$flag"; log "Wipe for cycle $cycle already done; ignoring the flag."; return 0
    fi
    # A stale flag never fires.
    if [ -n "$expires" ] && [ "$expires" -lt "$now" ] 2>/dev/null; then
        rm -f "$flag"; warn "Wipe flag expired ($(date -u -d "@$expires" +%FT%TZ 2>/dev/null)); ignoring."; return 0
    fi

    # Checked by the same rules as hotwire.cfg before anything is written or deleted.
    local why=""; CFG_WHY=""
    if [ -z "$seed" ] || ! cfg_check seed "$seed"; then why="seed ${CFG_WHY:-is missing}"
    elif [ -n "$size" ] && ! cfg_check worldsize "$size"; then why="size $CFG_WHY"
    elif [ -n "$levelurl" ] && { ! cfg_check url "$levelurl" || [[ "$levelurl" == *[\"\'\`\$\\]* ]]; }; then why="map address ${CFG_WHY:-has a quote, \$ or backslash}"
    fi
    case "$bp" in keep|rename|delete) ;; *) [ -z "$why" ] && why="blueprints must be keep, rename or delete";; esac
    # Wipes are part of AFKPanel Pro: AFKPanel's permission for this server, this wipe and this map, checked against
    # the values exactly as the flag carries them.
    if [ -z "$why" ]; then
        local my_server; my_server="$(_json_val "$CONNECT_FILE" server_id)"
        if [ -z "$permit" ]; then why="no permission from AFKPanel (wipes are part of AFKPanel Pro)"
        elif ! [[ "$permit_expires" =~ ^[0-9]+$ ]] || [ "$permit_expires" -le "$now" ]; then why="AFKPanel's permission has expired"
        elif [ -z "$my_server" ] || [ "$permit_server" != "$my_server" ]; then why="AFKPanel's permission is for another server"
        elif ! wipe_permit_ok "$WIPE_PERMIT_PUBKEY" "$permit_server" "$cycle" "$seed" "$size" "$levelurl" "$permit_expires" "$permit" "$bp"; then
            why="AFKPanel's permission does not match this wipe"
        fi
    fi
    [ -z "$why" ] && seed="$((10#$seed))" && { [ -z "$size" ] || size="$((10#$size))"; }
    if [ -n "$why" ]; then
        rule; bad "Wipe CANCELLED: $why. Booting unchanged."; rule
        printf 'cancelled: %s\n' "$why" > "$WIPE_RESULT" 2>/dev/null || true
        rm -f "$flag"
        return 0
    fi

    # A forced wipe rides the monthly update: it is applied only in a start whose
    # update changed the installed build. Otherwise the old world boots, the flag
    # stays for the next start inside its window, and the plugin tries again.
    if [ "$forced" = "1" ]; then
        read_installed_build
        if [ -z "$INSTALLED_BUILD" ]; then
            warn "Forced wipe (cycle ${cycle:-none}): the installed build cannot be read, so the wipe waits. Booting unchanged."
            printf 'deferred: installed build unknown\n' > "$WIPE_RESULT" 2>/dev/null || true
            return 0
        fi
        if [ -n "$armed_build" ] && [ "$INSTALLED_BUILD" = "$armed_build" ]; then
            log "Forced wipe (cycle ${cycle:-none}): still build $INSTALLED_BUILD, no update yet. Booting the old world; the wipe waits."
            printf 'deferred: no new build (installed %s)\n' "$INSTALLED_BUILD" > "$WIPE_RESULT" 2>/dev/null || true
            return 0
        fi
        log "Forced wipe (cycle ${cycle:-none}): build ${armed_build:-unknown} -> $INSTALLED_BUILD, the update arrived."
        # The before-wipe backup was held back until this was known (backup_before_launch).
        if [ "$BACKUPS" = "1" ] && grep -q '^backup 1' "$flag" 2>/dev/null; then
            log "Backing up the stopped server before the wipe..."
            backup_archive "before_wipe" "$(date -u +%Y%m%dT%H%M%SZ)-before_wipe" "" "" "" "" "" || true
        fi
    fi

    local mapwords="new seed $seed${size:+, size $size}"
    [ -n "$levelurl" ] && mapwords="custom map $levelurl"
    rule; log "Wiping (cycle ${cycle:-none}): $mapwords, blueprints: $bp."
    # 1) The map change first: write the new map into settings, all of it or none.
    #    A custom map is its address; a generated map is its seed (and size), and
    #    a custom map set before is cleared, or Rust would keep loading it. If that
    #    cannot be done, cancel before touching anything else and boot unchanged.
    local pairs
    if [ -n "$levelurl" ]; then
        pairs=( server.levelurl "$levelurl" )
    else
        pairs=( server.seed "$seed" )
        [ -n "$size" ] && pairs+=( server.worldsize "$size" )
        [ -n "$SERVER_LEVELURL" ] && pairs+=( server.levelurl "" )
    fi
    if ! cfg_set "${pairs[@]}"; then
        rule; bad "Wipe CANCELLED: could not write the new map to hotwire.cfg. Booting unchanged."; rule
        printf 'cancelled: could not write the new map\n' > "$WIPE_RESULT" 2>/dev/null || true
        rm -f "$flag"; return 0
    fi
    if [ -n "$levelurl" ]; then
        SERVER_LEVELURL="$levelurl"
    else
        SERVER_SEED="$seed"; SERVER_LEVELURL=""
        [ -n "$size" ] && SERVER_WORLDSIZE="$size"
    fi

    # 2) A fresh world, even on the same map. Rust names a save after its map (level,
    #    size, seed and protocol, or a custom map's file name) and loads that save if
    #    it exists, so the same seed or the same custom map would bring the old world
    #    back. Every world save in the identity folder is set aside (renamed, never
    #    deleted): the .sav, its numbered copies and its .navmesh. A custom map's
    #    downloaded copy goes too, so a map changed at the same address is fetched
    #    again; a generated map's .map stays, as Rust builds the same one anyway.
    local identity="${SERVER_IDENTITY:-my_server_identity}" bpmsg="kept"
    local idir="$ROOT/server/$identity" set_aside=0
    if [ -d "$idir" ]; then
        local wstamp g; wstamp="$(date +%Y%m%d-%H%M%S)"
        for g in "$idir"/*.sav "$idir"/*.sav.[0-9]* "$idir"/*.navmesh "$idir"/*.map; do
            [ -f "$g" ] || continue
            case "$(basename "$g")" in *.wiped-*) continue ;; esac
            if [[ "$g" == *.map ]]; then
                [ -n "$levelurl" ] || continue
                [[ "$(basename "$g")" =~ ^[a-z0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.map$ ]] && continue
            fi
            mv -f "$g" "$g.wiped-$wstamp" && set_aside=$((set_aside + 1))
        done
    fi

    # 3) Blueprints, in the identity folder. Match by glob (the version in the name
    #    changes between builds). Never touch player.tokens.db.
    if [ "$bp" != "keep" ] && [ -d "$idir" ]; then
        local stamp f cnt=0; stamp="$(date +%Y%m%d-%H%M%S)"
        for f in "$idir"/player.blueprints.*.db; do
            [ -e "$f" ] || continue
            if [ "$bp" = "delete" ]; then rm -f "$f" && cnt=$((cnt + 1))
            else mv -f "$f" "$f.wiped-$stamp" && cnt=$((cnt + 1)); fi
        done
        bpmsg="$bp ($cnt file(s))"
    fi

    # 4) Record the cycle and clear the flag last, so a crash mid-wipe re-runs safely.
    [ -n "$cycle" ] && { mkdir -p "$(dirname "$WIPE_STATE")" 2>/dev/null; printf '%s' "$cycle" > "$WIPE_STATE" 2>/dev/null || true; }
    rm -f "$flag"
    if [ -n "$levelurl" ]; then
        printf 'applied: map %s blueprints %s (%s)\n' "$levelurl" "$bp" "$bpmsg" > "$WIPE_RESULT" 2>/dev/null || true
    else
        printf 'applied: seed %s size %s blueprints %s (%s)\n' "$seed" "${size:-unchanged}" "$bp" "$bpmsg" > "$WIPE_RESULT" 2>/dev/null || true
    fi
    WIPE_APPLIED=1
    ok "Wipe applied: $mapwords, blueprints $bpmsg. A new world starts on this boot; $set_aside old world file(s) were renamed *.wiped-* and left on disk."
}

# ======================================================================
# Update mode from AFKPanel (capability: update_mode_set). The plugin writes
# UPDATE_MODE.request holding one word. Only auto and always are taken: off and
# hotwire stay something the admin writes into hotwire.cfg. It is applied before
# the update decision, so a waiting UPDATE.flag installs on this same start.
# The receipt is UPDATE_MODE.result; the request is removed either way.
# ======================================================================
apply_update_mode_request() {
    [ -e "$UPDATE_MODE_REQUEST" ] || [ -L "$UPDATE_MODE_REQUEST" ] || return 0
    local want was="$UPDATE_MODE"
    rm -f "$UPDATE_MODE_RESULT"
    # The plugin writes a plain file; a link is not followed.
    if [ -L "$UPDATE_MODE_REQUEST" ] || [ ! -f "$UPDATE_MODE_REQUEST" ]; then
        rm -f "$UPDATE_MODE_REQUEST"
        printf 'reject : UPDATE_MODE.request is a link, not a file\n' > "$UPDATE_MODE_RESULT" 2>/dev/null || true
        warn "UPDATE_MODE.request is a link, not a file, so it was not read. hotwire.update_mode stays $was."
        return 0
    fi
    want="$(head -c 64 "$UPDATE_MODE_REQUEST" 2>/dev/null | tr -d '\r\n[:space:]')"
    rm -f "$UPDATE_MODE_REQUEST"
    case "$want" in
        auto|always) ;;
        *)
            printf 'reject %s : the panel sets auto or always only\n' "${want:0:16}" > "$UPDATE_MODE_RESULT" 2>/dev/null || true
            warn "AFKPanel asked for update mode '${want:0:16}', which is not auto or always. hotwire.update_mode stays $was."
            return 0 ;;
    esac
    if [ "$want" = "$was" ]; then
        printf 'unchanged %s\n' "$want" > "$UPDATE_MODE_RESULT" 2>/dev/null || true
        log "AFKPanel asked for update mode $want; hotwire.update_mode is already $want."
        return 0
    fi
    if cfg_set hotwire.update_mode "$want"; then
        load_config || config_reload
        # Read back: a hotwire.cfg the launcher cannot use keeps the last start's settings, and then the mode did not change.
        if [ "$UPDATE_MODE" != "$want" ]; then
            printf "reject %s : hotwire.cfg was written but cannot be used now, so the last start's settings stay\n" "$want" > "$UPDATE_MODE_RESULT" 2>/dev/null || true
            bad "hotwire.update_mode $want was written into hotwire.cfg, but the file cannot be used now, so this start keeps $UPDATE_MODE. Run ./hotwire.sh check."
            return 0
        fi
        printf 'applied %s (was %s)\n' "$want" "$was" > "$UPDATE_MODE_RESULT" 2>/dev/null || true
        ok "Update mode set to $want from AFKPanel (was $was); hotwire.cfg now says hotwire.update_mode $want."
    else
        printf 'reject %s : could not write hotwire.cfg\n' "$want" > "$UPDATE_MODE_RESULT" 2>/dev/null || true
        bad "AFKPanel asked for update mode $want, but hotwire.cfg could not be written. hotwire.update_mode stays $was."
    fi
}

# ======================================================================
# Hotwire's own updates (capability: self_update). Off unless hotwire.cfg says
# hotwire.self_update auto, or AFKPanel's "Update Hotwire" button asks for one
# (HOTWIRE_UPDATE.request). Then, before a start, with the server stopped:
#
#   1. Find the newest release on the channel (hotwire.self_update_channel) that
#      is at least hotwire.self_update_days old (0 is early release; the button
#      does not wait) and newer than what is installed. Where releases come from
#      is fixed here, never a setting.
#   2. Download its manifest and signature, and install nothing unless the
#      manifest is signed by a key below. AFKPanel never holds those keys, so a
#      breach of AFKPanel cannot sign a release.
#   3. Download the files the manifest names and check each one's SHA-256.
#   4. Run the new hotwire-launcher.sh in check mode against this server's own
#      hotwire.cfg; install nothing it refuses.
#   5. Keep the current files in hotwire/previous/, move the new ones in, and
#      note it in hotwire/self-update/applied. A new launcher takes over at once
#      (exit 75, hotwire.sh runs it); a new plugin loads with the server.
#   6. Probation: the new plugin must say it loaded (oxide/data/Hotwire/loaded.json)
#      within SU_PROBATION_SECONDS. If it does not, the previous plugin is written
#      back while the server runs, and Oxide loads it. If the server crashes before
#      then, both previous files go back before the next start. If the new
#      launcher fails to start the server, hotwire.sh puts the previous one back.
#      After any of these, automatic updates stop until an admin asks again.
#
# Nothing here can stop a start: every failure leaves the installed files as
# they were and the server starts as it would have.
# ======================================================================
SU_FEED="https://api.github.com/repos/xman2000/hotwire/releases?per_page=30"
SU_DOWNLOAD="https://github.com/xman2000/hotwire/releases/download"
# For the tests only: a feed and downloads served elsewhere. Still nothing installs unless a trusted key signed it.
[ -n "${HOTWIRE_SELF_UPDATE_FEED:-}" ] && SU_FEED="$HOTWIRE_SELF_UPDATE_FEED"
[ -n "${HOTWIRE_SELF_UPDATE_DOWNLOAD:-}" ] && SU_DOWNLOAD="$HOTWIRE_SELF_UPDATE_DOWNLOAD"
# The keys a release may be signed with: "<id>:<public key, P-256, X then Y in hex>".
SU_KEYS=("yk-38628349:876f79ef6a2a50e64677a099245995cb9f787ca8eb77dde0ebcd615c8af9603a9e2551dfe21759d86be07be8e7627aef9a9f3345fe0fa3c353871b79d7ea147e" "yk-38628153:f1e8fe30f1201bf8ec8d856402f9113cf66a322be8b90907b89f28ff3f24fb005d5a86d99e58117499a561464e6cf96fa3ae4a7b54fdae086dc9e93fdb7357b9")
SU_DIR="$ROOT/hotwire/self-update"
SU_PREVIOUS="$ROOT/hotwire/previous"
SU_APPLIED="$SU_DIR/applied"
SU_ROLLED_BACK="$SU_DIR/rolled-back"
SU_STATE="$SU_DIR/state"
SU_REQUEST="$ROOT/SELF_UPDATE.request"
SU_NOW_REQUEST="$ROOT/HOTWIRE_UPDATE.request"
SU_RESULT="$ROOT/SELF_UPDATE.result"
SU_PLUGIN="$ROOT/oxide/plugins/Hotwire.cs"
SU_LOADED="$ROOT/oxide/data/Hotwire/loaded.json"
SU_PROBATION_SECONDS=1200
SU_FEED_CACHE_HOURS=1

# state: key=value lines; su_state_get <key>, su_state_set <key> <value> ...
su_state_get() { [ -f "$SU_STATE" ] && sed -n "s/^$1=//p" "$SU_STATE" | head -1; }
su_state_set() {
    mkdir -p "$SU_DIR" 2>/dev/null || return 0
    local tmp; tmp="$SU_STATE.tmp"
    { [ -f "$SU_STATE" ] && cat "$SU_STATE"; } > "$tmp" 2>/dev/null || : > "$tmp"
    while [ $# -ge 2 ]; do
        grep -v "^$1=" "$tmp" > "$tmp.n" 2>/dev/null; printf '%s=%s\n' "$1" "${2//$'\n'/ }" >> "$tmp.n"; mv -f "$tmp.n" "$tmp"
        shift 2
    done
    mv -f "$tmp" "$SU_STATE"
}
su_block() {  # <reason> <tag>
    su_state_set blocked 1 reason "$1" blocked_tag "$2" blocked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# The installed plugin's version, from its [Info] line.
su_plugin_version() {
    [ -f "$SU_PLUGIN" ] && sed -n -E 's/.*\[Info\("Hotwire", "[^"]*", "([0-9.]+)"\)\].*/\1/p' "$SU_PLUGIN" | head -1
}
# su_newer <a> <b>: whether version a is newer than b (dotted numbers; a -linux suffix is ignored).
su_newer() {
    local a="${1%-linux}" b="${2%-linux}"
    [ -n "$a" ] || return 1
    [ -n "$b" ] || return 0
    [ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]
}

# su_hex2bin: hex on stdin to bytes on stdout.
su_hex2bin() { local h; h="$(tr -d ' \n')"; printf '%b' "$(printf '%s' "$h" | sed 's/../\\x&/g')"; }
# su_der_int <32-byte hex>: the DER INTEGER for it.
su_der_int() {
    local h="$1"
    while [ "${h:0:2}" = "00" ] && [ ${#h} -gt 2 ]; do h="${h:2}"; done
    [ $(( 16#${h:0:1} )) -ge 8 ] && h="00$h"
    printf '02%02x%s' $(( ${#h} / 2 )) "$h"
}
# su_verify <manifest> <signature file>: 0 when a trusted key signed the manifest. The signature file is
# "key <id>" and "sig <base64 of r and s, 32 bytes each>".
su_verify() {
    local manifest="$1" sigfile="$2" id sig rs r s der key keyid pub tmp ok=1
    command -v openssl >/dev/null 2>&1 || { SU_WHY="openssl is not installed, so the release's signature cannot be checked"; return 1; }
    id="$(sed -n 's/^key \([A-Za-z0-9._-]\{1,64\}\)$/\1/p' "$sigfile" | head -1)"
    sig="$(sed -n 's/^sig \([A-Za-z0-9+/=]\{80,100\}\)$/\1/p' "$sigfile" | head -1)"
    [ -n "$id" ] && [ -n "$sig" ] || { SU_WHY="the signature file is not in the expected form"; return 1; }
    rs="$(printf '%s' "$sig" | base64 -d 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ ${#rs} -eq 128 ] || { SU_WHY="the signature is not 64 bytes"; return 1; }
    r="$(su_der_int "${rs:0:64}")"; s="$(su_der_int "${rs:64:64}")"
    der="30$(printf '%02x' $(( (${#r} + ${#s}) / 2 )))$r$s"
    for key in "${SU_KEYS[@]}"; do
        keyid="${key%%:*}"; pub="${key#*:}"
        [ "$keyid" = "$id" ] || continue
        tmp="$(mktemp -d)" || break
        printf '%s' "$der" | su_hex2bin > "$tmp/sig.der"
        { echo "-----BEGIN PUBLIC KEY-----"
          printf '3059301306072a8648ce3d020106082a8648ce3d03010703420004%s' "$pub" | su_hex2bin | base64 -w 64
          echo "-----END PUBLIC KEY-----"; } > "$tmp/key.pem"
        openssl dgst -sha256 -verify "$tmp/key.pem" -signature "$tmp/sig.der" "$manifest" >/dev/null 2>&1 && ok=0
        rm -rf "$tmp"
    done
    [ "$ok" = 0 ] || SU_WHY="it is not signed by a key this launcher trusts (key $id)"
    return "$ok"
}

# A flat field from the manifest: su_mf <manifest> <key> (a "key": "value" line).
su_mf() { sed -n -E "s/^[[:space:]]*\"$2\":[[:space:]]*\"([^\"]*)\",?[[:space:]]*$/\1/p" "$1" | head -1; }
# A file's SHA-256 from the manifest's "files" block: su_mf_file <manifest> <name>.
su_mf_file() { sed -n -E "/\"files\"/,/\}/s/^[[:space:]]*\"$2\":[[:space:]]*\"([0-9a-f]{64})\",?[[:space:]]*$/\1/p" "$1" | head -1; }

# SELF_UPDATE.request from AFKPanel: "off", "auto <days>", or "retry". It is written into hotwire.cfg, as the update
# mode is. Only these words are taken: the channel stays the admin's, in hotwire.cfg.
su_apply_request() {
    [ -e "$SU_REQUEST" ] || [ -L "$SU_REQUEST" ] || return 0
    rm -f "$SU_RESULT"
    if [ -L "$SU_REQUEST" ] || [ ! -f "$SU_REQUEST" ]; then
        rm -f "$SU_REQUEST"; printf 'reject : not a file\n' > "$SU_RESULT" 2>/dev/null; return 0
    fi
    local want days
    read -r want days < <(head -c 64 "$SU_REQUEST" 2>/dev/null | tr -d '\r')
    rm -f "$SU_REQUEST"
    case "$want" in
        off)
            if cfg_set hotwire.self_update off; then
                load_config || config_reload
                printf 'applied off\n' > "$SU_RESULT"; ok "Hotwire's automatic updates turned off from AFKPanel."
            else
                printf 'reject off : could not write hotwire.cfg\n' > "$SU_RESULT"
            fi ;;
        auto)
            [[ "${days:-}" =~ ^[0-9]{1,3}$ ]] || { printf 'reject auto : days must be 0 to 999\n' > "$SU_RESULT"; return 0; }
            if cfg_set hotwire.self_update auto hotwire.self_update_days "$days"; then
                load_config || config_reload
                su_state_set blocked 0 reason ""
                printf 'applied auto %s\n' "$days" > "$SU_RESULT"
                ok "Hotwire's automatic updates turned on from AFKPanel: releases at least $days days old."
            else
                printf 'reject auto : could not write hotwire.cfg\n' > "$SU_RESULT"
            fi ;;
        retry) su_state_set blocked 0 reason ""; printf 'applied retry\n' > "$SU_RESULT"
               log "Hotwire's automatic updates resume: AFKPanel asked to try again." ;;
        *) printf 'reject %s : not off, auto or retry\n' "${want:0:16}" > "$SU_RESULT" ;;
    esac
}

# The previous plugin back over the new one. Written into the file, not renamed over it: Oxide reloads a plugin when its
# file is written, and ignores one moved into place, so while the server runs this is what makes Oxide load it again.
su_plugin_back() {
    [ -f "$SU_PREVIOUS/Hotwire.cs" ] && cp -f "$SU_PREVIOUS/Hotwire.cs" "$SU_PLUGIN"
}

# A rollback hotwire.sh made (the new launcher failed): the plugin it came with goes back too, and updates stop.
su_after_launcher_rollback() {
    [ -f "$SU_ROLLED_BACK" ] || return 0
    local tag; tag="$(sed -n 's/^tag \(.*\)$/\1/p' "$SU_ROLLED_BACK" | head -1)"
    su_plugin_back
    rm -f "$SU_ROLLED_BACK" "$SU_APPLIED"
    su_block launcher_failed "$tag"
    su_state_set last_tag "$tag" last_result rolled_back last_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    bad "The update to Hotwire $tag was rolled back: the new launcher failed to start the server. Automatic updates are off until you retry in AFKPanel."
    report_step hotwire_update failed ",\"tag\":$(json_text "$tag"),\"reason\":\"launcher_failed\",\"rolled_back\":true"
}

# An update applied before the last run that never proved itself: put the previous files back.
su_after_failed_probation() {  # <reason>
    [ -f "$SU_APPLIED" ] || return 0
    local tag; tag="$(sed -n 's/^tag \(.*\)$/\1/p' "$SU_APPLIED" | head -1)"
    su_plugin_back
    if [ -f "$SU_PREVIOUS/hotwire-launcher.sh" ] && grep -q '^launcher ' "$SU_APPLIED"; then
        cp -p "$SU_PREVIOUS/hotwire-launcher.sh" "$ROOT/hotwire-launcher.sh.tmp" && mv -f "$ROOT/hotwire-launcher.sh.tmp" "$ROOT/hotwire-launcher.sh"
    fi
    rm -f "$SU_APPLIED"
    su_block "$1" "$tag"
    su_state_set last_tag "$tag" last_result rolled_back last_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    bad "The update to Hotwire $tag was rolled back ($1). Automatic updates are off until you retry in AFKPanel."
    report_step hotwire_update failed ",\"tag\":$(json_text "$tag"),\"reason\":$(json_text "$1"),\"rolled_back\":true"
}

# The newest release on the channel this server may take: SU_TAG, SU_AGE_DAYS. 1 when there is none.
su_pick_release() {  # <ignore days 0|1>
    local feed="$SU_DIR/feed.json" age
    mkdir -p "$SU_DIR" 2>/dev/null || return 1
    age=$(( $(date +%s) - $(stat -c %Y "$feed" 2>/dev/null || echo 0) ))
    if [ "$1" = 1 ] || [ "$age" -ge $(( SU_FEED_CACHE_HOURS * 3600 )) ]; then
        curl -fsS --max-time 15 -H 'Accept: application/vnd.github+json' "$SU_FEED" -o "$feed.tmp" 2>/dev/null \
            && mv -f "$feed.tmp" "$feed" || { rm -f "$feed.tmp"; SU_WHY="GitHub's release list did not answer"; return 1; }
    fi
    # One release per line: tag, prerelease, published_at. The list is newest first.
    local line tag pre pub
    SU_TAG=""
    while IFS=$'\t' read -r tag pre pub; do
        case "$SELF_UPDATE_CHANNEL" in
            dev) [[ "$tag" =~ ^(release|dev)-[0-9A-Za-z.-]+$ ]] || continue ;;
            *)   [[ "$tag" =~ ^release-[0-9A-Za-z.-]+$ ]] && [ "$pre" = "false" ] || continue ;;
        esac
        local pub_s; pub_s="$(date -d "$pub" +%s 2>/dev/null)" || continue
        SU_AGE_DAYS=$(( ( $(date +%s) - pub_s ) / 86400 ))
        [ "$1" = 1 ] || [ "$SU_AGE_DAYS" -ge "$SELF_UPDATE_DAYS" ] || continue
        SU_TAG="$tag"; break
    done < <(tr -d '\n' < "$feed" | grep -oE '"tag_name": *"[^"]+"|"prerelease": *(true|false)|"published_at": *"[^"]+"' \
        | sed -E 's/^"[a-z_]+": *"?//; s/"$//' | paste - - - 2>/dev/null)
    [ -n "$SU_TAG" ] || { SU_WHY="no release is old enough yet"; return 1; }
}

# What launcher.json says about Hotwire's own updates, for the plugin to pass to AFKPanel.
self_update_json() {
    local probation=""; [ -f "$SU_APPLIED" ] && probation="$(sed -n 's/^tag \(.*\)$/\1/p' "$SU_APPLIED" | head -1)"
    printf '{"mode":%s,"days":%s,"channel":%s,"blocked":%s,"reason":%s,"blocked_tag":%s,"last_tag":%s,"last_result":%s,"last_at":%s,"probation":%s}' \
        "$(json_text "$SELF_UPDATE")" "${SELF_UPDATE_DAYS:-3}" "$(json_text "$SELF_UPDATE_CHANNEL")" \
        "$( [ "$(su_state_get blocked)" = 1 ] && echo true || echo false )" "$(json_text "$(su_state_get reason)")" \
        "$(json_text "$(su_state_get blocked_tag)")" "$(json_text "$(su_state_get last_tag)")" \
        "$(json_text "$(su_state_get last_result)")" "$(json_text "$(su_state_get last_at)")" "$(json_text "$probation")"
}

# The update itself. Returns 75 when the launcher was replaced (the caller exits 75), else 0.
self_update_step() {
    SU_WHY=""
    [ -z "$CHECK_ONLY" ] || return 0
    su_apply_request
    su_after_launcher_rollback
    local now=0; { [ -e "$SU_NOW_REQUEST" ] || [ -L "$SU_NOW_REQUEST" ]; } && now=1
    rm -f "$SU_NOW_REQUEST"
    [ "$now" = 1 ] && su_state_set blocked 0 reason ""
    if [ "$SELF_UPDATE" != "auto" ] && [ "$now" != 1 ]; then return 0; fi
    if [ "$(su_state_get blocked)" = "1" ]; then
        log "Hotwire's automatic updates are paused after a rolled-back update ($(su_state_get reason)). Retry in AFKPanel."
        return 0
    fi
    # One change per start: a wipe this start goes alone.
    [ -e "$ROOT/$WIPE_FLAG" ] && { log "A wipe is waiting, so Hotwire's own update waits for the next start."; return 0; }
    su_pick_release "$now" || { [ "$now" = 1 ] && warn "Update Hotwire: $SU_WHY."; return 0; }
    local tag="$SU_TAG" stage="$SU_DIR/stage" plugin_now launcher_now plugin_new launcher_new
    plugin_now="$(su_plugin_version)"; launcher_now="$HOTWIRE_LAUNCHER_VERSION"
    rm -rf "$stage"; mkdir -p "$stage" || return 0
    if ! curl -fsSL --max-time 30 "$SU_DOWNLOAD/$tag/manifest.json" -o "$stage/manifest.json" 2>/dev/null \
        || ! curl -fsSL --max-time 30 "$SU_DOWNLOAD/$tag/manifest.sig" -o "$stage/manifest.sig" 2>/dev/null; then
        rm -rf "$stage"; [ "$now" = 1 ] && warn "Update Hotwire: $tag has no signed manifest to download."; return 0
    fi
    if ! su_verify "$stage/manifest.json" "$stage/manifest.sig"; then
        bad "Hotwire $tag was not installed: $SU_WHY."
        report_step hotwire_update failed ",\"tag\":$(json_text "$tag"),\"reason\":\"signature\""
        rm -rf "$stage"; return 0
    fi
    [ "$(su_mf "$stage/manifest.json" tag)" = "$tag" ] || { bad "Hotwire $tag was not installed: its manifest names another release."; rm -rf "$stage"; return 0; }
    plugin_new="$(su_mf "$stage/manifest.json" plugin)"; launcher_new="$(su_mf "$stage/manifest.json" launcher_linux)"
    local want_plugin=0 want_launcher=0
    su_newer "$plugin_new" "$plugin_now" && want_plugin=1
    # The launcher's own file is replaced only under hotwire.sh, which runs the new one and puts the old one back if it
    # fails. Run on its own, only the plugin updates.
    [ -n "${HOTWIRE_STARTER:-}" ] && su_newer "$launcher_new" "$launcher_now" && want_launcher=1
    if [ "$want_plugin" = 0 ] && [ "$want_launcher" = 0 ]; then rm -rf "$stage"; [ "$now" = 1 ] && log "Update Hotwire: this server already runs $tag or newer."; return 0; fi
    log "Updating Hotwire to $tag (plugin ${plugin_now:-?} -> $plugin_new, launcher $launcher_now -> $launcher_new)..."
    report_step hotwire_update begun ",\"tag\":$(json_text "$tag")"
    local f sha
    for f in Hotwire.cs hotwire-launcher.sh; do
        [ "$f" = Hotwire.cs ] && [ "$want_plugin" = 0 ] && continue
        [ "$f" = hotwire-launcher.sh ] && [ "$want_launcher" = 0 ] && continue
        sha="$(su_mf_file "$stage/manifest.json" "$f")"
        if [ -z "$sha" ] || ! curl -fsSL --max-time 120 "$SU_DOWNLOAD/$tag/$f" -o "$stage/$f" 2>/dev/null \
            || [ "$(sha256sum "$stage/$f" | cut -c1-64)" != "$sha" ]; then
            bad "Hotwire $tag was not installed: $f did not download, or is not the file the signed manifest names."
            report_step hotwire_update failed ",\"tag\":$(json_text "$tag"),\"reason\":\"download\""
            rm -rf "$stage"; return 0
        fi
    done
    # The new launcher checks this server's own settings before it is trusted with them.
    if [ "$want_launcher" = 1 ] && ! HOTWIRE_ROOT_OVERRIDE="$ROOT" bash "$stage/hotwire-launcher.sh" check > "$stage/check.log" 2>&1; then
        bad "Hotwire $tag was not installed: its launcher refused this server's settings. See hotwire/self-update/stage/check.log."
        report_step hotwire_update failed ",\"tag\":$(json_text "$tag"),\"reason\":\"check\""
        su_block check_failed "$tag"; return 0
    fi
    mkdir -p "$SU_PREVIOUS" || return 0
    { printf 'tag %s\nat %s\n' "$tag" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      [ "$want_plugin" = 1 ] && printf 'plugin %s %s\n' "${plugin_now:-none}" "$plugin_new"
      [ "$want_launcher" = 1 ] && printf 'launcher %s %s\n' "$launcher_now" "$launcher_new"
      true; } > "$SU_APPLIED.tmp" || return 0
    if [ "$want_plugin" = 1 ]; then
        [ -f "$SU_PLUGIN" ] && cp -p "$SU_PLUGIN" "$SU_PREVIOUS/Hotwire.cs"
        mkdir -p "$(dirname "$SU_PLUGIN")" && cp "$stage/Hotwire.cs" "$SU_PLUGIN.tmp" && mv -f "$SU_PLUGIN.tmp" "$SU_PLUGIN" \
            || { bad "Hotwire $tag: the plugin could not be put in place."; return 0; }
    fi
    if [ "$want_launcher" = 1 ]; then
        cp -p "$ROOT/hotwire-launcher.sh" "$SU_PREVIOUS/hotwire-launcher.sh" \
            && cp "$stage/hotwire-launcher.sh" "$ROOT/hotwire-launcher.sh.tmp" && chmod 755 "$ROOT/hotwire-launcher.sh.tmp" \
            && mv -f "$ROOT/hotwire-launcher.sh.tmp" "$ROOT/hotwire-launcher.sh" \
            || { bad "Hotwire $tag: the launcher could not be put in place; the plugin goes back."; su_after_failed_probation install_failed; return 0; }
    fi
    mv -f "$SU_APPLIED.tmp" "$SU_APPLIED"
    rm -rf "$stage"
    su_state_set last_tag "$tag" last_result installed last_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ok "Hotwire $tag is installed. It is on probation until the plugin says it loaded."
    report_step hotwire_update done ",\"tag\":$(json_text "$tag"),\"plugin\":$(json_text "$plugin_new"),\"launcher\":$(json_text "$launcher_new")"
    if [ "$want_launcher" = 1 ]; then
        log "The new launcher takes over now."
        spool_flush
        return 75
    fi
    return 0
}

# Probation, while the server runs: a separate process, as the boot watch is. The new plugin must write loaded.json
# with its version within SU_PROBATION_SECONDS; if it does not and the server still runs, the previous plugin goes back.
SU_WATCH_PID=""
su_watch_start() {
    SU_WATCH_PID=""
    [ -f "$SU_APPLIED" ] && [ -z "$CHECK_ONLY" ] || return 0
    su_watch "$(date +%s)" & SU_WATCH_PID=$!
}
su_watch_stop() {
    [ -n "$SU_WATCH_PID" ] || return 0
    kill -TERM "$SU_WATCH_PID" 2>/dev/null; wait "$SU_WATCH_PID" 2>/dev/null
    SU_WATCH_PID=""
}
su_watch() {  # <launch epoch>
    local since="$1" want deadline
    trap 'exit 0' TERM
    want="$(sed -n 's/^plugin [^ ]* \(.*\)$/\1/p' "$SU_APPLIED" | head -1)"
    # A launcher-only update has proved itself once the server has run hotwire.crash_seconds.
    if [ -z "$want" ]; then
        sleep "$CRASH_SECONDS"
        local tag; tag="$(sed -n 's/^tag \(.*\)$/\1/p' "$SU_APPLIED" | head -1)"
        rm -f "$SU_APPLIED"
        su_state_set last_result loaded last_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        ok "Hotwire $tag passed probation: the server is running on the new launcher."
        report_step hotwire_update loaded ",\"tag\":$(json_text "$tag")"
        return 0
    fi
    deadline=$(( since + SU_PROBATION_SECONDS ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ -f "$SU_LOADED" ] && [ "$(stat -c %Y "$SU_LOADED" 2>/dev/null || echo 0)" -ge "$since" ] \
            && grep -q "\"version\": *\"$want\"" "$SU_LOADED"; then
            local tag; tag="$(sed -n 's/^tag \(.*\)$/\1/p' "$SU_APPLIED" | head -1)"
            rm -f "$SU_APPLIED"
            su_state_set last_result loaded last_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            ok "Hotwire $tag passed probation: plugin $want loaded."
            report_step hotwire_update loaded ",\"tag\":$(json_text "$tag"),\"plugin\":$(json_text "$want")"
            return 0
        fi
        sleep 10
    done
    # Still running and the new plugin never said it loaded: put the previous one back now. Oxide loads it as it runs.
    su_after_failed_probation plugin_not_loaded
}

# ======================================================================
# Convar persist (capability: convar_persist). The plugin writes CONVAR.request
# -- one "<convar> <value>" per line -- to ask that a start-arg convar be made
# permanent. Between server runs (the safe moment) the launcher checks each and
# writes it into hotwire.cfg with cfg_set, and leaves a CONVAR.result receipt. It
# takes effect on this and every future boot.
#
# Hard rules, enforced here and not merely in the panel:
#   - It is a TYPED SET, never a console passthrough: the name must be a dotted
#     convar, and the value carries no double quote or control character.
#   - The map-defining convars (seed/worldsize/level/levelurl) and the secret
#     rcon.password are REFUSED: those belong to wipe / secrets. A routine convar
#     edit can never silently wipe a map.
#   - hotwire.* is REFUSED: the launcher's own settings are the admin's, and a
#     panel command never reconfigures the launcher.
#   - A convar the launcher reads itself must also pass that setting's own check.
# ======================================================================
CONVAR_CHANGED=0
apply_convar_requests() {
    CONVAR_CHANGED=0
    [ -f "$CONVAR_REQUEST" ] || return 0
    : > "$CONVAR_RESULT"
    local applied=0 rejected=0 line name value
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        name="${line%% *}"; value="${line#* }"
        if ! [[ "$name" =~ ^[a-z][a-z0-9]*(\.[a-z0-9_]+)+$ ]]; then
            echo "reject $name : not a dotted convar name" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue
        fi
        case "$name" in
            hotwire.*)
                echo "reject $name : a launcher setting, never set through the panel" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue ;;
            server.seed|server.worldsize|server.level|server.levelurl)
                echo "reject $name : map-defining, belongs to wipe not the convar editor" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue ;;
            rcon.password)
                echo "reject $name : a secret, never set through the panel" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue ;;
        esac
        # hotwire.cfg is data, so only what the reader refuses matters here: a
        # double quote and a control character.
        if [ "$name" = "$value" ] || [[ "$value" =~ [[:cntrl:]] ]]; then
            echo "reject $name : missing or non-printable value" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue
        fi
        case "$value" in
            *'"'*) echo "reject $name : value has a double quote" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue ;;
        esac
        if [ "${#value}" -gt 1024 ]; then
            echo "reject $name : value longer than 1024 characters" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue
        fi
        local own="${CV_SETTINGS[$name]:-}"
        if [ -n "$own" ] && ! cfg_check "${own#* }" "$value"; then
            echo "reject $name : $CFG_WHY" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue
        fi
        if cfg_set "$name" "$value"; then
            echo "applied $name $value" >> "$CONVAR_RESULT"; applied=$((applied+1)); CONVAR_CHANGED=1
        else
            echo "reject $name : could not write settings" >> "$CONVAR_RESULT"; rejected=$((rejected+1))
        fi
    done < "$CONVAR_REQUEST"
    rm -f "$CONVAR_REQUEST"
    log "Convar persist: applied $applied, rejected $rejected (details in CONVAR.result)."
}

# ======================================================================
# Backups (capability: backup). Hotwire decides when a backup runs and
# prepares what only the game can copy safely: right after Rust's own save it
# writes each game database's snapshot (through the game's own connection) and
# copies the config and plugin data files, one file per frame, into
# backup/<identity>/.staging-<run>/. Then it writes BACKUP.flag and plays on.
# The launcher does the heavy part here, with the system's tools and at the
# lowest priority: it adds the save (checking it did not change while copied),
# the plugins and the map, compresses, verifies, rotates, and leaves a result
# for Hotwire to report. Between runs, before an update or a wipe, it backs up
# the stopped server on its own. Nothing here can stop the server starting: a
# backup that fails says why in its result and in backup/<identity>/backup.log.
#
# Archives: backup/<identity>/<UTC stamp>-<trigger>.tar.zst, each with a
# .meta beside it. The map, which never changes within a wipe, is kept once
# per map in backup/<identity>/maps/. Rust's own server.backup uses backup/0-3
# only, so the two never meet.
# ======================================================================
BACKUP_WATCH_PID=""
BACKUP_STOP=0

_bconf() {  # _bconf <key> <default>: a value from backup.conf, which Hotwire writes
    local v=""
    [ -f "$BACKUP_CONF" ] && v="$(grep -m1 "^$1 " "$BACKUP_CONF" 2>/dev/null | cut -d' ' -f2-)"
    printf '%s' "${v:-$2}"
}
_bint() {  # _bint <key> <default>: the same, but only a plain non-negative integer
    local v; v="$(_bconf "$1" "$2")"
    [[ "$v" =~ ^[0-9]{1,9}$ ]] && printf '%s' "$v" || printf '%s' "$2"
}
_ms() {  # milliseconds; %N, not %3N, which uutils' date prints at full width
    local n; n="$(date +%s%N 2>/dev/null)"
    [[ "$n" =~ ^[0-9]{13,}$ ]] && echo $(( n / 1000000 )) || echo $(( $(date +%s) * 1000 ))
}

backup_identity() {
    local id; id="$(_bconf identity "${SERVER_IDENTITY:-my_server_identity}")"
    # A folder name, never a path; and never 0-3, which are Rust's own server.backup folders.
    [[ "$id" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] || return 1
    case "$id" in 0|1|2|3) return 1 ;; esac
    printf '%s' "$id"
}

# A framework folder Hotwire named in backup.conf, used only if it is inside this server.
_bdir() {  # _bdir <key> <default>
    local d; d="$(_bconf "$1" "$2")"
    case "$d" in "$ROOT"/*) [ -d "$d" ] && printf '%s' "$d" ;; esac
}

_blog() {  # _blog <dest> <line>: the full record, on this machine
    local f="$1/backup.log"
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$2" >> "$f" 2>/dev/null || true
    if [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -gt 5242880 ]; then mv -f "$f" "$f.1" 2>/dev/null || true; fi
}

_bresult() {  # _bresult <dest> <run> <key value lines...>: written whole, then moved into place
    local dest="$1" run="$2"; shift 2
    mkdir -p "$dest/.results" 2>/dev/null || return 0
    printf '%s\n' "$@" > "$dest/.results/.$run.tmp" 2>/dev/null && mv -f "$dest/.results/.$run.tmp" "$dest/.results/$run.result"
}

# Keeps: everything from the last recent_hours; then the newest backup of each
# day for daily days, of each week for weekly weeks, of each month for monthly
# months; the newest keep_wipes of the before-wipe backups; and always the
# newest backup. Then the size cap, oldest first. A map no backup names goes too.
backup_rotate() {  # backup_rotate <dest>
    local dest="$1" now recent daily weekly monthly wipes cap
    now="$(date +%s)"
    recent=$(( $(_bint keep_recent_hours 24) * 3600 ))
    daily="$(_bint keep_daily 7)"; weekly="$(_bint keep_weekly 4)"; monthly="$(_bint keep_monthly 3)"
    wipes="$(_bint keep_wipes 3)"; cap=$(( $(_bint max_total_mb 0) * 1048576 ))
    local nowmonth=$(( 10#$(date -u +%Y) * 12 + 10#$(date -u +%m) ))
    local -A seen=()
    local keep=() drop=() f base stamp ts age wipecount=0 first=1 d w m
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        base="$(basename "$f")"; stamp="${base%%-*}"
        [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
        ts="$(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null)" || continue
        age=$(( now - ts ))
        d="${stamp:0:8}"; w="$(date -u -d "@$ts" +%G%V)"; m="${stamp:0:6}"
        if [[ "$base" == *-before_wipe.tar.zst ]]; then
            wipecount=$((wipecount+1))
            if [ "$wipecount" -le "$wipes" ] || [ "$first" = "1" ]; then keep+=("$f"); else drop+=("$f"); fi
            first=0; continue
        fi
        local k=0
        if [ "$first" = "1" ] || [ "$age" -lt "$recent" ]; then k=1
        elif [ "$age" -lt $(( daily * 86400 )) ] && [ -z "${seen[d$d]:-}" ]; then k=1
        elif [ "$age" -lt $(( weekly * 7 * 86400 )) ] && [ -z "${seen[w$w]:-}" ]; then k=1
        elif [ $(( nowmonth - (10#${stamp:0:4} * 12 + 10#${stamp:4:2}) )) -lt "$monthly" ] && [ -z "${seen[m$m]:-}" ]; then k=1
        fi
        first=0
        if [ "$k" = "1" ]; then keep+=("$f"); seen[d$d]=1; seen[w$w]=1; seen[m$m]=1; else drop+=("$f"); fi
    done < <(ls -1 "$dest"/*.tar.zst 2>/dev/null | sort -r)

    for f in "${drop[@]}"; do rm -f "$f" "${f%.tar.zst}.meta"; _blog "$dest" "rotate: removed $(basename "$f")"; done
    BACKUP_REMOVED=${#drop[@]}

    # The size cap: oldest first, the newest backup never.
    if [ "$cap" -gt 0 ]; then
        local total; total="$(du -cb "$dest"/*.tar.zst "$dest"/maps/* 2>/dev/null | tail -1 | cut -f1)"
        local i
        for (( i=${#keep[@]}-1; i>0 && ${total:-0}>cap; i-- )); do
            f="${keep[$i]}"
            total=$(( total - $(stat -c %s "$f" 2>/dev/null || echo 0) ))
            rm -f "$f" "${f%.tar.zst}.meta"; BACKUP_REMOVED=$((BACKUP_REMOVED+1))
            _blog "$dest" "rotate: removed $(basename "$f") (over the ${cap} byte cap)"
        done
    fi

    # Maps no remaining backup names.
    local mf name used
    for mf in "$dest"/maps/*.zst; do
        [ -f "$mf" ] || continue
        name="$(basename "$mf" .zst)"
        used="$(grep -l "^map $name\$" "$dest"/*.meta 2>/dev/null | head -1)"
        [ -z "$used" ] && { rm -f "$mf"; _blog "$dest" "rotate: removed map $name (no backup uses it)"; }
    done
}

# One backup, start to finish. With a staging folder it completes a live backup
# Hotwire prepared; without one, the server is stopped and this copies everything.
backup_archive() {  # <trigger> <run> <staging|""> <sav name|""> <sav size|""> <sav mtime|""> <sets|"">
    local trigger="$1" run="$2" staging="$3" savname="$4" savsize="$5" savmtime="$6" sets="$7"
    local id save_dir dest started
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ -n "$sets" ] || sets="$(printf '%s' "world,$([ "$(_bconf map 1)" = 1 ] && echo map,)$([ "$(_bconf config 1)" = 1 ] && echo config,)$([ "$(_bconf oxide 1)" = 1 ] && echo oxide)")"
    sets=",${sets%,},"
    local setwords="${sets//,/ }"; setwords="${setwords# }"; setwords="${setwords% }"
    if ! id="$(backup_identity)"; then
        warn "Backup $run: the save folder's name is not usable, so nothing was backed up."
        return 1
    fi
    save_dir="$ROOT/server/$id"; dest="$ROOT/backup/$id"
    mkdir -p "$dest/maps" "$dest/.results" 2>/dev/null || { warn "Backup $run: cannot create $dest."; return 1; }
    local fail=""
    _bfail() { fail="$1"; _blog "$dest" "$run failed: $1 ${2:-}"; }

    # One backup at a time for this save folder; a second waits for no one.
    exec 7>"$dest/.lock"
    if ! flock -n 7; then
        _blog "$dest" "$run refused: another backup is running"
        _bresult "$dest" "$run" "run $run" "trigger $trigger" "status refused" "code busy" "started $started" "finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        [ -n "$staging" ] && rm -rf "$staging"
        exec 7>&-; return 1
    fi
    # What a backup cut short left behind.
    rm -rf "$dest"/.work-* "$dest"/*.part 2>/dev/null
    _blog "$dest" "$run start: trigger $trigger, sets $setwords"

    local work="$dest/.work-$run" t0 t1 archive_ms=0 bytes_in=0 bytes_out=0 files=0 sha="" newmap=""
    t0="$(_ms)"
    command -v zstd >/dev/null 2>&1 || _bfail no_zstd "zstd is not installed"

    # The floor: never let a backup be what fills the disk.
    local floor avail need
    floor=$(( $(_bint min_free_mb 5120) * 1048576 ))
    if [ -z "$fail" ]; then
        avail=$(( $(df -Pk "$dest" | awk 'NR==2{print $4}') * 1024 ))
        need="$(du -cb "$save_dir"/*.sav "$save_dir"/*.db "$save_dir"/*.db-wal 2>/dev/null | tail -1 | cut -f1)"
        [ $(( avail - ${need:-0} )) -lt "$floor" ] && _bfail disk_low "free $avail, floor $floor"
    fi

    if [ -z "$fail" ]; then
        if [ -n "$staging" ]; then
            [ -d "$staging" ] || _bfail no_staging "$staging"
            [ -z "$fail" ] && { mv "$staging" "$work" || _bfail no_staging "could not take $staging"; }
        else
            mkdir -p "$work"
            # Stopped: nothing is writing, so the files as they lie are consistent.
            if [[ "$sets" == *,world,* ]]; then
                mkdir -p "$work/world/db"
                local db
                for db in "$save_dir"/*.db "$save_dir"/*.db-wal; do [ -f "$db" ] && cp -p "$db" "$work/world/db/"; done
            fi
            if [[ "$sets" == *,config,* ]] && [ -d "$save_dir/cfg" ]; then
                mkdir -p "$work/cfg" && cp -p "$save_dir"/cfg/* "$work/cfg/" 2>/dev/null
            fi
            if [[ "$sets" == *,oxide,* ]]; then
                local sub src
                for sub in config data lang; do
                    src="$(_bdir "${sub}_dir" "$ROOT/oxide/$sub")"
                    [ -n "$src" ] || continue
                    mkdir -p "$work/oxide/$sub"
                    # Hotwire's own data holds this server's panel keys: never in a backup.
                    ( cd "$src" && tar -cf - --exclude=./Hotwire . 2>/dev/null ) | ( cd "$work/oxide/$sub" && tar -xf - 2>/dev/null )
                done
            fi
        fi
    fi

    # The save. Copied here because it can be large; checked unchanged across the copy.
    if [ -z "$fail" ] && [[ "$sets" == *,world,* ]]; then
        if [ -z "$savname" ]; then savname="$(ls -1t "$save_dir"/*.sav 2>/dev/null | head -1)"; savname="$(basename "${savname:-}")"; fi
        if ! [[ "$savname" =~ ^[A-Za-z0-9_.-]+\.sav$ ]] || [ ! -f "$save_dir/$savname" ]; then
            _bfail no_save "${savname:-none found}"
        else
            local try s1 s2
            mkdir -p "$work/world"
            for try in 1 2; do
                s1="$(stat -c '%s %Y' "$save_dir/$savname")"
                if [ -n "$savsize" ] && [ "$s1" != "$savsize $savmtime" ]; then s2="moved"; else
                    cp -p "$save_dir/$savname" "$work/world/$savname"
                    s2="$(stat -c '%s %Y' "$save_dir/$savname")"
                fi
                [ "$s1" = "$s2" ] && break
                # A save landed during the copy (or before it). Copy the new one once more.
                savsize=""; s2="changed"; sleep 2
            done
            [ "$s1" = "$s2" ] || _bfail sav_changed "$savname"
        fi
    fi

    if [ -z "$fail" ] && [[ "$sets" == *,oxide,* ]]; then
        local pdir; pdir="$(_bdir plugins_dir "$ROOT/oxide/plugins")"
        if [ -n "$pdir" ]; then mkdir -p "$work/oxide/plugins" && cp -p "$pdir"/*.cs "$work/oxide/plugins/" 2>/dev/null; fi
    fi
    if [ -z "$fail" ] && [[ "$sets" == *,config,* ]]; then
        # The launcher's settings: hotwire.cfg, which holds no secret. hotwire-secrets.cfg is never backed up here.
        [ -f "$CFG" ] && cp -p "$CFG" "$work/hotwire.cfg" 2>/dev/null
    fi

    # The map: once per map, compressed on its own, named in every backup that needs it.
    local mapname=""
    if [ -z "$fail" ] && [[ "$sets" == *,map,* ]]; then
        local mapfile; mapfile="$(ls -1t "$save_dir"/*.map 2>/dev/null | head -1)"
        if [ -n "$mapfile" ]; then
            mapname="$(basename "$mapfile")"
            if [ ! -f "$dest/maps/$mapname.zst" ]; then
                if nice -n 19 "${IONICE[@]}" zstd -3 -T2 -q -f "$mapfile" -o "$dest/maps/$mapname.zst.part" 2>/dev/null \
                   && mv -f "$dest/maps/$mapname.zst.part" "$dest/maps/$mapname.zst"; then newmap="$mapname"
                else rm -f "$dest/maps/$mapname.zst.part"; _blog "$dest" "$run: the map could not be kept (the backup goes on)"; mapname=""; fi
            fi
        fi
    fi

    local name="${run}.tar.zst"
    if [ -z "$fail" ]; then
        {
            printf 'run %s\ntrigger %s\nidentity %s\nsave %s\nmap %s\nsets %s\ncreated %s\nlauncher %s\n' \
                "$run" "$trigger" "$id" "$savname" "$mapname" "$setwords" "$started" "$HOTWIRE_LAUNCHER_VERSION"
            ( cd "$work" && find . -type f ! -name MANIFEST -print0 | sort -z | xargs -0 -r sha256sum )
        } > "$work/MANIFEST"
        bytes_in="$(du -sb "$work" | cut -f1)"; files="$(find "$work" -type f | wc -l)"
        t1="$(_ms)"
        if ( cd "$work" && tar -cf - . ) | nice -n 19 "${IONICE[@]}" zstd -3 -T2 -q -o "$dest/$name.part" 2>/dev/null \
           && nice -n 19 zstd -t -q "$dest/$name.part" 2>/dev/null; then
            mv -f "$dest/$name.part" "$dest/$name"
            archive_ms=$(( $(_ms) - t1 ))
            bytes_out="$(stat -c %s "$dest/$name")"
            sha="sha256:$(sha256sum "$dest/$name" | cut -d' ' -f1)"
            printf 'run %s\ntrigger %s\nmap %s\nsha256 %s\nbytes %s\n' "$run" "$trigger" "$mapname" "$sha" "$bytes_out" > "$dest/${run}.meta"
        else
            rm -f "$dest/$name.part"; _bfail archive_failed "tar or zstd"
        fi
    fi
    rm -rf "$work"; [ -n "$staging" ] && rm -rf "$staging"

    BACKUP_REMOVED=0
    [ -z "$fail" ] && backup_rotate "$dest"
    local count total free
    count="$(ls -1 "$dest"/*.tar.zst 2>/dev/null | wc -l)"
    total="$(du -cb "$dest"/*.tar.zst "$dest"/maps/*.zst 2>/dev/null | tail -1 | cut -f1)"
    free=$(( $(df -Pk "$dest" | awk 'NR==2{print $4}') * 1024 ))
    local status=ok; [ -n "$fail" ] && status=failed; [ "$fail" = "disk_low" ] && status=refused
    _bresult "$dest" "$run" "run $run" "trigger $trigger" "status $status" "code ${fail:--}" "sets $setwords" \
        "archive $([ -z "$fail" ] && echo "$name" || echo -)" "sha256 ${sha:--}" "bytes_in $bytes_in" "bytes_out $bytes_out" \
        "files $files" "archive_ms $archive_ms" "total_ms $(( $(_ms) - t0 ))" "map ${mapname:--}" "new_map ${newmap:--}" \
        "removed ${BACKUP_REMOVED:-0}" "archives $count" "stored_bytes ${total:-0}" "free_bytes $free" \
        "started $started" "finished $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -z "$fail" ]; then
        _blog "$dest" "$run ok: $name, $bytes_in bytes in, $bytes_out out, $files files, ${archive_ms} ms, $sha, removed ${BACKUP_REMOVED:-0}"
        log "Backup $run: $name ($bytes_out bytes)."
    else
        warn "Backup $run did not complete ($fail); see $dest/backup.log."
    fi
    exec 7>&-
    [ -z "$fail" ]
}

# A live backup Hotwire prepared: take the flag, then finish it.
backup_from_flag() {
    local claim="$BACKUP_FLAG.work" run trigger sav size mtime sets id
    mv -f "$BACKUP_FLAG" "$claim" 2>/dev/null || return 0
    _kv() { grep -m1 "^$1 " "$claim" 2>/dev/null | cut -d' ' -f2-; }
    run="$(_kv run)"; trigger="$(_kv trigger)"; sav="$(_kv save)"; size="$(_kv save_size)"; mtime="$(_kv save_mtime)"; sets="$(_kv sets)"
    rm -f "$claim"
    [[ "$run" =~ ^[0-9]{8}T[0-9]{6}Z-[a-z_]{1,24}$ ]] || { warn "Backup flag ignored: no usable run id."; return 0; }
    case "$trigger" in scheduled|manual) ;; *) warn "Backup flag ignored: unknown trigger."; return 0 ;; esac
    [[ "$size" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ ]] || { size=""; mtime=""; }
    [[ "$sets" =~ ^[a-z,]{0,40}$ ]] || sets=""
    id="$(backup_identity)" || return 0
    backup_archive "$trigger" "$run" "$ROOT/backup/$id/.staging-$run" "$sav" "$size" "$mtime" "$sets" || true
}

# Beside the running server, at the lowest priority: pick up flags until the
# server exits, finishing any backup already under way.
backup_watch() {
    trap 'BACKUP_STOP=1' TERM
    renice -n 19 -p $BASHPID >/dev/null 2>&1; ionice -c3 -p $BASHPID >/dev/null 2>&1
    local parent=$$
    while [ "$BACKUP_STOP" = "0" ] && kill -0 "$parent" 2>/dev/null; do
        [ -f "$BACKUP_FLAG" ] && backup_from_flag
        sleep 5 & wait $! 2>/dev/null
    done
}
backup_watch_start() {
    BACKUP_WATCH_PID=""
    [ "$BACKUPS" = "1" ] || return 0
    rm -f "$BACKUP_FLAG.work"
    backup_watch & BACKUP_WATCH_PID=$!
}
backup_watch_stop() {  # a backup in progress gets up to five minutes to finish
    [ -n "$BACKUP_WATCH_PID" ] || return 0
    kill -TERM "$BACKUP_WATCH_PID" 2>/dev/null
    local i
    for (( i=0; i<300; i++ )); do kill -0 "$BACKUP_WATCH_PID" 2>/dev/null || break; sleep 1; done
    kill -KILL "$BACKUP_WATCH_PID" 2>/dev/null; wait "$BACKUP_WATCH_PID" 2>/dev/null
    BACKUP_WATCH_PID=""
}

# Between runs: before an update or a wipe, back up the stopped server. A wipe
# asks for its backup in WIPE.flag ("backup 1"); an update backs up when
# Hotwire's backup settings say so.
backup_before_launch() {
    [ "$BACKUPS" = "1" ] || return 0
    local trigger="" flag="$ROOT/$WIPE_FLAG"
    # A forced wipe may not happen this start (no new build yet), so its backup is
    # taken in apply_wipe once that is known, not here on every try.
    if [ -f "$flag" ] && grep -q '^backup 1' "$flag" 2>/dev/null && ! grep -q '^forced 1' "$flag" 2>/dev/null; then
        local cycle expires
        cycle="$(grep -m1 '^cycle ' "$flag" | awk '{print $2}')"; expires="$(grep -m1 '^expires ' "$flag" | awk '{print $2}')"
        if { [ -z "$cycle" ] || [ "$(cat "$WIPE_STATE" 2>/dev/null)" != "$cycle" ]; } && { [ -z "$expires" ] || [ "$expires" -ge "$(date +%s)" ] 2>/dev/null; }; then
            # Only for a wipe that will happen: one without a permission that verifies is cancelled, before any backup.
            flag_permit_ok "$flag" && trigger="before_wipe"
        fi
    fi
    if [ -z "$trigger" ] && [ "${DO_UPDATE:-0}" = "1" ] && [ "$(_bconf enabled 0)" = "1" ] && [ "$(_bconf before_update 1)" = "1" ]; then
        trigger="before_update"
    fi
    [ -n "$trigger" ] || return 0
    log "Backing up the stopped server before the $( [ "$trigger" = before_wipe ] && echo wipe || echo update)..."
    report_step backup begun ",\"detail\":$(json_text "Before the $( [ "$trigger" = before_wipe ] && echo wipe || echo update)")"
    if backup_archive "$trigger" "$(date -u +%Y%m%dT%H%M%SZ)-$trigger" "" "" "" "" ""; then
        report_step backup done
    else
        report_step backup failed ",\"detail\":$(json_text "The backup did not finish; the start carried on. The Backups tab says why once the server reports it.")"
    fi
}

# ======================================================================
# Everything that must happen before each launch, and RE-happen on every
# relaunch exactly as hotwire.bat does from :start: the build check, the update
# decision, the hooks and the update itself, pending convar persists, the args
# and the option check. This is why a plugin that writes UPDATE.flag and
# restarts the server gets its update -- it is picked up here on the relaunch.
# ======================================================================
# A hook: an admin's own script beside the launcher, run with bash. It never
# blocks a start (a failure is logged) and never runs in check mode. Only the
# admin writes these files; nothing Hotwire or the panel produces creates them.
# It runs in its own process group, so a hook still running at
# hotwire.hook_timeout_minutes is stopped with everything it started, and the
# start carries on. How long it took goes to AFKPanel in the session report.
HOOK_RUN_BEFORE=""; HOOK_RUN_AFTER=""
run_hook() {  # run_hook <file> <label> <before|after>
    [ -f "$1" ] || return 0
    local name; name="$(basename "$1")"
    log "Running $2 ($name)..."
    report_step "hook_$3" begun ",\"detail\":$(json_text "$name")"
    # HOOK_LIMIT_SECONDS is for the launcher's own tests (tests/launcher-hooks), which cannot wait a minute.
    local limit="${HOOK_LIMIT_SECONDS:-$(( HOOK_TIMEOUT_MINUTES * 60 ))}" t0 t1 pid rc timed_out=0 tenths
    t0="${EPOCHREALTIME/[.,]/}"
    # DO_UPDATE tells the hook whether this start updates: 1 or 0.
    # Without the launcher's locks: a hook that leaves something running in the background would otherwise keep the
    # folder locked, and the next start would refuse as "another launcher is running".
    ( exec 4>&- 7>&- 8>&- 9>&-; cd "$ROOT" && DO_UPDATE="${DO_UPDATE:-0}" exec setsid bash "$1" ) &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        t1="${EPOCHREALTIME/[.,]/}"
        if [ $(( (t1 - t0) / 1000000 )) -ge "$limit" ]; then
            timed_out=1
            warn "$name was still running after $HOOK_TIMEOUT_MINUTES minutes (hotwire.hook_timeout_minutes); stopping it and starting anyway."
            kill -TERM -- "-$pid" 2>/dev/null
            local waited=0
            while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
            kill -KILL -- "-$pid" 2>/dev/null
            break
        fi
        sleep 0.2
    done
    wait "$pid" 2>/dev/null; rc=$?
    t1="${EPOCHREALTIME/[.,]/}"
    tenths=$(( (t1 - t0 + 50000) / 100000 ))
    local run="{\"seconds\":$((tenths / 10)).$((tenths % 10)),\"exit_code\":"
    if [ "$timed_out" = 1 ]; then run="$run"'null,"timed_out":true}'
    else
        run="$run$rc,\"timed_out\":false}"
        [ "$rc" = 0 ] || warn "$name exited non-zero; carrying on."
    fi
    if [ "$3" = "before" ]; then HOOK_RUN_BEFORE="$run"; else HOOK_RUN_AFTER="$run"; fi
    if [ "$timed_out" = 1 ]; then
        report_step "hook_$3" failed ",\"seconds\":$((tenths / 10)).$((tenths % 10)),\"detail\":$(json_text "$name was stopped after $HOOK_TIMEOUT_MINUTES min; the start carried on.")"
    else
        report_step "hook_$3" "$( [ "$rc" = 0 ] && echo done || echo failed )" ",\"seconds\":$((tenths / 10)).$((tenths % 10)),\"exit_code\":$rc,\"detail\":$(json_text "$name")"
    fi
}

# The hooks this start ran, as the session report's "launcher_hooks" field, or
# nothing when neither ran.
launcher_hooks_json() {
    local parts=""
    [ -n "$HOOK_RUN_BEFORE" ] && parts="\"before\":$HOOK_RUN_BEFORE"
    [ -n "$HOOK_RUN_AFTER" ] && parts="${parts:+$parts,}\"after\":$HOOK_RUN_AFTER"
    [ -n "$parts" ] && printf ',"launcher_hooks":{%s}' "$parts"
}

# Backups yield the disk to the game through ionice. Where it is missing or not allowed (some containers and VPSs),
# ionice exits instead of running the command, so backups run without it, at normal disk priority, and AFKPanel is told.
IONICE=(ionice -c3)
check_ionice() {
    LAUNCHER_NOTICES=()
    if [ "$BACKUPS" = "1" ] && ! ionice -c3 true >/dev/null 2>&1; then
        IONICE=()
        LAUNCHER_NOTICES+=("ionice_unavailable"$'\t'"ionice cannot run on this machine, so backups run at normal disk priority and compete with the game for the disk. Install util-linux's ionice, or allow it in the container, to fix it.")
        warn "ionice cannot run here; backups run at normal disk priority."
    else
        IONICE=(ionice -c3)
    fi
}

# A stop (systemctl stop, a reboot) used to end Rust with a signal, and Rust does not save on one: play since the
# last autosave was lost. Now the launcher catches the stop and asks Hotwire, through STOP.request beside the server, to
# save and quit with Rust's own quit; it waits hotwire.stop_ask_seconds for Hotwire to answer (STOP.ack) and
# hotwire.stop_save_seconds for Rust to finish, then stops it the old way. Under systemd this needs KillMode=mixed, or
# systemd signals Rust itself at the same moment: check_stop_unit tells AFKPanel when the unit lacks it.
STOP_REQUESTED=0
RUST_PID=""
run_server() {
    STOP_REQUESTED=0
    rm -f "$ROOT/STOP.request" "$ROOT/STOP.ack"
    trap 'STOP_REQUESTED=1' TERM INT
    # In the background so a signal reaches this script while Rust runs. A script's background job starts with stdin on
    # /dev/null; stdin is given back so the server console still reads what is typed. Ctrl+C in a terminal still reaches
    # Rust, which catches it and quits without saving; typing quit saves.
    "$RUST_BIN" "${ARGS[@]}" -logfile "$LOGFILE" <&0 &
    RUST_PID=$!
    local rc=0
    while :; do
        wait "$RUST_PID"; rc=$?
        if [ "$STOP_REQUESTED" = "1" ]; then
            stop_server
            wait "$RUST_PID" 2>/dev/null; rc=$?
            break
        fi
        kill -0 "$RUST_PID" 2>/dev/null || break
    done
    trap - TERM INT
    RUST_RC=$rc
}

stop_server() {
    local req="$ROOT/STOP.request" ack="$ROOT/STOP.ack" i
    log "Stop requested: asking Hotwire to save the world and quit..."
    date -u +%Y-%m-%dT%H:%M:%SZ > "$req" 2>/dev/null
    for (( i=0; i < STOP_ASK_SECONDS * 2; i++ )); do
        [ -f "$ack" ] && break
        kill -0 "$RUST_PID" 2>/dev/null || break
        sleep 0.5
    done
    if [ -f "$ack" ]; then
        for (( i=0; i < STOP_SAVE_SECONDS; i++ )); do
            kill -0 "$RUST_PID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$RUST_PID" 2>/dev/null; then
            warn "The server did not quit within ${STOP_SAVE_SECONDS}s (hotwire.stop_save_seconds); stopping it without a save."
        else
            ok "The server saved and quit."
        fi
    elif kill -0 "$RUST_PID" 2>/dev/null; then
        warn "Hotwire did not answer within ${STOP_ASK_SECONDS}s (hotwire.stop_ask_seconds; is it loaded?); stopping the server without a save."
    fi
    if kill -0 "$RUST_PID" 2>/dev/null; then
        kill -TERM "$RUST_PID" 2>/dev/null
        for (( i=0; i < 15; i++ )); do kill -0 "$RUST_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "$RUST_PID" 2>/dev/null
    fi
    rm -f "$req" "$ack"
}

# Under systemd, a unit without KillMode=mixed signals Rust itself when it stops, before Hotwire can save: the
# launcher's handshake cannot help it. Setup 0.2.28 writes the unit with it; AFKPanel is told when this one lacks it.
check_stop_unit() {
    [ -n "${INVOCATION_ID:-}" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit mode
    unit="$(sed -n 's|^0::.*/\([^/]*\.service\)$|\1|p' /proc/self/cgroup 2>/dev/null | head -1)"
    [ -n "$unit" ] || return 0
    mode="$(systemctl show -p KillMode --value "$unit" 2>/dev/null)"
    [ -z "$mode" ] || [ "$mode" = "mixed" ] && return 0
    LAUNCHER_NOTICES+=("stop_kills_server"$'\t'"This server's systemd unit ($unit) stops Rust directly, so a stop or a reboot loses the play since the last save. Run hotwire-setup.sh install again to update the unit, or add KillMode=mixed and TimeoutStopSec=120 to its [Service] section.")
    warn "$unit stops Rust directly (KillMode=$mode): a stop loses play since the last save. Run hotwire-setup.sh install again to fix it."
}

per_launch_prep() {
    UPDATE_ATTEMPTED=0; UPDATE_FLAG_KEPT=0; UPDATE_LOG=(); UPDATE_REASON=""; STEAM_OK=0; FRAMEWORK_OK=0
    # hotwire.cfg is read again before every start, so an edit takes effect on
    # the next restart without restarting the launcher.
    [ -n "${CONFIG_LOADED:-}" ] && { config_reload; load_secrets; }
    CONFIG_LOADED=1
    START_ID="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    init_reporting
    report_step check begun
    # Hotwire's own update goes first, while nothing else has changed: a new launcher takes over at once (exit 75).
    self_update_step || { [ $? = 75 ] && exit 75; }
    check_ionice
    check_stop_unit
    UPDATE_CAPTURE=1
    # An update mode AFKPanel asked for is written first, so this start's update decision already follows it.
    [ -z "$CHECK_ONLY" ] && apply_update_mode_request
    decide_update_mode
    build_check
    # The installed build before any update this pass: framework_update compares with it (Oxide goes back over a new build).
    BUILD_BEFORE="$INSTALLED_BUILD"
    update_decision
    report_check_step
    # Check mode says what a normal start would do, rather than "Plain restart".
    if [ -n "$CHECK_ONLY" ]; then
        if [ "$DO_UPDATE" = "1" ]; then log "Check mode: a normal start would update here. Nothing is installed."
        else log "Check mode: a normal start would launch without updating."; fi
        [ "$DO_UPDATE" = "1" ] && update_reason check_only
        DO_UPDATE=0
    fi
    # The backup and the before-start hook speak for themselves; their lines are not the update's.
    UPDATE_CAPTURE=0
    # A backup of the stopped server, before an update or a wipe changes it.
    [ -z "$CHECK_ONLY" ] && backup_before_launch
    # hotwire-before.sh runs on every real start (not in check mode), before any update.
    HOOK_RUN_BEFORE=""; HOOK_RUN_AFTER=""
    [ -z "$CHECK_ONLY" ] && run_hook "$HOOK_BEFORE" "the before-start hook" before
    if [ "$DO_UPDATE" = "1" ]; then
        UPDATE_ATTEMPTED=1
        UPDATE_CAPTURE=1
        steam_update
        framework_update
        finalize_update
        UPDATE_CAPTURE=0
        # hotwire-after.sh runs after an update attempt (success or not), like the .bat.
        run_hook "$HOOK_AFTER" "the after-update hook" after
    elif [ -z "$CHECK_ONLY" ]; then
        UPDATE_CAPTURE=1; log "Plain restart: no update this pass."; UPDATE_CAPTURE=0
        # A flag left on disk by a start that does not update (hotwire.update_mode off) is reported as kept.
        { [ -e "$ROOT/$UPDATE_FLAG" ] || [ -e "$ROOT/$VALIDATE_FLAG" ]; } && UPDATE_FLAG_KEPT=1
    fi
    # Check mode changes nothing on your behalf (as hotwire.bat's does): a wipe or a
    # convar persist is a real mutation, so it is only carried out on a real start.
    if [ -z "$CHECK_ONLY" ]; then
        WIPE_APPLIED=0
        apply_wipe
        [ "$WIPE_APPLIED" = 1 ] && report_step wipe done ",\"detail\":$(json_text "$(head -1 "$WIPE_RESULT" 2>/dev/null | sed 's/^applied: //')")"
        apply_convar_requests
        # Both write hotwire.cfg; read it again so this start uses what they wrote.
        if [ "$WIPE_APPLIED" = 1 ] || [ "$CONVAR_CHANGED" = 1 ]; then load_config || config_reload; fi
    fi
    build_args
    check_options
}

# ======================================================================
# The run loop.
# ======================================================================
run_loop() {
    while :; do
        per_launch_prep
        rotate_log
        write_launcher_state
        STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        report_session_start
        # Held reports go in the background, this start's among them; the server starts without waiting.
        spool_kick
        log "Starting server..."
        report_step launch done
        local start_ts end_ts run_secs rc crashed
        start_ts="$(date +%s)"
        backup_watch_start
        boot_watch_start
        su_watch_start
        run_server; rc=$RUST_RC
        end_ts="$(date +%s)"
        su_watch_stop
        boot_watch_stop
        backup_watch_stop
        run_secs=$(( end_ts - start_ts )); [ "$run_secs" -lt 0 ] && run_secs=99999

        if [ "$run_secs" -lt "$CRASH_SECONDS" ]; then CRASH_STREAK=$((CRASH_STREAK+1)); crashed=true; else CRASH_STREAK=0; crashed=false; fi
        # A stop that was asked for is not a crash, however soon after the start it came.
        if [ "$STOP_REQUESTED" = "1" ]; then CRASH_STREAK=0; crashed=false; fi
        # A crash while an update of Hotwire is still on probation puts the previous files back before the next start.
        [ "$crashed" = true ] && [ -f "$SU_APPLIED" ] && su_after_failed_probation crashed
        report_session "$rc" "$crashed"
        # It goes now, in the background, not after the next update.
        spool_kick

        # A stop that was asked for is final: exit 0, which a systemd unit with Restart=on-failure does not restart.
        if [ "$STOP_REQUESTED" = "1" ]; then log "Stopped."; spool_flush; exit 0; fi
        if [ "$RESTART_ON_EXIT" = "0" ]; then log "Server exited; hotwire.restart_on_exit is 0. Stopping."; spool_flush; exit 0; fi

        if [ "$MAX_CRASH_STREAK" != "0" ] && [ "$CRASH_STREAK" -ge "$MAX_CRASH_STREAK" ]; then
            rule
            bad "Stopped: the server has crashed $CRASH_STREAK times in a row (each under ${CRASH_SECONDS}s)."
            log  "The log that explains it is the newest logs/server_crash_*.txt."
            log  "Common causes: a bad convar, a port already in use (another server?), or a broken update."
            rule
            report_launcher_stopped "$CRASH_STREAK consecutive runs under ${CRASH_SECONDS}s"
            # Stopping for good: nothing waits to start, so this report goes now.
            spool_flush
            # Exit 0: this stop is on purpose. A systemd unit with Restart=on-failure restarts any other exit
            # status, which would bring the crash loop straight back.
            exit 0
        fi

        local delay="$RESTART_DELAY"
        if [ "$CRASH_BACKOFF" != "0" ]; then
            if   [ "$CRASH_STREAK" -ge 5 ]; then delay=300
            elif [ "$CRASH_STREAK" -ge 4 ]; then delay=120
            elif [ "$CRASH_STREAK" -ge 3 ]; then delay=60
            elif [ "$CRASH_STREAK" -ge 2 ]; then delay=30
            fi
        fi
        if [ "$CRASH_STREAK" -gt 0 ]; then
            warn "Server ran only ${run_secs}s (crash streak $CRASH_STREAK). Restarting in ${delay}s..."
        else
            log "Server exited after ${run_secs}s. Restarting in ${delay}s -- Ctrl-C to stop."
        fi
        sleep "$delay"

        # A hotwire-launcher.sh replaced while the server ran takes over here, as the Windows launcher's hotwire.ps1 does:
        # hotwire.sh runs it again (exit 75). Only when hotwire.sh started this one; run on its own, it keeps going.
        if [ -n "${HOTWIRE_STARTER:-}" ] && [ -n "${SELF_STAMP:-}" ] && [ "$(launcher_stamp)" != "$SELF_STAMP" ]; then
            log "hotwire-launcher.sh has changed: starting the new copy."
            spool_flush
            exit 75
        fi
    done
}

# The logic file's identity: size, time and inode, so a copy moved into place is seen even in the same second.
launcher_stamp() { stat -c '%s:%Y:%i' "$ROOT/hotwire-launcher.sh" 2>/dev/null; }

# ======================================================================
# Main.
# ======================================================================
printf '%s%s H O T W I R E %s  launcher %s%s%s\n' \
    "$C_BLD" "$C_CYN" "$C_OFF" "$C_BLD" "$HOTWIRE_LAUNCHER_VERSION" "$C_OFF"
[ -n "$CHECK_ONLY" ] && log "Check mode: everything is checked, nothing is started."

# One launcher per server folder. A second one would update, back up and wipe under the server the first one runs, then
# crash-loop on its ports. The lock is held for the launcher's life (and by the server it starts, so a server left
# running after its launcher was killed still holds the folder); the kernel drops it when the last holder ends.
if [ -z "$CHECK_ONLY" ] && command -v flock >/dev/null 2>&1; then
    mkdir -p "$ROOT/hotwire" 2>/dev/null
    if exec 4>"$ROOT/hotwire/launcher.lock"; then
        if ! flock -n 4; then
            holders="$(fuser "$ROOT/hotwire/launcher.lock" 2>/dev/null | tr -s '[:space:]' ' ')"
            # Exit 3, not die's 1: a second launcher refused is not a broken one, so hotwire.sh never rolls back over it.
            ( die "Another launcher, or the server it started, is already running in $ROOT${holders:+ (process$holders)}.
  Stop that one first. Two launchers in one folder would update and wipe under a running server." )
            exit 3
        fi
    fi
fi

config_or_die
load_secrets
preflight
init_reporting
SELF_STAMP="$(launcher_stamp)"

if [ -n "$CHECK_ONLY" ]; then
    per_launch_prep
    ok "Check complete. Not starting the server (check mode)."
    exit 0
fi

run_loop
