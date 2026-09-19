import Foundation
import Observation
import Sparkle

/// Thin wrapper over Sparkle's `SPUStandardUpdaterController`.
///
/// Sparkle is only meaningful once the app ships from a bundle with an
/// `SUFeedURL` in its Info.plist; when that is missing (a `swift run` debug
/// build, say) the updater is reported as unavailable instead of failing loudly.
@MainActor
@Observable
final class UpdaterController {
    private(set) var canCheckForUpdates = false
    private(set) var isConfigured = false
    private(set) var lastCheckDate: Date?

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    var feedURLString: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (v?, b?): return "\(v) (\(b))"
        case let (v?, nil): return v
        default: return "development build"
        }
    }

    init() {
        guard feedURLString?.isEmpty == false else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        self.isConfigured = true
        self.lastCheckDate = controller.updater.lastUpdateCheckDate
        // Sparkle gates checks on its own state (in-progress check, no feed);
        // mirror that rather than guessing.
        self.canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) {
            [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
                self?.lastCheckDate = updater.lastUpdateCheckDate
            }
        }
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }
}
