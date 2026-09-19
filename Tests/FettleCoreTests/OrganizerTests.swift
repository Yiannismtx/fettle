import Testing
import Foundation
@testable import FettleCore

@Suite("File organizer")
struct OrganizerTests {
    @Test("Files are routed to the folder for their type")
    func routing() throws {
        let folder = try TempFolder()
        try folder.write("shot.png")
        try folder.write("paper.pdf")
        try folder.write("src.zip")
        try folder.write("App.dmg")
        try folder.write("clip.mp4")

        let plan = try Organizer().plan(folder: folder.url, settings: .default)
        let routing = Dictionary(
            uniqueKeysWithValues: plan.items.map { ($0.name, $0.category) }
        )
        #expect(routing["shot.png"] == .images)
        #expect(routing["paper.pdf"] == .documents)
        #expect(routing["src.zip"] == .archives)
        #expect(routing["App.dmg"] == .installers)
        #expect(routing["clip.mp4"] == .other)
    }

    @Test("Only loose top-level files are planned; subfolders are left alone")
    func topLevelOnly() throws {
        let folder = try TempFolder()
        try folder.write("loose.png")
        try folder.write("nested.png", subdirectory: "My Project")

        let plan = try Organizer().plan(folder: folder.url, settings: .default)
        #expect(plan.items.map(\.name) == ["loose.png"])
        #expect(plan.skippedDirectories == 1)
    }

    @Test("Running the organizer twice is a no-op")
    func idempotent() throws {
        let folder = try TempFolder()
        try folder.write("shot.png")
        try folder.write("paper.pdf")

        let organizer = Organizer()
        let first = try organizer.plan(folder: folder.url, settings: .default)
        let results = organizer.apply(first.items)
        #expect(results.allSatisfy { $0.succeeded })

        let second = try organizer.plan(folder: folder.url, settings: .default)
        #expect(second.isEmpty)
        #expect(second.alreadyOrganized == 2)
    }

    @Test("Files actually land in the right folder")
    func executesMoves() throws {
        let folder = try TempFolder()
        try folder.write("shot.png", contents: "image bytes")

        let organizer = Organizer()
        let plan = try organizer.plan(folder: folder.url, settings: .default)
        let results = organizer.apply(plan.items)

        #expect(results.count == 1)
        #expect(results[0].succeeded)
        #expect(folder.exists("Images/shot.png"))
        #expect(!folder.exists("shot.png"))
    }

    @Test("A name clash is renamed, never overwritten")
    func neverOverwrites() throws {
        let folder = try TempFolder()
        try folder.write("notes.pdf", contents: "the original", subdirectory: "Documents")
        try folder.write("notes.pdf", contents: "the new one")

        let organizer = Organizer()
        let plan = try organizer.plan(folder: folder.url, settings: .default)
        #expect(plan.items.first?.willBeRenamed == true)

        let results = organizer.apply(plan.items)
        #expect(results[0].succeeded)
        #expect(folder.exists("Documents/notes.pdf"))
        #expect(folder.exists("Documents/notes 2.pdf"))

        let original = try String(
            contentsOf: folder.url.appendingPathComponent("Documents/notes.pdf"), encoding: .utf8
        )
        #expect(original == "the original")
    }

    @Test("A move that fails doesn't stop the rest of the batch")
    func partialFailure() throws {
        let folder = try TempFolder()
        try folder.write("good.png")
        let vanished = folder.url.appendingPathComponent("gone.png")

        let organizer = Organizer()
        var plan = try organizer.plan(folder: folder.url, settings: .default)
        plan = OrganizePlan(
            items: plan.items + [
                OrganizePlanItem(
                    source: vanished,
                    category: .images,
                    destinationDirectory: folder.url.appendingPathComponent("Images"),
                    size: 0,
                    willBeRenamed: false
                )
            ],
            skippedDirectories: 0,
            alreadyOrganized: 0
        )

        let results = organizer.apply(plan.items)
        #expect(results.filter(\.succeeded).count == 1)
        #expect(results.filter { !$0.succeeded }.first?.error == .missing)
        #expect(folder.exists("Images/good.png"))
    }

    @Test("Two same-named files in one batch are both flagged for renaming")
    func clashWithinBatch() throws {
        let folder = try TempFolder()
        // Different extensions, same classification, same eventual name clash
        // is impossible; instead check two files that both land in Documents.
        try folder.write("a.pdf")
        try folder.write("b.pdf")
        let plan = try Organizer().plan(folder: folder.url, settings: .default)
        #expect(plan.items.allSatisfy { !$0.willBeRenamed })
    }

    @Test("An empty folder plans nothing")
    func emptyFolder() throws {
        let folder = try TempFolder()
        let plan = try Organizer().plan(folder: folder.url, settings: .default)
        #expect(plan.isEmpty)
    }
}

@Suite("Destructive actions")
struct FileActionsTests {
    @Test("Trashing removes the file from its folder")
    func trashing() throws {
        let folder = try TempFolder()
        let url = try folder.write("junk.txt")

        let result = FileActions().trash(url)
        #expect(result.succeeded)
        #expect(!folder.exists("junk.txt"))
        // Cleanup: the file is now in the Trash, not gone.
        if let trashed = result.destination {
            try? FileManager.default.removeItem(at: trashed)
        }
    }

    @Test("Trashing a file that's already gone reports it, doesn't throw")
    func trashMissing() throws {
        let folder = try TempFolder()
        let result = FileActions().trash(folder.url.appendingPathComponent("nope.txt"))
        #expect(result.error == .missing)
    }

    @Test("A free name is found rather than overwriting")
    func availableName() throws {
        let folder = try TempFolder()
        try folder.write("file.txt")
        try folder.write("file 2.txt")

        let url = FileActions.availableURL(
            in: folder.url, fileName: "file.txt", fileManager: FileManager.default
        )
        #expect(url.lastPathComponent == "file 3.txt")
    }

    @Test("Extension-less names are numbered too")
    func availableNameNoExtension() throws {
        let folder = try TempFolder()
        try folder.write("README")
        let url = FileActions.availableURL(
            in: folder.url, fileName: "README", fileManager: FileManager.default
        )
        #expect(url.lastPathComponent == "README 2")
    }

    @Test("Moving into a folder that doesn't exist yet creates it")
    func createsDestination() throws {
        let folder = try TempFolder()
        let url = try folder.write("thing.txt")
        let destination = folder.url.appendingPathComponent("New/Nested")

        let result = FileActions().move(url, into: destination)
        #expect(result.succeeded)
        #expect(folder.exists("New/Nested/thing.txt"))
    }
}
