#!/usr/bin/env bash
# Build YTKB.app and YTKB.dmg from the Swift Package — Apple Silicon only.
#
# Steps:
#   1. Ensure vendored/yt-dlp exists.
#   2. Run unit tests.
#   3. swift build -c release --arch arm64.
#   4. Assemble + codesign + DMG-pack the bundle in /tmp (NOT in dist/).
#      iCloud-synced paths (Desktop/Documents) inject com.apple.FinderInfo
#      onto new directories, which codesign rejects with "resource fork,
#      Finder information, or similar detritus not allowed". Building in
#      /tmp avoids the File Provider entirely.
#   5. ditto the signed bundle + the DMG out to $ROOT/dist for distribution.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="YTKB"
DISPLAY_NAME="yt-kb"
DIST_DIR="$ROOT/dist"
DMG_OUT="$DIST_DIR/${APP_NAME}.dmg"
DIST_APP="$DIST_DIR/$APP_NAME.app"

WORK_DIR="$(mktemp -d -t ytkb-build)"
trap "rm -rf '$WORK_DIR'" EXIT
WORK_APP="$WORK_DIR/$APP_NAME.app"
WORK_STAGING="$WORK_DIR/staging"

SKIP_TESTS="${SKIP_TESTS:-0}"

echo "==> Step 1: ensure vendored yt-dlp"
if [[ ! -f "$ROOT/vendored/yt-dlp" ]]; then
    "$ROOT/scripts/download-ytdlp.sh"
fi

if [[ "$SKIP_TESTS" != "1" ]]; then
    echo "==> Step 2: run unit tests (custom harness via YTKBAppTests executable)"
    swift run YTKBAppTests
else
    echo "==> Step 2: tests skipped via SKIP_TESTS=1"
fi

echo "==> Step 3: swift build -c release --arch arm64"
swift build -c release --arch arm64

EXEC_PATH="$ROOT/.build/arm64-apple-macosx/release/YTKBApp"
if [[ ! -f "$EXEC_PATH" ]]; then
    echo "ERROR: built executable not found at $EXEC_PATH" >&2
    exit 1
fi
echo "  built: $EXEC_PATH"

echo "==> Step 4: ensure AppIcon.icns"
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    "$ROOT/scripts/make-icon.sh"
fi

echo "==> Step 5: assemble $APP_NAME.app in $WORK_DIR"
mkdir -p "$WORK_APP/Contents/MacOS"
mkdir -p "$WORK_APP/Contents/Resources"

cp "$ROOT/Info.plist" "$WORK_APP/Contents/Info.plist"
cp "$EXEC_PATH" "$WORK_APP/Contents/MacOS/$APP_NAME"
chmod +x "$WORK_APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/vendored/yt-dlp" "$WORK_APP/Contents/Resources/yt-dlp"
chmod +x "$WORK_APP/Contents/Resources/yt-dlp"
shasum -a 256 "$WORK_APP/Contents/Resources/yt-dlp" | awk '{print $1}' > "$WORK_APP/Contents/Resources/yt-dlp.sha256"
echo "  yt-dlp sha256: $(cat "$WORK_APP/Contents/Resources/yt-dlp.sha256")"
cp "$ROOT/Resources/AppIcon.icns" "$WORK_APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$WORK_APP/Contents/PkgInfo"
echo "  bundle assembled at $WORK_APP"

echo "==> Step 6: ad-hoc codesign (in /tmp, no iCloud File Provider)"
xattr -cr "$WORK_APP"
codesign --force --deep --sign - "$WORK_APP"
codesign --verify --verbose=2 "$WORK_APP"

echo "==> Step 7: build DMG with custom layout"
# Stage: app + Applications symlink + hidden background image
mkdir -p "$WORK_STAGING/.background"
cp -R "$WORK_APP" "$WORK_STAGING/"
ln -s /Applications "$WORK_STAGING/Applications"

# Generate the background image (640×400 with arrow + hint text)
"$ROOT/scripts/make-dmg-background.swift" "$WORK_STAGING/.background/background.png"

# Create a writable DMG, mount, run Finder layout via AppleScript, unmount,
# then convert to compressed UDBZ. This is the standard "branded DMG" flow
# used by every macOS app (Cursor, Notion, Slack, etc).
WORK_DMG_RW="$WORK_DIR/${APP_NAME}-rw.dmg"
WORK_DMG="$WORK_DIR/$APP_NAME.dmg"
hdiutil create \
    -srcfolder "$WORK_STAGING" \
    -volname "$DISPLAY_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size 60m \
    -ov \
    "$WORK_DMG_RW" >/dev/null

# Mount and remember the device + mount point
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK_DMG_RW" | egrep '^/dev/' | sed 1q | awk '{print $1}')
MNT="/Volumes/$DISPLAY_NAME"
sleep 1

# Drive Finder via AppleScript to set the icon-view layout. The osascript
# is best-effort — if it fails (e.g. Finder is uncooperative in CI) we
# fall back to a plain DMG without complaints.
osascript <<EOF || true
tell application "Finder"
    tell disk "$DISPLAY_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 740, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:background.png"
        set position of item "${APP_NAME}.app" of container window to {160, 200}
        set position of item "Applications" of container window to {480, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

# Force any pending writes to disk before detach
sync || true

# Detach (sometimes the volume is "busy" briefly — retry)
for i in 1 2 3 4 5; do
    if hdiutil detach "$DEV" >/dev/null 2>&1; then break; fi
    sleep 1
done

# Convert RW DMG → UDBZ (compressed, best-compression)
hdiutil convert "$WORK_DMG_RW" -format UDBZ -o "$WORK_DMG" >/dev/null

echo "==> Step 8: copy artifacts to $DIST_DIR"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP"
ditto "$WORK_APP" "$DIST_APP"
cp "$WORK_DMG" "$DMG_OUT"

echo
echo "==> Done"
echo "  app:  $DIST_APP"
echo "  dmg:  $DMG_OUT  ($(du -h "$DMG_OUT" | cut -f1))"
echo
echo "Install:  open $DMG_OUT, drag $APP_NAME.app into /Applications"
echo "Unblock:  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
