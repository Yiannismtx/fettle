import Foundation

/// A file on disk plus the metadata every scanner needs, read once.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let creationDate: Date
    public let modificationDate: Date
    public let isDirectory: Bool

    public var name: String { url.lastPathComponent }
    public var fileExtension: String { url.pathExtension.lowercased() }
    public var category: FileCategory { FileCategory.classify(url: url) }

    /// The date Fettle ages a file by. Uses the later of creation and
    /// modification so a freshly re-downloaded installer doesn't read as old.
    public var referenceDate: Date { max(creationDate, modificationDate) }

    public func age(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(referenceDate))
    }

    public func ageInDays(now: Date = Date()) -> Int {
        Int(age(now: now) / 86_400)
    }

    public init(
        url: URL, size: Int64, creationDate: Date, modificationDate: Date, isDirectory: Bool
    ) {
        self.url = url
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
    }
}

public struct FolderScanOptions: Sendable {
    /// Descend into subdirectories. Off for the organizer (it only moves what's
    /// loose at the top level); on for duplicates, so files already filed into
    /// Images/ or Documents/ are still compared.
    public var recursive: Bool
    public var skipHiddenFiles: Bool
    /// Treat `.app`, `.dmg`-mounted bundles etc. as single files rather than
    /// descending into them.
    public var treatPackagesAsFiles: Bool
    /// Directory names never descended into, on top of hidden ones.
    public var excludedDirectoryNames: Set<String>
    /// Report plain subdirectories as entries of their own. The organizer wants
    /// this so it can see (and leave alone) folders sitting in Downloads; the
    /// duplicate and installer scanners don't.
    public var includeDirectories: Bool

    public init(
        recursive: Bool = false,
        skipHiddenFiles: Bool = true,
        treatPackagesAsFiles: Bool = true,
        excludedDirectoryNames: Set<String> = [],
        includeDirectories: Bool = false
    ) {
        self.recursive = recursive
        self.skipHiddenFiles = skipHiddenFiles
        self.treatPackagesAsFiles = treatPackagesAsFiles
        self.excludedDirectoryNames = excludedDirectoryNames
        self.includeDirectories = includeDirectories
    }
}

public enum FolderScanError: Error, LocalizedError, Sendable {
    case notADirectory(URL)
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let url):
            return "\(url.lastPathComponent) isn't a folder."
        case .unreadable(let url):
            return "Fettle can't read \(url.lastPathComponent). Grant Full Disk Access in System Settings › Privacy & Security, then try again."
        }
    }
}

/// Reads a folder into `FileEntry` values. Synchronous and cheap (metadata
/// only, no file contents) — callers run it off the main actor.
public struct FolderScanner: Sendable {
    public init() {}

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isRegularFileKey, .isHiddenKey,
        .fileSizeKey, .totalFileAllocatedSizeKey,
        .creationDateKey, .contentModificationDateKey,
        .isSymbolicLinkKey,
    ]

    public func scan(
        folder: URL, options: FolderScanOptions = FolderScanOptions()
    ) throws -> [FileEntry] {
        let fm = FileManager()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            throw FolderScanError.unreadable(folder)
        }
        guard isDirectory.boolValue else {
            throw FolderScanError.notADirectory(folder)
        }

        var entries: [FileEntry] = []
        var queue: [URL] = [folder]
        var visitedDirectories = Set<String>()

        while let directory = queue.popLast() {
            // Guard against symlink loops when recursing.
            let resolved = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard visitedDirectories.insert(resolved).inserted else { continue }

            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Self.resourceKeys,
                    options: options.skipHiddenFiles ? [.skipsHiddenFiles] : []
                )
            } catch {
                // A single unreadable subdirectory shouldn't kill the whole scan,
                // but an unreadable root is a real failure worth reporting.
                if directory == folder { throw FolderScanError.unreadable(folder) }
                continue
            }

            for url in contents {
                guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
                else { continue }
                // Never follow symlinks: moving or hashing through one would act
                // on a file outside the folder the user chose.
                if values.isSymbolicLink == true { continue }
                if options.skipHiddenFiles, values.isHidden == true { continue }

                let isPackage = values.isPackage == true
                let isDir = values.isDirectory == true
                let treatAsFile = !isDir || (isPackage && options.treatPackagesAsFiles)

                if !treatAsFile {
                    if options.recursive,
                       !options.excludedDirectoryNames.contains(url.lastPathComponent) {
                        queue.append(url)
                    }
                    if options.includeDirectories {
                        entries.append(
                            FileEntry(
                                url: url,
                                size: 0,
                                creationDate: values.creationDate ?? .distantPast,
                                modificationDate: values.contentModificationDate
                                    ?? values.creationDate ?? .distantPast,
                                isDirectory: true
                            )
                        )
                    }
                    continue
                }

                let size = Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
                let created = values.creationDate ?? values.contentModificationDate ?? .distantPast
                let modified = values.contentModificationDate ?? created
                entries.append(
                    FileEntry(
                        url: url,
                        size: size,
                        creationDate: created,
                        modificationDate: modified,
                        isDirectory: isDir
                    )
                )
            }
        }

        return entries.sorted { $0.url.path < $1.url.path }
    }

    /// Top level only, with plain subfolders reported alongside files so the
    /// organizer can show what it is deliberately leaving in place.
    public func scanTopLevelIncludingDirectories(folder: URL, skipHidden: Bool) throws -> [FileEntry] {
        try scan(
            folder: folder,
            options: FolderScanOptions(
                recursive: false,
                skipHiddenFiles: skipHidden,
                treatPackagesAsFiles: true,
                includeDirectories: true
            )
        )
    }
}
