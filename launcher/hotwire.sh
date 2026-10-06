#!/usr/bin/env bash
#
# ==[ H O T W I R E ]===================================================
#  Hotwire launcher for Linux. Its version is HOTWIRE_LAUNCHER_VERSION below.
#  Built by xman2000 and Claude.  MIT License.
#  https://github.com/xman2000/hotwire
#
#  Your settings are in hotwire.cfg, beside this file, and the RCON
#  password is in hotwire-secrets.cfg. This file holds no settings:
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
HOTWIRE_LAUNCHER_VERSION="1.1.11-linux"
HOTWIRE_LAUNCHER_CAPABILITIES="supervise,update,framework_verify,crash_backstop,log_rotate,convar_persist,wipe,wipe_same_map,wipe_custom_map,backup,settings_file"

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
#     2. Copy hotwire-secrets.example.cfg to hotwire-secrets.cfg and set the
#        RCON password.
#     3. Keep hotwire.sh beside RustDedicated: its own folder is the server's.
#     4. Run ./hotwire.sh check, then ./hotwire.sh.
#
# ======================================================================

# ------------------------------------------------------ fixed, not settings ----
# Where code comes from is never a setting: hotwire.cfg is data that other tools
# may write, and data must never be able to say what gets downloaded or run.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    MAX_DAYS_WITHOUT_UPDATE="14"; MAX_STEAM_TRIES="5"; STEAM_RETRY_SECONDS="60"; STEAMCMD_WAIT_MINUTES="60"; FORCED_WIPE_STEAM_MINUTES="15"
    BUILD_CHECK_HOURS="6"; UPDATE_ON_NEW_BUILD="1"; FAST_RUST_UPDATES="0"; RECOVER_REFUSED_UPDATE="1"
    INSTALL_FRAMEWORK="1"; SKIP_UNCHANGED_FRAMEWORK="1"; VERIFY_FRAMEWORK="1"
    RESTART_ON_EXIT="1"; RESTART_DELAY="15"; CRASH_SECONDS="60"; MAX_CRASH_STREAK="10"; CRASH_BACKOFF="1"
    ROTATE_LOGS="1"; LOG_KEEP="14"; RCON_PASSWORD_MIN="8"; CHECK_OPTIONS="1"; BACKUPS="1"
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
log()  { printf '%s[%s]%s %s\n' "$C_DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_OFF" "$*"; }
ok()   { printf '%s[%s]%s %s[ ok ]%s %s\n'  "$C_DIM" "$(date '+%H:%M:%S')" "$C_OFF" "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[%s]%s %s[warn]%s %s\n'  "$C_DIM" "$(date '+%H:%M:%S')" "$C_OFF" "$C_YEL" "$C_OFF" "$*"; }
bad()  { printf '%s[%s]%s %s[fail]%s %s\n'  "$C_DIM" "$(date '+%H:%M:%S')" "$C_OFF" "$C_RED" "$C_OFF" "$*"; }
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

# load_config: read hotwire.cfg into the settings. Returns non-zero when a
# critical line failed (CFG_FATAL), in which case nothing is changed.
load_config() {
    CFG_PROBLEMS=(); CFG_FATAL=(); CFG_UNKNOWN=()
    if [ ! -f "$CFG" ]; then
        CFG_FATAL+=("hotwire.cfg is missing")
        return 1
    fi
    local -A staged=() extra=() known=()
    local -a order=()
    local n=0 raw line name lower spec var kind listed=1
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
        if ! cfg_line "$line"; then CFG_PROBLEMS+=("line $n: $CFG_WHY"); continue; fi
        name="$CFG_NAME"; lower="${name,,}"
        [ "$listed" = 1 ] && known[$lower]=1
        if [ "$lower" = "rcon.password" ]; then
            CFG_PROBLEMS+=("line $n: rcon.password: belongs in hotwire-secrets.cfg, never here; ignored"); continue
        fi
        spec="${HW_SETTINGS[$lower]:-${CV_SETTINGS[$lower]:-}}"
        if [ -n "$spec" ]; then
            var="${spec%% *}"; kind="${spec#* }"
            if ! cfg_check "$kind" "$CFG_VALUE"; then
                if cfg_critical "$kind"; then CFG_FATAL+=("line $n: $name: $CFG_WHY")
                else CFG_PROBLEMS+=("line $n: $name: $CFG_WHY; the default is used"); fi
                continue
            fi
            # A number goes on in base 10: bash reads a leading zero as octal, so "08" would stop the launcher.
            case "$kind" in int|int1|seed|worldsize|port) [ -n "$CFG_VALUE" ] && CFG_VALUE="$((10#$CFG_VALUE))" ;; esac
            # For a launcher setting an empty value is its default, except the Steam branch, where empty means
            # "let Steam keep the last one". A server convar's empty value is the game's default, as the file says.
            if [ -z "$CFG_VALUE" ] && [ -n "${HW_SETTINGS[$lower]:-}" ] && [ "$kind" != word ]; then continue; fi
            staged[$var]="$CFG_VALUE"
            continue
        fi
        if [[ "$lower" == hotwire.* ]]; then
            CFG_PROBLEMS+=("line $n: $name: not a launcher setting; ignored"); continue
        fi
        # Any other Rust convar, passed through as it is. Empty means the default.
        [ -z "$CFG_VALUE" ] && continue
        [ -z "${extra[$lower]+x}" ] && order+=("$lower")
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
# hotwire.cfg; only rcon.password is taken from it. Read before every start:
# a problem stops the first start, and a later start keeps the last good
# password and says so.
# ======================================================================
RCON_PASSWORD=""
load_secrets() {
    local raw line n=0 password="" why=""
    if [ ! -f "$SECRETS_CFG" ]; then
        why="No hotwire-secrets.cfg beside the launcher. Copy hotwire-secrets.example.cfg to hotwire-secrets.cfg and set rcon.password."
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
        if [ -z "$password" ]; then why="hotwire-secrets.cfg does not set rcon.password."
        elif [ "$password" = "change_me" ]; then why="rcon.password is still the example 'change_me'. Set a real one in hotwire-secrets.cfg."
        elif [ "${#password}" -lt "$RCON_PASSWORD_MIN" ]; then why="rcon.password is shorter than hotwire.rcon_password_min ($RCON_PASSWORD_MIN)."
        fi
    fi
    if [ -n "$why" ]; then
        [ -z "$RCON_PASSWORD" ] && die "$why"
        rule; bad "$why"; bad "Starting with the RCON password from the last start."; rule
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

    local tries=0
    while :; do
        tries=$((tries+1))
        if [ "$deadline" -gt 0 ] && [ "$tries" -gt "$MAX_STEAM_TRIES" ]; then
            log "steamcmd update, attempt $tries (a forced wipe waits: trying until $(date -d "@$deadline" +%H:%M))..."
        else
            log "steamcmd update, attempt $tries of $MAX_STEAM_TRIES..."
        fi
        # Blocking lock, but bounded by STEAMCMD_WAIT_MINUTES so a stuck sibling
        # never holds this server down: past the deadline we start what we have.
        exec 8>"$STEAM_LOCK" || { warn "Could not open the steamcmd lock."; return 0; }
        if flock -w $(( STEAMCMD_WAIT_MINUTES * 60 )) 8; then
            note_steam_logs
            "$STEAMCMD" "${args[@]}"; local rc=$?
            refused=0; [ "$rc" != "0" ] && update_refused_installed && refused=1
            exec 8>&-
            if [ "$rc" = "0" ]; then STEAM_OK=1; ok "steamcmd finished."; return 0; fi
            bad "steamcmd exited $rc."
        else
            exec 8>&-
            warn "Waited $STEAMCMD_WAIT_MINUTES min for another server's steamcmd; starting with what is on disk."
            return 0
        fi
        # Once per update, a refusal of the installed build's file list is mended at once, whatever the try count:
        # every further try would be refused the same way.
        if [ "$refused" = "1" ] && [ "$recovery_used" = "0" ] && set_record_aside; then
            recovery_used=1
            continue
        fi
        if [ "$tries" -ge "$MAX_STEAM_TRIES" ] && [ "$(date +%s)" -ge "$deadline" ]; then
            warn "steamcmd gave up after $tries attempts; starting what is on disk."
            return 0
        fi
        # Once per update, a try that left the install marked Files Corrupt is retried at once: Steam checks every
        # file on that next run, so waiting changes nothing.
        if [ "$quick_retry_used" = "0" ] && manifest_marked_corrupt; then
            quick_retry_used=1
            log "Steam marked the game files for a full check; trying again now."
            continue
        fi
        log "Retrying in $STEAM_RETRY_SECONDS s..."; sleep "$STEAM_RETRY_SECONDS"
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
            FRAMEWORK_OK=1; return 0
        fi
    fi

    local zip="$ROOT/OxideMod.zip"
    [ -n "$sha" ] && log "Downloading Oxide ${tag:-latest} (will verify SHA-256)..." || log "Downloading Oxide (unverified)..."
    # A stalled download gives up (under 1 byte a second for 2 minutes); a slow one carries on.
    if ! curl -fSL -A "Mozilla/5.0" --connect-timeout 30 --speed-limit 1 --speed-time 120 "$from" --output "$zip" 2>/dev/null; then
        warn "Oxide download failed; keeping the current install."
        rm -f "$zip"; return 0
    fi
    if [ -n "$sha" ]; then
        local got; got="$(sha256sum "$zip" | cut -d' ' -f1)"
        if [ "${got,,}" != "${sha,,}" ]; then
            bad "Oxide SHA-256 does not match; NOT extracting."; rm -f "$zip"; return 0
        fi
        ok "Oxide SHA-256 matches."
    fi
    if unzip -o "$zip" -d "$ROOT" >/dev/null 2>&1; then
        FRAMEWORK_OK=1
        # Record the version we just installed for the next skip check: the release we downloaded, or nothing when it
        # could not be read (the next update then extracts again, the safe direction).
        if [ -n "$tag" ]; then printf '%s' "$tag" > "$OXIDE_STAMP" 2>/dev/null || true; else rm -f "$OXIDE_STAMP"; fi
        ok "Oxide extracted."
    else
        warn "Could not extract Oxide; keeping the current install."
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
    ARGS+=( +rcon.password "$RCON_PASSWORD" )
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
    local self; self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    cat > "$LAUNCHER_STATE" 2>/dev/null <<JSON || true
{
  "version": "$HOTWIRE_LAUNCHER_VERSION",
  "capabilities": "$HOTWIRE_LAUNCHER_CAPABILITIES",
  "platform": "linux",
  "update_mode": "$UPDATE_MODE",
  "path": "$self"
}
JSON
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
_hmac()   { printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" | sed 's/^.*= *//'; }
_bool()   { [ "$1" = "1" ] && printf 'true' || printf 'false'; }

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
    sig="$(_hmac "$SCRIPT_SECRET" "$(printf '%s %s\n%s\n%s\n%s' POST /api/v1/report "$ts" "$nonce" "$(_sha256 "$body")")")"
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
            429|5*|000) break ;;
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
spool_kick() {
    [ "$REPORT_ENABLED" = "1" ] || return 0
    [ -d "$SPOOL_DIR" ] || return 0
    # Its own descriptor (6), and none of the launcher's locks (7 backup, 8 and 9
    # SteamCMD) kept open in it: a sender still running must not hold them.
    ( exec 7>&- 8>&- 9>&- 6>"$SPOOL_DIR/.sending"; flock -n 6 || exit 0; spool_drain ) </dev/null &
}

# Before the launcher stops for good: the last reports go now, while there is a
# launcher to send them. Waits for a background sender first, at most a minute.
spool_flush() {
    [ "$REPORT_ENABLED" = "1" ] || return 0
    [ -d "$SPOOL_DIR" ] || return 0
    ( exec 7>&- 8>&- 9>&- 6>"$SPOOL_DIR/.sending"; flock -w 60 6 || exit 0; spool_drain ) </dev/null
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
    p="$p,\"update\":{\"attempted\":$(_bool "$UPDATE_ATTEMPTED"),\"steam_ok\":$(_bool "$STEAM_OK"),\"framework_ok\":$(_bool "$FRAMEWORK_OK"),\"flag_kept\":$(_bool "$UPDATE_FLAG_KEPT")}}"
    hw_send session "$p"
}

# The launcher report: sent when the crash-streak backstop stops the server for
# good. Absence of a heartbeat cannot tell "stopped, needs a human" from "the
# network is out"; this can.
report_launcher_stopped() {  # <detail>
    [ "$REPORT_ENABLED" = "1" ] || return 0
    local plog; plog="$(ls -1t "$LOGDIR" 2>/dev/null | grep server_crash_ | head -1)"
    [ -n "$plog" ] && plog="logs/$plog"
    hw_send launcher "{\"state\":\"stopped\",\"reason\":\"crash_streak\",\"detail\":\"$1\",\"crash_streak\":$CRASH_STREAK,\"preserved_log\":\"$plog\"}"
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
        !done {
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
    [ -z "$why" ] && seed="$((10#$seed))" && { [ -z "$size" ] || size="$((10#$size))"; }
    case "$bp" in keep|rename|delete) ;; *) [ -z "$why" ] && why="blueprints must be keep, rename or delete";; esac
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
                if nice -n 19 ionice -c3 zstd -3 -T2 -q -f "$mapfile" -o "$dest/maps/$mapname.zst.part" 2>/dev/null \
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
        if ( cd "$work" && tar -cf - . ) | nice -n 19 ionice -c3 zstd -3 -T2 -q -o "$dest/$name.part" 2>/dev/null \
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
            trigger="before_wipe"
        fi
    fi
    if [ -z "$trigger" ] && [ "${DO_UPDATE:-0}" = "1" ] && [ "$(_bconf enabled 0)" = "1" ] && [ "$(_bconf before_update 1)" = "1" ]; then
        trigger="before_update"
    fi
    [ -n "$trigger" ] || return 0
    log "Backing up the stopped server before the $( [ "$trigger" = before_wipe ] && echo wipe || echo update)..."
    backup_archive "$trigger" "$(date -u +%Y%m%dT%H%M%SZ)-$trigger" "" "" "" "" "" || true
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
run_hook() {  # run_hook <file> <label>
    [ -f "$1" ] || return 0
    log "Running $2 ($(basename "$1"))..."
    # DO_UPDATE tells the hook whether this start updates: 1 or 0.
    ( cd "$ROOT" && DO_UPDATE="${DO_UPDATE:-0}" bash "$1" ) || warn "$(basename "$1") exited non-zero; carrying on."
}

per_launch_prep() {
    UPDATE_ATTEMPTED=0
    # hotwire.cfg is read again before every start, so an edit takes effect on
    # the next restart without restarting the launcher.
    [ -n "${CONFIG_LOADED:-}" ] && { config_reload; load_secrets; }
    CONFIG_LOADED=1
    init_reporting
    decide_update_mode
    build_check
    # The installed build before any update this pass: framework_update compares with it (Oxide goes back over a new build).
    BUILD_BEFORE="$INSTALLED_BUILD"
    update_decision
    # Check mode says what a normal start would do, rather than "Plain restart".
    if [ -n "$CHECK_ONLY" ]; then
        if [ "$DO_UPDATE" = "1" ]; then log "Check mode: a normal start would update here. Nothing is installed."
        else log "Check mode: a normal start would launch without updating."; fi
        DO_UPDATE=0
    fi
    # A backup of the stopped server, before an update or a wipe changes it.
    [ -z "$CHECK_ONLY" ] && backup_before_launch
    # hotwire-before.sh runs on every real start (not in check mode), before any update.
    [ -z "$CHECK_ONLY" ] && run_hook "$HOOK_BEFORE" "the before-start hook"
    if [ "$DO_UPDATE" = "1" ]; then
        UPDATE_ATTEMPTED=1
        steam_update
        framework_update
        finalize_update
        # hotwire-after.sh runs after an update attempt (success or not), like the .bat.
        run_hook "$HOOK_AFTER" "the after-update hook"
    elif [ -z "$CHECK_ONLY" ]; then
        log "Plain restart: no update this pass."
    fi
    # Check mode changes nothing on your behalf (as hotwire.bat's does): a wipe or a
    # convar persist is a real mutation, so it is only carried out on a real start.
    if [ -z "$CHECK_ONLY" ]; then
        WIPE_APPLIED=0
        apply_wipe
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
        # Held reports go in the background; the server starts without waiting.
        spool_kick
        rotate_log
        write_launcher_state
        log "Starting server..."
        STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local start_ts end_ts run_secs rc crashed
        start_ts="$(date +%s)"
        backup_watch_start
        "$RUST_BIN" "${ARGS[@]}" -logfile "$LOGFILE"; rc=$?
        end_ts="$(date +%s)"
        backup_watch_stop
        run_secs=$(( end_ts - start_ts )); [ "$run_secs" -lt 0 ] && run_secs=99999

        if [ "$run_secs" -lt "$CRASH_SECONDS" ]; then CRASH_STREAK=$((CRASH_STREAK+1)); crashed=true; else CRASH_STREAK=0; crashed=false; fi
        report_session "$rc" "$crashed"
        # It goes now, in the background, not after the next update.
        spool_kick

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
    done
}

# ======================================================================
# Main.
# ======================================================================
printf '%s%s H O T W I R E %s  launcher %s%s%s\n' \
    "$C_BLD" "$C_CYN" "$C_OFF" "$C_BLD" "$HOTWIRE_LAUNCHER_VERSION" "$C_OFF"
[ -n "$CHECK_ONLY" ] && log "Check mode: everything is checked, nothing is started."

config_or_die
load_secrets
preflight
init_reporting

if [ -n "$CHECK_ONLY" ]; then
    per_launch_prep
    ok "Check complete. Not starting the server (check mode)."
    exit 0
fi

run_loop
