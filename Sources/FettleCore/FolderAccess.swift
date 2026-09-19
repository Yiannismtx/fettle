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

    /// Returns the bookmarked folder, or the Downloads folder when there is no
    /// bookmark or it can no longer be resolved.
    public static func resolve(bookmark: Data?) -> (url: URL, isStale: Bool) {
        guard let bookmark else { return (defaultFolder, false) }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return (defaultFolder, true)
        }
        return (url, stale)
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
