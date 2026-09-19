import Foundation

/// One installer Fettle is proposing to trash, with everything the user needs
/// to judge the proposal.
public struct InstallerCandidate: Identifiable, Hashable, Sendable {
    public var id: URL { entry.url }
    public let entry: FileEntry
    public let match: AppMatch?
    public let ageInDays: Int

    public var url: URL { entry.url }
    public var size: Int64 { entry.size }
    public var matchConfidence: MatchConfidence { match?.confidence ?? .none }

    /// Pre-ticked in the review list. Fettle only volunteers what it is
    /// confident about; weaker matches are shown but left for the user to tick.
    public var isRecommended: Bool { matchConfidence >= .strong }

    public init(entry: FileEntry, match: AppMatch?, ageInDays: Int) {
        self.entry = entry
        self.match = match
        self.ageInDays = ageInDays
    }

    public var reason: String {
        let age = Formatting.age(days: ageInDays)
        switch matchConfidence {
        case .exact, .strong:
            let name = match?.app.displayName ?? "the app"
            return "\(name) is installed · downloaded \(age) ago"
        case .weak:
            let name = match?.app.displayName ?? "an installed app"
            return "Might be \(name) · downloaded \(age) ago"
        case .none:
            return "No matching app installed · downloaded \(age) ago"
        }
    }
}

public struct InstallerScanResult: Sendable {
    public let candidates: [InstallerCandidate]
    /// Installers found but excluded because they're newer than the threshold.
    public let skippedForAge: Int
    public let installedAppCount: Int

    public var reclaimableBytes: Int64 {
        candidates.filter(\.isRecommended).reduce(0) { $0 + $1.size }
    }

    public init(candidates: [InstallerCandidate], skippedForAge: Int, installedAppCount: Int) {
        self.candidates = candidates
        self.skippedForAge = skippedForAge
        self.installedAppCount = installedAppCount
    }
}

/// Finds `.dmg`/`.pkg` files past the user's age threshold and works out which
/// ones are dead weight because the app is already installed (spec §3.1).
public struct InstallerScanner: Sendable {
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso"]

    private let scanner = FolderScanner()

    public init() {}

    public func scan(
        folder: URL,
        settings: FettleSettings,
        now: Date = Date(),
        matcher: AppMatcher? = nil
    ) throws -> InstallerScanResult {
        let entries = try scanner.scan(
            folder: folder,
            options: FolderScanOptions(
                recursive: true,
                skipHiddenFiles: settings.skipHiddenFiles,
                treatPackagesAsFiles: true
            )
        )

        let matcher = matcher ?? AppMatcher()
        let thresholdDays = settings.installerAgeThresholdDays
        var candidates: [InstallerCandidate] = []
        var skipped = 0

        for entry in entries where Self.installerExtensions.contains(entry.fileExtension) {
            let age = entry.ageInDays(now: now)
            guard age >= thresholdDays else {
                skipped += 1
                continue
            }
            let match = matcher.match(fileName: entry.name)
            if settings.requireMatchingInstalledApp, (match?.confidence ?? .none) < .strong {
                continue
            }
            candidates.append(InstallerCandidate(entry: entry, match: match, ageInDays: age))
        }

        // Most confident first, then biggest — the order in which a reviewer
        // wants to make decisions.
        candidates.sort { lhs, rhs in
            if lhs.matchConfidence != rhs.matchConfidence {
                return lhs.matchConfidence > rhs.matchConfidence
            }
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.entry.name.localizedStandardCompare(rhs.entry.name) == .orderedAscending
        }

        return InstallerScanResult(
            candidates: candidates,
            skippedForAge: skipped,
            installedAppCount: matcher.installedApps.count
        )
    }
}
