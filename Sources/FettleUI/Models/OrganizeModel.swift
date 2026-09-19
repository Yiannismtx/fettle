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

    var selectedItems: [OrganizePlanItem] {
        items.filter { selection.contains($0.source) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    var groupedSelection: [(category: FileCategory, count: Int)] {
        FileCategory.allCases.compactMap { category in
            let count = selectedItems.filter { $0.category == category }.count
            return count == 0 ? nil : (category, count)
        }
    }

    func plan(folder: URL, settings: FettleSettings) {
        planTask?.cancel()
        state = .planning
        planTask = Task {
            let outcome: Result<OrganizePlan, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try Organizer().plan(folder: folder, settings: settings)) }
                catch { return .failure(error) }
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
                state = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
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
}

struct OrganizeSummary: Equatable, Sendable {
    let total: Int
    let skippedDirectories: Int
    let alreadyOrganized: Int
}
