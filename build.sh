#!/bin/zsh
# Build HeatWatch and assemble build/HeatWatch.app (no Xcode project needed).
#   ./build.sh            build only
#   ./build.sh --run      build, relaunch
#   ./build.sh --install  build, replace the installed copy, relaunch
#   ./build.sh --dist     build, package dist/HeatWatch-<version>.dmg and .zip
#
# The binary is universal (arm64 + x86_64). Signing is ad-hoc unless
# CODESIGN_IDENTITY is set to a "Developer ID Application: …" identity, in
# which case the hardened runtime is enabled so the result can be notarized.
set -euo pipefail
cd "$(dirname "$0")"

# Xcode's toolchain refuses to run until its licence has been accepted
# (sudo xcodebuild -license); the Command Line Tools build this just as well.
# The Command Line Tools ship without the SwiftUI macro plugin, so borrow
# Xcode's copy (same compiler build) when it is there.
EXTRA=()
if ! swift --version >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  PLUGINS=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins
  [[ -d $PLUGINS ]] && EXTRA=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
fi

APP=build/HeatWatch.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
ARCHS=(--arch arm64 --arch x86_64)

[[ -f Resources/AppIcon.icns ]] || swift Tools/make-icon.swift

swift build -c release "${ARCHS[@]}" "${EXTRA[@]}" 2>&1 | grep -Ev '^\s*$' | tail -3
BIN="$(swift build -c release "${ARCHS[@]}" "${EXTRA[@]}" --show-bin-path)/HeatWatch"

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
    # Replace the copy that is already installed (/Applications if it is there,
    # otherwise ~/Applications) and relaunch it.
    if [[ -d /Applications/HeatWatch.app ]]; then DEST=/Applications/HeatWatch.app; else mkdir -p ~/Applications; DEST=~/Applications/HeatWatch.app; fi
    pkill -x HeatWatch 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "installed $DEST"
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
