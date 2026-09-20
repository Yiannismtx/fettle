#!/usr/bin/env bash
#
# One-time setup for auto-update. Run this once, ever:
#
#   Scripts/setup-updates.sh
#
# It generates the Sparkle signing key pair, saves the public half into the
# repository (it is public by design — it gets embedded in the app so the app
# can verify updates), and leaves the private half in your login keychain,
# where only you and `sign_update` can reach it.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$FETTLE_ROOT"

KEY_FILE="$FETTLE_ROOT/Sparkle/public-key.txt"

echo "==> Locating Sparkle's key tools"
if [ ! -d "$FETTLE_SCRATCH" ] || ! find "$FETTLE_SCRATCH" -name generate_keys -type f >/dev/null 2>&1; then
  echo "    Fetching Sparkle first…"
  swift build "${SWIFT_FLAGS[@]}" --product Fettle >/dev/null
fi
GENERATE_KEYS="$(find "$FETTLE_SCRATCH" -name generate_keys -type f -perm +111 2>/dev/null | head -1)"
if [ -z "$GENERATE_KEYS" ]; then
  echo "!! Couldn't find Sparkle's generate_keys tool under $FETTLE_SCRATCH." >&2
  exit 1
fi

# -p looks up an existing key without creating one, so re-running this script
# is safe: it will never replace a key you already ship updates with.
if PUBLIC_KEY="$("$GENERATE_KEYS" -p 2>/dev/null)" && [ -n "$PUBLIC_KEY" ]; then
  echo "==> Found an existing signing key in your keychain — reusing it."
else
  echo "==> Generating a new signing key pair"
  echo "    macOS will ask permission to save it to your login keychain. Allow it."
  "$GENERATE_KEYS"
  PUBLIC_KEY="$("$GENERATE_KEYS" -p)"
fi

PUBLIC_KEY="$(printf '%s' "$PUBLIC_KEY" | tr -d '[:space:]')"
if [ -z "$PUBLIC_KEY" ]; then
  echo "!! No public key came back from generate_keys." >&2
  exit 1
fi

printf '%s\n' "$PUBLIC_KEY" > "$KEY_FILE"
echo "==> Wrote the public key to Sparkle/public-key.txt"
echo "    $PUBLIC_KEY"
echo
echo "The private key stays in your login keychain and is never read by these"
echo "scripts — sign_update does the signing. Back it up if you care about"
echo "shipping updates after a disk failure:"
echo
echo "    $GENERATE_KEYS -x fettle-private-key.txt"
echo "    (then store that file somewhere safe and delete it from disk)"
echo
echo "Next: commit Sparkle/public-key.txt and appcast.xml, then cut a release"
echo "with Scripts/release.sh."
