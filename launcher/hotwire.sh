#!/usr/bin/env bash
#
# ==[ H O T W I R E ]===================================================
#
#   Hotwire launcher for Linux -- the bash sibling of hotwire.bat.
#
#   Built by xman2000 and Claude. MIT License.
#   https://github.com/xman2000/hotwire
#
#   It keeps a Rust dedicated server running: it updates the game and
#   Oxide when told to, starts the server, restarts it when it exits,
#   and stops trying only when a server crashes over and over (so a
#   broken server does not thrash forever).
#
#   THE PANEL NEVER REACHES IN. There is no inbound path: the plugin and the
#   launcher speak only through the local flag file (UPDATE.flag / VALIDATE.flag),
#   and the launcher reports OUTWARD to the panel as the contract's `script`
#   component -- signed with the script key, best-effort, spooled on failure, and
#   never able to block or fail the server (rule 1). It reports only what only it
#   knows: how a run ended, the update outcome, and a crash-streak stop. It sends
#   findings and facts; a file never travels.
#
#   Requires: bash 4+, curl, unzip, and flock (util-linux). jq is used
#   for the Oxide SHA-256 verification when present; without it the
#   download is taken unverified, with a warning, exactly as the guide
#   describes.
#
#   Usage:
#     ./hotwire.sh          start (or resume) the supervised server
#     ./hotwire.sh check    run every check and report, but do not start
#
# ======================================================================

# --- Launcher identity (see the SETTINGS block below for what an admin edits).
#     HOTWIRE_LAUNCHER_HASH is stamped by tools/launcher-hash.sh at release and
#     is excluded from its own computation, as is the whole SETTINGS block, so an
#     admin editing settings never changes the hash. The plugin recomputes the
#     hash from these bytes to confirm this is an unmodified Hotwire launcher
#     before it offers a launcher-editing feature. Capabilities, not the version
#     number, are what a feature is gated on.
HOTWIRE_LAUNCHER_VERSION="1.0.0-linux"
HOTWIRE_LAUNCHER_CAPABILITIES="supervise,update,framework_verify,crash_backstop,log_rotate,convar_persist"
HOTWIRE_LAUNCHER_HASH="a1d258eae29c040c42d67141c7459239c7b5c9a89f12a8405f6f8e8c50a26c8d"

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

# ======================================================================
# === HOTWIRE SETTINGS BEGIN ===========================================
#   Everything between BEGIN and END is yours to edit. It is excluded
#   from the launcher's code hash, so changing anything here never marks
#   the launcher "modified" or turns off a panel feature. To turn a
#   convar on, remove the leading '#'; to turn it off, put it back.
# ======================================================================

# -- Where things are ---------------------------------------------------
# ROOT is worked out from this script's own location, so a copied server
# folder brings its launcher with it. Leave it unless you know better.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The steamcmd executable. The Ubuntu package installs it here; other
# distributions differ. Several servers may share one steamcmd.
STEAMCMD="/usr/games/steamcmd"

# Rust's Steam app id. Do not change this.
APPID="258550"

# Steam branch. "public" is the live game. Empty lets Steam keep the last one.
STEAM_BRANCH="public"

# -- Updating -----------------------------------------------------------
# always  = update the game and Oxide every start (simple, a little slower).
# hotwire = update only on a flag, a newer build, or the day backstop below.
# off     = never update here; a flag is left in place and reported.
UPDATE_MODE="always"

# The flag files the plugin writes to ask for an update. Must match the
# plugin's config. UPDATE = update; VALIDATE = update and re-verify every file.
UPDATE_FLAG="UPDATE.flag"
VALIDATE_FLAG="VALIDATE.flag"

# hotwire mode only: force an update after this many days without one. 0 = off.
MAX_DAYS_WITHOUT_UPDATE="14"

# steamcmd attempts before giving up and starting what is on disk.
MAX_STEAM_TRIES="5"
# Seconds between steamcmd attempts.
STEAM_RETRY_SECONDS="60"
# Minutes to wait for another server's steamcmd run (the shared lock) before
# giving up on updating this pass and starting as-is.
STEAMCMD_WAIT_MINUTES="60"

# -- The "am I behind?" build check (hotwire mode) ----------------------
# Cache lifetime in hours for the Steam build check. 0 disables the check.
BUILD_CHECK_HOURS="6"
# Update when Steam's build is newer than the installed one. Needs the check on.
UPDATE_ON_NEW_BUILD="1"

# -- Oxide (the framework) ----------------------------------------------
# 1 = install/refresh Oxide with the server; 0 = vanilla, never touched.
INSTALL_FRAMEWORK="1"
# 1 = skip re-extracting Oxide when neither it nor the game changed.
SKIP_UNCHANGED_FRAMEWORK="1"
# Verify the Oxide download against GitHub's published SHA-256 before extracting.
VERIFY_FRAMEWORK="1"
# The umod feed publishing Oxide's current version (used for the skip check).
FRAMEWORK_FEED="https://assets.umod.org/games/rust.json"
# The Linux Oxide build and where its SHA-256 is published.
FRAMEWORK_RELEASES="https://api.github.com/repos/OxideMod/Oxide.Rust/releases/latest"
FRAMEWORK_ASSET="Oxide.Rust-linux.zip"
FRAMEWORK_URL="https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust-linux.zip"

# -- Restarting and crashes ---------------------------------------------
# 1 = relaunch the server when it exits; 0 = the launcher stops when it does.
RESTART_ON_EXIT="1"
# Seconds to wait before a normal relaunch (grows on repeated crashes).
RESTART_DELAY="15"
# A run shorter than this many seconds counts as a crash, not a restart.
CRASH_SECONDS="60"
# Consecutive crashes before the launcher stops. 0 = never stop.
MAX_CRASH_STREAK="10"
# 1 = wait longer after repeated crashes (30, 60, 120, 300s). 0 = always the delay above.
CRASH_BACKOFF="1"

# -- Logs ---------------------------------------------------------------
# 1 = keep each run's log; 0 lets the server truncate it every start.
ROTATE_LOGS="1"
# How many rotated logs to keep. Cannot be 0.
LOG_KEEP="14"

# -- Safety and hooks ---------------------------------------------------
# Shortest RCON password allowed. Cannot be 0 (an empty password crashes Rust).
RCON_PASSWORD_MIN="8"
# 1 = check the convar list below before starting; 0 = skip the check.
CHECK_OPTIONS="1"
# Commands to run before every start (HOOK_BEFORE) and after an update (HOOK_AFTER).
HOOK_BEFORE=""
HOOK_AFTER=""

# -- Server settings the browser and the map use -----------------------
# Filled in as plain values (safe for spaces and symbols). Empty = the game's default.
SERVER_IDENTITY=""          # save-folder name; empty = my_server_identity
SERVER_SEED=""              # map seed; empty = 1337. hotwire-setup writes one for a new server.
SERVER_WORLDSIZE=""         # metres across, 1000-6000; empty = 4500
SERVER_LEVEL="Procedural Map"
SERVER_LEVELURL=""          # a custom map URL; replaces level/seed/worldsize
SERVER_PORT="28015"
SERVER_QUERYPORT="28017"
RCON_PORT="28016"
RCON_WEB="1"
SERVER_MAXPLAYERS=""        # empty = the game's default (500)
SERVER_HOSTNAME=""          # your server's name in the browser
SERVER_DESCRIPTION=""
SERVER_TAGS=""

# -- Extra convars ------------------------------------------------------
# Add one per line, uncommented, exactly as you would on the command line.
# Examples (remove the '#' to use):
#EXTRA_CONVARS+=( "+server.saveinterval" "300" )
#EXTRA_CONVARS+=( "+server.printReportsToConsole" "1" )
EXTRA_CONVARS=()

# ======================================================================
# === HOTWIRE SETTINGS END =============================================
# ======================================================================


# ----------------------------------------------------- derived paths ----
LOGDIR="$ROOT/logs"
LOGFILE="$LOGDIR/server_log.txt"
UPDATE_STAMP="$LOGDIR/last_update.txt"
BUILD_CACHE="$LOGDIR/build_check.txt"
OXIDE_STAMP="$LOGDIR/oxide_installed.txt"
CONVAR_REQUEST="$ROOT/CONVAR.request"
CONVAR_RESULT="$ROOT/CONVAR.result"
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
SECRETS="$ROOT/secrets.sh"
RUST_BIN="$ROOT/RustDedicated"
APPMANIFEST="$ROOT/steamapps/appmanifest_${APPID}.acf"
LAUNCHER_STATE="$ROOT/oxide/data/Hotwire/launcher.json"

CRASH_STREAK=0

# ======================================================================
# Section 1b -- settings validation. A wrong number here is caught now,
# not with a broken server at three in the morning.
# ======================================================================
validate_settings() {
    local bad_cfg=""
    ROOT="${ROOT%/}"; STEAMCMD="${STEAMCMD%/}"

    [ -z "$ROOT" ] && bad_cfg+=$'\n  ROOT is empty.'
    case "$UPDATE_MODE" in
        always|hotwire|off) ;;
        *) bad_cfg+=$'\n  UPDATE_MODE must be always, hotwire or off.' ;;
    esac
    [ -z "$UPDATE_FLAG" ]   && bad_cfg+=$'\n  UPDATE_FLAG is empty.'
    [ -z "$VALIDATE_FLAG" ] && bad_cfg+=$'\n  VALIDATE_FLAG is empty.'

    local n
    for n in MAX_DAYS_WITHOUT_UPDATE MAX_STEAM_TRIES STEAM_RETRY_SECONDS \
             STEAMCMD_WAIT_MINUTES LOG_KEEP RESTART_DELAY CRASH_SECONDS \
             MAX_CRASH_STREAK RCON_PASSWORD_MIN BUILD_CHECK_HOURS; do
        case "${!n}" in
            ''|*[!0-9]*) bad_cfg+=$'\n  '"$n must be a whole number (is '${!n}')." ;;
        esac
    done
    [ "$LOG_KEEP" = "0" ]          && bad_cfg+=$'\n  LOG_KEEP cannot be 0 (it would delete every log).'
    [ "$MAX_STEAM_TRIES" = "0" ]   && bad_cfg+=$'\n  MAX_STEAM_TRIES cannot be 0.'
    [ "$RCON_PASSWORD_MIN" = "0" ] && bad_cfg+=$'\n  RCON_PASSWORD_MIN cannot be 0 (an empty password crashes Rust).'

    if [ -n "$bad_cfg" ]; then
        die "The launcher's settings need fixing before it can run:${bad_cfg}"
    fi
}

# ======================================================================
# Section 2 -- secrets and the RCON password.
# ======================================================================
load_secrets() {
    if [ ! -f "$SECRETS" ]; then
        die "No secrets file at $SECRETS. Copy secrets.example.sh to secrets.sh and set RCON_PASSWORD."
    fi
    # shellcheck disable=SC1090
    . "$SECRETS"
    if [ -z "${RCON_PASSWORD:-}" ]; then
        die "secrets.sh did not set RCON_PASSWORD."
    fi
    local len=${#RCON_PASSWORD}
    if [ "$RCON_PASSWORD" = "change_me" ]; then
        die "RCON_PASSWORD is still the example 'change_me'. Set a real one in secrets.sh."
    elif [ "$len" -lt "$RCON_PASSWORD_MIN" ]; then
        die "RCON_PASSWORD is shorter than RCON_PASSWORD_MIN ($RCON_PASSWORD_MIN)."
    elif [[ "$RCON_PASSWORD" == *'"'* ]]; then
        die "RCON_PASSWORD contains a double quote, which Rust cannot accept. Choose another."
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
# Section 3a -- the "am I behind?" build check. Reads the installed build
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
    # Fresh cache wins.
    if [ -f "$BUILD_CACHE" ]; then
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
# Section 3 -- decide whether to update this pass.
# ======================================================================
DO_UPDATE=0; DO_VALIDATE=0
update_decision() {
    DO_UPDATE=0; DO_VALIDATE=0
    if [ "$UPDATE_MODE" = "off" ]; then
        [ -e "$ROOT/$UPDATE_FLAG" ] && log "UPDATE_MODE is off; leaving $UPDATE_FLAG in place, not acting on it."
        return 0
    fi
    [ "$UPDATE_MODE" = "always" ] && { DO_UPDATE=1; return 0; }

    # hotwire mode:
    if [ -e "$ROOT/$VALIDATE_FLAG" ]; then DO_UPDATE=1; DO_VALIDATE=1; return 0; fi
    if [ -e "$ROOT/$UPDATE_FLAG" ]; then DO_UPDATE=1; return 0; fi

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
# Section 3-steam -- run steamcmd under a blocking lock with a deadline.
# ======================================================================
STEAM_OK=0
steam_update() {
    STEAM_OK=0
    local args=( +force_install_dir "$ROOT" +login anonymous +app_update "$APPID" )
    [ -n "$STEAM_BRANCH" ] && args+=( -beta "$STEAM_BRANCH" )
    [ "$DO_VALIDATE" = "1" ] && args+=( validate )
    args+=( +quit )

    local tries=0
    while :; do
        tries=$((tries+1))
        log "steamcmd update, attempt $tries of $MAX_STEAM_TRIES..."
        # Blocking lock, but bounded by STEAMCMD_WAIT_MINUTES so a stuck sibling
        # never holds this server down: past the deadline we start what we have.
        exec 8>"$STEAM_LOCK" || { warn "Could not open the steamcmd lock."; return 0; }
        if flock -w $(( STEAMCMD_WAIT_MINUTES * 60 )) 8; then
            "$STEAMCMD" "${args[@]}"; local rc=$?
            exec 8>&-
            if [ "$rc" = "0" ]; then STEAM_OK=1; ok "steamcmd finished."; return 0; fi
            bad "steamcmd exited $rc."
        else
            exec 8>&-
            warn "Waited $STEAMCMD_WAIT_MINUTES min for another server's steamcmd; starting with what is on disk."
            return 0
        fi
        if [ "$tries" -ge "$MAX_STEAM_TRIES" ]; then
            warn "steamcmd gave up after $tries attempts; launching what we have."
            return 0
        fi
        log "Retrying in $STEAM_RETRY_SECONDS s..."; sleep "$STEAM_RETRY_SECONDS"
    done
}

# ======================================================================
# Section 3-framework -- install/refresh Oxide (the Linux build), with a
# skip-when-unchanged optimisation and a GitHub SHA-256 verification.
# ======================================================================
FRAMEWORK_OK=0
have_json() { command -v jq >/dev/null 2>&1; }
framework_update() {
    FRAMEWORK_OK=0
    if [ "$INSTALL_FRAMEWORK" = "0" ]; then log "Vanilla: Oxide is not managed here."; FRAMEWORK_OK=1; return 0; fi

    local build_after; read_installed_build; build_after="$INSTALLED_BUILD"

    # Skip if neither the game nor Oxide changed.
    if [ "$SKIP_UNCHANGED_FRAMEWORK" = "1" ] && [ -f "$OXIDE_STAMP" ]; then
        local want=""
        want="$(curl -fsSL --max-time 25 "$FRAMEWORK_FEED" 2>/dev/null | grep -oE '"latest_release_version"[^,]*' | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)"
        local have; have="$(cat "$OXIDE_STAMP" 2>/dev/null || true)"
        if [ -n "$want" ] && [ "$want" = "$have" ]; then
            log "Oxide $have and the game are unchanged; skipping the framework refresh."
            FRAMEWORK_OK=1; return 0
        fi
    fi

    # Resolve the download and (if verifying) the published SHA-256 from GitHub.
    local from="$FRAMEWORK_URL" sha="" tag=""
    if [ "$VERIFY_FRAMEWORK" = "1" ] && have_json; then
        local rel; rel="$(curl -fsSL --max-time 25 -H 'Accept: application/vnd.github+json' "$FRAMEWORK_RELEASES" 2>/dev/null || true)"
        if [ -n "$rel" ]; then
            from="$(printf '%s' "$rel" | jq -r --arg n "$FRAMEWORK_ASSET" '.assets[]?|select(.name==$n)|.browser_download_url' 2>/dev/null | head -1)"
            sha="$(printf '%s' "$rel" | jq -r --arg n "$FRAMEWORK_ASSET" '.assets[]?|select(.name==$n)|.digest' 2>/dev/null | head -1)"
            tag="$(printf '%s' "$rel" | jq -r '.tag_name // empty' 2>/dev/null)"
            sha="${sha#sha256:}"
            case "$from" in https://github.com/*) ;; *) from="$FRAMEWORK_URL"; sha="" ;; esac
            [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || sha=""
        fi
        [ -z "$sha" ] && warn "Could not read a verified SHA-256 from GitHub; taking the download unverified."
    elif [ "$VERIFY_FRAMEWORK" = "1" ]; then
        warn "jq is not installed; taking the Oxide download unverified."
    fi

    local zip="$ROOT/OxideMod.zip"
    [ -n "$sha" ] && log "Downloading Oxide ${tag:-latest} (will verify SHA-256)..." || log "Downloading Oxide (unverified)..."
    if ! curl -fSL -A "Mozilla/5.0" "$from" --output "$zip" 2>/dev/null; then
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
        # Record the version we just installed for the next skip check.
        local ver; ver="$(curl -fsSL --max-time 25 "$FRAMEWORK_FEED" 2>/dev/null | grep -oE '"latest_release_version"[^,]*' | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)"
        [ -n "$ver" ] && printf '%s' "$ver" > "$OXIDE_STAMP" 2>/dev/null || true
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
# Section 4 -- build the launch arguments.
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

# A light option check: every convar starts with '+' and has a value.
check_options() {
    [ "$CHECK_OPTIONS" = "0" ] && { log "Option check skipped."; return 0; }
    local i=0 problems=0
    while [ "$i" -lt "${#ARGS[@]}" ]; do
        local a="${ARGS[$i]}"
        case "$a" in
            +*)
                local dotted="${a#+}"
                case "$dotted" in *.*) ;; *) warn "Convar '$a' has no dot; is it a real convar?"; problems=$((problems+1)) ;; esac
                if [ $((i+1)) -ge "${#ARGS[@]}" ] || [[ "${ARGS[$((i+1))]}" == +* ]] || [[ "${ARGS[$((i+1))]}" == -* ]]; then
                    warn "Convar '$a' has no value after it."; problems=$((problems+1))
                fi ;;
        esac
        i=$((i+1))
    done
    if [ "$problems" -gt 0 ]; then
        die "The option check found $problems problem(s) above. Fix the SETTINGS block, or set CHECK_OPTIONS=0 to bypass."
    fi
    ok "Options look sane."
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
# The launcher's identity file, for the plugin to read. The plugin
# recomputes the code hash from this launcher's bytes to confirm it is
# unmodified, and reads the capability list to know what features it may
# offer. Written before each launch; harmless if no plugin reads it yet.
# ======================================================================
write_launcher_state() {
    local dir; dir="$(dirname "$LAUNCHER_STATE")"
    mkdir -p "$dir" 2>/dev/null || return 0
    local self; self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    cat > "$LAUNCHER_STATE" 2>/dev/null <<JSON || true
{
  "version": "$HOTWIRE_LAUNCHER_VERSION",
  "hash": "$HOTWIRE_LAUNCHER_HASH",
  "capabilities": "$HOTWIRE_LAUNCHER_CAPABILITIES",
  "platform": "linux",
  "path": "$self"
}
JSON
}

# ======================================================================
# Reporting to the panel -- kind: session and kind: launcher. The launcher is
# the `script` component of the contract: it signs with the script key connect
# wrote (hotwire/keys.json) and reports only what only it knows -- how a run
# ended, the update outcome, and a crash-streak stop ("the most important report
# in the contract"). Everything here is best-effort: a report that cannot be
# sent is spooled and drained next boot, and nothing here ever blocks or fails
# the server (rule 1). The plugin still reports the boot itself (ADR-0080), so
# this is not "Last boot"; it is the update-and-exit account only the script has.
# ======================================================================
_json_str() {  # a flat JSON string value: _json_str <file> <key>
    [ -f "$1" ] || return 0
    grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
}
_sha256() { printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.*= *//'; }
_hmac()   { printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" | sed 's/^.*= *//'; }
_bool()   { [ "$1" = "1" ] && printf 'true' || printf 'false'; }

REPORT_ENABLED=0; PANEL_URL=""; SCRIPT_KEY=""; SCRIPT_SECRET=""
init_reporting() {
    PANEL_URL="$(_json_str "$CONNECT_FILE" panel_url)"
    SCRIPT_KEY="$(_json_str "$KEYS_FILE" key_id)"
    SCRIPT_SECRET="$(_json_str "$KEYS_FILE" secret)"
    if [ -n "$PANEL_URL" ] && [ -n "$SCRIPT_KEY" ] && [ -n "$SCRIPT_SECRET" ]; then
        REPORT_ENABLED=1
    else
        log "Not connected to a panel (no keys); the launcher will not report."
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
    printf '%s\n%s\n%s\n%s\n' "$1" "$3" "$4" "$2" > "$SPOOL_DIR/$(date +%s)-$3" 2>/dev/null || true
    local n; n="$(ls -1 "$SPOOL_DIR" 2>/dev/null | wc -l)"
    if [ "$n" -gt "$SPOOL_MAX" ]; then
        ls -1tr "$SPOOL_DIR" 2>/dev/null | head -n "$((n - SPOOL_MAX))" | while read -r o; do rm -f "$SPOOL_DIR/$o"; done
    fi
}

hw_send() {  # <kind> <payload-json>  -- first send; spool on a retryable failure
    [ "$REPORT_ENABLED" = "1" ] || return 0
    local kind="$1" payload="$2" rid sent_at code
    rid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)"
    sent_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    code="$(_hw_post "$kind" "$payload" "$rid" "$sent_at")"
    case "$code" in
        2*) : ;;
        429|5*|000) _spool_write "$kind" "$payload" "$rid" "$sent_at"; log "Report ($kind) not sent (HTTP $code); spooled." ;;
        *) log "Report ($kind) refused (HTTP $code); not retrying." ;;
    esac
}

# Drain oldest-first; stop at the first that still cannot be sent. Politely bounded.
spool_drain() {
    [ "$REPORT_ENABLED" = "1" ] || return 0
    [ -d "$SPOOL_DIR" ] || return 0
    local sent=0 f p kind rid sent_at payload code
    for f in $(ls -1tr "$SPOOL_DIR" 2>/dev/null); do
        [ "$sent" -ge 50 ] && break
        p="$SPOOL_DIR/$f"
        kind="$(sed -n 1p "$p")"; rid="$(sed -n 2p "$p")"; sent_at="$(sed -n 3p "$p")"; payload="$(sed -n 4p "$p")"
        [ -z "$kind" ] && { rm -f "$p"; continue; }
        code="$(_hw_post "$kind" "$payload" "$rid" "$sent_at")"
        case "$code" in 2*) rm -f "$p"; sent=$((sent + 1)) ;; *) break ;; esac
    done
    [ "$sent" -gt 0 ] && log "Spool: sent $sent held report(s)."
    return 0
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
# Convar persist (capability: convar_persist). The plugin writes CONVAR.request
# -- one "<convar> <value>" per line -- to ask that a start-arg convar be made
# permanent. Between server runs (the safe moment) the launcher validates each,
# writes it into its OWN settings block as a managed EXTRA_CONVARS line, and
# leaves a CONVAR.result receipt. It takes effect on this and every future boot.
#
# Two hard rules, enforced here and not merely in the panel:
#   - It is a TYPED SET, never a console passthrough: the name must be a dotted
#     convar and the value must carry no quote or control character, so a forged
#     request can never inject a command into a file the machine executes.
#   - The map-defining convars (seed/worldsize/level/levelurl) and the secret
#     rcon.password are REFUSED here: those belong to wipe / secrets, not to the
#     convar editor. A routine convar edit can never silently wipe a map.
#
# Editing the running script is safe on bash: every function and the run loop
# are parsed before main begins, so by the time this runs the file is fully read
# and the settings block (earlier in the file) is never re-read.
CONVAR_CHANGED=0
persist_convar() {  # persist_convar <name> <value>
    local name="$1" value="$2" self tmp
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    tmp="$(mktemp)" || return 1
    awk -v n="$name" -v v="$value" '
        $0 ~ ("# hotwire-managed:" n "$") { next }
        { print }
        /^EXTRA_CONVARS=\(\)/ { print "EXTRA_CONVARS+=( \"+" n "\" \"" v "\" )  # hotwire-managed:" n }
    ' "$self" > "$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" > "$self" && rm -f "$tmp" || { rm -f "$tmp"; return 1; }
    EXTRA_CONVARS+=( "+$name" "$value" )
    return 0
}
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
            server.seed|server.worldsize|server.level|server.levelurl)
                echo "reject $name : map-defining, belongs to wipe not the convar editor" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue ;;
            rcon.password)
                echo "reject $name : a secret, never set through the panel" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue ;;
        esac
        # The value is written into a bash file that is later executed, so reject
        # every character that stays active inside double quotes (", $, `, \) as
        # well as any control character. This is the injection boundary.
        if [ "$name" = "$value" ] || printf '%s' "$value" | LC_ALL=C grep -q '[^[:print:]]'; then
            echo "reject $name : missing or non-printable value" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue
        fi
        case "$value" in
            *'"'*|*'$'*|*'`'*|*'\'*)
                echo "reject $name : value has a shell-active character (\" \$ \` \\)" >> "$CONVAR_RESULT"; rejected=$((rejected+1)); continue ;;
        esac
        if persist_convar "$name" "$value"; then
            echo "applied $name $value" >> "$CONVAR_RESULT"; applied=$((applied+1)); CONVAR_CHANGED=1
        else
            echo "reject $name : could not write settings" >> "$CONVAR_RESULT"; rejected=$((rejected+1))
        fi
    done < "$CONVAR_REQUEST"
    rm -f "$CONVAR_REQUEST"
    log "Convar persist: applied $applied, rejected $rejected (details in CONVAR.result)."
}

# ======================================================================
# Everything that must happen before each launch, and RE-happen on every
# relaunch exactly as hotwire.bat does from :start: the build check, the update
# decision, the hooks and the update itself, pending convar persists, the args
# and the option check. This is why a plugin that writes UPDATE.flag and
# restarts the server gets its update -- it is picked up here on the relaunch.
# ======================================================================
per_launch_prep() {
    UPDATE_ATTEMPTED=0
    build_check
    update_decision
    [ -n "$CHECK_ONLY" ] && DO_UPDATE=0
    # HOOK_BEFORE runs on every real start (not in check mode), before any update.
    [ -z "$CHECK_ONLY" ] && [ -n "$HOOK_BEFORE" ] && { log "Running HOOK_BEFORE..."; bash -c "$HOOK_BEFORE" || warn "HOOK_BEFORE exited non-zero."; }
    if [ "$DO_UPDATE" = "1" ]; then
        UPDATE_ATTEMPTED=1
        steam_update
        framework_update
        finalize_update
        # HOOK_AFTER runs after an update attempt (success or not), like the .bat.
        [ -n "$HOOK_AFTER" ] && { log "Running HOOK_AFTER..."; bash -c "$HOOK_AFTER" || warn "HOOK_AFTER exited non-zero."; }
    else
        log "Plain restart: no update this pass."
    fi
    apply_convar_requests
    build_args
    check_options
}

# ======================================================================
# Section 5 -- the run loop.
# ======================================================================
run_loop() {
    while :; do
        spool_drain
        per_launch_prep
        rotate_log
        write_launcher_state
        log "Starting server..."
        STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local start_ts end_ts run_secs rc crashed
        start_ts="$(date +%s)"
        "$RUST_BIN" "${ARGS[@]}" -logfile "$LOGFILE"; rc=$?
        end_ts="$(date +%s)"
        run_secs=$(( end_ts - start_ts )); [ "$run_secs" -lt 0 ] && run_secs=99999

        if [ "$run_secs" -lt "$CRASH_SECONDS" ]; then CRASH_STREAK=$((CRASH_STREAK+1)); crashed=true; else CRASH_STREAK=0; crashed=false; fi
        report_session "$rc" "$crashed"

        if [ "$RESTART_ON_EXIT" = "0" ]; then log "Server exited; RESTART_ON_EXIT is off. Stopping."; exit 0; fi

        if [ "$MAX_CRASH_STREAK" != "0" ] && [ "$CRASH_STREAK" -ge "$MAX_CRASH_STREAK" ]; then
            rule
            bad "Stopped: the server has crashed $CRASH_STREAK times in a row (each under ${CRASH_SECONDS}s)."
            log  "The log that explains it is the newest logs/server_crash_*.txt."
            log  "Common causes: a bad convar, a port already in use (another server?), or a broken update."
            rule
            report_launcher_stopped "$CRASH_STREAK consecutive runs under ${CRASH_SECONDS}s"
            exit 1
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
printf '%s%s H O T W I R E %s  launcher %s%s (linux)  --  %s\n' \
    "$C_BLD" "$C_CYN" "$C_OFF" "$C_BLD" "$HOTWIRE_LAUNCHER_VERSION" "$C_OFF"
[ -n "$CHECK_ONLY" ] && log "Check mode: everything is checked, nothing is started."

validate_settings
load_secrets
preflight
init_reporting

if [ -n "$CHECK_ONLY" ]; then
    per_launch_prep
    ok "Check complete. Not starting the server (check mode)."
    exit 0
fi

run_loop
