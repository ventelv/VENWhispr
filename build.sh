#!/bin/bash
# Builds VENWhispr.app. Usage:
#   ./build.sh           build into ./build/VENWhispr.app
#   ./build.sh install   also copy to /Applications and launch it
#
# If scripts/build_servers.sh has been run, whisper-server and llama-server from vendor/bin are
# bundled inside the app, so it runs on Macs without Homebrew. Otherwise the app uses Homebrew's.
#
# Signing: ad-hoc by default, which means macOS forgets the Accessibility grant after every
# rebuild. To avoid that, create a "Code Signing" certificate in Keychain Access
# (Certificate Assistant → Create a Certificate…) and run: SIGN_ID="Its Name" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

SIGN_ID="${SIGN_ID:--}"
APP="build/VENWhispr.app"

swift build -c release --arch arm64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/VENWhispr "$APP/Contents/MacOS/VENWhispr"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

# Nested code is signed before the app, whose signature then seals it.
for server in whisper-server llama-server; do
    if [ -x "vendor/bin/$server" ]; then
        cp "vendor/bin/$server" "$APP/Contents/MacOS/$server"
        codesign --force --sign "$SIGN_ID" --identifier "com.venwhispr.$server" "$APP/Contents/MacOS/$server"
        echo "Bundled $server"
    fi
done
if [ -x vendor/bin/whisper-server ] || [ -x vendor/bin/llama-server ]; then
    [ -f vendor/THIRD-PARTY-NOTICES.txt ] || { echo "vendor/THIRD-PARTY-NOTICES.txt is missing: run scripts/build_servers.sh" >&2; exit 1; }
    cp vendor/THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/"
fi

codesign --force --sign "$SIGN_ID" --identifier com.venwhispr.app "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x VENWhispr 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/VENWhispr.app
    cp -R "$APP" /Applications/
    open /Applications/VENWhispr.app
    echo "Installed and launched /Applications/VENWhispr.app"
fi
