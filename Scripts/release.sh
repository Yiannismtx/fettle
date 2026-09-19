#!/usr/bin/env bash
#
# Cut a release: build the app, zip it, sign the zip with the Sparkle EdDSA key,
# and add an entry to appcast.xml.
#
#   Scripts/release.sh "What changed in this version"
#
# Requires, once:
#   1. An EdDSA key pair. Sparkle ships `generate_keys`; find it with
#        find ~/Library/Caches/dev.fettle.build -name generate_keys
#      Run it — the private key goes into your login keychain, and it prints the
#      public key.
#   2. export FETTLE_ED_PUBLIC_KEY="<the printed public key>"
#      export FETTLE_FEED_URL="https://raw.githubusercontent.com/<you>/fettle/main/appcast.xml"
#      Put those in your shell profile so every build carries them.
#
# The private key never leaves the keychain and is never read by this script —
# `sign_update` does the signing.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$FETTLE_ROOT"

NOTES="${1:-}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD)"

if [ -z "${FETTLE_ED_PUBLIC_KEY:-}" ]; then
  echo "!! FETTLE_ED_PUBLIC_KEY isn't set — the build would ship without an update feed." >&2
  echo "   See the comment at the top of this script." >&2
  exit 1
fi

echo "==> Releasing Fettle $VERSION ($BUILD)"
./Scripts/build-app.sh

DIST="$FETTLE_ROOT/dist"
ZIP="$DIST/Fettle-$VERSION.zip"
rm -f "$ZIP"
# ditto -c -k --keepParent is what Sparkle expects; plain `zip` loses symlinks
# inside the embedded framework.
ditto -c -k --sequesterRsrc --keepParent "$DIST/Fettle.app" "$ZIP"
LENGTH="$(stat -f%z "$ZIP")"

SIGN_UPDATE="$(find "$FETTLE_SCRATCH" -name sign_update -type f -perm +111 2>/dev/null | head -1)"
if [ -z "$SIGN_UPDATE" ]; then
  echo "!! Sparkle's sign_update tool not found under $FETTLE_SCRATCH." >&2
  echo "   Run a build first so SwiftPM fetches the Sparkle artifact." >&2
  exit 1
fi

echo "==> Signing $ZIP"
SIGNATURE="$("$SIGN_UPDATE" "$ZIP" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
if [ -z "$SIGNATURE" ]; then
  echo "!! sign_update produced no signature. Is the private key in your keychain?" >&2
  exit 1
fi

PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
DOWNLOAD_URL="${FETTLE_DOWNLOAD_BASE:-https://github.com/Yiannismtx/fettle/releases/download/v$VERSION}/Fettle-$VERSION.zip"

python3 - "$FETTLE_ROOT/appcast.xml" "$VERSION" "$BUILD" "$PUBDATE" \
  "$DOWNLOAD_URL" "$LENGTH" "$SIGNATURE" "$NOTES" <<'PY'
import sys, os, re
path, version, build, pubdate, url, length, signature, notes = sys.argv[1:9]

item = f"""        <item>
            <title>Version {version}</title>
            <pubDate>{pubdate}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[{notes or 'Maintenance release.'}]]></description>
            <enclosure url="{url}"
                       length="{length}"
                       type="application/octet-stream"
                       sparkle:edSignature="{signature}" />
        </item>
"""

if not os.path.exists(path):
    open(path, "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        '    <channel>\n'
        '        <title>Fettle</title>\n'
        '        <description>Updates for Fettle</description>\n'
        '        <language>en</language>\n'
        '    </channel>\n'
        '</rss>\n'
    )

text = open(path).read()
# Drop any existing entry for this build, so re-running is idempotent.
text = re.sub(
    r"[ \t]*<item>(?:(?!</item>).)*?<sparkle:version>" + re.escape(build)
    + r"</sparkle:version>.*?</item>\n",
    "", text, flags=re.S,
)
# Newest first.
text = text.replace("        <language>en</language>\n",
                    "        <language>en</language>\n" + item, 1)
open(path, "w").write(text)
print(f"appcast.xml now advertises {version} (build {build})")
PY

echo "==> Done."
echo "    Upload $ZIP to the v$VERSION GitHub release,"
echo "    then commit and push appcast.xml."
