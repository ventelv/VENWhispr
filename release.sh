#!/bin/bash
# Makes the downloadable VENWhispr-<version>.dmg (the app with its speech and punctuation servers
# inside) plus a .sha256 file, in ./build. Usage:
#   ./release.sh            build the DMG
#   ./release.sh publish    also create the GitHub Release v<version> and upload both files
# The version comes from CFBundleShortVersionString in Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DMG="build/VENWhispr-$VERSION.dmg"
APP="build/VENWhispr.app"

if [ ! -x vendor/bin/whisper-server ] || [ ! -x vendor/bin/llama-server ]; then
    scripts/build_servers.sh
fi
./build.sh

for server in whisper-server llama-server; do
    [ -x "$APP/Contents/MacOS/$server" ] || { echo "$server is missing from the app" >&2; exit 1; }
done
codesign --verify --strict --deep "$APP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "VENWhispr" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Made $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' ')), SHA-256 $(cut -d ' ' -f 1 "$DMG.sha256")"

if [ "${1:-}" = "publish" ]; then
    [ -z "$(git status --porcelain)" ] || { echo "Commit your changes before publishing." >&2; exit 1; }
    git push origin HEAD
    gh release create "v$VERSION" "$DMG" "$DMG.sha256" --title "VENWhispr $VERSION" --notes-file - <<EOF
Download **VENWhispr-$VERSION.dmg**, open it and drag VENWhispr to Applications.
Needs an Apple Silicon Mac (M1 or newer) with macOS 14 or later.

The first time you open it, macOS says it can't check the app for malicious software, because
VENWhispr isn't paid-signed by Apple. See [Install](https://github.com/ventelv/VENWhispr#install)
for the one-time "Open Anyway" step. On first launch VENWhispr downloads its speech models (4.3 GB).

SHA-256 of the DMG: \`$(cut -d ' ' -f 1 "$DMG.sha256")\`
EOF
fi
