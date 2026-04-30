#!/usr/bin/env bash
# Generate Resources/AppIcon.icns from a 1024x1024 source PNG.
# Falls back to creating a simple solid-colour icon if no source PNG provided.
#
# Usage:
#   ./scripts/make-icon.sh                       # uses Resources/AppIcon.png if it exists, else generates one
#   ./scripts/make-icon.sh path/to/source.png

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES_DIR="$ROOT/Resources"
ICONSET="$RES_DIR/AppIcon.iconset"
SRC_PNG="${1:-$RES_DIR/AppIcon.png}"
OUT_ICNS="$RES_DIR/AppIcon.icns"

mkdir -p "$RES_DIR"

# If no source PNG, generate a simple one via sips/SF Symbol fallback (a flat colour square).
if [[ ! -f "$SRC_PNG" ]]; then
    echo "No source PNG at $SRC_PNG — generating simple coloured square."
    # Use Swift to render a 1024x1024 PNG with an SF symbol on solid background.
    /usr/bin/swift - <<'SWIFT' "$SRC_PNG"
import AppKit
import Foundation

let outPath = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let bg = NSColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 1.0)
bg.setFill()
let bgPath = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 220, yRadius: 220)
bgPath.fill()

let symbolConfig = NSImage.SymbolConfiguration(pointSize: 600, weight: .medium)
if let sym = NSImage(systemSymbolName: "text.book.closed.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(symbolConfig) {
    let tinted = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
        sym.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    let drawRect = NSRect(x: (size.width - 600)/2, y: (size.height - 600)/2, width: 600, height: 600)
    tinted.draw(in: drawRect)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG export failed\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
SWIFT
fi

echo "Building iconset from $SRC_PNG"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

for size in 16 32 64 128 256 512 1024; do
    out="$ICONSET/icon_${size}x${size}.png"
    sips -z "$size" "$size" "$SRC_PNG" --out "$out" >/dev/null
done
# @2x variants
sips -z 32 32 "$SRC_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 64 64 "$SRC_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 256 256 "$SRC_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 512 512 "$SRC_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 1024 1024 "$SRC_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
rm -rf "$ICONSET"
echo "AppIcon.icns ready ($(du -h "$OUT_ICNS" | cut -f1))"
