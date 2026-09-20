import SwiftUI
import AppKit
import FettleCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            CleanupSettingsTab()
                .tabItem { Label("Cleanup", systemImage: "sparkles") }
            ScanningSettingsTab()
                .tabItem { Label("Scanning", systemImage: "checkmark.shield") }
            UpdatesSettingsTab()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Folder") {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(model.folder.path)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .font(.callout)
                    HStack {
                        Button("Choose…") {
                            FolderPicker.choose(startingAt: model.folder) { model.chooseFolder($0) }
                        }
                        Button("Use Downloads") { model.resetFolderToDownloads() }
                            .disabled(model.folder == FolderAccess.defaultFolder)
                    }
                }
            }
            Toggle("Skip hidden files", isOn: $model.settings.skipHiddenFiles)
        }
        .formStyle(.grouped)
        .padding(.vertical, Theme.Spacing.s)
    }
}

private struct CleanupSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Installers") {
                LabeledContent("Consider installers older than") {
                    HStack(spacing: Theme.Spacing.s) {
                        // Stepper + field: the slider-free pairing is precise and
                        // still quick, and the unit sits next to the number it labels.
                        TextField(
                            "",
                            value: $model.settings.installerAgeThresholdDays,
                            format: .number
                        )
                        .labelsHidden()
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                        Stepper(
                            "",
                            value: $model.settings.installerAgeThresholdDays,
                            in: 0...3650
                        )
                        .labelsHidden()
                        Text("days")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(
                    "Only when the app is already installed",
                    isOn: $model.settings.requireMatchingInstalledApp
                )
                Text(
                    model.settings.requireMatchingInstalledApp
                        ? "Fettle proposes an installer only when it finds a matching app in /Applications."
                        : "Fettle proposes any installer past the age threshold, and marks the ones whose app it found."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Duplicates") {
                LabeledContent("Ignore files smaller than") {
                    HStack(spacing: Theme.Spacing.s) {
                        TextField(
                            "",
                            value: Binding(
                                get: { model.settings.duplicateMinimumBytes / 1024 },
                                set: { model.settings.duplicateMinimumBytes = max(0, $0) * 1024 }
                            ),
                            format: .number
                        )
                        .labelsHidden()
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                        Text("KB")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, Theme.Spacing.s)
    }
}

private struct ScanningSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var probe = ClamAVAvailability.unknown
    @State private var access = FullDiskAccessStatus.unknown

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Coverage") {
                LabeledContent("Full Disk Access") {
                    FullDiskAccessLabel(status: access)
                }
                HStack(spacing: Theme.Spacing.m) {
                    Button("Re-check") { Task { await refresh() } }
                    if access != .granted {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(FullDiskAccess.settingsPaneURL)
                        }
                        .help("Privacy & Security › Full Disk Access")
                    }
                }
            }
            Section("Malware scan") {
                Picker("Opens with", selection: $model.settings.lastMalwareScanKind) {
                    ForEach(MalwareScanKind.allCases) { kind in
                        Text(kind.title).tag(kind.rawValue)
                    }
                }
                Text(scanKindSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("ClamAV") {
                LabeledContent("Status") {
                    ClamAVStatusLabel(availability: probe)
                }
                LabeledContent("clamscan path") {
                    TextField(
                        "Discover automatically",
                        text: $model.settings.clamscanPathOverride
                    )
                    .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: Theme.Spacing.m) {
                    Button("Re-check") { Task { await refresh() } }
                    if !probe.isUsable {
                        Button("Install ClamAV…") { model.selection = .scan }
                            .help("Opens the Malware Scan page, which can install it for you")
                    }
                }
            }
            Section("Flagged files") {
                Picker("Move flagged files to", selection: $model.settings.quarantineInsteadOfTrash) {
                    Text("Quarantine folder").tag(true)
                    Text("Trash").tag(false)
                }
                .pickerStyle(.radioGroup)
                Text("Fettle never deletes anything permanently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, Theme.Spacing.s)
        .task { await refresh() }
    }

    /// What the currently chosen scan actually covers.
    ///
    /// Picking between three names is only a choice if the names mean
    /// something, and "Quick" on its own doesn't say what it skips.
    private var scanKindSummary: String {
        let kind = MalwareScanKind(rawValue: model.settings.lastMalwareScanKind) ?? .quick
        return "\(kind.summary) \(kind.expectedDuration). "
            + "Running a different scan makes that one the new default."
    }

    private func refresh() async {
        probe = await ClamAVService(overridePath: model.settings.clamscanPathOverride).probe()
        access = await Task.detached(priority: .utility) { FullDiskAccess.probe() }.value
    }
}

private struct UpdatesSettingsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdaterController.self) private var updater

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Version", value: updater.versionString)
            if updater.isConfigured {
                Toggle("Check for updates automatically", isOn: $model.settings.automaticUpdateChecks)
                    .onChange(of: model.settings.automaticUpdateChecks) { _, newValue in
                        updater.setAutomaticChecks(newValue)
                    }
                if let date = updater.lastCheckDate {
                    LabeledContent("Last checked", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } else {
                Text("Updates are available in release builds only. This build has no update feed configured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, Theme.Spacing.s)
    }
}
