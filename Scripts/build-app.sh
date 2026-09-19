#!/usr/bin/env bash
#
# Assemble Fettle.app from the SwiftPM build products.
#
# SwiftPM can't produce an app bundle on its own, so this script does the three
# things it leaves out: write Info.plist, embed Sparkle.framework with a working
# rpath, and lay out Contents/ the way macOS expects.
#
# Usage: Scripts/build-app.sh [--debug] [--run]
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
ROOT="$FETTLE_ROOT"
cd "$ROOT"

CONFIG="release"
RUN_AFTER=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    --run)   RUN_AFTER=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(tr -d '[:space:]' < VERSION)"
# Build number must increase monotonically for Sparkle to see an update; the
# commit count is monotonic and needs no manual bookkeeping.
if git rev-parse --git-dir >/dev/null 2>&1; then
  BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
else
  BUILD="1"
fi

# Optional release configuration, supplied by the environment so no key material
# ever lands in the repository.
FEED_URL="${FETTLE_FEED_URL:-https://raw.githubusercontent.com/Yiannismtx/fettle/main/appcast.xml}"
ED_PUBLIC_KEY="${FETTLE_ED_PUBLIC_KEY:-}"

echo "==> Building Fettle $VERSION ($BUILD), $CONFIG"
swift build "${SWIFT_FLAGS[@]}" -c "$CONFIG" --product Fettle

BIN_PATH="$(swift build "${SWIFT_FLAGS[@]}" -c "$CONFIG" --product Fettle --show-bin-path)"
APP="$ROOT/dist/Fettle.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN_PATH/Fettle" "$APP/Contents/MacOS/Fettle"

# --- Info.plist -------------------------------------------------------------
python3 - "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist" \
  "$VERSION" "$BUILD" "$FEED_URL" "$ED_PUBLIC_KEY" <<'PY'
import sys
src, dst, version, build, feed, edkey = sys.argv[1:7]
text = open(src).read()
text = (text.replace("__VERSION__", version)
            .replace("__BUILD__", build)
            .replace("__FEED_URL__", feed)
            .replace("__ED_PUBLIC_KEY__", edkey))
if not edkey:
    # Sparkle refuses to run with an empty SUPublicEDKey. Drop the key entirely
    # for unsigned local builds: the app then reports updates as unconfigured
    # rather than failing at launch.
    import re
    text = re.sub(r"\t<key>SUPublicEDKey</key>\n\t<string></string>\n", "", text)
    text = re.sub(r"\t<key>SUFeedURL</key>\n\t<string>.*?</string>\n", "", text)
open(dst, "w").write(text)
PY
echo "APPL????" > "$APP/Contents/PkgInfo"

# --- App icon ---------------------------------------------------------------
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "    (no Resources/AppIcon.icns — run Scripts/make-icon.sh to generate one)"
fi

# --- Sparkle ----------------------------------------------------------------
SPARKLE_FRAMEWORK="$(find "$FETTLE_SCRATCH" -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
  SPARKLE_FRAMEWORK="$(find "$FETTLE_SCRATCH" -type d -name 'Sparkle.framework' 2>/dev/null | head -1)"
fi
if [ -n "$SPARKLE_FRAMEWORK" ]; then
  echo "==> Embedding $(basename "$(dirname "$SPARKLE_FRAMEWORK")")/Sparkle.framework"
  # --norsrc/--noextattr: stray extended attributes from the SPM artifact
  # cache make codesign reject the bundle as "detritus".
  ditto --norsrc --noextattr --noacl "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
else
  echo "!! Sparkle.framework not found under $FETTLE_SCRATCH — the app will not launch." >&2
  exit 1
fi

# --- Signing ----------------------------------------------------------------
# Ad-hoc signing is enough for a personal build: it satisfies the checks an
# embedded framework triggers on Apple silicon. A real Developer ID identity can
# be supplied via FETTLE_CODESIGN_IDENTITY.
#
# Sparkle ships already signed by the Sparkle project and contains nested
# helper bundles, so re-signing it is both unnecessary and fragile. Only the
# outer app is signed, which seals Frameworks/ into the app signature.
IDENTITY="${FETTLE_CODESIGN_IDENTITY:--}"
echo "==> Signing with identity: $IDENTITY"
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify "$APP" && echo "    signature OK"

echo "==> Built $APP"
if [ "$RUN_AFTER" = "1" ]; then
  open "$APP"
fi
