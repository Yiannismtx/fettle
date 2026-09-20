#!/usr/bin/env bash
#
# Screenshot Fettle's window only — never the whole screen, so a capture can't
# pick up whatever else the user happens to have open.
set -euo pipefail
OUT="${1:-/tmp/fettle-shot.png}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/winid.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
for window in list {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owner == "Fettle",
          let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let height = bounds["Height"] as? Double, height > 200
    else { continue }
    print(number)
    exit(0)
}
FileHandle.standardError.write(Data("No Fettle window on screen.\n".utf8))
exit(1)
SWIFT

screencapture -x -o -l "$(swift "$WORK/winid.swift")" "$OUT"
echo "$OUT"
