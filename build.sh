#!/bin/zsh
# Build HeatWatch and assemble build/HeatWatch.app (no Xcode project needed).
#   ./build.sh            build only
#   ./build.sh --run      build, relaunch
#   ./build.sh --install  build, copy to ~/Applications
#   ./build.sh --dist     build, package dist/HeatWatch-<version>.dmg and .zip
#
# The binary is universal (arm64 + x86_64). Signing is ad-hoc unless
# CODESIGN_IDENTITY is set to a "Developer ID Application: …" identity, in
# which case the hardened runtime is enabled so the result can be notarized.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/HeatWatch.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ARCHS=(--arch arm64 --arch x86_64)

[[ -f Resources/AppIcon.icns ]] || swift Tools/make-icon.swift

swift build -c release "${ARCHS[@]}" 2>&1 | grep -Ev '^\s*$' | tail -3
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/HeatWatch"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HeatWatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
fi
echo "built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/HeatWatch"))"

case "${1:-}" in
  --run)
    pkill -x HeatWatch 2>/dev/null || true
    open "$APP"
    ;;
  --install)
    mkdir -p ~/Applications
    rm -rf ~/Applications/HeatWatch.app
    cp -R "$APP" ~/Applications/HeatWatch.app
    echo "installed ~/Applications/HeatWatch.app"
    ;;
  --dist)
    mkdir -p dist
    STAGE=$(mktemp -d)
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "dist/HeatWatch-$VERSION.dmg" "dist/HeatWatch-$VERSION.zip"
    hdiutil create -volname "HeatWatch" -srcfolder "$STAGE" -ov -format UDZO -quiet "dist/HeatWatch-$VERSION.dmg"
    ditto -c -k --keepParent "$APP" "dist/HeatWatch-$VERSION.zip"
    rm -rf "$STAGE"
    ls -lh dist/HeatWatch-$VERSION.* | awk '{print $5, $9}'
    ;;
esac
