import SwiftUI
import FettleCore

/// Fettle's single window. Settings is a page inside it rather than a
/// scene of its own, so there is only ever one window to manage.
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
            // Settings is a page in the main window rather than a Settings
            // scene, so ⌘, navigates to it instead of opening a second window.
            //
            // A separate settings window is the macOS default, and for an app
            // with a sidebar full of pages it is also the one place the user
            // can't get to by looking. Fettle's settings are mostly about what
            // the pages do — the folder, the thresholds, which scan runs — so
            // they belong beside them, not in a window you have to dismiss to
            // see whether the change did anything.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.selection = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // Fettle has no documents, so New/Open would only ever be dead menu items.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
