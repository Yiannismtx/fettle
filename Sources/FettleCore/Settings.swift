import Foundation

/// User-adjustable preferences. Nothing about Fettle's behaviour is hardcoded
/// that the spec says should be tunable — notably the installer age threshold
/// (spec §3.1), which has a suggested default but no locked-in value.
public struct FettleSettings: Codable, Equatable, Sendable {
    /// How old a `.dmg`/`.pkg` must be before Fettle proposes trashing it.
    public var installerAgeThresholdDays: Int
    /// Only propose installers whose app appears to already be in /Applications.
    /// Off means age alone is enough to flag an installer.
    public var requireMatchingInstalledApp: Bool
    /// Minimum file size considered by the duplicate scanner, in bytes.
    /// Filters out the swarm of tiny identical files that aren't worth reviewing.
    public var duplicateMinimumBytes: Int
    /// Skip files the Finder hides. Effectively always on; exposed for symmetry.
    public var skipHiddenFiles: Bool
    /// Where the scanners look. Defaults to ~/Downloads.
    public var scanFolderBookmark: Data?
    /// Send malware hits to a quarantine folder instead of the Trash.
    public var quarantineInsteadOfTrash: Bool
    /// Absolute path to `clamscan`. Empty means "discover it on PATH".
    public var clamscanPathOverride: String
    /// Check for updates on launch via Sparkle.
    public var automaticUpdateChecks: Bool

    public static let `default` = FettleSettings(
        installerAgeThresholdDays: 30,
        requireMatchingInstalledApp: false,
        duplicateMinimumBytes: 1024,
        skipHiddenFiles: true,
        scanFolderBookmark: nil,
        quarantineInsteadOfTrash: true,
        clamscanPathOverride: "",
        automaticUpdateChecks: true
    )

    public init(
        installerAgeThresholdDays: Int,
        requireMatchingInstalledApp: Bool,
        duplicateMinimumBytes: Int,
        skipHiddenFiles: Bool,
        scanFolderBookmark: Data?,
        quarantineInsteadOfTrash: Bool,
        clamscanPathOverride: String,
        automaticUpdateChecks: Bool
    ) {
        self.installerAgeThresholdDays = installerAgeThresholdDays
        self.requireMatchingInstalledApp = requireMatchingInstalledApp
        self.duplicateMinimumBytes = duplicateMinimumBytes
        self.skipHiddenFiles = skipHiddenFiles
        self.scanFolderBookmark = scanFolderBookmark
        self.quarantineInsteadOfTrash = quarantineInsteadOfTrash
        self.clamscanPathOverride = clamscanPathOverride
        self.automaticUpdateChecks = automaticUpdateChecks
    }

    /// Clamp values that would make the app behave nonsensically if a stale or
    /// hand-edited defaults plist supplies them.
    public func normalized() -> FettleSettings {
        var copy = self
        copy.installerAgeThresholdDays = max(0, min(3650, installerAgeThresholdDays))
        copy.duplicateMinimumBytes = max(0, duplicateMinimumBytes)
        return copy
    }
}

/// Persists `FettleSettings` in `UserDefaults` as a single JSON blob, so adding
/// a field never needs a migration.
public final class SettingsStore: @unchecked Sendable {
    private static let key = "com.fettle.settings.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> FettleSettings {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(FettleSettings.self, from: data)
        else { return .default }
        return decoded.normalized()
    }

    public func save(_ settings: FettleSettings) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(settings.normalized()) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.key)
    }
}
