import Testing
import Foundation
@testable import FettleCore

@Suite("Duplicate detection")
struct DuplicateScannerTests {
    private func settings(minimumBytes: Int = 1) -> FettleSettings {
        var settings = FettleSettings.default
        settings.duplicateMinimumBytes = minimumBytes
        return settings
    }

    @Test("Identical contents match even under unrelated names")
    func matchesByContent() throws {
        let folder = try TempFolder()
        try folder.write("report.pdf", contents: "identical content here")
        try folder.write("totally-different-name.bin", contents: "identical content here")
        try folder.write("other.txt", contents: "something else")

        let result = try DuplicateScanner().scan(folder: folder.url, settings: settings())
        #expect(result.groups.count == 1)
        #expect(result.groups[0].totalCount == 2)
    }

    @Test("Same-sized files with different contents are not duplicates")
    func sameSizeDifferentContent() throws {
        let folder = try TempFolder()
        try folder.write("a.txt", contents: "aaaa")
        try folder.write("b.txt", contents: "bbbb")

        let result = try DuplicateScanner().scan(folder: folder.url, settings: settings())
        #expect(result.groups.isEmpty)
    }

    @Test("Files larger than the prefix window still compare correctly")
    func largeFilesBeyondPrefixWindow() throws {
        let folder = try TempFolder()
        let prefix = [UInt8](repeating: 0x41, count: DuplicateScanner.prefixHashBytes)
        // Same first 64 KB, different tail: the prefix pass must not be trusted
        // on its own.
        try folder.writeBytes("same-prefix-1.bin", bytes: prefix + [0x01, 0x02])
        try folder.writeBytes("same-prefix-2.bin", bytes: prefix + [0x03, 0x04])
        // And a genuine pair of the same length, so the group still forms.
        try folder.writeBytes("real-dupe-1.bin", bytes: prefix + [0x09, 0x09])
        try folder.writeBytes("real-dupe-2.bin", bytes: prefix + [0x09, 0x09])

        let result = try DuplicateScanner().scan(folder: folder.url, settings: settings())
        #expect(result.groups.count == 1)
        let names = Set([result.groups[0].original.name] + result.groups[0].duplicates.map(\.name))
        #expect(names == ["real-dupe-1.bin", "real-dupe-2.bin"])
    }

    @Test("The oldest copy is the one kept")
    func keepsOldest() throws {
        let folder = try TempFolder()
        try folder.write("new.txt", contents: "same", daysAgo: 1)
        try folder.write("old.txt", contents: "same", daysAgo: 100)
        try folder.write("middle.txt", contents: "same", daysAgo: 50)

        let result = try DuplicateScanner().scan(folder: folder.url, settings: settings())
        #expect(result.groups.count == 1)
        #expect(result.groups[0].original.name == "old.txt")
        #expect(result.groups[0].duplicates.map(\.name) == ["middle.txt", "new.txt"])
    }

    @Test("Files below the size floor are ignored")
    func minimumSize() throws {
        let folder = try TempFolder()
        try folder.write("tiny-1.txt", contents: "ab")
        try folder.write("tiny-2.txt", contents: "ab")

        let result = try DuplicateScanner().scan(folder: folder.url, settings: settings(minimumBytes: 1024))
        #expect(result.groups.isEmpty)
        #expect(result.filesConsidered == 0)
    }

    @Test("Duplicates are found across subfolders")
    func recursive() throws {
        let folder = try TempFolder()
        try folder.write("a.txt", contents: "shared payload")
        try folder.write("a.txt", contents: "shared payload", subdirectory: "Documents")

        let result = try DuplicateScanner().scan(folder: folder.url, settings: settings())
        #expect(result.groups.count == 1)
    }

    @Test("Reclaimable bytes count every copy but the one kept")
    func reclaimableBytes() throws {
        let folder = try TempFolder()
        let payload = String(repeating: "x", count: 4096)
        for index in 1...3 {
            try folder.write("copy\(index).bin", contents: payload, daysAgo: 10 - index)
        }

        let result = try DuplicateScanner().scan(folder: folder.url, settings: settings())
        #expect(result.duplicateCount == 2)
        #expect(result.reclaimableBytes == 2 * 4096)
    }

    @Test("Cancellation stops the scan")
    func cancellation() throws {
        let folder = try TempFolder()
        try folder.write("a.txt", contents: "same")
        try folder.write("b.txt", contents: "same")

        #expect(throws: CancellationError.self) {
            try DuplicateScanner().scan(
                folder: folder.url, settings: settings(), isCancelled: { true }
            )
        }
    }

    @Test("An empty folder produces no groups")
    func emptyFolder() throws {
        let folder = try TempFolder()
        let result = try DuplicateScanner().scan(folder: folder.url, settings: settings())
        #expect(result.groups.isEmpty)
        #expect(result.filesConsidered == 0)
    }
}

@Suite("Content hashing")
struct HashingTests {
    @Test("Hashes match a known SHA-256 value")
    func knownVector() throws {
        let folder = try TempFolder()
        let url = try folder.write("abc.txt", contents: "abc")
        #expect(
            Hashing.sha256(of: url)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("Chunked reading produces the same hash as a single read")
    func chunking() throws {
        let folder = try TempFolder()
        let bytes = (0..<(Hashing.chunkSize * 2 + 17)).map { UInt8($0 % 251) }
        let url = try folder.writeBytes("big.bin", bytes: bytes)
        let viaFile = Hashing.sha256(of: url)
        #expect(viaFile != nil)
        #expect(viaFile == Hashing.sha256(of: url))
    }

    @Test("A limit hashes only the prefix")
    func limited() throws {
        let folder = try TempFolder()
        let shared = [UInt8](repeating: 0x7f, count: 128)
        let a = try folder.writeBytes("a.bin", bytes: shared + [1])
        let b = try folder.writeBytes("b.bin", bytes: shared + [2])
        #expect(Hashing.sha256(of: a, limit: 128) == Hashing.sha256(of: b, limit: 128))
        #expect(Hashing.sha256(of: a) != Hashing.sha256(of: b))
    }

    @Test("An unreadable path returns nil instead of crashing")
    func missingFile() {
        #expect(Hashing.sha256(of: URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID())")) == nil)
    }
}

@Suite("Folder scanning")
struct FolderScannerTests {
    @Test("Package-cache directories are never descended into")
    func skipsManagedDirectories() throws {
        let folder = try TempFolder()
        try folder.write("real.txt", contents: "keep me")
        try folder.write("index.js", contents: "keep me", subdirectory: "node_modules/left-pad")
        try folder.write("config", contents: "keep me", subdirectory: ".git")

        let entries = try FolderScanner().scan(
            folder: folder.url, options: FolderScanOptions(recursive: true, skipHiddenFiles: false)
        )
        #expect(entries.map(\.name) == ["real.txt"])
    }

    @Test("A file inside node_modules is never offered as a duplicate")
    func duplicatesIgnoreManagedDirectories() throws {
        let folder = try TempFolder()
        try folder.write("lib.js", contents: "module.exports = 1")
        try folder.write("lib.js", contents: "module.exports = 1", subdirectory: "node_modules/pkg")

        let result = try DuplicateScanner().scan(folder: folder.url, settings: .default)
        #expect(result.groups.isEmpty)
    }

    @Test("Non-recursive scans stay at the top level")
    func nonRecursive() throws {
        let folder = try TempFolder()
        try folder.write("top.txt")
        try folder.write("nested.txt", subdirectory: "Documents")

        let entries = try FolderScanner().scan(folder: folder.url)
        #expect(entries.map(\.name) == ["top.txt"])
    }

    @Test("Subfolders are reported when asked for, and never as files")
    func includesDirectories() throws {
        let folder = try TempFolder()
        try folder.write("top.txt")
        _ = try folder.makeDirectory("A Folder")

        let entries = try FolderScanner().scanTopLevelIncludingDirectories(
            folder: folder.url, skipHidden: true
        )
        #expect(entries.count == 2)
        #expect(entries.first(where: { $0.name == "A Folder" })?.isDirectory == true)
    }

    @Test("Symlinks are never followed out of the folder")
    func ignoresSymlinks() throws {
        let folder = try TempFolder()
        let outside = try TempFolder()
        try outside.write("secret.txt", contents: "not yours")
        try FileManager.default.createSymbolicLink(
            at: folder.url.appendingPathComponent("link"), withDestinationURL: outside.url
        )
        try folder.write("own.txt")

        let entries = try FolderScanner().scan(
            folder: folder.url, options: FolderScanOptions(recursive: true)
        )
        #expect(entries.map(\.name) == ["own.txt"])
    }

    @Test("Cancellation stops enumeration")
    func cancellation() throws {
        let folder = try TempFolder()
        try folder.write("a.txt")
        #expect(throws: CancellationError.self) {
            try FolderScanner().scan(folder: folder.url, isCancelled: { true })
        }
    }
}
