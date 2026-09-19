import SwiftUI
import FettleCore

/// Fettle's window and settings scenes.
public struct FettleScene: Scene {
    @State private var model = AppModel()
    @State private var updater = UpdaterController()

    public init() {}

    public var body: some Scene {
        Window("Fettle", id: "main") {
            RootView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 880, minHeight: 560)
                .onAppear {
                    updater.setAutomaticChecks(model.settings.automaticUpdateChecks)
                }
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            // Fettle has no documents, so New/Open would only ever be dead menu items.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
        }
    }
}
