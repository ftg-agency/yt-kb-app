#!/usr/bin/env bash
# Build YTKB.app and YTKB.dmg from the Swift Package.
#
# Strategy:
#   1. Ensure vendored/yt-dlp exists (run download-ytdlp.sh otherwise).
#   2. swift build -c release. Try arm64+x86_64 universal first; on failure, fall back to arm64-only.
#   3. Assemble .app bundle: Contents/{Info.plist,MacOS/YTKB,Resources/yt-dlp,Resources/AppIcon.icns}.
#   4. Ad-hoc codesign (--sign -) so Hardened Runtime / Gatekeeper don't reject as "damaged".
#   5. hdiutil create UDBZ DMG with a /Applications symlink for drag-n-drop.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="YTKB"
DISPLAY_NAME="yt-kb"
APP_BUNDLE="$ROOT/dist/$APP_NAME.app"
STAGING="$ROOT/dist/staging"
DMG_OUT="$ROOT/dist/${APP_NAME}.dmg"

echo "==> Step 1: ensure vendored yt-dlp"
if [[ ! -f "$ROOT/vendored/yt-dlp" ]]; then
    "$ROOT/scripts/download-ytdlp.sh"
fi

echo "==> Step 2: swift build (release)"
ARCHS=(arm64)
# Try universal: build x86_64 separately first; if it fails we keep arm64-only
if swift build -c release --arch arm64 --arch x86_64 2>/tmp/ytkb-build-universal.log; then
    ARCHS=(arm64 x86_64)
    echo "  universal binary OK (arm64 + x86_64)"
else
    echo "  universal build failed — falling back to arm64-only"
    swift build -c release --arch arm64
fi

# Locate produced executable
if [[ ${#ARCHS[@]} -eq 2 ]]; then
    EXEC_PATH="$ROOT/.build/apple/Products/Release/YTKBApp"
else
    EXEC_PATH="$ROOT/.build/arm64-apple-macosx/release/YTKBApp"
fi
if [[ ! -f "$EXEC_PATH" ]]; then
    # Final fallback: search
    EXEC_PATH="$(find "$ROOT/.build" -name YTKBApp -type f -perm -u+x 2>/dev/null | head -1)"
fi
if [[ ! -f "$EXEC_PATH" ]]; then
    echo "ERROR: could not locate built executable" >&2
    exit 1
fi
echo "  built: $EXEC_PATH"

echo "==> Step 3: ensure AppIcon.icns"
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    "$ROOT/scripts/make-icon.sh"
fi

echo "==> Step 4: assemble $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$ROOT/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$EXEC_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/vendored/yt-dlp" "$APP_BUNDLE/Contents/Resources/yt-dlp"
chmod +x "$APP_BUNDLE/Contents/Resources/yt-dlp"
cp "$ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# PkgInfo (helps Finder treat us as an app, optional but cheap)
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "  bundle assembled at $APP_BUNDLE"

echo "==> Step 5: ad-hoc codesign"
# Strip extended attributes (resource forks, Finder info) — codesign rejects them.
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --verbose=2 "$APP_BUNDLE" || true

echo "==> Step 6: build DMG"
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
