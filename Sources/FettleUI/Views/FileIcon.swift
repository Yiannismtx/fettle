import SwiftUI
import AppKit
import QuickLookThumbnailing

/// A file's icon, upgraded to a real thumbnail when one is available.
///
/// Reviewing a list of files means deciding *which* file each row is, and at
/// 20pt a dozen generic document glyphs are indistinguishable. The type icon
/// appears immediately and a Quick Look thumbnail replaces it when it arrives,
/// so the row is never empty and never blocks.
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 22
    /// Off for rows where the type is already obvious from context.
    var wantsThumbnail: Bool = true

    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? IconCache.shared.typeIcon(for: url, size: size))
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task(id: url) {
                guard wantsThumbnail else { return }
                thumbnail = await IconCache.shared.thumbnail(for: url, size: size)
            }
    }
}

/// Caches both kinds of icon.
///
/// `NSWorkspace.icon(forFile:)` touches the disk and is far too slow to call
/// per row during body evaluation — a few hundred rows is enough to stall the
/// main thread visibly. Type icons are cached by extension (every `.pdf` gets
/// the same one); thumbnails are per file, so they're cached by path.
final class IconCache: @unchecked Sendable {
    static let shared = IconCache()

    private let typeIcons = NSCache<NSString, NSImage>()
    private let thumbnails = NSCache<NSString, NSImage>()
    /// Paths Quick Look has already declined, so a plain .txt isn't re-asked
    /// every time it scrolls back into view.
    private var withoutThumbnail = Set<String>()
    private let lock = NSLock()

    private init() {
        typeIcons.countLimit = 256
        thumbnails.countLimit = 512
    }

    /// Bundles carry their own icon, so they can't share one by extension.
    private static let bundleExtensions: Set<String> = ["app", "bundle", "framework", "plugin"]

    /// The generic icon for this file's type. Cheap, synchronous, cached.
    ///
    /// The nominal size has to be set explicitly: handing SwiftUI the raw 32pt
    /// multi-representation image makes it pick the wrong representation and
    /// fall back to the blank document glyph.
    func typeIcon(for url: URL, size: CGFloat) -> NSImage {
        let ext = url.pathExtension.lowercased()
        let key: NSString = Self.bundleExtensions.contains(ext)
            ? "path:\(url.path)#\(size)" as NSString
            : "ext:\(ext)#\(size)" as NSString

        lock.lock()
        defer { lock.unlock() }

        if let cached = typeIcons.object(forKey: key) { return cached }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let sized = (icon.copy() as? NSImage) ?? icon
        sized.size = NSSize(width: size, height: size)
        typeIcons.setObject(sized, forKey: key)
        return sized
    }

    /// A Quick Look thumbnail, or nil when the file doesn't have one.
    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let key = "\(url.path)#\(size)" as NSString

        let cached: NSImage? = lock.withLockReturning {
            if withoutThumbnail.contains(key as String) { return nil }
            return thumbnails.object(forKey: key)
        }
        if let cached { return cached }

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            // .thumbnail only: the icon-style representations are what
            // typeIcon already provides, and asking for them would just hand
            // back the same blank glyph after a round trip.
            representationTypes: .thumbnail
        )

        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request)
        else {
            lock.withLock { withoutThumbnail.insert(key as String) }
            return nil
        }

        let image = NSImage(cgImage: representation.cgImage, size: NSSize(width: size, height: size))
        lock.withLock { thumbnails.setObject(image, forKey: key) }
        return image
    }
}

private extension NSLock {
    func withLock(_ body: () -> Void) {
        lock()
        defer { unlock() }
        body()
    }

    func withLockReturning<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
