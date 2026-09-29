#!/usr/bin/env bash
#
# build-release.sh -- build the files a Hotwire release offers, into dist/.
#
# Run by .github/workflows/release.yml on a tag, and by hand to check it. Refuses to build when a setup script's pin
# does not match the file it pins, or a launcher's stamped code hash is stale: a release with either would stop every
# install at a hash mismatch.
#
#   dist/hotwire-windows.zip   the setup script (.bat + .ps1), hotwire.bat, the settings and hook examples, Hotwire.cs,
#                              README.txt
#   dist/hotwire-linux.zip     hotwire.sh, the settings and hook examples, Hotwire.cs, README.txt: Hotwire for a server
#                              that is already installed (the start-script converter's first download, panel ADR-0204)
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
pin_check launcher/hotwire.example.cfg "$(grep -oP "^PIN_CFG=\"\K[0-9a-f]{64}" setup/hotwire-setup.sh)" hotwire-setup.sh
pin_check launcher/hotwire.example.cfg "$(grep -oP "^\s*'hotwire.example.cfg'\s*=\s*'\K[0-9a-f]{64}" setup/hotwire-setup.ps1)" hotwire-setup.ps1
for f in launcher/hotwire.bat launcher/hotwire.sh; do tools/launcher-hash.sh check "$f" >/dev/null || { echo "STALE CODE HASH: $f" >&2; fail=1; }; done
[ "$fail" = 0 ] || { echo "Not building: fix the pins or run tools/launcher-hash.sh stamp, then commit." >&2; exit 1; }

blob setup/hotwire-setup.bat     | crlf > dist/windows/hotwire-setup.bat
blob setup/hotwire-setup.ps1     | crlf > dist/windows/hotwire-setup.ps1
blob launcher/hotwire.bat        | crlf > dist/windows/hotwire.bat
blob launcher/hotwire.example.cfg | crlf > dist/windows/hotwire.example.cfg
blob launcher/hotwire-secrets.example.cfg | crlf > dist/windows/hotwire-secrets.example.cfg
blob launcher/hotwire-before.example.bat | crlf > dist/windows/hotwire-before.example.bat
blob launcher/hotwire-after.example.bat | crlf > dist/windows/hotwire-after.example.bat
blob src/Hotwire.cs > dist/windows/Hotwire.cs
crlf > dist/windows/README.txt <<'TXT'
Hotwire for Windows

To install a server: right-click hotwire-setup.bat and choose Run as administrator.
It checks this machine, then asks before each step. Keep hotwire-setup.ps1 beside it.

To add Hotwire to a server you already run: put hotwire.bat beside RustDedicated.exe
and Hotwire.cs in oxide\plugins. Your settings go in hotwire.cfg: make it from your
old start script at https://afkpanel.com/get-started, or copy hotwire.example.cfg.
The RCON password goes in hotwire-secrets.cfg (copy hotwire-secrets.example.cfg).

The guide: https://afkpanel.com/docs/install-windows
TXT
touch -d "$(git log -1 --format=%cI HEAD)" dist/windows/*
(cd dist/windows && zip -qX ../hotwire-windows.zip hotwire-setup.bat hotwire-setup.ps1 hotwire.bat hotwire.example.cfg \
    hotwire-secrets.example.cfg hotwire-before.example.bat hotwire-after.example.bat Hotwire.cs README.txt)
rm -rf dist/windows

# The Linux launcher with its examples. zip keeps each file's mode, so hotwire.sh unzips runnable.
mkdir -p dist/linux
blob launcher/hotwire.sh > dist/linux/hotwire.sh
blob launcher/hotwire.example.cfg > dist/linux/hotwire.example.cfg
blob launcher/hotwire-secrets.example.cfg > dist/linux/hotwire-secrets.example.cfg
blob launcher/hotwire-before.example.sh > dist/linux/hotwire-before.example.sh
blob launcher/hotwire-after.example.sh > dist/linux/hotwire-after.example.sh
blob src/Hotwire.cs > dist/linux/Hotwire.cs
cat > dist/linux/README.txt <<'TXT'
Hotwire for Linux, for a Rust server you already run

Put hotwire.sh beside RustDedicated and Hotwire.cs in oxide/plugins. Your settings go in
hotwire.cfg: make it from your old start script at https://afkpanel.com/get-started, or
copy hotwire.example.cfg. The RCON password goes in hotwire-secrets.cfg (copy
hotwire-secrets.example.cfg, then chmod 600 it). Run ./hotwire.sh check, then ./hotwire.sh.

To install a server from nothing, use hotwire-setup.sh instead.
The guide: https://afkpanel.com/docs/install-linux
TXT
chmod 755 dist/linux/hotwire.sh
chmod 644 dist/linux/hotwire.example.cfg dist/linux/hotwire-secrets.example.cfg dist/linux/hotwire-before.example.sh \
    dist/linux/hotwire-after.example.sh dist/linux/Hotwire.cs dist/linux/README.txt
touch -d "$(git log -1 --format=%cI HEAD)" dist/linux/*
(cd dist/linux && zip -qX ../hotwire-linux.zip hotwire.sh hotwire.example.cfg hotwire-secrets.example.cfg \
    hotwire-before.example.sh hotwire-after.example.sh Hotwire.cs README.txt)
rm -rf dist/linux

blob setup/hotwire-setup.sh > dist/hotwire-setup.sh
blob src/Hotwire.cs > dist/Hotwire.cs
(cd dist && sha256sum hotwire-windows.zip hotwire-linux.zip hotwire-setup.sh Hotwire.cs > SHA256SUMS)
cat dist/SHA256SUMS
