import Foundation
import UniformTypeIdentifiers

/// The type-based buckets the organizer sorts Downloads into.
///
/// Deliberately coarse (spec §3.3): five folders, no date sub-sorting.
public enum FileCategory: String, CaseIterable, Codable, Sendable {
    case images = "Images"
    case documents = "Documents"
    case archives = "Archives"
    case installers = "Installers"
    case other = "Other"

    /// Folder name used on disk. Matches the raw value so the mapping stays obvious.
    public var folderName: String { rawValue }

    public var systemImageName: String {
        switch self {
        case .images: return "photo"
        case .documents: return "doc.text"
        case .archives: return "archivebox"
        case .installers: return "shippingbox"
        case .other: return "questionmark.folder"
        }
    }

    /// Every folder name the organizer owns. Used to skip its own destination
    /// folders when re-scanning, so organizing twice is a no-op.
    public static var allFolderNames: Set<String> {
        Set(allCases.map(\.folderName))
    }

    /// Extensions that are unambiguous enough to classify without touching the
    /// file. `UTType` handles the long tail; this table handles what it gets
    /// wrong or doesn't know (e.g. `.pkg` reads as an archive, not an installer).
    private static let extensionOverrides: [String: FileCategory] = [
        "dmg": .installers,
        "pkg": .installers,
        "mpkg": .installers,
        "app": .installers,
        "iso": .installers,
        "zip": .archives,
        "gz": .archives,
        "tgz": .archives,
        "bz2": .archives,
        "xz": .archives,
        "7z": .archives,
        "rar": .archives,
        "tar": .archives,
        "heic": .images,
        "webp": .images,
        "avif": .images,
        "svg": .images,
        "md": .documents,
        "markdown": .documents,
        "csv": .documents,
        "epub": .documents,
        "numbers": .documents,
        "pages": .documents,
        "key": .documents,
    ]

    /// Classify by file extension alone — no disk I/O, so this is safe to call
    /// for thousands of files on a background task.
    public static func classify(fileName: String) -> FileCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        if let override = extensionOverrides[ext] { return override }

        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .diskImage) { return .installers }
        // Audio and video conform to `.content`, which would otherwise sweep
        // them into Documents. They belong in Other.
        if type.conforms(to: .audio) || type.conforms(to: .movie) { return .other }
        if type.conforms(to: .text) || type.conforms(to: .pdf)
            || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .content) {
            return .documents
        }
        return .other
    }

    public static func classify(url: URL) -> FileCategory {
        classify(fileName: url.lastPathComponent)
    }
}
