#!/usr/bin/env bash
#
# sign-release.sh -- sign a Hotwire release's manifest, so launchers will install it.
#
# A launcher installs an update of Hotwire only when the release's manifest.json is signed by a key it trusts. The
# private keys never leave their owner: they are not in this repository, not in GitHub, and not on AFKPanel.
#
#   tools/sign-release.sh file <manifest.json> <key-id> <private-key.pem | yubikey>
#       Sign a manifest, writing manifest.sig beside it.
#   tools/sign-release.sh release <tag> <key-id> <private-key.pem | yubikey>
#       Download the release's manifest and every file it names from GitHub, check each file's SHA-256 against the
#       manifest, sign it, and upload manifest.sig to the release (gh, logged in).
#
# The key is a file, or the word yubikey for a key on a PKCS#11 token (pkcs11-tool). Settings, all optional:
#   HOTWIRE_PKCS11_MODULE  the PKCS#11 module
#   HOTWIRE_PKCS11_KEY     the key's PKCS#11 id (default 02)
#   HOTWIRE_PKCS11_TOKEN   a token label, to pick one token when several are present
#   HOTWIRE_PKCS11_PIN     for tests only
#
# The signature is ECDSA P-256 over the manifest's bytes with SHA-256. manifest.sig holds two lines:
#   key <key-id>
#   sig <base64 of r and s, 32 bytes each>
# which every launcher can check: Linux with openssl, Windows with .NET.

set -euo pipefail

usage() { sed -n '3,19p' "$0" >&2; exit 2; }

# sign_pkcs11 <manifest> -> 64 bytes of r and s on stdout, from the key on the PKCS#11 token.
sign_pkcs11() {
    local manifest="$1" module="${HOTWIRE_PKCS11_MODULE:-}" keyid="${HOTWIRE_PKCS11_KEY:-02}" tmp args
    command -v pkcs11-tool >/dev/null || { echo "pkcs11-tool is not installed (Ubuntu: apt install opensc)." >&2; exit 1; }
    if [ -z "$module" ]; then
        for module in /usr/lib/x86_64-linux-gnu/libykcs11.so /usr/lib/aarch64-linux-gnu/libykcs11.so /usr/local/lib/libykcs11.so \
                      /usr/lib/libykcs11.so ''; do [ -f "$module" ] && break; done
        [ -n "$module" ] || { echo "Yubico's PKCS#11 module is not installed (Ubuntu: apt install ykcs11)." >&2; exit 1; }
    fi
    [[ "$keyid" =~ ^[0-9A-Fa-f]{2,64}$ ]] || { echo "Not a PKCS#11 key id: $keyid" >&2; exit 2; }
    tmp="$(mktemp -d)"
    args=(--module "$module" --id "$keyid")
    [ -n "${HOTWIRE_PKCS11_TOKEN:-}" ] && args+=(--token-label "$HOTWIRE_PKCS11_TOKEN")
    # The token signs the SHA-256 of the manifest (plain ECDSA, which every PKCS#11 module has) and returns r and s.
    openssl dgst -sha256 -binary -out "$tmp/digest" "$manifest"
    if [ -n "${HOTWIRE_PKCS11_PIN:-}" ]; then args+=(--pin "$HOTWIRE_PKCS11_PIN"); else args+=(--login); fi
    echo "Signing with the key on the token. Enter its PIN, then touch it if it blinks." >&2
    pkcs11-tool "${args[@]}" --sign --mechanism ECDSA --signature-format rs \
        --input-file "$tmp/digest" --output-file "$tmp/rs" >&2 || { rm -rf "$tmp"; echo "The token did not sign." >&2; exit 1; }
    [ "$(wc -c < "$tmp/rs")" -eq 64 ] || { rm -rf "$tmp"; echo "The signature did not come out as two 32-byte numbers." >&2; exit 1; }
    od -An -tx1 "$tmp/rs" | tr -d ' \n'
    rm -rf "$tmp"
}

# sign <manifest> <key-id> <key.pem | yubikey> -> <manifest dir>/manifest.sig
sign() {
    local manifest="$1" id="$2" key="$3" der hex r s out
    [[ "$id" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "Not a key id: $id" >&2; exit 2; }
    if [ "$key" = yubikey ]; then
        hex="$(sign_pkcs11 "$manifest")"
        write_sig "$manifest" "$id" "${hex:0:64}" "${hex:64:64}"
        return
    fi
    der="$(mktemp)"; trap 'rm -f "$der"' RETURN
    openssl dgst -sha256 -sign "$key" -out "$der" "$manifest"
    # The DER signature is two INTEGERs; each becomes exactly 32 bytes.
    hex="$(openssl asn1parse -inform DER -in "$der" | sed -n 's/.*INTEGER *:\([0-9A-Fa-f]*\)$/\1/p')"
    r="$(printf '%s' "$hex" | sed -n 1p)"; s="$(printf '%s' "$hex" | sed -n 2p)"
    r="$(printf '%064s' "$r" | tr ' ' 0)"; s="$(printf '%064s' "$s" | tr ' ' 0)"
    [ ${#r} -eq 64 ] && [ ${#s} -eq 64 ] || { echo "The signature did not come out as two 32-byte numbers." >&2; exit 1; }
    write_sig "$manifest" "$id" "$r" "$s"
}

# write_sig <manifest> <key-id> <r hex> <s hex> -> <manifest dir>/manifest.sig
write_sig() {
    local manifest="$1" id="$2" r="$3" s="$4" out
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
