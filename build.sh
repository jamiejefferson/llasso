#!/usr/bin/env bash
# Build the SwiftPM executable and wrap it in a .app bundle so macOS treats it as a
# real app for Screen Recording, Microphone and Accessibility permissions.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="Llasso"
EXE="Llasso"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$EXE"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$EXE"

# Output outside the iCloud-synced Documents folder: sync re-adds FinderInfo after
# signing, which breaks the signature and makes macOS forget permissions.
APP="$HOME/Applications/$APP_NAME.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps permission grants across rebuilds; ad-hoc
# signing changes the identity every build.
IDENTITY="${LLASSO_SIGN_IDENTITY:-IDEalize Local Signing}"
xattr -cr "$APP" 2>/dev/null || true
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "▸ codesign (\"$IDENTITY\")"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "▸ codesign (ad-hoc: permissions reset on each rebuild)"
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict "$APP" && echo "✓ Built $APP (signature valid)"
echo "  Run: open \"$APP\""
