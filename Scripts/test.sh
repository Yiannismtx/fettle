#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$FETTLE_ROOT"
exec swift test "${SWIFT_FLAGS[@]}" "$@"
