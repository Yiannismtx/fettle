import SwiftUI
import FettleCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 280)
        } detail: {
            detail
                .toolbar { FolderToolbar() }
        }
        .overlay(alignment: .bottom) {
            BannerView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview: OverviewView()
        case .installers: InstallersView()
        case .duplicates: DuplicatesView()
        case .organize: OrganizeView()
        case .scan: MalwareScanView()
        case .quarantine: QuarantineView()
        case .settings: SettingsView()
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: Destination

    var body: some View {
        List(Destination.allCases, selection: $selection) { destination in
            Label(destination.title, systemImage: destination.systemImage)
                .tag(destination)
                .help(destination.subtitle)
        }
        .listStyle(.sidebar)
        .navigationTitle("Fettle")
    }
}

private struct FolderToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([model.folder])
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "folder")
                    Text(model.folder.lastPathComponent)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.accessoryBar)
            .help("Reveal \(model.folder.path) in the Finder")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                FolderPicker.choose(startingAt: model.folder) { url in
                    model.chooseFolder(url)
                }
            } label: {
                // Plain folder, not folder.badge.gearshape: that symbol reads
                // as "folder settings", which this button isn't, and sitting
                // next to the real Settings gear it made both of them vaguer.
                Label("Choose Folder…", systemImage: "folder")
            }
            .help("Point Fettle at a different folder")
        }
        ToolbarItem(placement: .primaryAction) {
            // Settings is a page in this window, not a separate one, so this
            // navigates rather than opening anything. A second window showing
            // the same form is a second place for the app's state to live and
            // one more thing to close.
            Button {
                model.selection = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Thresholds, scanning, and updates (⌘,)")
            .disabled(model.selection == .settings)
        }
    }
}

enum FolderPicker {
    /// `message` and `prompt` are parameters because the same panel is used to
    /// pick the folder Fettle tidies and to pick a one-off folder to scan for
    /// malware, and telling somebody they are choosing a folder "to clean up"
    /// when they asked to scan one is a small lie the panel doesn't need to
    /// tell.
    @MainActor
    static func choose(
        startingAt url: URL,
        message: String = "Choose the folder Fettle should clean up.",
        prompt: String = "Use Folder",
        completion: @escaping (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.prompt = prompt
        panel.message = message
        if panel.runModal() == .OK, let picked = panel.url {
            completion(picked)
        }
    }
}
