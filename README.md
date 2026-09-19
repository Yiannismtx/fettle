# Fettle

<img src="docs/icon.png" width="96" align="right" alt="">

A native macOS utility for the Downloads folder. It clears out dead-weight
installers, finds duplicate files by content, sorts what's left into type
folders, and runs an on-demand malware scan through ClamAV.

**Nothing in Fettle deletes permanently.** Every destructive path ends at the
Trash or a quarantine folder, and every batch is reviewed and approved before it
runs. `FileActions` — the one type all of it goes through — has no
permanent-delete API on it at all.

## What it does

| | |
|---|---|
| **Overview** | What's in the folder: size, type breakdown, biggest and oldest files, and which tools have something to offer. |
| **Installers** | `.dmg`/`.pkg`/`.iso` files past an age threshold you set, fuzzy-matched against `/Applications` so you can see which ones you've already installed from. |
| **Duplicates** | Byte-identical files found by SHA-256, so it catches the same file saved under two unrelated names. Keeps the oldest copy; you can override which one stays. |
| **Organize** | Sorts loose top-level files into Images / Documents / Archives / Installers / Other. Never overwrites: a name that's taken gets numbered. |
| **Malware Scan** | Hands the folder to ClamAV's `clamscan` and reports what it flags. Flagged files go to quarantine or the Trash — never deleted, never acted on without you. |
| **Quarantine** | What a scan moved aside, what matched it, and a Put Back button. A signature match isn't proof, so the most consequential action in the app is also the one with an undo. |

### What it deliberately doesn't do

- **No detection engine of its own.** Real malware detection is a security
  company's job. Fettle wraps ClamAV and never passes it `--remove` or `--move`.
- **No real-time scanning.** That needs Apple's Endpoint Security entitlement,
  which is out of scope for a personal on-demand tool.
- **No permanent deletion, anywhere.**
- **No date-based folders** in the organizer — type only.

Package-cache directories (`node_modules`, `.git`, `Pods`, `DerivedData`, …) are
skipped everywhere. Files in there are identical to thousands of others by
design, and trashing one silently breaks whatever project owns it.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode 16+) to build
- `brew install clamav` — only the malware scan needs it; everything else works
  without it

## Build and run

```bash
Scripts/build-app.sh --debug --run
```

Release build into `dist/Fettle.app`:

```bash
Scripts/build-app.sh
```

The script does the three things SwiftPM can't: writes `Info.plist`, embeds
`Sparkle.framework` with a working rpath, and signs the bundle. It stages the
bundle outside the project, because an iCloud-synced project folder re-stamps
extended attributes fast enough to make `codesign` fail intermittently.

### First launch

Fettle is signed ad-hoc, not with an Apple Developer ID, so Gatekeeper will
block the first launch. Right-click the app → **Open** → **Open**. macOS will
also ask for access to your Downloads folder the first time.

## Test

```bash
Scripts/test.sh
```

ClamAV isn't required: the integration is covered by tests that drive the real
service against a stand-in `clamscan` emitting genuine clamscan-shaped output.

`Scripts/make-fixture.sh` builds a synthetic Downloads folder — aged installers,
byte-identical duplicates under different names, a spread of file types, and a
`node_modules` tree that must be left alone — so you can exercise the app
without touching your real one:

```bash
Scripts/make-fixture.sh          # prints /tmp/fettle-fixture
```

Then point Fettle at it with **Choose Folder…**.

## Releasing

Auto-update runs on [Sparkle](https://sparkle-project.org). One-time setup:

1. Generate an EdDSA key pair. Sparkle's tool comes down with the package:
   ```bash
   find ~/Library/Caches/dev.fettle.build -name generate_keys -exec {} \;
   ```
   The private key goes into your login keychain; the public key is printed.
2. Put these in your shell profile:
   ```bash
   export FETTLE_ED_PUBLIC_KEY="<the printed public key>"
   export FETTLE_FEED_URL="https://raw.githubusercontent.com/Yiannismtx/fettle/main/appcast.xml"
   ```

Then, per release: bump `VERSION`, and run

```bash
Scripts/release.sh "What changed in this version"
```

It builds, zips, signs the zip with the key from your keychain, and adds an
entry to `appcast.xml`. Upload the zip to the matching GitHub release, then
commit and push `appcast.xml`.

Builds without `FETTLE_ED_PUBLIC_KEY` simply ship without a feed — Sparkle
refuses to run with an empty key, so the app reports updates as unconfigured
rather than failing at launch.

## Layout

```
Sources/FettleCore    scanning, hashing, matching, file actions — no UI, fully tested
Sources/FettleUI      the interface; a library, so its view models are testable
Sources/Fettle        the executable: an entry point and nothing else
Scripts/              build, test, release, icon, fixture
```

The interface lives in a library on purpose. A SwiftUI screen that only ever
runs inside the app is a screen whose state machine is never checked — the tests
assert that each screen reaches a settled state instead of spinning forever,
which is how the Organize page's hang was found and fixed.

## Licence

MIT — see [LICENSE](LICENSE).
