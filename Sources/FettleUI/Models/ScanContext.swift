import Foundation
import FettleCore

/// Everything a scan's results depend on.
///
/// Each screen records the context it last scanned. When the folder changes, or
/// a setting that would change the answer changes, the screen rescans instead
/// of showing results computed under different rules — which is otherwise easy
/// to miss, because the stale list looks perfectly plausible.
struct ScanContext: Equatable, Sendable {
    let folder: URL
    let skipHiddenFiles: Bool
    let installerAgeThresholdDays: Int
    let requireMatchingInstalledApp: Bool
    let duplicateMinimumBytes: Int

    init(folder: URL, settings: FettleSettings) {
        self.folder = folder
        self.skipHiddenFiles = settings.skipHiddenFiles
        self.installerAgeThresholdDays = settings.installerAgeThresholdDays
        self.requireMatchingInstalledApp = settings.requireMatchingInstalledApp
        self.duplicateMinimumBytes = settings.duplicateMinimumBytes
    }

    /// The subset of the context each scan's answer actually depends on, so a
    /// setting one screen doesn't use never forces it to rescan.
    var installerKey: [String] {
        [
            folder.path,
            "\(skipHiddenFiles)",
            "\(installerAgeThresholdDays)",
            "\(requireMatchingInstalledApp)",
        ]
    }

    var duplicateKey: [String] {
        [folder.path, "\(skipHiddenFiles)", "\(duplicateMinimumBytes)"]
    }

    var organizeKey: [String] {
        [folder.path, "\(skipHiddenFiles)"]
    }

    var overviewKey: [String] {
        [folder.path, "\(skipHiddenFiles)", "\(installerAgeThresholdDays)"]
    }
}
