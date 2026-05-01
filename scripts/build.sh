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

echo "==> Step 7: build DMG"
mkdir -p "$WORK_STAGING"
cp -R "$WORK_APP" "$WORK_STAGING/"
ln -s /Applications "$WORK_STAGING/Applications"
WORK_DMG="$WORK_DIR/$APP_NAME.dmg"
hdiutil create \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$WORK_STAGING" \
    -ov \
    -format UDBZ \
    "$WORK_DMG" >/dev/null

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
