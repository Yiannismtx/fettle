import Testing
import Foundation
@testable import FettleCore

@Suite("Installer name matching")
struct AppMatcherTests {
    private func app(_ name: String) -> InstalledApp {
        InstalledApp(
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            displayName: name,
            bundleIdentifier: nil,
            version: nil
        )
    }

    @Test("Version numbers and download noise are stripped")
    func normalization() {
        #expect(AppMatcher.normalize("Firefox 121.0.dmg") == "firefox")
        #expect(AppMatcher.normalize("VSCode-darwin-arm64.zip") == "vscode")
        #expect(AppMatcher.normalize("Docker-Installer-4.26.1-universal.dmg") == "docker")
        #expect(AppMatcher.normalize("GoogleChrome") == "googlechrome")
        #expect(AppMatcher.normalize("node-v20.11.0.pkg") == "node")
    }

    @Test("Node.js keeps its meaningful suffix")
    func doesNotEatRealSuffixes() {
        #expect(AppMatcher.tokens("Node.js") == ["node", "js"])
    }

    @Test("Identical names match exactly")
    func exact() {
        let matcher = AppMatcher(apps: [app("Firefox")])
        #expect(matcher.match(fileName: "Firefox.dmg")?.confidence == .exact)
        #expect(matcher.match(fileName: "Firefox 121.0.dmg")?.confidence == .exact)
    }

    @Test("Multi-word app names match their installers")
    func multiWord() {
        let matcher = AppMatcher(apps: [app("Google Chrome"), app("Visual Studio Code")])
        #expect(matcher.match(fileName: "googlechrome.dmg")?.app.displayName == "Google Chrome")
        #expect(matcher.match(fileName: "GoogleChrome-124.dmg")?.confidence == .exact)
        let vscode = matcher.match(fileName: "Visual Studio Code 1.87 Installer.dmg")
        #expect(vscode?.app.displayName == "Visual Studio Code")
        #expect(vscode?.confidence == .exact)
    }

    @Test("A short name can't swallow a longer, different one")
    func noShortNameOvermatching() {
        let matcher = AppMatcher(apps: [app("Go")])
        #expect(matcher.match(fileName: "GoLand-2024.1.dmg") == nil)
        #expect(matcher.match(fileName: "Google Chrome.dmg") == nil)
    }

    @Test("Unrelated names don't match")
    func unrelated() {
        let matcher = AppMatcher(apps: [app("Firefox"), app("Slack")])
        #expect(matcher.match(fileName: "Blender-4.0.dmg") == nil)
        #expect(matcher.match(fileName: "SomeRandomThing.pkg") == nil)
    }

    @Test("A partial overlap reads as weak, not certain")
    func partial() {
        let matcher = AppMatcher(apps: [app("Adobe Photoshop 2024")])
        let match = matcher.match(fileName: "Photoshop Installer.dmg")
        #expect(match != nil)
        #expect(match!.confidence < .exact)
    }

    @Test("The best of several candidates wins")
    func bestWins() {
        let matcher = AppMatcher(apps: [app("Chrome Remote Desktop"), app("Google Chrome")])
        #expect(matcher.match(fileName: "googlechrome.dmg")?.app.displayName == "Google Chrome")
    }

    @Test("Empty and punctuation-only names are handled")
    func degenerate() {
        let matcher = AppMatcher(apps: [app("Firefox")])
        #expect(matcher.match(fileName: "") == nil)
        #expect(matcher.match(fileName: "---.dmg") == nil)
        #expect(matcher.match(fileName: "1.2.3.dmg") == nil)
    }
}
