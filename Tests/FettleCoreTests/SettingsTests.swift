import Testing
import Foundation
@testable import FettleCore

@Suite("Settings persistence")
struct SettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "com.fettle.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("An empty store returns the defaults")
    func emptyStore() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.load() == .default)
    }

    @Test("Saved settings round-trip")
    func roundTrip() {
        let store = SettingsStore(defaults: makeDefaults())
        var settings = FettleSettings.default
        settings.installerAgeThresholdDays = 90
        settings.quarantineInsteadOfTrash = false
        settings.clamscanPathOverride = "/opt/homebrew/bin/clamscan"
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test("Out-of-range values are clamped rather than trusted")
    func clamping() {
        let store = SettingsStore(defaults: makeDefaults())
        var settings = FettleSettings.default
        settings.installerAgeThresholdDays = -5
        settings.duplicateMinimumBytes = -100
        store.save(settings)
        let loaded = store.load()
        #expect(loaded.installerAgeThresholdDays == 0)
        #expect(loaded.duplicateMinimumBytes == 0)
    }

    @Test("Reset restores the defaults")
    func reset() {
        let store = SettingsStore(defaults: makeDefaults())
        var settings = FettleSettings.default
        settings.installerAgeThresholdDays = 5
        store.save(settings)
        store.reset()
        #expect(store.load() == .default)
    }
}

@Suite("Scan folder resolution")
struct FolderAccessTests {
    @Test("No stored choice means the Downloads folder")
    func defaultsToDownloads() {
        let resolved = FolderAccess.resolve(path: "", bookmark: nil)
        #expect(resolved.url == FolderAccess.defaultFolder)
        #expect(!resolved.isStale)
    }

    @Test("A stored path is used when there's no bookmark")
    func usesPath() throws {
        let folder = try TempFolder()
        let resolved = FolderAccess.resolve(path: folder.url.path, bookmark: nil)
        #expect(resolved.url.path == folder.url.path)
        #expect(!resolved.isStale)
    }

    @Test("A path that's gone is reported stale rather than silently replaced")
    func stalePath() {
        let missing = "/tmp/fettle-gone-\(UUID().uuidString)"
        let resolved = FolderAccess.resolve(path: missing, bookmark: nil)
        #expect(resolved.url.path == missing)
        #expect(resolved.isStale)
    }

    @Test("A path pointing at a file, not a folder, is stale")
    func pathIsAFile() throws {
        let folder = try TempFolder()
        let file = try folder.write("notafolder.txt")
        #expect(FolderAccess.resolve(path: file.path, bookmark: nil).isStale)
    }

    @Test("Tildes are expanded")
    func expandsTilde() {
        let resolved = FolderAccess.resolve(path: "~/Downloads", bookmark: nil)
        #expect(resolved.url.path == FolderAccess.defaultFolder.path)
    }

    @Test("A settings file written before a field existed keeps everything else")
    func olderStoredSettingsSurviveANewField() throws {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)

        // Exactly what an older build wrote: no lastMalwareScanKind key at all.
        // Settings live in one JSON blob, so a decoder that threw on the
        // missing key would silently reset every other preference the moment
        // an upgraded build read the file.
        let older = """
            {
              "installerAgeThresholdDays": 90,
              "requireMatchingInstalledApp": true,
              "duplicateMinimumBytes": 4096,
              "skipHiddenFiles": true,
              "scanFolderPath": "/Users/me/Downloads",
              "quarantineInsteadOfTrash": false,
              "clamscanPathOverride": "/opt/homebrew/bin/clamscan",
              "automaticUpdateChecks": true
            }
            """
        defaults.set(Data(older.utf8), forKey: "com.fettle.settings.v1")

        let loaded = store.load()
        #expect(loaded.installerAgeThresholdDays == 90)
        #expect(loaded.duplicateMinimumBytes == 4096)
        #expect(loaded.clamscanPathOverride == "/opt/homebrew/bin/clamscan")
        #expect(loaded.quarantineInsteadOfTrash == false)
        // The new field takes its default rather than taking the file with it.
        #expect(loaded.lastMalwareScanKind == MalwareScanKind.quick.rawValue)
    }

    @Test("A scan type the app no longer knows about falls back to Quick")
    func unknownScanKindIsNormalised() {
        var settings = FettleSettings.default
        settings.lastMalwareScanKind = "psychic"
        #expect(settings.normalized().lastMalwareScanKind == MalwareScanKind.quick.rawValue)
    }
}
