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

    public var hadError: Bool { exitCode != 0 && exitCode != 1 }

    public init(
        findings: [MalwareFinding], filesScanned: Int, duration: TimeInterval,
        exitCode: Int32, errorOutput: String
    ) {
        self.findings = findings
        self.filesScanned = filesScanned
        self.duration = duration
        self.exitCode = exitCode
        self.errorOutput = errorOutput
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

    private static let databaseDirectories = [
        "/opt/homebrew/var/lib/clamav",
        "/usr/local/var/lib/clamav",
        "/opt/local/var/lib/clamav",
        "/var/lib/clamav",
    ]

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

    /// Run a scan, streaming per-file progress as `clamscan` prints it.
    ///
    /// `--stdout` keeps findings out of stderr, and `--no-summary` is deliberately
    /// *not* passed: the summary line is where the scanned-file count comes from.
    public func scan(
        folder: URL,
        recursive: Bool = true,
        onProgress: (@Sendable (ClamAVProgress) -> Void)? = nil
    ) async throws -> ClamAVScanReport {
        guard let path = locateExecutable() else { throw ClamAVError.notInstalled }

        // Findings go to stdout; the trailing summary block is what carries the
        // scanned-file count, so `--no-summary` is deliberately not passed.
        // Fettle decides what happens to a hit, so clamscan is never given
        // --remove or --move: it reports, it doesn't act.
        var arguments = ["--stdout", "--infected", "--suppress-ok-results"]
        arguments.append(recursive ? "--recursive=yes" : "--recursive=no")
        arguments.append(folder.path)

        let collected = Locked(ScanAccumulator())
        let started = Date()

        let result = try await Process.runStreaming(
            executable: path,
            arguments: arguments,
            onStandardOutputLine: { line in
                if let finding = Self.parseFinding(line: line) {
                    collected.withLock { $0.findings.append(finding) }
                    onProgress?(.found(finding))
                } else if let scanned = Self.parseScannedCount(line: line) {
                    collected.withLock { $0.filesScanned = scanned }
                } else if !line.isEmpty {
                    onProgress?(.message(line))
                }
            }
        )

        let accumulated = collected.withLock { $0 }
        return ClamAVScanReport(
            findings: accumulated.findings,
            filesScanned: accumulated.filesScanned,
            duration: Date().timeIntervalSince(started),
            exitCode: result.exitCode,
            errorOutput: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// `/path/to/file: Signature.Name FOUND`
    static func parseFinding(line: String) -> MalwareFinding? {
        guard line.hasSuffix(" FOUND") else { return nil }
        let body = String(line.dropLast(" FOUND".count))
        // Split on the LAST ": " so paths containing ": " still parse.
        guard let separator = body.range(of: ": ", options: .backwards) else { return nil }
        let path = String(body[body.startIndex..<separator.lowerBound])
        let signature = String(body[separator.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !signature.isEmpty else { return nil }
        return MalwareFinding(url: URL(fileURLWithPath: path), signature: signature)
    }

    /// `Scanned files: 1234`
    static func parseScannedCount(line: String) -> Int? {
        guard line.hasPrefix("Scanned files:") else { return nil }
        return Int(line.dropFirst("Scanned files:".count).trimmingCharacters(in: .whitespaces))
    }
}

private struct ScanAccumulator {
    var findings: [MalwareFinding] = []
    var filesScanned = 0
}

public enum ClamAVProgress: Sendable {
    case found(MalwareFinding)
    case message(String)
}
