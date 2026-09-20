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
    ///
    /// The path is the primary record and the bookmark is the fallback: a
    /// bookmark survives the folder being renamed or moved, but a path is
    /// legible, inspectable, and can't silently resolve to somewhere else.
    public var scanFolderPath: String
    public var scanFolderBookmark: Data?
    /// Send malware hits to a quarantine folder instead of the Trash.
    public var quarantineInsteadOfTrash: Bool
    /// Absolute path to `clamscan`. Empty means "discover it on PATH".
    public var clamscanPathOverride: String
    /// Check for updates on launch via Sparkle.
    public var automaticUpdateChecks: Bool
    /// The page that was open when the app last quit, so it reopens where the
    /// user left off instead of always resetting to Overview.
    public var lastDestination: String
    /// Which malware scan the user ran last: quick, folder, or full system.
    /// Reaching for the same scan twice is the common case, and re-picking it
    /// on every launch is a small tax on the thing people do most.
    public var lastMalwareScanKind: String

    public static let `default` = FettleSettings(
        installerAgeThresholdDays: 30,
        requireMatchingInstalledApp: false,
        duplicateMinimumBytes: 1024,
        skipHiddenFiles: true,
        scanFolderPath: "",
        scanFolderBookmark: nil,
        quarantineInsteadOfTrash: true,
        clamscanPathOverride: "",
        automaticUpdateChecks: true,
        lastDestination: "",
        lastMalwareScanKind: MalwareScanKind.quick.rawValue
    )

    public init(
        installerAgeThresholdDays: Int,
        requireMatchingInstalledApp: Bool,
        duplicateMinimumBytes: Int,
        skipHiddenFiles: Bool,
        scanFolderPath: String = "",
        scanFolderBookmark: Data?,
        quarantineInsteadOfTrash: Bool,
        clamscanPathOverride: String,
        automaticUpdateChecks: Bool,
        lastDestination: String = "",
        lastMalwareScanKind: String = MalwareScanKind.quick.rawValue
    ) {
        self.installerAgeThresholdDays = installerAgeThresholdDays
        self.requireMatchingInstalledApp = requireMatchingInstalledApp
        self.duplicateMinimumBytes = duplicateMinimumBytes
        self.skipHiddenFiles = skipHiddenFiles
        self.scanFolderPath = scanFolderPath
        self.scanFolderBookmark = scanFolderBookmark
        self.quarantineInsteadOfTrash = quarantineInsteadOfTrash
        self.clamscanPathOverride = clamscanPathOverride
        self.automaticUpdateChecks = automaticUpdateChecks
        self.lastDestination = lastDestination
        self.lastMalwareScanKind = lastMalwareScanKind
    }

    /// Decoded field by field, each one falling back to its default.
    ///
    /// Settings are stored as a single JSON blob, and Swift's synthesised
    /// decoder throws `keyNotFound` for any key the stored blob lacks —
    /// declaring a default value on the property does not change that. Since
    /// `SettingsStore.load` treats a decode failure as "no settings", every
    /// field added in a new version would otherwise reset every *other*
    /// preference the first time the upgraded build read the file: the folder
    /// you chose, your installer threshold, your clamscan path, all silently
    /// back to stock. Writing the decoder out makes a missing key mean "this
    /// version didn't have that setting" instead.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = FettleSettings.default
        installerAgeThresholdDays = try container.decodeIfPresent(
            Int.self, forKey: .installerAgeThresholdDays
        ) ?? fallback.installerAgeThresholdDays
        requireMatchingInstalledApp = try container.decodeIfPresent(
            Bool.self, forKey: .requireMatchingInstalledApp
        ) ?? fallback.requireMatchingInstalledApp
        duplicateMinimumBytes = try container.decodeIfPresent(
            Int.self, forKey: .duplicateMinimumBytes
        ) ?? fallback.duplicateMinimumBytes
        skipHiddenFiles = try container.decodeIfPresent(
            Bool.self, forKey: .skipHiddenFiles
        ) ?? fallback.skipHiddenFiles
        scanFolderPath = try container.decodeIfPresent(
            String.self, forKey: .scanFolderPath
        ) ?? fallback.scanFolderPath
        scanFolderBookmark = try container.decodeIfPresent(
            Data.self, forKey: .scanFolderBookmark
        )
        quarantineInsteadOfTrash = try container.decodeIfPresent(
            Bool.self, forKey: .quarantineInsteadOfTrash
        ) ?? fallback.quarantineInsteadOfTrash
        clamscanPathOverride = try container.decodeIfPresent(
            String.self, forKey: .clamscanPathOverride
        ) ?? fallback.clamscanPathOverride
        automaticUpdateChecks = try container.decodeIfPresent(
            Bool.self, forKey: .automaticUpdateChecks
        ) ?? fallback.automaticUpdateChecks
        lastDestination = try container.decodeIfPresent(
            String.self, forKey: .lastDestination
        ) ?? fallback.lastDestination
        lastMalwareScanKind = try container.decodeIfPresent(
            String.self, forKey: .lastMalwareScanKind
        ) ?? fallback.lastMalwareScanKind
    }

    enum CodingKeys: String, CodingKey {
        case installerAgeThresholdDays
        case requireMatchingInstalledApp
        case duplicateMinimumBytes
        case skipHiddenFiles
        case scanFolderPath
        case scanFolderBookmark
        case quarantineInsteadOfTrash
        case clamscanPathOverride
        case automaticUpdateChecks
        case lastDestination
        case lastMalwareScanKind
    }

    /// Clamp values that would make the app behave nonsensically if a stale or
    /// hand-edited defaults plist supplies them.
    public func normalized() -> FettleSettings {
        var copy = self
        copy.installerAgeThresholdDays = max(0, min(3650, installerAgeThresholdDays))
        copy.duplicateMinimumBytes = max(0, duplicateMinimumBytes)
        if MalwareScanKind(rawValue: lastMalwareScanKind) == nil {
            copy.lastMalwareScanKind = MalwareScanKind.quick.rawValue
        }
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
