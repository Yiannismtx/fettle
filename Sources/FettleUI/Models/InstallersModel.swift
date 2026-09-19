import Foundation
import Observation
import FettleCore

@MainActor
@Observable
final class InstallersModel {
    enum State: Equatable {
        case idle
        case scanning
        case loaded(InstallerScanSummary)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var candidates: [InstallerCandidate] = []
    var selection: Set<URL> = []
    private(set) var isApplying = false

    private var scanTask: Task<Void, Never>?
    private var scanCancellation: CancellationFlag?
    /// The context the current results were computed under.
    private var scannedKey: [String]?

    var selectedCandidates: [InstallerCandidate] {
        candidates.filter { selection.contains($0.url) }
    }

    var selectedBytes: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.size }
    }

    /// Scan only if the folder or a relevant setting has changed since the last
    /// one — so navigating back to this page doesn't redo the work, but
    /// changing the age threshold does.
    func scanIfNeeded(context: ScanContext, settings: FettleSettings) {
        guard scannedKey != context.installerKey else { return }
        scan(folder: context.folder, settings: settings)
    }

    func scan(folder: URL, settings: FettleSettings) {
        cancelScan()
        scannedKey = ScanContext(folder: folder, settings: settings).installerKey
        state = .scanning
        let cancellation = CancellationFlag()
        scanCancellation = cancellation
        scanTask = Task {
            let outcome: Result<InstallerScanResult, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(
                        try InstallerScanner().scan(
                            folder: folder, settings: settings,
                            isCancelled: { cancellation.isCancelled }
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let result):
                candidates = result.candidates
                // Pre-tick only what Fettle is confident about; the user opts in
                // to anything weaker.
                selection = Set(result.candidates.filter(\.isRecommended).map(\.url))
                state = .loaded(
                    InstallerScanSummary(
                        total: result.candidates.count,
                        recommended: result.candidates.filter(\.isRecommended).count,
                        skippedForAge: result.skippedForAge,
                        installedAppCount: result.installedAppCount
                    )
                )
            case .failure(let error):
                candidates = []
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
        // Cancelling invalidates the recorded context, so returning to the page
        // scans again rather than showing a half-finished list.
        scannedKey = nil
        if case .scanning = state { state = .idle }
    }

    func selectAll() { selection = Set(candidates.map(\.url)) }
    func selectNone() { selection.removeAll() }
    func selectRecommended() {
        selection = Set(candidates.filter(\.isRecommended).map(\.url))
    }

    func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    /// Move the approved installers to the Trash, then drop them from the list
    /// so the view reflects the new state without a rescan.
    func trashSelected() async -> (results: [FileActionResult], freed: Int64) {
        isApplying = true
        defer { isApplying = false }

        let targets = selectedCandidates
        let urls = targets.map(\.url)
        let sizeByURL = Dictionary(uniqueKeysWithValues: targets.map { ($0.url, $0.size) })

        let results = await Task.detached(priority: .userInitiated) {
            FileActions().trash(urls)
        }.value

        let removed = Set(results.filter(\.succeeded).map(\.source))
        let freed = removed.reduce(Int64(0)) { $0 + (sizeByURL[$1] ?? 0) }
        candidates.removeAll { removed.contains($0.url) }
        selection.subtract(removed)
        return (results, freed)
    }
}

struct InstallerScanSummary: Equatable, Sendable {
    let total: Int
    let recommended: Int
    let skippedForAge: Int
    let installedAppCount: Int
}
