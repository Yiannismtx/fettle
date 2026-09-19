import Foundation
import Observation
import FettleCore

/// One quarantined file, plus what the manifest recorded about it.
struct QuarantinedItem: Identifiable, Sendable {
    var id: URL { entry.url }
    let entry: FileEntry
    let signature: String?
    let originalPath: String?

    var originalDirectory: URL? {
        guard let originalPath else { return nil }
        return URL(fileURLWithPath: originalPath).deletingLastPathComponent()
    }
}

@MainActor
@Observable
final class QuarantineModel {
    private(set) var items: [QuarantinedItem] = []
    private(set) var isLoading = false
    private(set) var isApplying = false

    func load() async {
        isLoading = true
        defer { isLoading = false }
        items = await Task.detached(priority: .userInitiated) {
            let quarantine = Quarantine()
            return quarantine.contents().map { entry in
                QuarantinedItem(
                    entry: entry,
                    signature: quarantine.recordedSignature(for: entry.url),
                    originalPath: quarantine.recordedOriginalPath(for: entry.url)
                )
            }
        }.value
    }

    /// Put a file back where it came from. ClamAV can be wrong, and a user who
    /// decides it was wrong needs a way to act on that.
    func restore(_ item: QuarantinedItem, to directory: URL) async -> FileActionResult {
        isApplying = true
        defer { isApplying = false }

        let url = item.entry.url
        let result = await Task.detached(priority: .userInitiated) {
            Quarantine().restore(url, to: directory)
        }.value
        if result.succeeded {
            items.removeAll { $0.id == url }
        }
        return result
    }

    func trash(_ item: QuarantinedItem) async -> FileActionResult {
        isApplying = true
        defer { isApplying = false }

        let url = item.entry.url
        let result = await Task.detached(priority: .userInitiated) {
            let actions = FileActions()
            let outcome = actions.trash(url)
            if outcome.succeeded {
                // Take the note with it; a note for a file that isn't there is
                // just litter.
                _ = actions.trash(url.appendingPathExtension("fettle-quarantine"))
            }
            return outcome
        }.value
        if result.succeeded {
            items.removeAll { $0.id == url }
        }
        return result
    }
}
