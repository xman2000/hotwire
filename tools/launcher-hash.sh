#!/usr/bin/env bash
#
# launcher-hash.sh -- compute, stamp, or verify a Hotwire launcher's code hash.
#
# The code hash is the launcher's identity: a SHA-256 over everything except
# the HOTWIRE_LAUNCHER_HASH declaration line itself, so the file can carry its
# own hash. The plugin recomputes this exact value from the launcher's bytes and
# AFKPanel shows whether the launcher is the released file; nothing is refused
# on the answer. The settings live in hotwire.cfg, so the launchers no longer
# carry a SETTINGS block; the step that drops one stays, so the hash of an older
# launcher is computed the same way as before.
#
# The algorithm must match the plugin's byte for byte:
#   - split on LF, treating CRLF as LF (hotwire.bat is checked out with CRLF);
#   - drop each SETTINGS block, if any (inclusive of both marker lines);
#   - drop the line beginning HOTWIRE_LAUNCHER_HASH= ;
#   - strip trailing whitespace from each remaining line;
#   - join with LF and SHA-256 the result.
#
# Usage:
#   launcher-hash.sh compute <file>     print the hash
#   launcher-hash.sh stamp   <file>     write the hash into the file's header
#   launcher-hash.sh check   <file>     exit 0 if the stamped hash matches, else 1
#
# 'check' is meant for CI / a pre-commit hook, so a launcher whose stamped hash
# has gone stale (the setup-pin bug all over again) never ships.

set -uo pipefail

BEGIN_MARKER="=== HOTWIRE SETTINGS BEGIN ==="
END_MARKER="=== HOTWIRE SETTINGS END ==="

compute() {
    local file="$1"
    [ -f "$file" ] || { echo "no such file: $file" >&2; exit 2; }
    awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
        { sub(/\r$/, "") }
        index($0, b) { skip=1 }
        skip==1 { if (index($0, e)) { skip=0 }; next }
        /^HOTWIRE_LAUNCHER_HASH=/ { next }
        { sub(/[ \t]+$/, ""); print }
    ' "$file" | sha256sum | cut -d' ' -f1
}

stamp() {
    local file="$1" h
    h="$(compute "$file")"
    # Replace the declaration line's value in place.
    if grep -q '^HOTWIRE_LAUNCHER_HASH=' "$file"; then
        # [^\r]* rather than .*, so a CRLF file keeps its CR on this line.
        sed -i -E "s|^HOTWIRE_LAUNCHER_HASH=[^\r]*|HOTWIRE_LAUNCHER_HASH=\"$h\"|" "$file"
        echo "stamped $file with $h"
    else
        echo "no HOTWIRE_LAUNCHER_HASH= line in $file" >&2; exit 2
    fi
}

check() {
    local file="$1" want got
    want="$(grep -m1 -oE '^HOTWIRE_LAUNCHER_HASH="[^"]*"' "$file" | sed -E 's/^HOTWIRE_LAUNCHER_HASH="([^"]*)"/\1/')"
    got="$(compute "$file")"
    if [ "$want" = "$got" ]; then
        echo "ok: $file hash matches ($got)"; exit 0
    fi
    echo "STALE: $file declares '$want' but computes '$got'. Re-stamp it." >&2; exit 1
}

cmd="${1:-}"; file="${2:-}"
case "$cmd" in
    compute) compute "$file" ;;
    stamp)   stamp "$file" ;;
    check)   check "$file" ;;
    *) echo "usage: $0 {compute|stamp|check} <launcher-file>" >&2; exit 2 ;;
esac
