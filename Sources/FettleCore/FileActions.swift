import Foundation

/// The result of attempting one file operation. Batch operations never throw on
/// the first failure — a single locked or already-moved file must not abort the
/// rest of the batch, and the user needs to see exactly what did and didn't happen.
public struct FileActionResult: Identifiable, Sendable {
    public let id = UUID()
    public let source: URL
    /// Where the file ended up, when the operation produced a new location.
    public let destination: URL?
    public let error: FileActionError?

    public var succeeded: Bool { error == nil }

    public init(source: URL, destination: URL?, error: FileActionError?) {
        self.source = source
        self.destination = destination
        self.error = error
    }
}

public enum FileActionError: Error, Equatable, Sendable, CustomStringConvertible {
    case missing
    case notPermitted
    case destinationExists(URL)
    case underlying(String)

    public var description: String {
        switch self {
        case .missing:
            return "The file no longer exists."
        case .notPermitted:
            return "Fettle doesn't have permission to move this file. Grant Full Disk Access in System Settings › Privacy & Security."
        case .destinationExists(let url):
            return "Something already exists at \(url.lastPathComponent)."
        case .underlying(let message):
            return message
        }
    }
}

/// Every destructive path in Fettle funnels through here.
///
/// There is deliberately no permanent-delete API on this type (spec §2): the
/// strongest thing Fettle can do to a file is move it to the Trash, which the
/// user can always undo from the Finder.
public struct FileActions: Sendable {
    private let fileManager: @Sendable () -> FileManager

    public init(fileManager: @escaping @Sendable () -> FileManager = { FileManager() }) {
        self.fileManager = fileManager
    }

    /// Move one file to the Trash. Returns the resulting trash URL on success.
    public func trash(_ url: URL) -> FileActionResult {
        let fm = fileManager()
        guard fm.fileExists(atPath: url.path) else {
            return FileActionResult(source: url, destination: nil, error: .missing)
        }
        do {
            var resulting: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &resulting)
            return FileActionResult(source: url, destination: resulting as URL?, error: nil)
        } catch {
            return FileActionResult(source: url, destination: nil, error: Self.map(error))
        }
    }

    public func trash(_ urls: [URL]) -> [FileActionResult] {
        urls.map { trash($0) }
    }

    /// Move a file into `directory`, creating the directory if needed and
    /// disambiguating the name rather than ever overwriting an existing file.
    public func move(_ url: URL, into directory: URL) -> FileActionResult {
        let fm = fileManager()
        guard fm.fileExists(atPath: url.path) else {
            return FileActionResult(source: url, destination: nil, error: .missing)
        }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = Self.availableURL(
                in: directory, fileName: url.lastPathComponent, fileManager: fm
            )
            // A move onto itself is a no-op, not an error.
            if destination.standardizedFileURL == url.standardizedFileURL {
                return FileActionResult(source: url, destination: url, error: nil)
            }
            try fm.moveItem(at: url, to: destination)
            return FileActionResult(source: url, destination: destination, error: nil)
        } catch {
            return FileActionResult(source: url, destination: nil, error: Self.map(error))
        }
    }

    /// Find a free name in `directory`, appending ` 2`, ` 3`, … before the
    /// extension the way the Finder does.
    public static func availableURL(
        in directory: URL, fileName: String, fileManager: FileManager
    ) -> URL {
        let candidate = directory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        // Bounded so a pathological directory can't spin forever; after this we
        // fall back to a UUID suffix, which is guaranteed free.
        for index in 2...999 {
            let attempt = ext.isEmpty ? "\(name) \(index)" : "\(name) \(index).\(ext)"
            let url = directory.appendingPathComponent(attempt)
            if !fileManager.fileExists(atPath: url.path) { return url }
        }
        let unique = ext.isEmpty
            ? "\(name) \(UUID().uuidString)"
            : "\(name) \(UUID().uuidString).\(ext)"
        return directory.appendingPathComponent(unique)
    }

    private static func map(_ error: Error) -> FileActionError {
        let nsError = error as NSError
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .missing
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return .notPermitted
        default:
            return .underlying(nsError.localizedDescription)
        }
    }
}
