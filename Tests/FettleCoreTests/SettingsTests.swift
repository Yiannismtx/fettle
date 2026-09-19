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
