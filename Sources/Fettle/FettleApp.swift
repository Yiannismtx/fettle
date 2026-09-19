import SwiftUI
import FettleCore

@main
struct FettleApp: App {
    @State private var model = AppModel()
    @State private var updater = UpdaterController()

    var body: some Scene {
        Window("Fettle", id: "main") {
            RootView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    updater.setAutomaticChecks(model.settings.automaticUpdateChecks)
                }
        }
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
        }
    }
}
