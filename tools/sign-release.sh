#!/usr/bin/env bash
#
# sign-release.sh -- sign a Hotwire release's manifest, so launchers will install it.
#
# A launcher installs an update of Hotwire only when the release's manifest.json is signed by a key it trusts. The
# private keys never leave their owner: they are not in this repository, not in GitHub, and not on AFKPanel.
#
#   tools/sign-release.sh file <manifest.json> <key-id> <private-key.pem>
#       Sign a manifest with a key in a file (the test key), writing manifest.sig beside it.
#   tools/sign-release.sh release <tag> <key-id> <private-key.pem>
#       Download the release's manifest and every file it names from GitHub, check each file's SHA-256 against the
#       manifest, sign it, and upload manifest.sig to the release (gh, logged in).
#
# The signature is ECDSA P-256 over the manifest's bytes with SHA-256. manifest.sig holds two lines:
#   key <key-id>
#   sig <base64 of r and s, 32 bytes each>
# which every launcher can check: Linux with openssl, Windows with .NET.

set -euo pipefail

usage() { sed -n '3,16p' "$0" >&2; exit 2; }

# sign <manifest> <key-id> <key.pem> -> <manifest dir>/manifest.sig
sign() {
    local manifest="$1" id="$2" key="$3" der hex r s out
    [[ "$id" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "Not a key id: $id" >&2; exit 2; }
    der="$(mktemp)"; trap 'rm -f "$der"' RETURN
    openssl dgst -sha256 -sign "$key" -out "$der" "$manifest"
    # The DER signature is two INTEGERs; each becomes exactly 32 bytes.
    hex="$(openssl asn1parse -inform DER -in "$der" | sed -n 's/.*INTEGER *:\([0-9A-Fa-f]*\)$/\1/p')"
    r="$(printf '%s' "$hex" | sed -n 1p)"; s="$(printf '%s' "$hex" | sed -n 2p)"
    r="$(printf '%064s' "$r" | tr ' ' 0)"; s="$(printf '%064s' "$s" | tr ' ' 0)"
    [ ${#r} -eq 64 ] && [ ${#s} -eq 64 ] || { echo "The signature did not come out as two 32-byte numbers." >&2; exit 1; }
    out="$(dirname "$manifest")/manifest.sig"
    local esc; esc="$(printf '%s%s' "$r" "$s" | sed 's/../\\x&/g')"
    { printf 'key %s\n' "$id"; printf 'sig %s\n' "$(printf '%b' "$esc" | base64 -w 0)"; } > "$out"
    echo "Signed $manifest with $id: $out"
}

case "${1:-}" in
    file)
        [ $# -eq 4 ] || usage
        sign "$2" "$3" "$4" ;;
    release)
        [ $# -eq 4 ] || usage
        tag="$2"; work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
        gh release download "$tag" --repo xman2000/hotwire --pattern manifest.json --dir "$work"
        # Every file the manifest names, checked against it, so a signature never vouches for a file nobody looked at.
        names="$(sed -n -E '/"files"/,/\}/s/^[[:space:]]*"([^"]+)":[[:space:]]*"([0-9a-f]{64})",?[[:space:]]*$/\1 \2/p' "$work/manifest.json")"
        [ -n "$names" ] || { echo "The manifest names no files." >&2; exit 1; }
        while read -r name sha; do
            gh release download "$tag" --repo xman2000/hotwire --pattern "$name" --dir "$work" --clobber
            got="$(sha256sum "$work/$name" | cut -c1-64)"
            [ "$got" = "$sha" ] || { echo "NOT SIGNED: $name is $got, the manifest says $sha." >&2; exit 1; }
            echo "checked $name"
        done <<< "$names"
        sign "$work/manifest.json" "$3" "$4"
        gh release upload "$tag" "$work/manifest.sig" --repo xman2000/hotwire --clobber
        echo "Uploaded manifest.sig to $tag." ;;
    *) usage ;;
esac
