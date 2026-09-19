import Foundation

/// A quick read of what's in the folder, for the Overview page.
///
/// Metadata only — no hashing, no /Applications lookup — so it stays fast
/// enough to run every time the page appears.
public struct FolderSummary: Sendable {
    public struct CategoryBreakdown: Identifiable, Sendable {
        public var id: FileCategory { category }
        public let category: FileCategory
        public let count: Int
        public let bytes: Int64
    }

    public let fileCount: Int
    public let totalBytes: Int64
    public let looseFileCount: Int
    public let folderCount: Int
    public let breakdown: [CategoryBreakdown]
    public let largestFiles: [FileEntry]
    public let oldestFiles: [FileEntry]
    /// Installers past the user's age threshold — the headline number for the
    /// Installers page, computed without the fuzzy app matching.
    public let agedInstallerCount: Int
    public let agedInstallerBytes: Int64

    public var isEmpty: Bool { fileCount == 0 && folderCount == 0 }

    public init(
        fileCount: Int, totalBytes: Int64, looseFileCount: Int, folderCount: Int,
        breakdown: [CategoryBreakdown], largestFiles: [FileEntry], oldestFiles: [FileEntry],
        agedInstallerCount: Int, agedInstallerBytes: Int64
    ) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.looseFileCount = looseFileCount
        self.folderCount = folderCount
        self.breakdown = breakdown
        self.largestFiles = largestFiles
        self.oldestFiles = oldestFiles
        self.agedInstallerCount = agedInstallerCount
        self.agedInstallerBytes = agedInstallerBytes
    }
}

public struct FolderSummarizer: Sendable {
    public static let highlightCount = 5

    private let scanner = FolderScanner()

    public init() {}

    public func summarize(
        folder: URL,
        settings: FettleSettings,
        now: Date = Date(),
        isCancelled: () -> Bool = { false }
    ) throws -> FolderSummary {
        let all = try scanner.scan(
            folder: folder,
            options: FolderScanOptions(
                recursive: true,
                skipHiddenFiles: settings.skipHiddenFiles,
                treatPackagesAsFiles: true
            ),
            isCancelled: isCancelled
        )
        let topLevel = try scanner.scanTopLevelIncludingDirectories(
            folder: folder, skipHidden: settings.skipHiddenFiles
        )
        if isCancelled() { throw CancellationError() }

        var counts: [FileCategory: (count: Int, bytes: Int64)] = [:]
        var totalBytes: Int64 = 0
        var agedInstallerCount = 0
        var agedInstallerBytes: Int64 = 0

        for entry in all {
            let category = entry.category
            var bucket = counts[category] ?? (0, 0)
            bucket.count += 1
            bucket.bytes += entry.size
            counts[category] = bucket
            totalBytes += entry.size

            if InstallerScanner.installerExtensions.contains(entry.fileExtension),
               entry.ageInDays(now: now) >= settings.installerAgeThresholdDays {
                agedInstallerCount += 1
                agedInstallerBytes += entry.size
            }
        }

        let breakdown = FileCategory.allCases.compactMap { category -> FolderSummary.CategoryBreakdown? in
            guard let bucket = counts[category], bucket.count > 0 else { return nil }
            return FolderSummary.CategoryBreakdown(
                category: category, count: bucket.count, bytes: bucket.bytes
            )
        }

        let largest = all.sorted { $0.size > $1.size }.prefix(Self.highlightCount)
        let oldest = all.sorted { $0.referenceDate < $1.referenceDate }.prefix(Self.highlightCount)

        return FolderSummary(
            fileCount: all.count,
            totalBytes: totalBytes,
            looseFileCount: topLevel.filter { !$0.isDirectory }.count,
            folderCount: topLevel.filter(\.isDirectory).count,
            breakdown: breakdown,
            largestFiles: Array(largest),
            oldestFiles: Array(oldest),
            agedInstallerCount: agedInstallerCount,
            agedInstallerBytes: agedInstallerBytes
        )
    }
}
