# Fettle

<img src="docs/icon.png" width="96" align="right" alt="">

A native macOS utility for the Downloads folder. It clears out dead-weight
installers, finds duplicate files by content, sorts what's left into type
folders, and runs on-demand malware scans through ClamAV.

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
| **Malware Scan** | Three scans through ClamAV's `clamscan`: **Quick** over the folders malware arrives and hides in, **Folder** over one folder you pick, and **Full System** over the whole startup disk. Flagged files go to quarantine or the Trash — never deleted, never acted on without you. |
| **Quarantine** | What a scan moved aside, what matched it, and a Put Back button. A signature match isn't proof, so the most consequential action in the app is also the one with an undo. |
| **Settings** | A page in the window, not a separate settings window: the folder, the thresholds, which scan runs, Full Disk Access and ClamAV's status. Reachable from the sidebar, the toolbar, or ⌘,. |

### What it deliberately doesn't do

- **No detection engine of its own.** Real malware detection is a security
  company's job. Fettle wraps ClamAV and never passes it `--remove` or `--move`.
- **No real-time scanning.** That needs Apple's Endpoint Security entitlement,
  which is out of scope for a personal on-demand tool.
- **No clean bill of health it didn't earn.** clamscan reports a folder macOS
  wouldn't let it open exactly as it reports an empty one, and exits zero
  either way. Fettle probes each location itself and says what was blocked
  rather than passing the silence on as "nothing found".
- **No permanent deletion, anywhere.**
- **No date-based folders** in the organizer — type only.

Package-cache directories (`node_modules`, `.git`, `Pods`, `DerivedData`, …) are
skipped everywhere. Files in there are identical to thousands of others by
design, and trashing one silently breaks whatever project owns it.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode 16+) to build
- ClamAV — only the malware scan needs it, and **Fettle can install it for
  you**; see below. Everything else works without it.

## The three scans

| Scan | Covers | Roughly |
|---|---|---|
| **Quick** | Downloads, `/Applications`, the LaunchAgents and LaunchDaemons folders, Application Support, Internet Plug-ins, `/private/tmp` — where Mac malware arrives and where it arranges to be run again. Skips iOS device backups. | Minutes |
| **Folder** | One folder and everything inside it. Defaults to the folder Fettle is pointed at; **Choose…** picks a different one for this scan only, without repointing the rest of the app. | Depends |
| **Full System** | The whole startup disk. | Hours |

The exact list of folders is shown on the page before the scan starts, each with
the reason it's there. A scan that claims coverage should be able to show its
working.

**Full System excludes** the sealed system volume (macOS verifies it itself, and
`/System/Volumes/Data` firmlinks back to the disk already being walked — leaving
it in scans everything twice), device nodes, `/Volumes`, the autofs trigger
paths `/net` and `/home`, virtual memory, and the per-user cache tree. The
temp tree is deliberately kept: it's a real staging ground for droppers.

### Full Disk Access

macOS refuses reads on Desktop, Documents, Downloads, Mail and Messages for an
app without Full Disk Access — and `clamscan` inherits that refusal, reports
those folders as scanned, and exits clean. Fettle checks each location itself
before scanning, names the ones that were blocked, and offers a button that
opens the right System Settings pane. A result that couldn't read everything
says so instead of claiming nothing was found.

**Settings › Scanning** shows the permission as a standing fact rather than
only as a warning mid-scan, alongside which scan the page opens with and the
ClamAV status.

## Installing ClamAV

Fettle uses ClamAV's detection engine rather than writing one (see
[non-goals](#what-it-deliberately-doesnt-do)). ClamAV isn't bundled — that would
mean shipping a 100 MB+ signature database and an updater for it — so it's a
one-time install.

### The button

Open **Malware Scan**. If ClamAV isn't there, the page offers to install it and
runs three things, showing you the output as it goes:

1. `brew install clamav` — a few hundred MB, a few minutes.
2. **Creates `freshclam.conf`.** Homebrew only installs `freshclam.conf.sample`,
   and `freshclam` refuses to start until a real config exists with its
   `Example` line commented out. This is the usual reason a fresh
   `brew install clamav` looks broken.
3. `freshclam` — downloads the signature database. Without it the scan runs and
   matches nothing.

You can cancel at any point, and the rest of Fettle keeps working while it runs.

**Homebrew has to be installed first.** Fettle won't install Homebrew for you:
its installer needs your administrator password, and it has to ask you for that
directly rather than through another app. If Homebrew is missing, the page hands
you the one-line installer to paste into Terminal, with a copy button and a link
to [brew.sh](https://brew.sh).

### Doing it by hand

Every command the button runs is listed under **Do it manually instead** on the
same page, with copy buttons. For reference (Apple silicon paths — use
`/usr/local` on Intel):

```bash
brew install clamav
cp /opt/homebrew/etc/clamav/freshclam.conf.sample /opt/homebrew/etc/clamav/freshclam.conf
sed -i '' 's/^Example$/# Example/' /opt/homebrew/etc/clamav/freshclam.conf
freshclam
```

### If Fettle still can't find it

- Fettle looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`,
  `/usr/bin`, and under whatever `HOMEBREW_PREFIX` is set to. Run
  `which clamscan`; if it's somewhere else, set the path in
  **Settings › Scanning**.
- A GUI app doesn't inherit your shell's `PATH`, so "it works in Terminal" isn't
  enough on its own — that's why Fettle searches explicitly.
- **Settings › Scanning › Re-check** re-probes without restarting the app.

### Keeping signatures current

Re-run `freshclam` from time to time. Fettle shows a warning bar when the
database is more than a week old, and says so if it can't find one at all.

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

Auto-update runs on [Sparkle](https://sparkle-project.org).

### One-time setup

```bash
Scripts/setup-updates.sh
```

That generates the EdDSA signing key pair and writes the public half to
`Sparkle/public-key.txt`. Re-running it is safe: if a key already exists in
your keychain it is reused, never replaced. Sparkle needs only one signing key
however many apps you use it in.

**The public key belongs in the repository.** It is embedded in every build so
the app can verify that an update was signed by the matching private key —
publishing it is the point. Only the private key is secret, and it stays in
your login keychain; none of these scripts ever read it, `sign_update` does the
signing.

Back the private key up if you care about shipping updates after a disk
failure — losing it means existing installs can never accept another update:

```bash
$(find ~/Library/Caches/dev.fettle.build -name generate_keys | head -1) -x fettle-private-key.txt
```

Store that file somewhere safe, then delete it from disk.

### Each release

```bash
# bump VERSION first
Scripts/release.sh "What changed in this version"
```

It builds, zips with `ditto`, signs the zip with the key from your keychain,
and adds an entry to `appcast.xml`. Then:

1. Create a GitHub release tagged `v<VERSION>` and upload `dist/Fettle-<VERSION>.zip` to it.
2. Commit and push `appcast.xml`.

The feed is `appcast.xml` served from the repo's `main` branch, so pushing it is
what publishes the update. Override with `FETTLE_FEED_URL` if you move it.

A build with no key in `Sparkle/public-key.txt` simply ships without a feed and
says so — Sparkle refuses to run with an empty key, so the app reports updates
as unconfigured rather than failing at launch.

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
