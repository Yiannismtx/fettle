import Foundation
import Observation
import FettleCore

@MainActor
@Observable
final class OrganizeModel {
    enum State: Equatable {
        case idle
        case planning
        case ready(OrganizeSummary)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var items: [OrganizePlanItem] = []
    var selection: Set<URL> = []
    private(set) var isApplying = false

    private var planTask: Task<Void, Never>?
    private var planCancellation: CancellationFlag?
    private var plannedKey: [String]?

    var selectedItems: [OrganizePlanItem] {
        items.filter { selection.contains($0.source) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    func planIfNeeded(context: ScanContext, settings: FettleSettings) {
        guard plannedKey != context.organizeKey else { return }
        plan(folder: context.folder, settings: settings)
    }

    func plan(folder: URL, settings: FettleSettings) {
        cancelPlan()
        plannedKey = ScanContext(folder: folder, settings: settings).organizeKey
        state = .planning
        let cancellation = CancellationFlag()
        planCancellation = cancellation
        planTask = Task {
            let outcome: Result<OrganizePlan, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(
                        try Organizer().plan(
                            folder: folder, settings: settings,
                            isCancelled: { cancellation.isCancelled }
                        )
                    )
                } catch { return .failure(error) }
            }.value

            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let plan):
                items = plan.items
                // Organizing is non-destructive, so the whole batch starts ticked.
                selection = Set(plan.items.map(\.source))
                state = .ready(
                    OrganizeSummary(
                        total: plan.items.count,
                        skippedDirectories: plan.skippedDirectories,
                        alreadyOrganized: plan.alreadyOrganized
                    )
                )
            case .failure(let error):
                items = []
                selection = []
                if error is CancellationError {
                    plannedKey = nil
                    state = .idle
                } else {
                    plannedKey = nil
                    state = .failed(
                        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                }
            }
        }
    }

    func cancelPlan() {
        planCancellation?.cancel()
        planCancellation = nil
        planTask?.cancel()
        planTask = nil
        plannedKey = nil
        if case .planning = state { state = .idle }
    }

    func selectAll() { selection = Set(items.map(\.source)) }
    func selectNone() { selection.removeAll() }

    func toggle(_ url: URL) {
        if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
    }

    func toggleCategory(_ category: FileCategory) {
        let urls = items.filter { $0.category == category }.map(\.source)
        if urls.allSatisfy({ selection.contains($0) }) {
            selection.subtract(urls)
        } else {
            selection.formUnion(urls)
        }
    }

    func apply() async -> [FileActionResult] {
        isApplying = true
        defer { isApplying = false }

        let targets = selectedItems
        guard !targets.isEmpty else { return [] }

        let results = await Task.detached(priority: .userInitiated) {
            Organizer().apply(targets)
        }.value

        let moved = Set(results.filter(\.succeeded).map(\.source))
        items.removeAll { moved.contains($0.source) }
        selection.subtract(moved)
        return results
    }

    /// Record a context as already reflected in the current results.
    ///
    /// After this screen acts on files it updates its own list in place, so it
    /// shouldn't redo the work just because the folder revision moved — which
    /// for the duplicate scan would mean rehashing every candidate again.
    func acknowledge(_ context: ScanContext) {
        plannedKey = context.organizeKey
    }
}

struct OrganizeSummary: Equatable, Sendable {
    let total: Int
    let skippedDirectories: Int
    let alreadyOrganized: Int

}
