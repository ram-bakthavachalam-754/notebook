#!/bin/bash
# Builds the downloadable Mac app: a Release build signed with a Developer ID,
# notarized by Apple, in a .dmg anyone can open. It's local-only (no iCloud
# entitlements), so it needs no provisioning profile.
#
#   npm run release:macos                  build, sign, notarize -> build/release/Notebook-<version>.dmg
#   NOTARIZE=0 npm run release:macos       skip notarizing (for a quick local check)
#   VERSION=0.4.0 BUILD_NUMBER=12 ...      set the app's version instead of the project's
#
# It needs a "Developer ID Application" certificate in the keychain, and one of
# these for notarizing:
#   - An App Store Connect API key: NOTARY_KEY_PATH (the .p8 file), NOTARY_KEY_ID
#     and NOTARY_ISSUER. This is what the GitHub release workflow uses.
#   - Credentials stored once in the keychain (NOTARY_PROFILE, default "notebook"):
#       xcrun notarytool store-credentials notebook --apple-id you@example.com --team-id YOURTEAMID
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-notebook}"
OUT=build/release
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 '"Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate in your keychain."; exit 1; }
TEAM=$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
echo "Signing as $IDENTITY"

VERSIONS=()
[ -n "${VERSION:-}" ] && VERSIONS+=(MARKETING_VERSION="$VERSION")
[ -n "${BUILD_NUMBER:-}" ] && VERSIONS+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

rm -rf "$OUT"
xcodebuild -project ios/Notebook.xcodeproj -scheme NotebookMac -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$OUT/derived" ${VERSIONS[@]+"${VERSIONS[@]}"} \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    NOTEBOOK_MAC_ENTITLEMENTS= NOTEBOOK_CLOUD_ENABLED=NO CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp build | grep -E '\*\* BUILD|error:' || true

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
    if [ -n "${NOTARY_KEY_PATH:-}" ]; then
        AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    else
        AUTH=(--keychain-profile "$PROFILE")
    fi
    xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
echo "Built $DMG"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "dmg=$DMG" >> "$GITHUB_OUTPUT"
