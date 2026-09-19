import Testing
import Foundation
@testable import FettleUI
@testable import FettleCore

@MainActor
@Suite("Organize screen")
struct OrganizeModelTests {
    @Test("Planning reaches a ready state instead of spinning forever")
    func reachesReady() async throws {
        let folder = try TempFolder()
        try folder.write("shot.png")
        try folder.write("paper.pdf")

        let model = OrganizeModel()
        #expect(model.state == .idle)
        model.plan(folder: folder.url, settings: .default)

        let settled = await waitUntil { if case .ready = model.state { return true }; return false }
        #expect(settled, "the organize screen never left its loading state")
        #expect(model.items.count == 2)
        #expect(model.selection.count == 2)
    }

    @Test("Re-planning while a plan is in flight still settles")
    func rapidRescan() async throws {
        let folder = try TempFolder()
        try folder.write("a.png")

        let model = OrganizeModel()
        model.plan(folder: folder.url, settings: .default)
        model.plan(folder: folder.url, settings: .default)
        model.plan(folder: folder.url, settings: .default)

        let settled = await waitUntil { if case .ready = model.state { return true }; return false }
        #expect(settled, "a rescan left the screen stuck loading")
        #expect(model.items.count == 1)
    }

    @Test("An unreadable folder surfaces an error rather than loading forever")
    func failureIsReported() async throws {
        let model = OrganizeModel()
        model.plan(
            folder: URL(fileURLWithPath: "/tmp/fettle-nope-\(UUID().uuidString)"),
            settings: .default
        )
        let settled = await waitUntil { if case .failed = model.state { return true }; return false }
        #expect(settled)
    }

    @Test("Applying moves the selected files and clears them from the plan")
    func applyMoves() async throws {
        let folder = try TempFolder()
        try folder.write("shot.png")
        try folder.write("paper.pdf")

        let model = OrganizeModel()
        model.plan(folder: folder.url, settings: .default)
        _ = await waitUntil { if case .ready = model.state { return true }; return false }

        let results = await model.apply()
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.succeeded })
        #expect(folder.exists("Images/shot.png"))
        #expect(folder.exists("Documents/paper.pdf"))
        #expect(model.items.isEmpty)
    }

    @Test("Toggling a category selects and deselects everything in it")
    func categoryToggle() async throws {
        let folder = try TempFolder()
        try folder.write("a.png")
        try folder.write("b.png")
        try folder.write("c.pdf")

        let model = OrganizeModel()
        model.plan(folder: folder.url, settings: .default)
        _ = await waitUntil { if case .ready = model.state { return true }; return false }

        model.toggleCategory(.images)
        #expect(model.selection.count == 1)
        model.toggleCategory(.images)
        #expect(model.selection.count == 3)
    }
}
