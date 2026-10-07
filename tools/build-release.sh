#!/usr/bin/env bash
#
# build-release.sh -- build the files a Hotwire release offers, into dist/.
#
# Run by .github/workflows/release.yml on a tag (TAG=release-...), and by hand to check it.
#
# The setup scripts it publishes carry the tag they were built for, and download Hotwire's files from that tag, so a
# copy of setup always installs the files it was released with. Setup checks each file against the SHA-256 list
# AFKPanel publishes (afkpanel.com/hotwire/released-files.json); a release whose files that list does not hold yet
# would stop every install, so with a TAG this refuses to build until the list has them: the release's files go on
# AFKPanel's list first, then the tag is pushed.
# HOTWIRE_SKIP_LIST_CHECK=1 skips that check for a build by hand.
#
#   dist/hotwire-windows.zip   the setup script (.bat + .ps1), hotwire.bat and hotwire.ps1, the settings and hook examples, Hotwire.cs,
#                              README.txt
#   dist/hotwire-linux.zip     hotwire.sh, the settings and hook examples, Hotwire.cs, README.txt: Hotwire for a server
#                              that is already installed (what the start-script converter on afkpanel.com sends people to)
#   dist/hotwire-setup.sh      the Linux setup script
#   dist/Hotwire.cs            the plugin
#   dist/SHA256SUMS            sha256 of each of the above
#
# Files are taken from the commit (git show HEAD:path), not the working tree, so they are the bytes raw GitHub serves
# and the published list describes. The Windows scripts go into the zip with CRLF, which cmd needs; the plugin keeps its bytes.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
rm -rf dist && mkdir -p dist/windows

blob() { git show "HEAD:$1"; }
sha() { sha256sum | cut -c1-64; }
crlf() { sed 's/\r$//; s/$/\r/'; }

TAG="${TAG:-}"
if [ -n "$TAG" ]; then
    [[ "$TAG" =~ ^release-[0-9A-Za-z.-]+$ ]] || { echo "Not building: '$TAG' is not a release tag." >&2; exit 1; }
    if [ "${HOTWIRE_SKIP_LIST_CHECK:-0}" != 1 ]; then
        list="$(curl -fsS --retry 3 --max-time 30 "${HOTWIRE_RELEASED_FILES_URL:-https://afkpanel.com/hotwire/released-files.json}")" \
            || { echo "Not building: AFKPanel's list of released files did not answer. Try again." >&2; exit 1; }
        missing=0
        for pair in Hotwire.cs:plugin/Hotwire.cs hotwire.bat:launcher/hotwire.bat hotwire.ps1:launcher/hotwire.ps1 \
                    hotwire.sh:launcher/hotwire.sh hotwire.example.cfg:examples/hotwire.example.cfg; do
            name="${pair%%:*}"; got=$(blob "${pair#*:}" | sha)
            if ! printf '%s' "$list" | HW_NAME="$name" HW_SHA="$got" python3 -c 'import json,os,sys; f=json.load(sys.stdin).get("files",{}); sys.exit(0 if os.environ["HW_SHA"] in f.get(os.environ["HW_NAME"],{}) else 1)'; then
                echo "NOT ON THE LIST: $name ($got) is not on AFKPanel's list of released files." >&2; missing=1
            fi
        done
        [ "$missing" = 0 ] || { echo "Not building: put this commit's files on AFKPanel's list first, then run the release again." >&2; exit 1; }
    fi
fi
# The setup scripts carry the tag they were built for (empty on a build without one: that copy uses the latest release).
stamp_ps1() { HW_TAG="$TAG" awk -v q="'" '!d && $0 == "$ReleaseTag = " q q { print "$ReleaseTag = " q ENVIRON["HW_TAG"] q; d = 1; next } { print }'; }
stamp_sh() { HW_TAG="$TAG" awk '!d && $0 == "RELEASE_TAG=\"\"" { print "RELEASE_TAG=\"" ENVIRON["HW_TAG"] "\""; d = 1; next } { print }'; }

blob setup/hotwire-setup.bat     | crlf > dist/windows/hotwire-setup.bat
blob setup/hotwire-setup.ps1     | stamp_ps1 | crlf > dist/windows/hotwire-setup.ps1
blob launcher/hotwire.bat        | crlf > dist/windows/hotwire.bat
blob launcher/hotwire.ps1        | crlf > dist/windows/hotwire.ps1
blob examples/hotwire.example.cfg | crlf > dist/windows/hotwire.example.cfg
blob examples/hotwire-secrets.example.cfg | crlf > dist/windows/hotwire-secrets.example.cfg
blob examples/hotwire-before.example.bat | crlf > dist/windows/hotwire-before.example.bat
blob examples/hotwire-after.example.bat | crlf > dist/windows/hotwire-after.example.bat
blob plugin/Hotwire.cs > dist/windows/Hotwire.cs
crlf > dist/windows/README.txt <<'TXT'
Hotwire for Windows

To install a server: right-click hotwire-setup.bat and choose Run as administrator.
It checks this machine, then asks before each step. Keep hotwire-setup.ps1 beside it.

To add Hotwire to a server you already run: put hotwire.bat and hotwire.ps1 beside
RustDedicated.exe and Hotwire.cs in oxide\plugins. Your settings go in hotwire.cfg: make
it from your old start script at https://afkpanel.com/get-started, or copy
hotwire.example.cfg. Only if you use an RCON tool, set its password in
hotwire-secrets.cfg (copy hotwire-secrets.example.cfg); without one RCON is off.

To update the launcher: replace hotwire.ps1; it takes over at the next restart. When
hotwire.bat changes too, close the launcher's window first, then replace both.

The guide: https://afkpanel.com/docs/install-windows
TXT
touch -d "$(git log -1 --format=%cI HEAD)" dist/windows/*
(cd dist/windows && zip -qX ../hotwire-windows.zip hotwire-setup.bat hotwire-setup.ps1 hotwire.bat hotwire.ps1 hotwire.example.cfg \
    hotwire-secrets.example.cfg hotwire-before.example.bat hotwire-after.example.bat Hotwire.cs README.txt)
rm -rf dist/windows

# The Linux launcher with its examples. zip keeps each file's mode, so hotwire.sh unzips runnable.
mkdir -p dist/linux
blob launcher/hotwire.sh > dist/linux/hotwire.sh
blob examples/hotwire.example.cfg > dist/linux/hotwire.example.cfg
blob examples/hotwire-secrets.example.cfg > dist/linux/hotwire-secrets.example.cfg
blob examples/hotwire-before.example.sh > dist/linux/hotwire-before.example.sh
blob examples/hotwire-after.example.sh > dist/linux/hotwire-after.example.sh
blob plugin/Hotwire.cs > dist/linux/Hotwire.cs
cat > dist/linux/README.txt <<'TXT'
Hotwire for Linux, for a Rust server you already run

Put hotwire.sh beside RustDedicated and Hotwire.cs in oxide/plugins. Your settings go in
hotwire.cfg: make it from your old start script at https://afkpanel.com/get-started, or
copy hotwire.example.cfg. Only if you use an RCON tool, set its password in
hotwire-secrets.cfg (copy hotwire-secrets.example.cfg, then chmod 600 it); without one RCON
is off. Run ./hotwire.sh check, then ./hotwire.sh.

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

blob setup/hotwire-setup.sh | stamp_sh > dist/hotwire-setup.sh
blob plugin/Hotwire.cs > dist/Hotwire.cs
(cd dist && sha256sum hotwire-windows.zip hotwire-linux.zip hotwire-setup.sh Hotwire.cs > SHA256SUMS)
cat dist/SHA256SUMS
