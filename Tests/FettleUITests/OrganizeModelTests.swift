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

@MainActor
@Suite("Rescanning when the context changes")
struct ScanContextTests {
    @Test("Changing the folder rescans instead of showing the old folder's plan")
    func folderChangeRescans() async throws {
        let first = try TempFolder()
        try first.write("a.png")
        let second = try TempFolder()
        try second.write("b.pdf")
        try second.write("c.pdf")

        let model = OrganizeModel()
        model.planIfNeeded(
            context: ScanContext(folder: first.url, settings: .default), settings: .default
        )
        _ = await waitUntil { if case .ready = model.state { return true }; return false }
        #expect(model.items.map(\.name) == ["a.png"])

        model.planIfNeeded(
            context: ScanContext(folder: second.url, settings: .default), settings: .default
        )
        let settled = await waitUntil { model.items.count == 2 }
        #expect(settled, "changing the folder left the previous folder's plan on screen")
        #expect(Set(model.items.map(\.name)) == ["b.pdf", "c.pdf"])
    }

    @Test("Returning to an unchanged page doesn't redo the work")
    func unchangedContextDoesNotRescan() async throws {
        let folder = try TempFolder()
        try folder.write("a.png")

        let model = OrganizeModel()
        let context = ScanContext(folder: folder.url, settings: .default)
        model.planIfNeeded(context: context, settings: .default)
        _ = await waitUntil { if case .ready = model.state { return true }; return false }

        // A second visit with the same context must not knock the page back
        // into its loading state.
        model.planIfNeeded(context: context, settings: .default)
        if case .ready = model.state {} else {
            Issue.record("an unchanged context triggered a rescan")
        }
    }

    @Test("Changing the age threshold rescans the installer page")
    func installerThresholdRescans() async throws {
        let folder = try TempFolder()
        try folder.write("Old.dmg", daysAgo: 60)
        try folder.write("Newer.dmg", daysAgo: 10)

        var strict = FettleSettings.default
        strict.installerAgeThresholdDays = 30
        var loose = FettleSettings.default
        loose.installerAgeThresholdDays = 5

        let model = InstallersModel()
        model.scanIfNeeded(context: ScanContext(folder: folder.url, settings: strict), settings: strict)
        _ = await waitUntil { if case .loaded = model.state { return true }; return false }
        #expect(model.candidates.count == 1)

        model.scanIfNeeded(context: ScanContext(folder: folder.url, settings: loose), settings: loose)
        let settled = await waitUntil { model.candidates.count == 2 }
        #expect(settled, "changing the threshold left the old results on screen")
    }

    @Test("A setting the page doesn't use doesn't force a rescan")
    func irrelevantSettingIsIgnored() {
        let folder = URL(fileURLWithPath: "/tmp")
        var a = FettleSettings.default
        a.duplicateMinimumBytes = 1024
        var b = FettleSettings.default
        b.duplicateMinimumBytes = 999_999

        let first = ScanContext(folder: folder, settings: a)
        let second = ScanContext(folder: folder, settings: b)
        #expect(first.organizeKey == second.organizeKey)
        #expect(first.installerKey == second.installerKey)
        #expect(first.duplicateKey != second.duplicateKey)
    }
}
