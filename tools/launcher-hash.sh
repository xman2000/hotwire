#!/usr/bin/env bash
#
# launcher-hash.sh -- compute a Hotwire launcher's code hash.
#
# The code hash is the launcher's identity. The plugin works out the same value
# from the launcher's files and reports it, and AFKPanel compares it with the
# released launchers' to show whether a server runs one; nothing is refused on
# the answer. Launchers are no longer stamped with their own hash (from Windows
# 1.1.25 and Linux 1.1.10). Older launchers carry a HOTWIRE_LAUNCHER_HASH line,
# which is left out, so their hashes are unchanged.
#
# The algorithm must match the plugin's byte for byte:
#   - split on LF, treating CRLF as LF (hotwire.bat is checked out with CRLF);
#   - drop each SETTINGS block, if any (inclusive of both marker lines);
#   - drop the line beginning HOTWIRE_LAUNCHER_HASH= , if any;
#   - strip trailing whitespace from each remaining line;
#   - then the same for each file named on a "REM HOTWIRE-PART <name>" line, in
#     the order those lines appear; the file sits beside the launcher (the
#     Windows launcher's hotwire.bat names hotwire.ps1). A missing part is an
#     error, never an empty one;
#   - join with LF and SHA-256 the result.
#
# Usage:
#   launcher-hash.sh compute <file>     print the hash

set -uo pipefail

BEGIN_MARKER="=== HOTWIRE SETTINGS BEGIN ==="
END_MARKER="=== HOTWIRE SETTINGS END ==="

normalise() {
    awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
        { sub(/\r$/, "") }
        index($0, b) { skip=1 }
        skip==1 { if (index($0, e)) { skip=0 }; next }
        /^HOTWIRE_LAUNCHER_HASH=/ { next }
        { sub(/[ \t]+$/, ""); print }
    ' "$1"
}

parts() {
    tr -d '\r' < "$1" | sed -n -E 's/^REM HOTWIRE-PART ([A-Za-z0-9_.-]+)$/\1/p'
}

compute() {
    local file="$1" dir part
    [ -f "$file" ] || { echo "no such file: $file" >&2; exit 2; }
    dir="$(dirname "$file")"
    for part in $(parts "$file"); do
        [ -f "$dir/$part" ] || { echo "missing part beside $file: $part" >&2; exit 2; }
    done
    {
        normalise "$file"
        for part in $(parts "$file"); do normalise "$dir/$part"; done
    } | sha256sum | cut -d' ' -f1
}

cmd="${1:-}"; file="${2:-}"
case "$cmd" in
    compute) compute "$file" ;;
    *) echo "usage: $0 compute <launcher-file>" >&2; exit 2 ;;
esac
