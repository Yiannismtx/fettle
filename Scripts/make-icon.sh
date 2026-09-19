#!/usr/bin/env bash
# Render Resources/AppIcon.icns from Scripts/make-icon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift "$ROOT/Scripts/make-icon.swift" "$WORK/icon-1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$WORK/icon-1024.png" --out "$ICONSET/icon_$2.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "wrote Resources/AppIcon.icns"
