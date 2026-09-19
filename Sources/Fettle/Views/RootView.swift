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
                Label("Choose Folder…", systemImage: "folder.badge.gearshape")
            }
            .help("Point Fettle at a different folder")
        }
    }
}

enum FolderPicker {
    @MainActor
    static func choose(startingAt url: URL, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder Fettle should clean up."
        if panel.runModal() == .OK, let picked = panel.url {
            completion(picked)
        }
    }
}
