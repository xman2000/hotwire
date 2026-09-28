#!/usr/bin/env bash
#
# build-release.sh -- build the files a Hotwire release offers, into dist/.
#
# Run by .github/workflows/release.yml on a tag, and by hand to check it. Refuses to build when a setup script's pin
# does not match the file it pins, or a launcher's stamped code hash is stale: a release with either would stop every
# install at a hash mismatch.
#
#   dist/hotwire-windows.zip   the setup script (.bat + .ps1), hotwire.bat, secrets.example.bat, Hotwire.cs, README.txt
#   dist/hotwire-setup.sh      the Linux setup script
#   dist/Hotwire.cs            the plugin
#   dist/SHA256SUMS            sha256 of each of the above
#
# Files are taken from the commit (git show HEAD:path), not the working tree, so they are the bytes raw GitHub serves
# and the pins describe. The Windows scripts go into the zip with CRLF, which cmd needs; the plugin keeps its bytes.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
rm -rf dist && mkdir -p dist/windows

blob() { git show "HEAD:$1"; }
sha() { sha256sum | cut -c1-64; }
crlf() { sed 's/\r$//; s/$/\r/'; }

fail=0
pin_check() { # <file> <pinned hash> <where>
    local got; got=$(blob "$1" | sha)
    if [ "$got" != "$2" ]; then echo "STALE PIN: $3 pins $1 as $2, the commit has $got" >&2; fail=1; fi
}
pin_check src/Hotwire.cs "$(grep -oP "^PIN_PLUGIN=\"\K[0-9a-f]{64}" setup/hotwire-setup.sh)" hotwire-setup.sh
pin_check launcher/hotwire.sh "$(grep -oP "^PIN_LAUNCHER=\"\K[0-9a-f]{64}" setup/hotwire-setup.sh)" hotwire-setup.sh
pin_check src/Hotwire.cs "$(grep -oP "^\s*'Hotwire.cs'\s*=\s*'\K[0-9a-f]{64}" setup/hotwire-setup.ps1)" hotwire-setup.ps1
pin_check launcher/hotwire.bat "$(grep -oP "^\s*'hotwire.bat'\s*=\s*'\K[0-9a-f]{64}" setup/hotwire-setup.ps1)" hotwire-setup.ps1
for f in launcher/hotwire.bat launcher/hotwire.sh; do tools/launcher-hash.sh check "$f" >/dev/null || { echo "STALE CODE HASH: $f" >&2; fail=1; }; done
[ "$fail" = 0 ] || { echo "Not building: fix the pins or run tools/launcher-hash.sh stamp, then commit." >&2; exit 1; }

blob setup/hotwire-setup.bat     | crlf > dist/windows/hotwire-setup.bat
blob setup/hotwire-setup.ps1     | crlf > dist/windows/hotwire-setup.ps1
blob launcher/hotwire.bat        | crlf > dist/windows/hotwire.bat
blob launcher/secrets.example.bat | crlf > dist/windows/secrets.example.bat
blob src/Hotwire.cs > dist/windows/Hotwire.cs
crlf > dist/windows/README.txt <<'TXT'
Hotwire for Windows

To install a server: right-click hotwire-setup.bat and choose Run as administrator.
It checks this machine, then asks before each step. Keep hotwire-setup.ps1 beside it.

To add Hotwire to a server you already run: put hotwire.bat beside RustDedicated.exe
and Hotwire.cs in oxide\plugins.

The guide: https://afkpanel.com/docs/install-windows
TXT
touch -d "$(git log -1 --format=%cI HEAD)" dist/windows/*
(cd dist/windows && zip -qX ../hotwire-windows.zip hotwire-setup.bat hotwire-setup.ps1 hotwire.bat secrets.example.bat Hotwire.cs README.txt)
rm -rf dist/windows

blob setup/hotwire-setup.sh > dist/hotwire-setup.sh
blob src/Hotwire.cs > dist/Hotwire.cs
(cd dist && sha256sum hotwire-windows.zip hotwire-setup.sh Hotwire.cs > SHA256SUMS)
cat dist/SHA256SUMS
