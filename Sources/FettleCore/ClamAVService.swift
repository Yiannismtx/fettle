import Foundation

/// What Fettle found when it went looking for ClamAV.
public enum ClamAVAvailability: Equatable, Sendable {
    case unknown
    case available(path: String, version: String, databaseDate: Date?)
    case missing
    /// Found the binary but couldn't run it — usually a broken Homebrew link.
    case broken(path: String, reason: String)

    public var isUsable: Bool {
        if case .available = self { return true }
        return false
    }

    public var executablePath: String? {
        switch self {
        case .available(let path, _, _), .broken(let path, _): return path
        default: return nil
        }
    }
}

/// One line of `clamscan` output that matched a signature.
public struct MalwareFinding: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let signature: String

    public init(url: URL, signature: String) {
        self.url = url
        self.signature = signature
    }
}

public struct ClamAVScanReport: Sendable {
    public let findings: [MalwareFinding]
    public let filesScanned: Int
    public let duration: TimeInterval
    /// `clamscan` exits 0 (clean), 1 (found something) or 2 (error).
    public let exitCode: Int32
    public let errorOutput: String
    /// A sample of the files and folders clamscan was refused by the
    /// operating system, capped — see `inaccessibleCount` for the real total.
    ///
    /// These are the reason a scan report can't be read as a clean bill of
    /// health on its own: clamscan counts a folder it couldn't open towards
    /// "scanned" and moves on, so without this a scan blocked out of every
    /// interesting folder looks exactly like a scan that found nothing.
    public let inaccessiblePaths: [URL]
    /// How many paths were refused in total.
    ///
    /// Kept separately from the list because a whole-disk scan without Full
    /// Disk Access is refused hundreds of thousands of times, and holding a
    /// URL for every one of them would cost more memory than the scan itself.
    public let inaccessibleCount: Int

    public var hadError: Bool { exitCode != 0 && exitCode != 1 }

    /// A scan that read nothing at all. An error alongside real results is
    /// usually one unreadable corner of a large tree, and reporting the whole
    /// scan as a failure would throw away findings that were genuinely made.
    public var readNothing: Bool { filesScanned == 0 && findings.isEmpty }

    public init(
        findings: [MalwareFinding], filesScanned: Int, duration: TimeInterval,
        exitCode: Int32, errorOutput: String, inaccessiblePaths: [URL] = [],
        inaccessibleCount: Int? = nil
    ) {
        self.findings = findings
        self.filesScanned = filesScanned
        self.duration = duration
        self.exitCode = exitCode
        self.errorOutput = errorOutput
        self.inaccessiblePaths = inaccessiblePaths
        self.inaccessibleCount = inaccessibleCount ?? inaccessiblePaths.count
    }
}

public enum ClamAVError: Error, LocalizedError, Sendable {
    case notInstalled
    case launchFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "ClamAV isn't installed. Run `brew install clamav`, then `freshclam` to download signatures."
        case .launchFailed(let message):
            return "Couldn't run clamscan: \(message)"
        case .cancelled:
            return "Scan cancelled."
        }
    }
}

/// Wraps the Homebrew-installed `clamscan` binary (spec §3.4). Fettle does not
/// implement detection itself; it shells out to a real engine and parses it.
public struct ClamAVService: Sendable {
    /// Homebrew's two prefixes plus the usual Unix spots. `which` alone isn't
    /// enough: a GUI app launched from the Finder doesn't inherit the shell PATH
    /// that Homebrew adds.
    public static let searchPaths = [
        "/opt/homebrew/bin/clamscan",
        "/usr/local/bin/clamscan",
        "/opt/local/bin/clamscan",
        "/usr/bin/clamscan",
    ]

    private static var databaseDirectories: [String] {
        var directories = [
            "/opt/homebrew/var/lib/clamav",
            "/usr/local/var/lib/clamav",
            "/opt/local/var/lib/clamav",
            "/var/lib/clamav",
        ]
        if let brew = Homebrew.locate() {
            directories.append("\(brew.prefix)/var/lib/clamav")
        }
        return directories
    }

    private let overridePath: String

    public init(overridePath: String = "") {
        self.overridePath = overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func locateExecutable() -> String? {
        let fm = FileManager.default
        if !overridePath.isEmpty {
            return fm.isExecutableFile(atPath: overridePath) ? overridePath : nil
        }
        for path in Self.searchPaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Whatever Homebrew prefix is actually in use, last: a user with a
        // custom HOMEBREW_PREFIX would otherwise install ClamAV through Fettle
        // and still be told it isn't installed.
        if let brew = Homebrew.locate() {
            let path = "\(brew.prefix)/bin/clamscan"
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Latest mtime across the signature databases, so the UI can warn about
    /// stale definitions without shelling out to `freshclam`.
    public static func signatureDatabaseDate() -> Date? {
        let fm = FileManager.default
        var newest: Date?
        for directory in databaseDirectories {
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where name.hasSuffix(".cvd") || name.hasSuffix(".cld") {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let attributes = try? fm.attributesOfItem(atPath: path),
                      let modified = attributes[.modificationDate] as? Date else { continue }
                if newest == nil || modified > newest! { newest = modified }
            }
        }
        return newest
    }

    public func probe() async -> ClamAVAvailability {
        guard let path = locateExecutable() else { return .missing }
        do {
            let result = try await Process.runCapturing(
                executable: path, arguments: ["--version"], timeout: 15
            )
            let version = result.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? "ClamAV"
            guard result.exitCode == 0, !version.isEmpty else {
                return .broken(
                    path: path,
                    reason: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                        ? "clamscan --version exited with code \(result.exitCode)."
                        : result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return .available(
                path: path, version: version, databaseDate: Self.signatureDatabaseDate()
            )
        } catch {
            return .broken(path: path, reason: error.localizedDescription)
        }
    }

    /// How many files `clamscan` will visit.
    ///
    /// clamscan has no progress output of its own, so the denominator for the
    /// percentage has to come from walking the folder first. This is a
    /// metadata-only enumeration — no file is opened — so it costs a fraction
    /// of the scan it is measuring.
    ///
    /// Hidden files and the insides of app bundles are both counted, because
    /// clamscan descends into both. The count is a denominator, not a promise:
    /// clamscan also reports on files it finds *inside* archives, so the real
    /// total can come out higher. The UI clamps rather than pretending.
    public static func countScannableFiles(
        in folder: URL,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Int {
        countScannableFiles(in: [folder], isCancelled: isCancelled)
    }

    /// The same walk across several roots, skipping the directories the scan
    /// itself will skip.
    ///
    /// The exclusions have to be applied here too, not just passed to clamscan.
    /// A denominator that counted every file on the startup disk while the scan
    /// skipped half of them would leave the bar stuck at 50% on a scan that had
    /// actually finished.
    ///
    /// `onCount` exists because on a full system scan this walk is itself a
    /// minutes-long wait. Reporting a running total turns "Preparing to scan"
    /// from a frozen label into a number that visibly climbs.
    public static func countScannableFiles(
        in roots: [URL],
        excluding exclusions: [String] = [],
        isCancelled: @Sendable () -> Bool = { false },
        onCount: (@Sendable (Int) -> Void)? = nil
    ) -> Int {
        let matchers = exclusions.compactMap {
            try? NSRegularExpression(pattern: $0, options: [])
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        var count = 0
        var seen = 0

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                seen += 1
                // Checking the flag per entry would cost more than the walk.
                if seen % 512 == 0 {
                    if isCancelled() { return count }
                    onCount?(count)
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    // Only directories are matched against the exclusions:
                    // there are orders of magnitude fewer of them than files,
                    // and skipping one skips everything beneath it anyway.
                    if matches(matchers, path: url.path) { enumerator.skipDescendants() }
                    continue
                }
                if values?.isRegularFile == true { count += 1 }
            }
        }
        onCount?(count)
        return count
    }

    private static func matches(_ matchers: [NSRegularExpression], path: String) -> Bool {
        guard !matchers.isEmpty else { return false }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return matchers.contains { $0.firstMatch(in: path, options: [], range: range) != nil }
    }

    /// Run a scan, streaming per-file progress as `clamscan` prints it.
    ///
    /// `--stdout` keeps findings out of stderr, and `--no-summary` is deliberately
    /// *not* passed: the summary line is where the scanned-file count comes from.
    public func scan(
        folder: URL,
        recursive: Bool = true,
        onProgress: (@Sendable (ClamAVProgress) -> Void)? = nil
    ) async throws -> ClamAVScanReport {
        var plan = MalwareScanPlan.folder(folder)
        if !recursive {
            plan = MalwareScanPlan(
                kind: plan.kind,
                locations: plan.locations,
                accessProbes: plan.accessProbes,
                recursive: false
            )
        }
        return try await scan(plan: plan, onProgress: onProgress)
    }

    /// Run a planned scan — one folder, a list of high-risk folders, or the
    /// whole startup disk. The plan is the only thing that differs between
    /// them; everything downstream of here is identical.
    public func scan(
        plan: MalwareScanPlan,
        onProgress: (@Sendable (ClamAVProgress) -> Void)? = nil
    ) async throws -> ClamAVScanReport {
        guard let path = locateExecutable() else { throw ClamAVError.notInstalled }
        // A quick scan on a machine missing every preset folder would otherwise
        // invoke clamscan with no paths at all, which makes it scan the working
        // directory — a scan of somewhere nobody asked about.
        guard !plan.isEmpty else {
            return ClamAVScanReport(
                findings: [], filesScanned: 0, duration: 0, exitCode: 0, errorOutput: ""
            )
        }

        // Findings go to stdout; the trailing summary block is what carries the
        // scanned-file count, so `--no-summary` is deliberately not passed.
        //
        // `--infected` is deliberately *not* passed either: it would suppress
        // the per-file `path: OK` lines, and those lines are the only signal
        // clamscan gives about how far along it is. Without them the UI can
        // only spin. The extra output costs nothing — it is streamed and
        // counted, never buffered.
        //
        // Fettle decides what happens to a hit, so clamscan is never given
        // --remove, --move or --copy: it reports, it doesn't act.
        var arguments = ["--stdout"]
        arguments.append(plan.recursive ? "--recursive=yes" : "--recursive=no")
        for pattern in plan.excludedDirectories {
            arguments.append("--exclude-dir=\(pattern)")
        }
        arguments.append(contentsOf: plan.roots.map(\.path))

        let collected = Locked(ScanAccumulator())
        let started = Date()

        let result = try await Process.runStreaming(
            executable: path,
            arguments: arguments,
            // Piped, clamscan holds every line until it exits — a thirteen
            // second scan would report nothing until it was already over.
            // Given a terminal it line-buffers, which is what makes a real
            // percentage possible.
            usePseudoTerminal: true,
            onStandardOutputLine: { line in
                // Checked before the per-file parse: clamscan announces a
                // refusal as `/some/path: Access denied.`, which has the exact
                // shape of a clean result and would otherwise be counted as a
                // file successfully scanned.
                if let refusal = Self.parseInaccessible(line: line) {
                    collected.withLock { $0.noteInaccessible(refusal.url) }
                    onProgress?(.inaccessible(refusal.url))
                } else if let outcome = Self.parseScanResult(line: line) {
                    collected.withLock { $0.streamedFiles += 1 }
                    if let finding = outcome.finding {
                        collected.withLock { $0.findings.append(finding) }
                        onProgress?(.found(finding))
                    } else {
                        onProgress?(.scanned(outcome.url))
                    }
                } else if let loading = Self.parseSignatureLoading(line: line) {
                    onProgress?(.loadingSignatures(loaded: loading.loaded, total: loading.total))
                } else if let scanned = Self.parseScannedCount(line: line) {
                    collected.withLock { $0.summaryFiles = scanned }
                } else if !line.isEmpty {
                    onProgress?(.message(line))
                }
            }
        )

        let accumulated = collected.withLock { $0 }
        return ClamAVScanReport(
            findings: accumulated.findings,
            // The summary is authoritative when clamscan printed one; the
            // streamed count is the fallback so a cut-short scan still reports
            // what it got through.
            filesScanned: accumulated.summaryFiles > 0
                ? accumulated.summaryFiles
                : accumulated.streamedFiles,
            duration: Date().timeIntervalSince(started),
            exitCode: result.exitCode,
            errorOutput: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines),
            inaccessiblePaths: accumulated.inaccessible,
            inaccessibleCount: accumulated.inaccessibleCount
        )
    }

    /// One per-file result line: `/path/to/file: OK`, `/path/to/file: Empty file`
    /// or `/path/to/file: Signature.Name FOUND`.
    ///
    /// The leading `/` is what separates these from the summary block, which is
    /// full of lines like `Scanned files: 412` that also contain `": "`.
    static func parseScanResult(line: String) -> (url: URL, finding: MalwareFinding?)? {
        guard line.hasPrefix("/") else { return nil }
        // Split on the LAST ": " so paths containing ": " still parse.
        guard let separator = line.range(of: ": ", options: .backwards) else { return nil }
        let path = String(line[line.startIndex..<separator.lowerBound])
        let verdict = String(line[separator.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !verdict.isEmpty else { return nil }

        // "Access denied." parses as a verdict like any other. Treating it as
        // one would let a folder macOS locked us out of count as a folder that
        // came back clean.
        guard !Self.isAccessFailure(verdict) else { return nil }

        let url = URL(fileURLWithPath: path)
        guard verdict.hasSuffix("FOUND") else { return (url, nil) }
        let signature = String(verdict.dropLast("FOUND".count))
            .trimmingCharacters(in: .whitespaces)
        guard !signature.isEmpty else { return (url, nil) }
        return (url, MalwareFinding(url: url, signature: signature))
    }

    /// `/path/to/file: Signature.Name FOUND`
    static func parseFinding(line: String) -> MalwareFinding? {
        parseScanResult(line: line)?.finding
    }

    /// A path the operating system wouldn't let clamscan open.
    ///
    /// This is the line that makes a Full Disk Access problem visible. clamscan
    /// prints it and carries on; its exit code and its "Infected files: 0"
    /// summary look exactly the same whether it read the folder or was turned
    /// away at the door. Without parsing this, Fettle would report a scan of
    /// somewhere it never got into as a scan that found nothing.
    static func parseInaccessible(line: String) -> (url: URL, reason: String)? {
        // clamscan says it two ways depending on whether the refusal came on a
        // directory or on a file inside one.
        let prefixes = [
            "ERROR: Can't open directory ",
            "ERROR: Can't access file ",
            "ERROR: Can't open file ",
            "WARNING: Can't open directory ",
            "WARNING: Can't access file ",
            "WARNING: Can't open file ",
        ]
        for prefix in prefixes where line.hasPrefix(prefix) {
            var remainder = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
            var reason = "unreadable"
            // `/some/path: Permission denied` — split the reason back off the
            // path, but only when the tail isn't itself a path, so a folder
            // genuinely called `a: b` still parses whole.
            if let separator = remainder.range(of: ": ", options: .backwards) {
                let tail = String(remainder[separator.upperBound...])
                if !tail.hasPrefix("/") {
                    reason = tail
                    remainder = String(remainder[..<separator.lowerBound])
                }
            }
            guard remainder.hasPrefix("/") else { return nil }
            return (URL(fileURLWithPath: remainder), reason)
        }

        guard line.hasPrefix("/"),
              let separator = line.range(of: ": ", options: .backwards)
        else { return nil }
        let verdict = String(line[separator.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard isAccessFailure(verdict) else { return nil }
        let path = String(line[line.startIndex..<separator.lowerBound])
        guard !path.isEmpty else { return nil }
        return (URL(fileURLWithPath: path), verdict)
    }

    /// Verdicts that mean "couldn't look" rather than "looked and it's fine".
    ///
    /// Anything ending in ERROR is included because clamscan uses that suffix
    /// for the whole family of I/O failures, and every one of them leaves the
    /// file unread.
    static func isAccessFailure(_ verdict: String) -> Bool {
        let lowered = verdict.lowercased()
        return lowered.hasPrefix("access denied")
            || lowered.hasPrefix("permission denied")
            || lowered.hasPrefix("can't open file")
            || lowered.hasPrefix("can't access file")
            || lowered.hasPrefix("can't open directory")
            || verdict.hasSuffix("ERROR")
    }

    /// `Loading:     3s, ETA:   9s [=====>    ]  880.00K/3.64M sigs`
    ///
    /// clamscan reads its whole signature set into memory before it looks at a
    /// single file, and on a small folder that is most of the wait. Parsing
    /// this is what lets the screen say so instead of sitting at 0%.
    static func parseSignatureLoading(line: String) -> (loaded: Double, total: Double)? {
        guard line.hasPrefix("Loading:"), line.hasSuffix("sigs") else { return nil }
        guard let fraction = line.split(separator: " ").last(where: { $0.contains("/") })
        else { return nil }
        let parts = fraction.split(separator: "/")
        guard parts.count == 2,
              let loaded = signatureCount(parts[0]),
              let total = signatureCount(parts[1]),
              total > 0
        else { return nil }
        return (loaded, total)
    }

    /// `880.00K`, `3.64M`, `23` — clamscan abbreviates once the numbers get big.
    private static func signatureCount(_ text: Substring) -> Double? {
        let multipliers: [Character: Double] = ["K": 1_000, "M": 1_000_000, "G": 1_000_000_000]
        if let last = text.last, let multiplier = multipliers[last] {
            return Double(text.dropLast()).map { $0 * multiplier }
        }
        return Double(text)
    }

    /// `Scanned files: 1234`
    static func parseScannedCount(line: String) -> Int? {
        guard line.hasPrefix("Scanned files:") else { return nil }
        return Int(line.dropFirst("Scanned files:".count).trimmingCharacters(in: .whitespaces))
    }
}

private struct ScanAccumulator {
    var findings: [MalwareFinding] = []
    /// From the trailing summary block.
    var summaryFiles = 0
    /// Counted from the per-file result lines as they arrive.
    var streamedFiles = 0
    /// A sample of the paths the operating system refused to let clamscan
    /// open, and how many there were in total.
    ///
    /// A whole-disk scan run without Full Disk Access is refused on the order
    /// of a hundred thousand times. Keeping every one would mean the scan's
    /// own bookkeeping outgrowing anything it found.
    var inaccessible: [URL] = []
    var inaccessibleCount = 0

    /// Enough paths to name what was blocked, not enough to matter.
    static let inaccessibleSampleLimit = 500

    mutating func noteInaccessible(_ url: URL) {
        inaccessibleCount += 1
        if inaccessible.count < Self.inaccessibleSampleLimit { inaccessible.append(url) }
    }
}

public enum ClamAVProgress: Sendable {
    case found(MalwareFinding)
    /// macOS refused this path. Reported separately from `scanned` because it
    /// is the opposite of a result: nothing was read, so nothing was cleared.
    case inaccessible(URL)
    /// A file finished clean. One of these per file is what drives the
    /// percentage once the scan proper is under way.
    case scanned(URL)
    /// clamscan is still reading its signature database into memory. Nothing
    /// in the user's folder has been touched yet.
    case loadingSignatures(loaded: Double, total: Double)
    case message(String)
}
