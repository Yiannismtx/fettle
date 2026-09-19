import Foundation
import Testing
@testable import FettleUI

/// A throwaway directory for view-model tests that need real files.
final class TempFolder {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fettle-ui-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ name: String, contents: String = "hello", daysAgo: Int = 0) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: fileURL)
        if daysAgo > 0 {
            let date = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            try FileManager.default.setAttributes(
                [.creationDate: date, .modificationDate: date], ofItemAtPath: fileURL.path
            )
        }
        return fileURL
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path)
    }
}

/// Wait for a view model to settle, rather than sleeping a fixed amount.
/// Returns false if it never does, so a hang fails the test instead of hanging it.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
