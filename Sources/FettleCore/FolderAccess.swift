import Foundation

/// Resolves the folder Fettle operates on.
///
/// The choice is stored as a bookmark rather than a path so it survives the user
/// renaming or moving the folder, and so the app keeps working if it is ever
/// sandboxed (`startAccessing` is a no-op outside a sandbox).
public struct FolderAccess: Sendable {
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    public static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolve the chosen folder.
    ///
    /// The bookmark wins when it resolves, because it follows the folder if it
    /// was renamed or moved. The path is the fallback, and the Downloads folder
    /// is the fallback for that. `isStale` is true when the stored choice
    /// couldn't be honoured, so the UI can say so rather than quietly scanning
    /// somewhere the user didn't pick.
    public static func resolve(path: String, bookmark: Data?) -> (url: URL, isStale: Bool) {
        if let bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return (url, stale)
            }
        }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // isDirectory: true keeps the URL shape identical to the one the
            // folder picker produces, so equality checks against it hold.
            let url = URL(
                fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true
            )
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory
            )
            return (url, !(exists && isDirectory.boolValue))
        }

        return (defaultFolder, bookmark != nil)
    }

    /// Runs `body` with security-scoped access held, when the URL needs it.
    /// Outside a sandbox `startAccessingSecurityScopedResource` returns false and
    /// access works anyway, so a false return is not an error.
    @discardableResult
    public static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
