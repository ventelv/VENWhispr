#!/bin/bash
# Builds VENWhispr.app. Usage:
#   ./build.sh           build into ./build/VENWhispr.app
#   ./build.sh install   also copy to /Applications and launch it
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
