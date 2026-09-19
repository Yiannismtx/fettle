import SwiftUI
import FettleCore

struct InstallersView: View {
    @Environment(AppModel.self) private var app
    @State private var model = InstallersModel()
    @State private var confirmingTrash = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Installers",
                subtitle: subtitle
            ) {
                Button {
                    model.scan(folder: app.folder, settings: app.settings)
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(model.state == .scanning)
                .keyboardShortcut("r", modifiers: .command)
            }

            Divider()

            content
        }
        .task(id: app.folder) {
            if case .idle = model.state {
                model.scan(folder: app.folder, settings: app.settings)
            }
        }
        .confirmationDialog(
            "Move \(Formatting.count(model.selection.count, singular: "installer")) to the Trash?",
            isPresented: $confirmingTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll go to the Trash, where you can put them back. Nothing is deleted permanently.")
        }
    }

    private var subtitle: String {
        switch model.state {
        case .loaded(let summary) where summary.total > 0:
            return "\(Formatting.count(summary.total, singular: "installer")) older than \(Formatting.age(days: app.settings.installerAgeThresholdDays)) · \(summary.installedAppCount) apps installed"
        default:
            return "Disk images and packages you've already installed from"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            EmptyStateView(
                systemImage: "shippingbox",
                title: "Ready when you are",
                message: "Fettle will look for .dmg and .pkg files older than \(Formatting.age(days: app.settings.installerAgeThresholdDays)) and check whether the app is already installed.",
                actionTitle: "Scan",
                action: { model.scan(folder: app.folder, settings: app.settings) }
            )
        case .scanning:
            VStack(spacing: Theme.Spacing.m) {
                ProgressView()
                Text("Reading \(app.folder.lastPathComponent) and /Applications…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancelScan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't read that folder",
                message: message,
                actionTitle: "Try Again",
                action: { model.scan(folder: app.folder, settings: app.settings) }
            )
        case .loaded(let summary):
            if model.candidates.isEmpty {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "No dead-weight installers",
                    message: summary.skippedForAge > 0
                        ? "\(Formatting.count(summary.skippedForAge, singular: "installer")) in this folder \(summary.skippedForAge == 1 ? "is" : "are") newer than your \(Formatting.age(days: app.settings.installerAgeThresholdDays)) threshold, so Fettle left \(summary.skippedForAge == 1 ? "it" : "them") alone."
                        : "Nothing in \(app.folder.lastPathComponent) looks like an installer worth clearing out."
                )
            } else {
                list
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Table(model.candidates) {
                TableColumn("") { candidate in
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { model.selection.contains(candidate.url) },
                            set: { _ in model.toggle(candidate.url) }
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("Select \(candidate.entry.name)")
                }
                .width(28)

                TableColumn("Installer") { candidate in
                    FileRowLabel(url: candidate.url, secondary: candidate.reason)
                        .fileContextMenu(for: [candidate.url])
                }
                .width(min: 240, ideal: 340)

                TableColumn("Status") { candidate in
                    MatchBadge(confidence: candidate.matchConfidence)
                }
                .width(min: 110, ideal: 120)

                TableColumn("Size") { candidate in
                    Text(Formatting.bytes(candidate.size))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 72, ideal: 84)
            }
            .tableStyle(.inset)

            Divider()

            ReviewFooter(
                selectedCount: model.selection.count,
                totalCount: model.candidates.count,
                selectedBytes: model.selectedBytes,
                actionTitle: "Move to Trash",
                actionSystemImage: "trash",
                isBusy: model.isApplying,
                onSelectAll: { model.selectAll() },
                onSelectNone: { model.selectNone() },
                extraSelection: (
                    title: "Recommended",
                    help: "Select only the installers whose app Fettle found in /Applications",
                    action: { model.selectRecommended() }
                ),
                action: { confirmingTrash = true }
            )
        }
    }

    private func apply() {
        Task {
            let outcome = await model.trashSelected()
            app.reportResults(outcome.results, verb: "Trashed", freedBytes: outcome.freed)
        }
    }
}

struct MatchBadge: View {
    let confidence: MatchConfidence

    var body: some View {
        Text(confidence.label)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch confidence {
        case .exact, .strong: return Theme.Palette.safe
        case .weak: return Theme.Palette.caution
        case .none: return .secondary
        }
    }
}
