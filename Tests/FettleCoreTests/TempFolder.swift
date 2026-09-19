import Foundation
@testable import FettleCore

/// A throwaway directory for tests that need real files on disk.
/// Created under the system temp dir and removed on deinit.
final class TempFolder {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fettle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(
        _ name: String,
        contents: String = "hello",
        daysAgo: Int = 0,
        subdirectory: String? = nil
    ) throws -> URL {
        var directory = url
        if let subdirectory {
            directory = url.appendingPathComponent(subdirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fileURL = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: fileURL)
        if daysAgo > 0 {
            let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            try FileManager.default.setAttributes(
                [.creationDate: date, .modificationDate: date], ofItemAtPath: fileURL.path
            )
        }
        return fileURL
    }

    @discardableResult
    func writeBytes(_ name: String, bytes: [UInt8], daysAgo: Int = 0) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        try Data(bytes).write(to: fileURL)
        if daysAgo > 0 {
            let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            try FileManager.default.setAttributes(
                [.creationDate: date, .modificationDate: date], ofItemAtPath: fileURL.path
            )
        }
        return fileURL
    }

    func makeDirectory(_ name: String) throws -> URL {
        let directory = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }
}
