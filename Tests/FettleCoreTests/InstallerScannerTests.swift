import Testing
import Foundation
@testable import FettleCore

@Suite("Installer scanning")
struct InstallerScannerTests {
    private func settings(thresholdDays: Int, requireMatch: Bool = false) -> FettleSettings {
        var settings = FettleSettings.default
        settings.installerAgeThresholdDays = thresholdDays
        settings.requireMatchingInstalledApp = requireMatch
        return settings
    }

    private func matcher(_ names: [String]) -> AppMatcher {
        AppMatcher(apps: names.map {
            InstalledApp(
                url: URL(fileURLWithPath: "/Applications/\($0).app"),
                displayName: $0, bundleIdentifier: nil, version: nil
            )
        })
    }

    @Test("Only installer extensions are considered")
    func onlyInstallers() throws {
        let folder = try TempFolder()
        try folder.write("Firefox.dmg", daysAgo: 60)
        try folder.write("notes.pdf", daysAgo: 60)
        try folder.write("archive.zip", daysAgo: 60)
        try folder.write("Node.pkg", daysAgo: 60)

        let result = try InstallerScanner().scan(
            folder: folder.url, settings: settings(thresholdDays: 30), matcher: matcher([])
        )
        #expect(Set(result.candidates.map(\.entry.name)) == ["Firefox.dmg", "Node.pkg"])
    }

    @Test("Files newer than the threshold are skipped and counted")
    func ageThreshold() throws {
        let folder = try TempFolder()
        try folder.write("Old.dmg", daysAgo: 90)
        try folder.write("Fresh.dmg", daysAgo: 2)

        let result = try InstallerScanner().scan(
            folder: folder.url, settings: settings(thresholdDays: 30), matcher: matcher([])
        )
        #expect(result.candidates.map(\.entry.name) == ["Old.dmg"])
        #expect(result.skippedForAge == 1)
    }

    @Test("A threshold of zero includes everything")
    func zeroThreshold() throws {
        let folder = try TempFolder()
        try folder.write("Fresh.dmg", daysAgo: 0)

        let result = try InstallerScanner().scan(
            folder: folder.url, settings: settings(thresholdDays: 0), matcher: matcher([])
        )
        #expect(result.candidates.count == 1)
        #expect(result.skippedForAge == 0)
    }

    @Test("Only installers whose app is installed are recommended")
    func recommendation() throws {
        let folder = try TempFolder()
        try folder.write("Firefox 121.dmg", daysAgo: 60)
        try folder.write("SomeToolNobodyHas.dmg", daysAgo: 60)

        let result = try InstallerScanner().scan(
            folder: folder.url,
            settings: settings(thresholdDays: 30),
            matcher: matcher(["Firefox"])
        )
        let recommended = result.candidates.filter(\.isRecommended).map(\.entry.name)
        #expect(recommended == ["Firefox 121.dmg"])
        #expect(result.candidates.count == 2)
    }

    @Test("Requiring a matching app filters unmatched installers out entirely")
    func requireMatch() throws {
        let folder = try TempFolder()
        try folder.write("Firefox 121.dmg", daysAgo: 60)
        try folder.write("SomeToolNobodyHas.dmg", daysAgo: 60)

        let result = try InstallerScanner().scan(
            folder: folder.url,
            settings: settings(thresholdDays: 30, requireMatch: true),
            matcher: matcher(["Firefox"])
        )
        #expect(result.candidates.map(\.entry.name) == ["Firefox 121.dmg"])
    }

    @Test("Matched installers sort ahead of unmatched ones")
    func ordering() throws {
        let folder = try TempFolder()
        try folder.write("AAA-Unknown.dmg", contents: String(repeating: "x", count: 5000), daysAgo: 60)
        try folder.write("Firefox.dmg", daysAgo: 60)

        let result = try InstallerScanner().scan(
            folder: folder.url,
            settings: settings(thresholdDays: 30),
            matcher: matcher(["Firefox"])
        )
        #expect(result.candidates.first?.entry.name == "Firefox.dmg")
    }

    @Test("Scanning a folder that isn't there reports a readable error")
    func missingFolder() {
        let missing = URL(fileURLWithPath: "/tmp/fettle-does-not-exist-\(UUID().uuidString)")
        #expect(throws: FolderScanError.self) {
            try InstallerScanner().scan(
                folder: missing, settings: settings(thresholdDays: 30), matcher: matcher([])
            )
        }
    }
}
