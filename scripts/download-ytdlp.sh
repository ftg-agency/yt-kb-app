#!/usr/bin/env bash
# Download yt-dlp_macos universal binary into vendored/yt-dlp.
# Skips the download if the file already exists.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDORED="$ROOT/vendored"
TARGET="$VENDORED/yt-dlp"

mkdir -p "$VENDORED"

if [[ -f "$TARGET" && -s "$TARGET" ]]; then
    echo "yt-dlp already vendored at $TARGET ($(du -h "$TARGET" | cut -f1))"
    exit 0
fi

# Use the latest release marker; GitHub serves the freshest binary at this URL.
URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"

echo "Downloading yt-dlp_macos..."
curl -L --fail --progress-bar -o "$TARGET" "$URL"
chmod +x "$TARGET"

# Quick sanity check
if "$TARGET" --version >/dev/null 2>&1; then
    echo "yt-dlp $("$TARGET" --version) ready ($(du -h "$TARGET" | cut -f1))"
else
    echo "WARN: yt-dlp downloaded but --version check failed" >&2
fi
