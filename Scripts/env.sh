#!/usr/bin/env bash
# Shared build environment.
#
# The build directory is deliberately kept outside the project. When the project
# lives in an iCloud-synced folder (Desktop or Documents), the file provider
# stamps com.apple.FinderInfo on build products, and codesign then rejects them
# as "resource fork, Finder information, or similar detritus". Building to a
# local cache directory sidesteps it entirely.
FETTLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETTLE_SCRATCH="${FETTLE_SCRATCH:-$HOME/Library/Caches/dev.fettle.build}"
mkdir -p "$FETTLE_SCRATCH"
SWIFT_FLAGS=(--scratch-path "$FETTLE_SCRATCH")
