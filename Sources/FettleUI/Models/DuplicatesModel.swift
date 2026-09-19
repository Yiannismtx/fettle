import Foundation
import Observation
import FettleCore

@MainActor
@Observable
final class DuplicatesModel {
    enum State: Equatable {
        case idle
        case scanning(DuplicateProgressSnapshot)
        case loaded(DuplicateSummary)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var groups: [DuplicateGroup] = []
    /// Only duplicates are selectable; the kept original is never in here.
    var selection: Set<URL> = []
    var expandedGroups: Set<String> = []
    private(set) var isApplying = false

    private var scanTask: Task<Void, Never>?
    private var scanCancellation: CancellationFlag?
    private var scannedKey: [String]?

    var selectedBytes: Int64 {
        var total: Int64 = 0
        for group in groups {
            let count = group.duplicates.filter { selection.contains($0.url) }.count
            total += Int64(count) * group.fileSize
        }
        return total
    }

    var selectableCount: Int {
        groups.reduce(0) { $0 + $1.duplicates.count }
    }

    func scanIfNeeded(context: ScanContext, settings: FettleSettings) {
        guard scannedKey != context.duplicateKey else { return }
        scan(folder: context.folder, settings: settings)
    }

    func scan(folder: URL, settings: FettleSettings) {
        cancelScan()
        scannedKey = ScanContext(folder: folder, settings: settings).duplicateKey
        state = .scanning(DuplicateProgressSnapshot(fraction: 0, label: "Listing files…"))

        let progress = Locked(DuplicateProgressSnapshot(fraction: 0, label: "Listing files…"))
        let cancellation = CancellationFlag()
        scanCancellation = cancellation

        scanTask = Task {
            // Poll the shared snapshot rather than hopping to the main actor for
            // every chunk: hashing reports thousands of times a second, and a
            // hop per chunk would swamp the main thread it's trying to keep free.
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    if case .scanning = self.state {
                        self.state = .scanning(progress.withLock { $0 })
                    }
                }
            }
            defer { ticker.cancel() }

            let outcome: Result<DuplicateScanResult, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let result = try DuplicateScanner().scan(
                        folder: folder,
                        settings: settings,
                        onProgress: { update in
                            progress.withLock { $0 = DuplicateProgressSnapshot(update) }
                        },
                        isCancelled: { cancellation.isCancelled }
                    )
                    return .success(result)
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let result):
                groups = result.groups
                // Every duplicate is pre-ticked: the original is kept either
                // way, so the default is the whole point of the feature.
                selection = Set(result.groups.flatMap { $0.duplicates.map(\.url) })
                expandedGroups = Set(result.groups.prefix(3).map(\.contentHash))
                state = .loaded(
                    DuplicateSummary(
                        groupCount: result.groups.count,
                        duplicateCount: result.duplicateCount,
                        reclaimableBytes: result.reclaimableBytes,
                        filesConsidered: result.filesConsidered,
                        filesHashed: result.filesHashed
                    )
                )
            case .failure(let error):
                groups = []
                selection = []
                if error is CancellationError {
                    scannedKey = nil
                    state = .idle
                } else {
                    state = .failed(
                        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                }
            }
        }
    }

    func cancelScan() {
        scanCancellation?.cancel()
        scanCancellation = nil
        scanTask?.cancel()
        scanTask = nil
        scannedKey = nil
        if case .scanning = state { state = .idle }
    }

    func selectAll() {
        selection = Set(groups.flatMap { $0.duplicates.map(\.url) })
    }

    func selectNone() { selection.removeAll() }

    func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    func toggleExpansion(_ hash: String) {
        if expandedGroups.contains(hash) {
            expandedGroups.remove(hash)
        } else {
            expandedGroups.insert(hash)
        }
    }

    /// Promote a copy to "the one we keep", demoting the current original into
    /// the duplicate list. The user, not the heuristic, gets the final say.
    func keepInstead(_ entry: FileEntry, in group: DuplicateGroup) {
        guard let index = groups.firstIndex(where: { $0.contentHash == group.contentHash })
        else { return }
        var others = group.duplicates.filter { $0.url != entry.url }
        others.append(group.original)
        others.sort { $0.referenceDate < $1.referenceDate }
        groups[index] = DuplicateGroup(
            contentHash: group.contentHash, original: entry, duplicates: others
        )
        selection.remove(entry.url)
        selection.insert(group.original.url)
    }

    func trashSelected() async -> (results: [FileActionResult], freed: Int64) {
        isApplying = true
        defer { isApplying = false }

        var sizeByURL: [URL: Int64] = [:]
        for group in groups {
            for duplicate in group.duplicates where selection.contains(duplicate.url) {
                sizeByURL[duplicate.url] = group.fileSize
            }
        }
        let urls = Array(sizeByURL.keys)
        guard !urls.isEmpty else { return ([], 0) }

        let results = await Task.detached(priority: .userInitiated) {
            FileActions().trash(urls)
        }.value

        let removed = Set(results.filter(\.succeeded).map(\.source))
        let freed = removed.reduce(Int64(0)) { $0 + (sizeByURL[$1] ?? 0) }

        // Rebuild the groups without the trashed copies, dropping any group that
        // no longer has anything to compare.
        groups = groups.compactMap { group in
            let remaining = group.duplicates.filter { !removed.contains($0.url) }
            guard !remaining.isEmpty else { return nil }
            return DuplicateGroup(
                contentHash: group.contentHash, original: group.original, duplicates: remaining
            )
        }
        selection.subtract(removed)
        return (results, freed)
    }
}

struct DuplicateProgressSnapshot: Equatable, Sendable {
    var fraction: Double
    var label: String

    init(fraction: Double, label: String) {
        self.fraction = fraction
        self.label = label
    }

    init(_ progress: DuplicateScanProgress) {
        switch progress.phase {
        case .listing:
            self.fraction = 0
            self.label = progress.filesListed > 0
                ? "Listing files… \(progress.filesListed)"
                : "Listing files…"
        case .grouping:
            self.fraction = 0
            self.label = "Comparing sizes…"
        case .hashing:
            self.fraction = progress.fraction
            self.label = progress.currentFile.map { "Hashing \($0)" } ?? "Hashing…"
        }
    }
}

struct DuplicateSummary: Equatable, Sendable {
    let groupCount: Int
    let duplicateCount: Int
    let reclaimableBytes: Int64
    let filesConsidered: Int
    let filesHashed: Int
}
