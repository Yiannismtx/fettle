import Foundation

/// Where Homebrew is, if it's anywhere.
public struct Homebrew: Sendable {
    /// The two standard prefixes: Apple silicon, then Intel.
    public static let searchPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public let executablePath: String

    /// `$(brew --prefix)` — derived from the binary's own location rather than
    /// shelled out for, so it costs nothing.
    public var prefix: String {
        (executablePath as NSString).deletingLastPathComponent.replacingOccurrences(
            of: "/bin", with: "", options: [.backwards, .anchored]
        )
    }

    /// Find Homebrew.
    ///
    /// `HOMEBREW_PREFIX` is checked first: that's the variable Homebrew itself
    /// uses for an installation outside the two standard prefixes, so honouring
    /// it is what a user with a custom prefix already expects.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Homebrew? {
        let fm = FileManager.default
        if let prefix = environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
            let path = "\(prefix)/bin/brew"
            if fm.isExecutableFile(atPath: path) { return Homebrew(executablePath: path) }
        }
        for path in searchPaths where fm.isExecutableFile(atPath: path) {
            return Homebrew(executablePath: path)
        }
        return nil
    }

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    /// A GUI app inherits almost nothing of the user's shell environment, and
    /// Homebrew needs its own bin on PATH and a HOME to work with. Passing an
    /// explicit environment is more predictable than hoping the launch context
    /// supplied one.
    public var environment: [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "PATH": "\(prefix)/bin:\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
            "HOMEBREW_PREFIX": prefix,
            // Homebrew's own progress bars and colour codes are noise in a log
            // view that isn't a terminal.
            "HOMEBREW_NO_COLOR": "1",
            "HOMEBREW_NO_EMOJI": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "LANG": "en_US.UTF-8",
        ]
    }
}

/// One step of the install, as the UI presents it.
public enum ClamAVInstallStep: String, CaseIterable, Sendable {
    case install
    case configure
    case signatures

    public var title: String {
        switch self {
        case .install: return "Install ClamAV"
        case .configure: return "Set up freshclam"
        case .signatures: return "Download virus signatures"
        }
    }

    public var detail: String {
        switch self {
        case .install:
            return "Runs brew install clamav. A few hundred megabytes, so it takes a few minutes."
        case .configure:
            return "Homebrew ships freshclam.conf only as a sample, and freshclam refuses to run until a real one exists."
        case .signatures:
            return "Runs freshclam to fetch the signature database. Without it the scanner has nothing to match against."
        }
    }
}

public enum ClamAVInstallError: Error, LocalizedError, Sendable {
    case homebrewMissing
    case stepFailed(step: ClamAVInstallStep, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .homebrewMissing:
            return "Homebrew isn't installed. Fettle can't install it for you — Homebrew's installer needs your admin password, which it must ask you for directly."
        case .stepFailed(let step, let message):
            return "\(step.title) failed. \(message)"
        case .cancelled:
            return "Install cancelled."
        }
    }
}

/// Installs ClamAV through Homebrew, on the user's behalf and at their request.
///
/// The spec accepts the Homebrew dependency (§3.4) rather than bundling a
/// 100 MB+ engine. That leaves the user with a terminal errand, which this
/// turns into a button — but only the part Fettle can legitimately do
/// unattended. Installing Homebrew itself needs an admin password and must be
/// the user's own action, so that case is reported, not automated.
public struct ClamAVInstaller: Sendable {
    public init() {}

    /// Everything the installer knows before it starts, so the UI can show the
    /// right thing without guessing.
    public struct Readiness: Equatable, Sendable {
        public let homebrewPath: String?
        public let clamscanPath: String?

        public init(homebrewPath: String?, clamscanPath: String?) {
            self.homebrewPath = homebrewPath
            self.clamscanPath = clamscanPath
        }

        public var hasHomebrew: Bool { homebrewPath != nil }
        public var hasClamAV: Bool { clamscanPath != nil }
    }

    public func readiness(clamscanOverride: String = "") -> Readiness {
        Readiness(
            homebrewPath: Homebrew.locate()?.executablePath,
            clamscanPath: ClamAVService(overridePath: clamscanOverride).locateExecutable()
        )
    }

    /// Run the whole install, reporting each line of output as it arrives.
    ///
    /// - Parameter onOutput: called with `(step, line)` for every line the
    ///   underlying tools print, so the user can see it working rather than
    ///   watching an opaque spinner for four minutes.
    public func install(
        onStepStarted: @escaping @Sendable (ClamAVInstallStep) -> Void = { _ in },
        onOutput: @escaping @Sendable (ClamAVInstallStep, String) -> Void = { _, _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws {
        guard let brew = Homebrew.locate() else { throw ClamAVInstallError.homebrewMissing }

        // --- 1. brew install clamav ----------------------------------------
        onStepStarted(.install)
        if isCancelled() { throw ClamAVInstallError.cancelled }
        let installResult = try await Process.runStreaming(
            executable: brew.executablePath,
            arguments: ["install", "clamav"],
            environment: brew.environment,
            mergeStandardError: true,
            onStandardOutputLine: { onOutput(.install, $0) }
        )
        if isCancelled() { throw ClamAVInstallError.cancelled }
        // Exit code 0, or already-installed, both count as success. Homebrew
        // reports "already installed" on stderr with a non-zero status in some
        // versions, so the presence of the binary is the real test.
        let service = ClamAVService()
        if installResult.exitCode != 0, service.locateExecutable() == nil {
            throw ClamAVInstallError.stepFailed(
                step: .install,
                message: installResult.standardError.isEmpty
                    ? "brew exited with code \(installResult.exitCode)."
                    : installResult.standardError
            )
        }

        // --- 2. freshclam.conf ---------------------------------------------
        onStepStarted(.configure)
        if isCancelled() { throw ClamAVInstallError.cancelled }
        do {
            if let message = try prepareFreshclamConfig(prefix: brew.prefix) {
                onOutput(.configure, message)
            }
        } catch {
            throw ClamAVInstallError.stepFailed(
                step: .configure, message: error.localizedDescription
            )
        }

        // --- 3. freshclam ---------------------------------------------------
        onStepStarted(.signatures)
        if isCancelled() { throw ClamAVInstallError.cancelled }
        let freshclamPath = "\(brew.prefix)/bin/freshclam"
        guard FileManager.default.isExecutableFile(atPath: freshclamPath) else {
            throw ClamAVInstallError.stepFailed(
                step: .signatures,
                message: "freshclam wasn't found at \(freshclamPath) after installing."
            )
        }
        let freshResult = try await Process.runStreaming(
            executable: freshclamPath,
            arguments: [],
            environment: brew.environment,
            mergeStandardError: true,
            onStandardOutputLine: { onOutput(.signatures, $0) }
        )
        if isCancelled() { throw ClamAVInstallError.cancelled }
        // freshclam exits 1 when the database is already up to date, which is
        // not a failure. A missing database is.
        if freshResult.exitCode != 0, ClamAVService.signatureDatabaseDate() == nil {
            throw ClamAVInstallError.stepFailed(
                step: .signatures,
                message: "freshclam exited with code \(freshResult.exitCode) and no signature database was written."
            )
        }
    }

    /// Homebrew installs `freshclam.conf.sample`, never `freshclam.conf`, and
    /// freshclam refuses to start without the real file — the single most
    /// common reason a fresh `brew install clamav` appears not to work.
    ///
    /// Returns a line describing what it did, or nil if there was nothing to do.
    @discardableResult
    public func prepareFreshclamConfig(prefix: String) throws -> String? {
        let fm = FileManager.default
        let directory = "\(prefix)/etc/clamav"
        let config = "\(directory)/freshclam.conf"
        let sample = "\(config).sample"

        if fm.fileExists(atPath: config) {
            return "\(config) already exists — leaving it alone."
        }
        guard fm.fileExists(atPath: sample) else {
            // Nothing to copy from: write the minimum freshclam needs.
            try fm.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: nil
            )
            try Data(Self.minimalConfig.utf8).write(to: URL(fileURLWithPath: config))
            return "Wrote a minimal \(config)."
        }

        let sampleText = try String(contentsOfFile: sample, encoding: .utf8)
        // The sample's first directive is a literal `Example` line, present
        // solely to make freshclam refuse to run until someone has read the
        // file. Commenting it out is exactly what the docs tell you to do.
        let prepared = sampleText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                line.trimmingCharacters(in: .whitespaces) == "Example" ? "# Example" : String(line)
            }
            .joined(separator: "\n")

        try Data(prepared.utf8).write(to: URL(fileURLWithPath: config))
        return "Created \(config) from the sample, with the Example line commented out."
    }

    static let minimalConfig = """
        # Written by Fettle. freshclam won't start without a config file.
        DatabaseMirror database.clamav.net
        """
}
