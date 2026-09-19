import Foundation

/// One planned move. Non-destructive, but shown for review anyway (spec §3.3):
/// a batch that touches a hundred files at once deserves a look first.
public struct OrganizePlanItem: Identifiable, Hashable, Sendable {
    public var id: URL { source }
    public let source: URL
    public let category: FileCategory
    public let destinationDirectory: URL
    public let size: Int64
    /// True when a file of this name is already in the destination folder, so
    /// the move will land under a numbered name instead.
    public let willBeRenamed: Bool

    public var name: String { source.lastPathComponent }

    public init(
        source: URL, category: FileCategory, destinationDirectory: URL,
        size: Int64, willBeRenamed: Bool
    ) {
        self.source = source
        self.category = category
        self.destinationDirectory = destinationDirectory
        self.size = size
        self.willBeRenamed = willBeRenamed
    }
}

public struct OrganizePlan: Sendable {
    public let items: [OrganizePlanItem]
    /// Loose items left alone, and why — so the page can say what it *isn't*
    /// doing rather than silently ignoring things.
    public let skippedDirectories: Int
    public let alreadyOrganized: Int

    public var isEmpty: Bool { items.isEmpty }

    public var byCategory: [(category: FileCategory, items: [OrganizePlanItem])] {
        FileCategory.allCases.compactMap { category in
            let matching = items.filter { $0.category == category }
            return matching.isEmpty ? nil : (category, matching)
        }
    }

    public init(items: [OrganizePlanItem], skippedDirectories: Int, alreadyOrganized: Int) {
        self.items = items
        self.skippedDirectories = skippedDirectories
        self.alreadyOrganized = alreadyOrganized
    }
}

/// Plans the type-based sort of a folder's loose files (spec §3.3).
///
/// Top level only, and never into its own destination folders, so running it
/// twice is a no-op rather than a cascade of nested folders.
public struct Organizer: Sendable {
    private let scanner = FolderScanner()

    public init() {}

    public func plan(folder: URL, settings: FettleSettings) throws -> OrganizePlan {
        let entries = try scanner.scanTopLevelIncludingDirectories(
            folder: folder, skipHidden: settings.skipHiddenFiles
        )

        let fileManager = FileManager()
        var items: [OrganizePlanItem] = []
        var skippedDirectories = 0
        var alreadyOrganized = 0
        // Track what each destination will contain so two files with the same
        // name in one batch are both reported as "will be renamed".
        var plannedNames: [URL: Set<String>] = [:]

        for entry in entries {
            if entry.isDirectory {
                if FileCategory.allFolderNames.contains(entry.name) {
                    alreadyOrganized += 1
                } else {
                    skippedDirectories += 1
                }
                continue
            }

            let category = entry.category
            let destination = folder.appendingPathComponent(category.folderName)
            let existing = fileManager.fileExists(
                atPath: destination.appendingPathComponent(entry.name).path
            )
            let clashesWithinBatch = plannedNames[destination]?.contains(entry.name) ?? false
            plannedNames[destination, default: []].insert(entry.name)

            items.append(
                OrganizePlanItem(
                    source: entry.url,
                    category: category,
                    destinationDirectory: destination,
                    size: entry.size,
                    willBeRenamed: existing || clashesWithinBatch
                )
            )
        }

        items.sort { lhs, rhs in
            if lhs.category != rhs.category {
                return categoryOrder(lhs.category) < categoryOrder(rhs.category)
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return OrganizePlan(
            items: items,
            skippedDirectories: skippedDirectories,
            alreadyOrganized: alreadyOrganized
        )
    }

    private func categoryOrder(_ category: FileCategory) -> Int {
        FileCategory.allCases.firstIndex(of: category) ?? 0
    }

    /// Execute a plan. Each move is independent: one failure doesn't stop
    /// the rest, and the caller reports exactly what happened.
    public func apply(_ items: [OrganizePlanItem]) -> [FileActionResult] {
        let actions = FileActions()
        return items.map { actions.move($0.source, into: $0.destinationDirectory) }
    }
}
