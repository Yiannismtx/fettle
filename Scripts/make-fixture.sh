#!/usr/bin/env bash
#
# Build a fake "Downloads" folder to exercise Fettle against, so testing never
# touches the real one. Prints the path it created.
set -euo pipefail
FIXTURE="${1:-/tmp/fettle-fixture}"
rm -rf "$FIXTURE"
mkdir -p "$FIXTURE"

# --- installers: some matching installed apps, some not ---------------------
for name in "Firefox 121.0" "Google Chrome" "Xcode-16.2" "SomeToolNobodyHas-3.1"; do
  head -c 2000000 /dev/urandom > "$FIXTURE/$name.dmg"
  touch -t 202401010900 "$FIXTURE/$name.dmg"
done
head -c 500000 /dev/urandom > "$FIXTURE/node-v20.11.0.pkg"
touch -t 202401010900 "$FIXTURE/node-v20.11.0.pkg"
# A fresh one, to prove the age threshold excludes it.
head -c 300000 /dev/urandom > "$FIXTURE/JustDownloaded.dmg"

# --- duplicates: identical bytes under unrelated names ----------------------
head -c 400000 /dev/urandom > "$FIXTURE/holiday-photo.jpg"
cp "$FIXTURE/holiday-photo.jpg" "$FIXTURE/IMG_4471.jpg"
cp "$FIXTURE/holiday-photo.jpg" "$FIXTURE/photo copy.jpg"
head -c 120000 /dev/urandom > "$FIXTURE/contract.pdf"
cp "$FIXTURE/contract.pdf" "$FIXTURE/contract (1).pdf"

# --- a spread of types for the organizer ------------------------------------
for i in 1 2 3 4 5; do head -c 90000 /dev/urandom > "$FIXTURE/screenshot-$i.png"; done
for i in 1 2 3; do head -c 40000 /dev/urandom > "$FIXTURE/notes-$i.txt"; done
head -c 700000 /dev/urandom > "$FIXTURE/project-export.zip"
head -c 250000 /dev/urandom > "$FIXTURE/clip.mp4"
head -c 60000 /dev/urandom > "$FIXTURE/spreadsheet.csv"

# --- things Fettle must leave alone -----------------------------------------
mkdir -p "$FIXTURE/My Project/node_modules/left-pad"
echo "module.exports = 1" > "$FIXTURE/My Project/node_modules/left-pad/index.js"
echo "module.exports = 1" > "$FIXTURE/My Project/index.js"
mkdir -p "$FIXTURE/Documents"
cp "$FIXTURE/contract.pdf" "$FIXTURE/Documents/contract.pdf"

echo "$FIXTURE"
