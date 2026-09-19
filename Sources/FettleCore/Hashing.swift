import Foundation
import CryptoKit

public enum Hashing {
    /// Read in 1 MB chunks so hashing a 4 GB disk image costs 1 MB of memory,
    /// not 4 GB.
    public static let chunkSize = 1 << 20

    /// SHA-256 of a file's contents, or nil if it can't be read.
    ///
    /// `onBytesRead` is called per chunk so a long hash can report progress, and
    /// cancellation is checked per chunk so cancelling is felt immediately
    /// rather than at the end of the file.
    public static func sha256(
        of url: URL,
        limit: Int? = nil,
        onBytesRead: ((Int) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var remaining = limit ?? Int.max

        while remaining > 0 {
            if isCancelled() { return nil }
            let want = min(chunkSize, remaining)
            guard let chunk = try? handle.read(upToCount: want), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            remaining -= chunk.count
            onBytesRead?(chunk.count)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
