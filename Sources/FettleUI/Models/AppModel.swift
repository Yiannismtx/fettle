import Foundation
import Observation
import SwiftUI
import FettleCore

enum Destination: String, CaseIterable, Identifiable, Hashable {
    case overview
    case installers
    case duplicates
    case organize
    case scan
    case quarantine

    var id: String { rawValue }

    /// Named for what's actually there, not a vague umbrella.
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .installers: return "Installers"
        case .duplicates: return "Duplicates"
        case .organize: return "Organize"
        case .scan: return "Malware Scan"
        case .quarantine: return "Quarantine"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .installers: return "shippingbox"
        case .duplicates: return "doc.on.doc"
        case .organize: return "folder.badge.gearshape"
        case .scan: return "checkmark.shield"
        case .quarantine: return "lock.shield"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "What's in the folder right now"
        case .installers: return "Dead-weight .dmg and .pkg files"
        case .duplicates: return "Identical files, matched by content"
        case .organize: return "Sort loose files into type folders"
        case .scan: return "On-demand ClamAV scan"
        case .quarantine: return "Files a scan moved aside, and how to undo that"
        }
    }
}

/// App-wide state: which folder Fettle is pointed at, the user's settings, and
/// the transient banner shown after an action completes.
@MainActor
@Observable
final class AppModel {
    var settings: FettleSettings {
        didSet {
            guard settings != oldValue else { return }
            store.save(settings)
            if settings.scanFolderBookmark != oldValue.scanFolderBookmark
                || settings.scanFolderPath != oldValue.scanFolderPath {
                refreshFolder()
            }
        }
    }

    private(set) var folder: URL
    private(set) var folderIsStale: Bool
    var selection: Destination = .overview {
        didSet {
            guard selection != oldValue else { return }
            settings.lastDestination = selection.rawValue
        }
    }
    var banner: Banner?
    /// Bumped whenever Fettle moves or trashes anything.
    ///
    /// Each screen caches its results, so without this, trashing installers on
    /// one page would leave the Overview and the duplicate list quoting numbers
    /// from before the move — plausible-looking figures for a folder that no
    /// longer exists in that shape.
    private(set) var folderRevision = 0

    func noteFolderChanged() {
        folderRevision &+= 1
    }

    private let store: SettingsStore

    struct Banner: Identifiable, Equatable {
        enum Kind: Equatable { case success, warning, failure }
        let id = UUID()
        var kind: Kind
        var title: String
        var detail: String?

        var systemImage: String {
            switch kind {
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch kind {
            case .success: return Theme.Palette.safe
            case .warning: return Theme.Palette.caution
            case .failure: return Theme.Palette.danger
            }
        }
    }

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        let loaded = store.load()
        self.settings = loaded
        let resolved = FolderAccess.resolve(
            path: loaded.scanFolderPath, bookmark: loaded.scanFolderBookmark
        )
        self.folder = resolved.url
        self.folderIsStale = resolved.isStale
        self.selection = Destination(rawValue: loaded.lastDestination) ?? .overview
    }

    func refreshFolder() {
        let resolved = FolderAccess.resolve(
            path: settings.scanFolderPath, bookmark: settings.scanFolderBookmark
        )
        folder = resolved.url
        folderIsStale = resolved.isStale
    }

    func chooseFolder(_ url: URL) {
        settings.scanFolderPath = url.path
        settings.scanFolderBookmark = FolderAccess.makeBookmark(for: url)
        // Reflect the choice immediately even if the bookmark couldn't be made.
        folder = url
        folderIsStale = false
    }

    func resetFolderToDownloads() {
        settings.scanFolderPath = ""
        settings.scanFolderBookmark = nil
        folder = FolderAccess.defaultFolder
        folderIsStale = false
    }

    func show(_ banner: Banner) {
        self.banner = banner
    }

    /// Summarise a batch of file operations into one banner, naming failures
    /// rather than quietly swallowing them.
    func reportResults(_ results: [FileActionResult], verb: String, freedBytes: Int64? = nil) {
        if results.contains(where: \.succeeded) { noteFolderChanged() }
        let failures = results.filter { !$0.succeeded }
        let successes = results.count - failures.count

        if failures.isEmpty {
            var detail: String?
            if let freedBytes, freedBytes > 0 {
                detail = "\(Formatting.bytes(freedBytes)) freed."
            }
            show(Banner(
                kind: .success,
                title: "\(verb) \(Formatting.count(successes, singular: "item")).",
                detail: detail
            ))
        } else if successes == 0 {
            show(Banner(
                kind: .failure,
                title: "Nothing was moved.",
                detail: failures.first?.error?.description
            ))
        } else {
            show(Banner(
                kind: .warning,
                title: "\(verb) \(Formatting.count(successes, singular: "item")), \(failures.count) failed.",
                detail: failures.first?.error?.description
            ))
        }
    }
}
