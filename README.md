# Fettle

A native macOS utility for the Downloads folder. It clears out dead-weight
installers, finds duplicate files by content, sorts what's left into type
folders, and runs an on-demand malware scan through ClamAV.

**Nothing in Fettle deletes permanently.** Every destructive path ends at the
Trash, and every batch is reviewed and approved before it runs.

## Requirements

- macOS 14 or later
- Xcode 16+ / Swift 6 toolchain to build
- `brew install clamav` (optional — only the malware scan needs it)

## Build

```bash
Scripts/build-app.sh          # release build → dist/Fettle.app
Scripts/build-app.sh --debug --run
```

The script assembles the app bundle SwiftPM can't produce on its own: it writes
`Info.plist`, embeds `Sparkle.framework`, and ad-hoc signs the result.

## Test

```bash
swift test
```

## Status

Work in progress. See `docs/` for the build plan.

## Licence

MIT — see [LICENSE](LICENSE).
