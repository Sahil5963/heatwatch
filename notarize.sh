#!/bin/zsh
# Notarize the packaged DMG so teammates get a clean install (no Gatekeeper
# "Open Anyway" step). One-time setup, storing an app-specific password in the
# login keychain under the profile name "heatwatch":
#
#   xcrun notarytool store-credentials heatwatch \
#       --apple-id <apple-id-email> --team-id <team-id> --password <app-specific-password>
#
# (App-specific passwords: appleid.apple.com → Sign-In and Security.)
# Then:  ./notarize.sh            after  CODESIGN_IDENTITY=... ./build.sh --dist
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DMG="dist/HeatWatch-$VERSION.dmg"
ZIP="dist/HeatWatch-$VERSION.zip"
PROFILE="${NOTARY_PROFILE:-heatwatch}"

[[ -f "$DMG" ]] || { echo "missing $DMG — run: CODESIGN_IDENTITY=... ./build.sh --dist"; exit 1; }
codesign -dv --verbose=1 build/HeatWatch.app 2>&1 | grep -q 'Authority=Developer ID' \
  || { echo "build/HeatWatch.app is not Developer ID signed"; exit 1; }

echo "submitting $DMG …"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler staple build/HeatWatch.app

# Re-zip the stapled app so the .zip carries the ticket too.
rm -f "$ZIP"
ditto -c -k --keepParent build/HeatWatch.app "$ZIP"

echo "== gatekeeper"
spctl -a -t open --context context:primary-signature -vv "$DMG"
spctl -a -t exec -vv build/HeatWatch.app
