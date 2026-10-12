#!/usr/bin/env bash
#
# ==[ H O T W I R E ]===================================================
#  Hotwire launcher for Linux. Everything it does is in hotwire-launcher.sh,
#  beside this file; this file only starts it. Built by xman2000 and
#  Claude. MIT License. https://github.com/xman2000/hotwire
#
#  Usage:
#    ./hotwire.sh          start the server, and restart it when it exits
#    ./hotwire.sh check    check the settings and report; start nothing
#
#  hotwire-launcher.sh can be replaced while the launcher runs: it takes over
#  at the next restart. This file rarely changes: replace it only with the
#  server stopped. The HOTWIRE-PART line at the end names the file the
#  launcher's code hash covers besides this one.
# ======================================================================
#
# What this file does, and nothing else:
#   - runs hotwire-launcher.sh, and runs it again when it exits with 75, which is how a replaced copy takes over;
#   - when hotwire-launcher.sh was just replaced by an update of Hotwire (hotwire/self-update/applied says so) and it
#     fails to start the server -- it exits with an error within ten minutes -- puts back the copy it replaced
#     (hotwire/previous/hotwire-launcher.sh), says so in hotwire/self-update/rolled-back, and runs that one. An
#     update that breaks the launcher can never leave the server unable to start.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGIC="$HERE/hotwire-launcher.sh"
PREVIOUS="$HERE/hotwire/previous/hotwire-launcher.sh"
APPLIED="$HERE/hotwire/self-update/applied"
ROLLED_BACK="$HERE/hotwire/self-update/rolled-back"
GRACE_SECONDS=600

while :; do
    if [ ! -f "$LOGIC" ]; then
        if [ -f "$PREVIOUS" ] && cp -p "$PREVIOUS" "$LOGIC.tmp" && mv -f "$LOGIC.tmp" "$LOGIC"; then
            echo "hotwire-launcher.sh was missing; the previous copy from hotwire/previous/ is back."
        else
            echo "hotwire-launcher.sh is missing. Put it beside hotwire.sh, then run ./hotwire.sh again." >&2
            exit 1
        fi
    fi
    started=$(date +%s)
    # Tells hotwire-launcher.sh it was started here, so exiting with 75 to hand over to a replaced copy is safe.
    HOTWIRE_STARTER=1 bash "$LOGIC" "$@"
    rc=$?
    [ "$rc" = 75 ] && continue
    # 0 is a stop that was asked for, 2 a check that found a problem, 3 a second launcher refused because one already
    # runs here, and 128 and up a signal: none is a broken launcher.
    if [ "$rc" != 0 ] && [ "$rc" != 2 ] && [ "$rc" != 3 ] && [ "$rc" -lt 128 ] && [ -f "$APPLIED" ] && [ -f "$PREVIOUS" ] \
        && [ $(( $(date +%s) - started )) -lt "$GRACE_SECONDS" ]; then
        if cp -p "$PREVIOUS" "$LOGIC.tmp" && mv -f "$LOGIC.tmp" "$LOGIC"; then
            { printf 'launcher_failed %s\n' "$rc"; cat "$APPLIED" 2>/dev/null; } > "$ROLLED_BACK.tmp" 2>/dev/null \
                && mv -f "$ROLLED_BACK.tmp" "$ROLLED_BACK"
            rm -f "$APPLIED"
            echo "The updated launcher stopped with error $rc before the server started. The previous launcher is back; starting it."
            continue
        fi
    fi
    exit "$rc"
done
exit 1
REM HOTWIRE-PART hotwire-launcher.sh
