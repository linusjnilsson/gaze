#!/usr/bin/env bash
# Builds Gaze.app from the Swift package.
#
# Signs with $GAZE_SIGN_IDENTITY, else the first "Apple Development" identity, else ad-hoc.
# A stable identity matters: macOS ties the camera permission to the code signature, so
# ad-hoc builds ask for camera access again after every rebuild.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP="build/Gaze.app"

swift build -c "$CONFIG" --product Gaze
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Gaze"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Gaze"
# Sparkle, for updates.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon, accent color, brand colors and menu bar icons.
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 15.0 \
  --app-icon AppIcon --accent-color AccentColor \
  --output-partial-info-plist "build/assets-info.plist" >/dev/null

# The gaze network is optional (make model); without it, Gaze tracks with the iris geometry alone.
if [ -d Models/GazeNet.mlpackage ]; then
  xcrun coremlcompiler compile Models/GazeNet.mlpackage "$APP/Contents/Resources" >/dev/null
fi

IDENTITY="${GAZE_SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | grep -m1 '"Apple Development' | awk '{print $2}' || true)}"
IDENTITY="${IDENTITY:--}"
# With the hardened runtime, which notarization requires; a release also needs a secure timestamp.
FLAGS=(--force --options runtime --sign "$IDENTITY")
if [ "${GAZE_TIMESTAMP:-0}" = 1 ]; then FLAGS+=(--timestamp); fi

# Inside out: Sparkle's helpers, the framework, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${FLAGS[@]}" "$SPARKLE/XPCServices/Installer.xpc"
codesign "${FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
codesign "${FLAGS[@]}" "$SPARKLE/Autoupdate"
codesign "${FLAGS[@]}" "$SPARKLE/Updater.app"
codesign "${FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${FLAGS[@]}" --entitlements Resources/Gaze.entitlements "$APP"

echo "Built $APP (signed with $IDENTITY)"
