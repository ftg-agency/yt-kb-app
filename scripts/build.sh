#!/usr/bin/env bash
# Build YTKB.app and YTKB.dmg from the Swift Package — Apple Silicon only.
#
# Steps:
#   1. Ensure vendored/yt-dlp exists (run download-ytdlp.sh otherwise).
#   2. Run unit tests (Apple Silicon, debug). Bail out on failure.
#   3. swift build -c release --arch arm64.
#   4. Assemble .app bundle.
#   5. Strip xattrs + ad-hoc codesign.
#   6. hdiutil create UDBZ DMG with /Applications symlink.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="YTKB"
DISPLAY_NAME="yt-kb"
APP_BUNDLE="$ROOT/dist/$APP_NAME.app"
STAGING="$ROOT/dist/staging"
DMG_OUT="$ROOT/dist/${APP_NAME}.dmg"

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

echo "==> Step 5: assemble $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$EXEC_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/vendored/yt-dlp" "$APP_BUNDLE/Contents/Resources/yt-dlp"
chmod +x "$APP_BUNDLE/Contents/Resources/yt-dlp"
# Anti-tamper: write SHA256 of the bundled binary so the app can verify it on launch
shasum -a 256 "$APP_BUNDLE/Contents/Resources/yt-dlp" | awk '{print $1}' > "$APP_BUNDLE/Contents/Resources/yt-dlp.sha256"
echo "  yt-dlp sha256: $(cat "$APP_BUNDLE/Contents/Resources/yt-dlp.sha256")"
cp "$ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
echo "  bundle assembled at $APP_BUNDLE"

echo "==> Step 6: ad-hoc codesign"
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --verbose=2 "$APP_BUNDLE" || true

echo "==> Step 7: build DMG"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG_OUT"
hdiutil create \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDBZ \
    "$DMG_OUT" >/dev/null

echo
echo "==> Done"
echo "  app:  $APP_BUNDLE"
echo "  dmg:  $DMG_OUT  ($(du -h "$DMG_OUT" | cut -f1))"
echo
echo "Install:  open $DMG_OUT, drag $APP_NAME.app into /Applications"
echo "Unblock:  xattr -dr com.apple.quarantine /Applications/$APP_NAME.app"
