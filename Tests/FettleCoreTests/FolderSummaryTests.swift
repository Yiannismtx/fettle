import Testing
import Foundation
@testable import FettleCore

@Suite("Folder summary")
struct FolderSummaryTests {
    @Test("Counts, sizes and the loose/subfolder split")
    func counts() throws {
        let folder = try TempFolder()
        try folder.write("a.png", contents: String(repeating: "x", count: 100))
        try folder.write("b.pdf", contents: String(repeating: "x", count: 200))
        try folder.write("nested.txt", contents: "abc", subdirectory: "Documents")
        _ = try folder.makeDirectory("Empty Folder")

        let summary = try FolderSummarizer().summarize(folder: folder.url, settings: .default)
        #expect(summary.fileCount == 3)
        #expect(summary.totalBytes == 303)
        #expect(summary.looseFileCount == 2)
        #expect(summary.folderCount == 2)
    }

    @Test("Installers past the threshold are counted; fresh ones aren't")
    func agedInstallers() throws {
        let folder = try TempFolder()
        try folder.write("Old.dmg", contents: String(repeating: "x", count: 1000), daysAgo: 90)
        try folder.write("AlsoOld.pkg", contents: String(repeating: "x", count: 500), daysAgo: 60)
        try folder.write("Fresh.dmg", contents: "x", daysAgo: 1)

        var settings = FettleSettings.default
        settings.installerAgeThresholdDays = 30
        let summary = try FolderSummarizer().summarize(folder: folder.url, settings: settings)
        #expect(summary.agedInstallerCount == 2)
        #expect(summary.agedInstallerBytes == 1500)
    }

    @Test("The breakdown only lists categories that are actually present")
    func breakdown() throws {
        let folder = try TempFolder()
        try folder.write("a.png")
        try folder.write("b.png")
        try folder.write("c.zip")

        let summary = try FolderSummarizer().summarize(folder: folder.url, settings: .default)
        #expect(summary.breakdown.map(\.category) == [.images, .archives])
        #expect(summary.breakdown.first(where: { $0.category == .images })?.count == 2)
    }

    @Test("Highlights are the biggest and the oldest, capped")
    func highlights() throws {
        let folder = try TempFolder()
        for index in 1...8 {
            try folder.write(
                "f\(index).bin",
                contents: String(repeating: "x", count: index * 100),
                daysAgo: index
            )
        }

        let summary = try FolderSummarizer().summarize(folder: folder.url, settings: .default)
        #expect(summary.largestFiles.count == FolderSummarizer.highlightCount)
        #expect(summary.largestFiles.first?.name == "f8.bin")
        #expect(summary.oldestFiles.first?.name == "f8.bin")
    }

    @Test("Package caches are excluded from the totals too")
    func excludesManagedDirectories() throws {
        let folder = try TempFolder()
        try folder.write("real.txt", contents: String(repeating: "x", count: 50))
        try folder.write(
            "index.js", contents: String(repeating: "x", count: 9999),
            subdirectory: "node_modules/pkg"
        )

        let summary = try FolderSummarizer().summarize(folder: folder.url, settings: .default)
        #expect(summary.fileCount == 1)
        #expect(summary.totalBytes == 50)
    }

    @Test("An empty folder summarises to nothing rather than failing")
    func emptyFolder() throws {
        let folder = try TempFolder()
        let summary = try FolderSummarizer().summarize(folder: folder.url, settings: .default)
        #expect(summary.isEmpty)
        #expect(summary.breakdown.isEmpty)
    }
}
