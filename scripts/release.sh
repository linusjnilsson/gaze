#!/usr/bin/env bash
# Builds a notarized Gaze DMG and the Sparkle appcast that announces it.
#
#     scripts/release.sh 0.2.0      (or: make release VERSION=0.2.0)
#
# Once per Mac, before the first release:
#   - The Developer ID certificate in the keychain ($GAZE_DEVELOPER_ID).
#   - Notary credentials, stored as a keychain profile ($GAZE_NOTARY_PROFILE):
#       xcrun notarytool store-credentials gaze --apple-id <apple id> --team-id <team id>
#     with an app-specific password from account.apple.com.
#   - Sparkle's signing key in the keychain (generate_keys, once; back it up with generate_keys -x).
#
# Then upload build/release/<version>/Gaze-<version>.dmg and appcast.xml to a GitHub release
# tagged v<version> in $GAZE_RELEASE_REPO. The app's feed is that repo's latest appcast.xml.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version, e.g. 0.2.0>}"
DEVELOPER_ID="${GAZE_DEVELOPER_ID:-Developer ID Application: Gait AS (46W69S748Y)}"
NOTARY_PROFILE="${GAZE_NOTARY_PROFILE:-gaze}"
REPO="${GAZE_RELEASE_REPO:-linusjnilsson/gaze}"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
OUT="build/release/$VERSION"
APP="build/Gaze.app"
DMG="$OUT/Gaze-$VERSION.dmg"

[ -d Models/GazeNet.mlpackage ] || { echo "Models/GazeNet.mlpackage is missing (make model)"; exit 1; }

# The version people see, kept in the source; the build number, which Sparkle compares, from the clock.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
BUILD="$(date +%Y%m%d%H%M)"

GAZE_SIGN_IDENTITY="$DEVELOPER_ID" GAZE_TIMESTAMP=1 ./scripts/build-app.sh
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# Changing Info.plist invalidates the signature: sign the app again (Sparkle inside stays signed).
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" --entitlements Resources/Gaze.entitlements "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$OUT"
mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Gaze.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "Gaze" -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$OUT/dmg"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

echo "Notarizing (a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# The appcast lists only this version: Sparkle only needs the newest.
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$OUT"

echo
echo "Built $DMG (version $VERSION, build $BUILD) and $OUT/appcast.xml."
echo "Upload both to a GitHub release tagged v$VERSION in $REPO."
