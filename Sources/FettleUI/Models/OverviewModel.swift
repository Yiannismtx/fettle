import Foundation
import Observation
import FettleCore

@MainActor
@Observable
final class OverviewModel {
    enum State: Equatable {
        case loading
        case loaded(FolderSummaryBox)
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): return true
            case (.loaded(let a), .loaded(let b)): return a === b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    private(set) var state: State = .loading
    private(set) var quarantinedCount = 0

    private var task: Task<Void, Never>?
    private var cancellation: CancellationFlag?
    private var loadedKey: [String]?

    func loadIfNeeded(context: ScanContext, settings: FettleSettings) {
        guard loadedKey != context.overviewKey else { return }
        load(folder: context.folder, settings: settings)
    }

    func load(folder: URL, settings: FettleSettings) {
        cancelLoad()
        loadedKey = ScanContext(folder: folder, settings: settings).overviewKey
        state = .loading
        let flag = CancellationFlag()
        cancellation = flag
        task = Task {
            let outcome: Result<FolderSummary, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(
                        try FolderSummarizer().summarize(
                            folder: folder, settings: settings,
                            isCancelled: { flag.isCancelled }
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }.value

            let quarantined = await Task.detached(priority: .utility) {
                Quarantine().contents().count
            }.value

            guard !Task.isCancelled else { return }
            quarantinedCount = quarantined
            switch outcome {
            case .success(let summary):
                state = .loaded(FolderSummaryBox(summary))
            case .failure(let error):
                if error is CancellationError {
                    loadedKey = nil
                    state = .loading
                } else {
                    state = .failed(
                        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                }
            }
        }
    }

    func cancelLoad() {
        cancellation?.cancel()
        cancellation = nil
        task?.cancel()
        task = nil
        loadedKey = nil
    }
}

/// `FolderSummary` isn't `Equatable` and doesn't need to be; boxing it gives
/// the state enum cheap identity comparison without inventing an equality that
/// would have to be kept in sync with the struct.
final class FolderSummaryBox {
    let summary: FolderSummary
    init(_ summary: FolderSummary) { self.summary = summary }
}
