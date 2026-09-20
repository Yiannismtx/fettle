import Testing
import Foundation
@testable import FettleCore

@Suite("Homebrew discovery")
struct HomebrewTests {
    @Test("The prefix is derived from the binary's location")
    func prefix() {
        #expect(Homebrew(executablePath: "/opt/homebrew/bin/brew").prefix == "/opt/homebrew")
        #expect(Homebrew(executablePath: "/usr/local/bin/brew").prefix == "/usr/local")
    }

    @Test("The environment gives Homebrew its own bin on PATH")
    func environment() {
        let env = Homebrew(executablePath: "/opt/homebrew/bin/brew").environment
        // A GUI app inherits almost none of the shell environment, so this has
        // to be supplied rather than assumed.
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin") == true)
        #expect(env["HOME"] != nil)
        #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test("Both standard prefixes are searched, Apple silicon first")
    func searchOrder() {
        #expect(Homebrew.searchPaths.first == "/opt/homebrew/bin/brew")
        #expect(Homebrew.searchPaths.contains("/usr/local/bin/brew"))
    }
}

@Suite("freshclam configuration")
struct FreshclamConfigTests {
    /// Homebrew installs freshclam.conf.sample and never freshclam.conf, and
    /// freshclam refuses to start without the real file. Getting this step
    /// wrong is the usual reason a fresh `brew install clamav` looks broken.
    @Test("The sample is copied with the Example line commented out")
    func createsFromSample() throws {
        let folder = try TempFolder()
        let etc = folder.url.appendingPathComponent("etc/clamav")
        try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
        try Data("""
            Example
            DatabaseMirror database.clamav.net
            """.utf8).write(to: etc.appendingPathComponent("freshclam.conf.sample"))

        let message = try ClamAVInstaller().prepareFreshclamConfig(prefix: folder.url.path)
        #expect(message?.contains("Created") == true)

        let written = try String(
            contentsOf: etc.appendingPathComponent("freshclam.conf"), encoding: .utf8
        )
        #expect(written.contains("# Example"))
        #expect(!written.split(separator: "\n").contains("Example"))
        #expect(written.contains("DatabaseMirror database.clamav.net"))
    }

    @Test("An `Example` appearing inside another word is left alone")
    func onlyCommentsTheDirective() throws {
        let folder = try TempFolder()
        let etc = folder.url.appendingPathComponent("etc/clamav")
        try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
        try Data("""
            # ExampleMirror is not a directive
            DatabaseMirror ExampleHost
            """.utf8).write(to: etc.appendingPathComponent("freshclam.conf.sample"))

        _ = try ClamAVInstaller().prepareFreshclamConfig(prefix: folder.url.path)
        let written = try String(
            contentsOf: etc.appendingPathComponent("freshclam.conf"), encoding: .utf8
        )
        #expect(written.contains("DatabaseMirror ExampleHost"))
        #expect(!written.contains("# # Example"))
    }

    @Test("An existing config is never overwritten")
    func leavesExistingConfigAlone() throws {
        let folder = try TempFolder()
        let etc = folder.url.appendingPathComponent("etc/clamav")
        try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
        let config = etc.appendingPathComponent("freshclam.conf")
        try Data("DatabaseMirror my.own.mirror\n".utf8).write(to: config)
        try Data("Example\n".utf8).write(to: etc.appendingPathComponent("freshclam.conf.sample"))

        let message = try ClamAVInstaller().prepareFreshclamConfig(prefix: folder.url.path)
        #expect(message?.contains("already exists") == true)
        // The user may have tuned this file; clobbering it would be rude.
        #expect(try String(contentsOf: config, encoding: .utf8) == "DatabaseMirror my.own.mirror\n")
    }

    @Test("With no sample, a minimal config is written")
    func writesMinimalConfig() throws {
        let folder = try TempFolder()
        let message = try ClamAVInstaller().prepareFreshclamConfig(prefix: folder.url.path)
        #expect(message?.contains("minimal") == true)

        let written = try String(
            contentsOf: folder.url.appendingPathComponent("etc/clamav/freshclam.conf"),
            encoding: .utf8
        )
        #expect(written.contains("DatabaseMirror"))
    }
}

@Suite("ClamAV install")
struct ClamAVInstallTests {
    @Test("Readiness reports what's actually on the machine")
    func readiness() {
        let readiness = ClamAVInstaller().readiness()
        #expect(readiness.hasHomebrew == (Homebrew.locate() != nil))
        #expect(readiness.hasClamAV == (ClamAVService().locateExecutable() != nil))
    }

    @Test("Without Homebrew the install refuses and says why, rather than half-running")
    func requiresHomebrew() async {
        guard Homebrew.locate() == nil else { return }
        await #expect(throws: ClamAVInstallError.self) {
            try await ClamAVInstaller().install()
        }
        // Fettle can't run Homebrew's installer: it needs an admin password,
        // which must be asked for directly and not brokered by another app.
        let message = ClamAVInstallError.homebrewMissing.errorDescription ?? ""
        #expect(message.contains("admin password"))
    }

    @Test("Every step describes what it will do before it does it")
    func stepsAreExplained() {
        for step in ClamAVInstallStep.allCases {
            #expect(!step.title.isEmpty)
            #expect(!step.detail.isEmpty)
        }
        #expect(ClamAVInstallStep.allCases.count == 3)
    }
}

@Suite("Custom Homebrew prefix")
struct HomebrewPrefixTests {
    private func makeFakeBrew(in folder: TempFolder) throws -> URL {
        let bin = folder.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let brew = bin.appendingPathComponent("brew")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: brew)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: brew.path
        )
        return brew
    }

    @Test("HOMEBREW_PREFIX is honoured, as Homebrew itself does")
    func honoursPrefix() throws {
        let folder = try TempFolder()
        let brew = try makeFakeBrew(in: folder)

        let found = Homebrew.locate(environment: ["HOMEBREW_PREFIX": folder.url.path])
        #expect(found?.executablePath == brew.path)
        #expect(found?.prefix == folder.url.path)
    }

    @Test("A prefix that doesn't hold a brew binary falls through to the standard paths")
    func ignoresBogusPrefix() throws {
        let folder = try TempFolder()
        let found = Homebrew.locate(environment: ["HOMEBREW_PREFIX": folder.url.path])
        #expect(found?.executablePath != "\(folder.url.path)/bin/brew")
    }

    @Test("An empty prefix is ignored rather than producing /bin/brew")
    func ignoresEmptyPrefix() {
        let found = Homebrew.locate(environment: ["HOMEBREW_PREFIX": ""])
        #expect(found?.executablePath != "/bin/brew")
    }
}

@Suite("Finding clamscan after a Fettle install")
struct ClamscanDiscoveryTests {
    @Test("A clamscan under the active Homebrew prefix is found")
    func findsUnderBrewPrefix() throws {
        // Without this, a user with a custom HOMEBREW_PREFIX could install
        // ClamAV through Fettle and still be told it isn't installed.
        let folder = try TempFolder()
        let bin = folder.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["brew", "clamscan"] {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }

        setenv("HOMEBREW_PREFIX", folder.url.path, 1)
        defer { unsetenv("HOMEBREW_PREFIX") }

        // Only meaningful on a machine without a standard-path clamscan.
        let standard = ClamAVService.searchPaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        guard standard == nil else { return }
        #expect(ClamAVService().locateExecutable() == bin.appendingPathComponent("clamscan").path)
    }

    @Test("An explicit override still wins over everything")
    func overrideWins() throws {
        let folder = try TempFolder()
        let url = folder.url.appendingPathComponent("my-clamscan")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        #expect(ClamAVService(overridePath: url.path).locateExecutable() == url.path)
    }
}
