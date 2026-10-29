#!/bin/bash
# Builds the downloadable Mac app: a Release build signed with a Developer ID,
# notarized by Apple, in a .dmg anyone can open. It's local-only (no iCloud
# entitlements), so it needs no provisioning profile.
#
#   npm run release:macos                  build, sign, notarize -> build/release/Notebook-<version>.dmg
#   NOTARIZE=0 npm run release:macos       skip notarizing (for a quick local check)
#
# One-time setup:
#   - A "Developer ID Application" certificate in your keychain.
#   - Stored notarization credentials (an app-specific password from appleid.apple.com):
#       xcrun notarytool store-credentials notebook --apple-id you@example.com --team-id YOURTEAMID
#     Use another profile name with NOTARY_PROFILE=name.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-notebook}"
OUT=build/release
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in your keychain."; exit 1; }
TEAM=$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
echo "Signing as $IDENTITY"

rm -rf "$OUT"
xcodebuild -project ios/Notebook.xcodeproj -scheme NotebookMac -configuration Release \
    -derivedDataPath "$OUT/derived" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    NOTEBOOK_MAC_ENTITLEMENTS= NOTEBOOK_CLOUD_ENABLED=NO CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp build | grep -E '^(\*\*|error|warning: .*sign)' || true

APP="$OUT/derived/Build/Products/Release/Notebook.app"
[ -d "$APP" ] || { echo "Build failed: no $APP"; exit 1; }
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

# The disk image: the app and a link to /Applications to drag it onto.
DMG="$OUT/Notebook-$VERSION.dmg"
mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/Notebook.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "Notebook $VERSION" -srcfolder "$OUT/dmg" -format UDZO -ov "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$DMG"

if [ "${NOTARIZE:-1}" = "1" ]; then
    echo "Notarizing (usually a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
echo "Built $DMG"
