import Testing
import Foundation
@testable import FettleUI
@testable import FettleCore

@MainActor
@Suite("Quarantine screen")
struct QuarantineModelTests {
    /// Quarantine writes to a fixed Application Support folder, so these tests
    /// clean up after themselves rather than assuming it starts empty.
    private func cleanUp(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(
                at: url.appendingPathExtension("fettle-quarantine")
            )
        }
    }

    @Test("A quarantined file is listed with its signature and origin")
    func listsQuarantined() async throws {
        let source = try TempFolder()
        let url = try source.write("suspect-\(UUID().uuidString).bin", contents: "payload")
        let finding = MalwareFinding(url: url, signature: "Win.Test.EICAR_HDB-1")
        let placed = Quarantine().quarantine(finding)
        #expect(placed.succeeded)
        defer { cleanUp([placed.destination].compactMap { $0 }) }

        let model = QuarantineModel()
        await model.load()

        let item = model.items.first { $0.entry.url == placed.destination }
        #expect(item != nil)
        #expect(item?.signature == "Win.Test.EICAR_HDB-1")
        #expect(item?.originalPath == url.path)
        #expect(item?.originalDirectory?.path == source.url.path)
    }

    @Test("Putting a file back restores it and clears its note")
    func restores() async throws {
        let source = try TempFolder()
        let name = "restore-me-\(UUID().uuidString).bin"
        let url = try source.write(name, contents: "payload")
        let placed = Quarantine().quarantine(
            MalwareFinding(url: url, signature: "Test.Sig-1")
        )
        #expect(placed.succeeded)

        let model = QuarantineModel()
        await model.load()
        guard let item = model.items.first(where: { $0.entry.url == placed.destination }) else {
            Issue.record("the quarantined file wasn't listed")
            return
        }

        let result = await model.restore(item, to: source.url)
        #expect(result.succeeded)
        #expect(source.exists(name))
        #expect(!model.items.contains { $0.id == item.id })
        if let destination = placed.destination {
            #expect(
                !FileManager.default.fileExists(
                    atPath: destination.appendingPathExtension("fettle-quarantine").path
                )
            )
        }
    }

    @Test("Trashing from quarantine takes the note with it")
    func trashes() async throws {
        let source = try TempFolder()
        let url = try source.write("trash-me-\(UUID().uuidString).bin", contents: "payload")
        let placed = Quarantine().quarantine(
            MalwareFinding(url: url, signature: "Test.Sig-2")
        )
        #expect(placed.succeeded)

        let model = QuarantineModel()
        await model.load()
        guard let item = model.items.first(where: { $0.entry.url == placed.destination }) else {
            Issue.record("the quarantined file wasn't listed")
            return
        }

        let result = await model.trash(item)
        #expect(result.succeeded)
        #expect(!model.items.contains { $0.id == item.id })
        if let trashed = result.destination {
            try? FileManager.default.removeItem(at: trashed)
        }
        if let destination = placed.destination {
            #expect(
                !FileManager.default.fileExists(
                    atPath: destination.appendingPathExtension("fettle-quarantine").path
                )
            )
        }
    }
}
