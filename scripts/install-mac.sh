#!/bin/bash
# Builds the signed native Mac app and installs it as /Applications/Notebook.app.
#
#   npm run install:macos              build, quit Notebook, install, open
#   npm run install:macos -- --no-build   install the last build
#
# It replaces /Applications/Notebook.app only when that is this same app (same
# bundle ID), so an Electron Notebook installed there is never overwritten.
# Rename or remove that one first, or run with FORCE=1 to replace it anyway.
# Your notebook's data isn't in the app; it stays where it is.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-build/mac-signed/Build/Products/Debug/Notebook.app}"
DEST="${DEST:-/Applications/Notebook.app}"

if [ "${1:-}" != "--no-build" ]; then npm run build:macos:signed; fi
[ -d "$APP" ] || { echo "No build at $APP. Run: npm run build:macos:signed"; exit 1; }

id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
if [ -d "$DEST" ]; then
    old=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST/Contents/Info.plist" 2>/dev/null || echo "unknown")
    if [ "$old" != "$id" ] && [ "${FORCE:-}" != "1" ]; then
        echo "$DEST is a different app ($old), perhaps the Electron Notebook. Not replacing it."
        echo "Rename or remove it, or run with FORCE=1 to replace it."
        exit 1
    fi
fi

# Quit the running copy so its files can be replaced and nothing is left unsaved.
if pgrep -f "$DEST/Contents/MacOS/" >/dev/null; then
    echo "Quitting Notebook…"
    osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -f "$DEST/Contents/MacOS/" >/dev/null || break; sleep 0.5; done
    if pgrep -f "$DEST/Contents/MacOS/" >/dev/null; then echo "Notebook is still open. Quit it (⌘Q) and run this again."; exit 1; fi
fi

# Copy beside the old app, then swap, so a failed copy leaves the old one in place.
rm -rf "$DEST.installing"
ditto "$APP" "$DEST.installing"
rm -rf "$DEST"
mv "$DEST.installing" "$DEST"
echo "Installed $DEST ($id)"

if [ "${NO_OPEN:-}" != "1" ]; then open "$DEST"; fi
