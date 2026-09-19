import Foundation

/// A set of files with byte-identical contents.
public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public var id: String { contentHash }
    public let contentHash: String
    /// The copy Fettle proposes keeping: the oldest one, on the assumption that
    /// it is the original and whatever references it still points at it.
    public let original: FileEntry
    /// The other copies, oldest first.
    public let duplicates: [FileEntry]

    public var fileSize: Int64 { original.size }
    /// What trashing every duplicate in this group would free.
    public var reclaimableBytes: Int64 { Int64(duplicates.count) * fileSize }
    public var totalCount: Int { duplicates.count + 1 }

    public init(contentHash: String, original: FileEntry, duplicates: [FileEntry]) {
        self.contentHash = contentHash
        self.original = original
        self.duplicates = duplicates
    }
}

public struct DuplicateScanResult: Sendable {
    public let groups: [DuplicateGroup]
    public let filesConsidered: Int
    public let filesHashed: Int
    public let bytesHashed: Int64

    public var reclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    public var duplicateCount: Int {
        groups.reduce(0) { $0 + $1.duplicates.count }
    }

    public init(
        groups: [DuplicateGroup], filesConsidered: Int, filesHashed: Int, bytesHashed: Int64
    ) {
        self.groups = groups
        self.filesConsidered = filesConsidered
        self.filesHashed = filesHashed
        self.bytesHashed = bytesHashed
    }
}

public struct DuplicateScanProgress: Sendable {
    public enum Phase: Sendable {
        case listing
        case grouping
        case hashing
    }
    public let phase: Phase
    public let bytesHashed: Int64
    public let bytesToHash: Int64
    public let currentFile: String?
    /// Files seen so far during the listing phase.
    public let filesListed: Int

    public var fraction: Double {
        guard bytesToHash > 0 else { return 0 }
        return min(1, Double(bytesHashed) / Double(bytesToHash))
    }

    public init(
        phase: Phase, bytesHashed: Int64, bytesToHash: Int64,
        currentFile: String?, filesListed: Int = 0
    ) {
        self.phase = phase
        self.bytesHashed = bytesHashed
        self.bytesToHash = bytesToHash
        self.currentFile = currentFile
        self.filesListed = filesListed
    }
}

/// Finds byte-identical files by content hash, not by filename (spec §3.2), so
/// the same file saved under two unrelated names is still caught.
///
/// Three passes, cheapest first, so a big Downloads folder doesn't get hashed
/// end to end:
///   1. group by size — files of different sizes can't be identical;
///   2. within each size group, hash the first 64 KB;
///   3. only for files that still collide, hash the whole thing.
public struct DuplicateScanner: Sendable {
    /// Enough to separate almost every unrelated pair, cheap enough to be free.
    static let prefixHashBytes = 64 * 1024

    private let scanner = FolderScanner()

    public init() {}

    public func scan(
        folder: URL,
        settings: FettleSettings,
        onProgress: ((DuplicateScanProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> DuplicateScanResult {
        onProgress?(DuplicateScanProgress(
            phase: .listing, bytesHashed: 0, bytesToHash: 0, currentFile: nil
        ))

        let entries = try scanner.scan(
            folder: folder,
            options: FolderScanOptions(
                recursive: true,
                skipHiddenFiles: settings.skipHiddenFiles,
                treatPackagesAsFiles: true
            ),
            onProgress: { count in
                onProgress?(DuplicateScanProgress(
                    phase: .listing, bytesHashed: 0, bytesToHash: 0,
                    currentFile: nil, filesListed: count
                ))
            },
            isCancelled: isCancelled
        )

        // Zero-byte files are all "identical" and never worth reviewing.
        let minimum = Int64(max(1, settings.duplicateMinimumBytes))
        let candidates = entries.filter { $0.size >= minimum }

        onProgress?(DuplicateScanProgress(
            phase: .grouping, bytesHashed: 0, bytesToHash: 0, currentFile: nil
        ))

        // Pass 1 — size.
        var bySize: [Int64: [FileEntry]] = [:]
        for entry in candidates { bySize[entry.size, default: []].append(entry) }
        let sizeCollisions = bySize.values.filter { $0.count > 1 }
        if isCancelled() { throw CancellationError() }

        // Pass 2 — prefix hash.
        var prefixBuckets: [[FileEntry]] = []
        for group in sizeCollisions {
            if isCancelled() { throw CancellationError() }
            // Below the prefix length the prefix hash *is* the full hash, so
            // skip straight to pass 3 rather than hashing twice.
            guard group[0].size > Int64(Self.prefixHashBytes) else {
                prefixBuckets.append(group)
                continue
            }
            var byPrefix: [String: [FileEntry]] = [:]
            for entry in group {
                guard let hash = Hashing.sha256(
                    of: entry.url, limit: Self.prefixHashBytes, isCancelled: isCancelled
                ) else { continue }
                byPrefix[hash, default: []].append(entry)
            }
            prefixBuckets.append(contentsOf: byPrefix.values.filter { $0.count > 1 })
        }

        // Pass 3 — full hash.
        let bytesToHash = prefixBuckets.reduce(Int64(0)) { total, group in
            total + group.reduce(Int64(0)) { $0 + $1.size }
        }
        var bytesHashed: Int64 = 0
        var filesHashed = 0
        var byContent: [String: [FileEntry]] = [:]

        for group in prefixBuckets {
            for entry in group {
                if isCancelled() { throw CancellationError() }
                onProgress?(DuplicateScanProgress(
                    phase: .hashing,
                    bytesHashed: bytesHashed,
                    bytesToHash: bytesToHash,
                    currentFile: entry.name
                ))
                var hashedThisFile: Int64 = 0
                let hash = Hashing.sha256(
                    of: entry.url,
                    onBytesRead: { hashedThisFile += Int64($0) },
                    isCancelled: isCancelled
                )
                bytesHashed += hashedThisFile
                guard let hash else { continue }
                filesHashed += 1
                byContent[hash, default: []].append(entry)
            }
        }

        onProgress?(DuplicateScanProgress(
            phase: .hashing, bytesHashed: bytesToHash, bytesToHash: bytesToHash, currentFile: nil
        ))

        var groups: [DuplicateGroup] = []
        for (hash, members) in byContent where members.count > 1 {
            // Oldest first; the oldest is the one Fettle keeps.
            let sorted = members.sorted { lhs, rhs in
                if lhs.referenceDate != rhs.referenceDate {
                    return lhs.referenceDate < rhs.referenceDate
                }
                return lhs.url.path < rhs.url.path
            }
            groups.append(
                DuplicateGroup(
                    contentHash: hash, original: sorted[0], duplicates: Array(sorted.dropFirst())
                )
            )
        }

        // Biggest win first.
        groups.sort { lhs, rhs in
            if lhs.reclaimableBytes != rhs.reclaimableBytes {
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            return lhs.original.name.localizedStandardCompare(rhs.original.name) == .orderedAscending
        }

        return DuplicateScanResult(
            groups: groups,
            filesConsidered: candidates.count,
            filesHashed: filesHashed,
            bytesHashed: bytesHashed
        )
    }
}
