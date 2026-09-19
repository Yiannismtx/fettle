import Foundation

/// Where flagged files go when the user chooses quarantine over the Trash.
///
/// Deliberately outside the folder being scanned, so a quarantined file isn't
/// found again by the next scan, and outside the Trash, so emptying the Trash
/// can't destroy evidence the user hasn't looked at yet.
public struct Quarantine: Sendable {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Fettle/Quarantine", isDirectory: true)
    }

    private let actions = FileActions()

    public init() {}

    /// Move a flagged file into quarantine and leave a note beside it saying
    /// what flagged it, so the folder is still meaningful months later.
    public func quarantine(_ finding: MalwareFinding) -> FileActionResult {
        let result = actions.move(finding.url, into: Self.directory)
        if result.succeeded, let destination = result.destination {
            writeManifestEntry(for: finding, at: destination)
        }
        return result
    }

    public func quarantine(_ findings: [MalwareFinding]) -> [FileActionResult] {
        findings.map { quarantine($0) }
    }

    /// What's currently in quarantine, newest first.
    public func contents() -> [FileEntry] {
        let scanner = FolderScanner()
        guard let entries = try? scanner.scan(
            folder: Self.directory,
            options: FolderScanOptions(recursive: false, skipHiddenFiles: true)
        ) else { return [] }
        return entries
            .filter { $0.url.pathExtension != "fettle-quarantine" }
            .sorted { $0.referenceDate > $1.referenceDate }
    }

    /// Put a quarantined file back where it came from. The user may disagree
    /// with ClamAV, and they're entitled to.
    public func restore(_ url: URL, to directory: URL) -> FileActionResult {
        let result = actions.move(url, into: directory)
        if result.succeeded {
            try? FileManager.default.removeItem(at: manifestURL(for: url))
        }
        return result
    }

    private func manifestURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("fettle-quarantine")
    }

    private func writeManifestEntry(for finding: MalwareFinding, at destination: URL) {
        let note = """
            Quarantined by Fettle
            Signature:     \(finding.signature)
            Original path: \(finding.url.path)
            Quarantined:   \(ISO8601DateFormatter().string(from: Date()))

            This file was moved here, not deleted. If you believe this is a false
            positive, you can move it back.
            """
        try? Data(note.utf8).write(to: manifestURL(for: destination))
    }

    /// The signature that flagged a quarantined file, read back from its note.
    public func recordedSignature(for url: URL) -> String? {
        guard let text = try? String(contentsOf: manifestURL(for: url), encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("Signature:") {
            return line.dropFirst("Signature:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public func recordedOriginalPath(for url: URL) -> String? {
        guard let text = try? String(contentsOf: manifestURL(for: url), encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("Original path:") {
            return line.dropFirst("Original path:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
