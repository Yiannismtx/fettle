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

    var id: String { rawValue }

    /// Named for what's actually there, not a vague umbrella.
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .installers: return "Installers"
        case .duplicates: return "Duplicates"
        case .organize: return "Organize"
        case .scan: return "Malware Scan"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .installers: return "shippingbox"
        case .duplicates: return "doc.on.doc"
        case .organize: return "folder.badge.gearshape"
        case .scan: return "checkmark.shield"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "What's in the folder right now"
        case .installers: return "Dead-weight .dmg and .pkg files"
        case .duplicates: return "Identical files, matched by content"
        case .organize: return "Sort loose files into type folders"
        case .scan: return "On-demand ClamAV scan"
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
            if settings.scanFolderBookmark != oldValue.scanFolderBookmark {
                refreshFolder()
            }
        }
    }

    private(set) var folder: URL
    private(set) var folderIsStale: Bool
    var selection: Destination = .overview
    var banner: Banner?

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
        let resolved = FolderAccess.resolve(bookmark: loaded.scanFolderBookmark)
        self.folder = resolved.url
        self.folderIsStale = resolved.isStale
    }

    func refreshFolder() {
        let resolved = FolderAccess.resolve(bookmark: settings.scanFolderBookmark)
        folder = resolved.url
        folderIsStale = resolved.isStale
    }

    func chooseFolder(_ url: URL) {
        settings.scanFolderBookmark = FolderAccess.makeBookmark(for: url)
        // Reflect the choice immediately even if the bookmark couldn't be made.
        folder = url
        folderIsStale = false
    }

    func resetFolderToDownloads() {
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
