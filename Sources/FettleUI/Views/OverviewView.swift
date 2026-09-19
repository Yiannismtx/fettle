import SwiftUI
import FettleCore

struct OverviewView: View {
    @Environment(AppModel.self) private var app
    @State private var model = OverviewModel()

    private var scanContext: ScanContext {
        ScanContext(
            folder: app.folder,
            settings: app.settings,
            revision: app.folderRevision
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Overview", subtitle: app.folder.path) {
                Button {
                    model.load(folder: app.folder, settings: app.settings)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.state == .loading)
                .keyboardShortcut("r", modifiers: .command)
            }

            Divider()

            content
        }
        .task(id: scanContext.overviewKey) {
            model.loadIfNeeded(context: scanContext, settings: app.settings)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            VStack(spacing: Theme.Spacing.m) {
                ProgressView()
                Text("Reading \(app.folder.lastPathComponent)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't read that folder",
                message: message,
                actionTitle: "Choose a Different Folder",
                action: {
                    FolderPicker.choose(startingAt: app.folder) { app.chooseFolder($0) }
                }
            )
        case .loaded(let box):
            summary(box.summary)
        }
    }

    private func summary(_ summary: FolderSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if app.folderIsStale {
                    Label(
                        "Fettle couldn't find the folder you chose, so it's showing this one instead.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(Theme.Palette.caution)
                }

                HStack(spacing: Theme.Spacing.m) {
                    StatTile(
                        value: Formatting.bytes(summary.totalBytes),
                        label: "in \(Formatting.count(summary.fileCount, singular: "file"))",
                        systemImage: "internaldrive"
                    )
                    StatTile(
                        value: "\(summary.looseFileCount)",
                        label: summary.looseFileCount == 1 ? "loose file" : "loose files",
                        systemImage: "tray.full"
                    )
                    StatTile(
                        value: "\(summary.folderCount)",
                        label: summary.folderCount == 1 ? "subfolder" : "subfolders",
                        systemImage: "folder"
                    )
                }

                if !summary.breakdown.isEmpty {
                    SectionCard(title: "What's in here") {
                        BreakdownBar(breakdown: summary.breakdown, total: summary.totalBytes)
                    }
                }

                SectionCard(title: "Worth a look") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SuggestionRow(
                            systemImage: Destination.installers.systemImage,
                            title: summary.agedInstallerCount > 0
                                ? (app.settings.installerAgeThresholdDays > 0
                                    ? "\(Formatting.count(summary.agedInstallerCount, singular: "installer")) older than \(Formatting.age(days: app.settings.installerAgeThresholdDays))"
                                    : Formatting.count(summary.agedInstallerCount, singular: "installer"))
                                : "No aging installers",
                            detail: summary.agedInstallerCount > 0
                                ? "\(Formatting.bytes(summary.agedInstallerBytes)) — Fettle can check which apps are already installed."
                                : "Nothing past your age threshold.",
                            isActionable: summary.agedInstallerCount > 0,
                            action: { app.selection = .installers }
                        )
                        Divider()
                        SuggestionRow(
                            systemImage: Destination.duplicates.systemImage,
                            title: "Check for duplicates",
                            detail: "Compares file contents, so it catches identical files saved under different names.",
                            isActionable: summary.fileCount > 1,
                            action: { app.selection = .duplicates }
                        )
                        Divider()
                        SuggestionRow(
                            systemImage: Destination.organize.systemImage,
                            title: summary.looseFileCount > 0
                                ? "\(Formatting.count(summary.looseFileCount, singular: "loose file")) to sort"
                                : "Nothing loose to sort",
                            detail: "Sorts into Images, Documents, Archives, Installers and Other.",
                            isActionable: summary.looseFileCount > 0,
                            action: { app.selection = .organize }
                        )
                        if model.quarantinedCount > 0 {
                            Divider()
                            SuggestionRow(
                                systemImage: "lock.shield",
                                title: "\(Formatting.count(model.quarantinedCount, singular: "file")) in quarantine",
                                detail: "Moved aside by a malware scan. You can put any of them back.",
                                isActionable: true,
                                action: { app.selection = .quarantine }
                            )
                        }
                    }
                }

                HStack(alignment: .top, spacing: Theme.Spacing.l) {
                    if !summary.largestFiles.isEmpty {
                        SectionCard(title: "Largest files") {
                            FileHighlightList(
                                entries: summary.largestFiles,
                                detail: { Formatting.bytes($0.size) }
                            )
                        }
                    }
                    if !summary.oldestFiles.isEmpty {
                        SectionCard(title: "Longest sitting there") {
                            FileHighlightList(
                                entries: summary.oldestFiles,
                                detail: { Formatting.age(days: $0.ageInDays()) }
                            )
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .monospacedDigit()
                // Large numbers read too loose at default tracking.
                .tracking(-0.4)
                .contentTransition(.numericText())
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(.headline)
            content
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
        }
    }
}

/// A proportional bar plus a legend. The bar answers "what's taking the space";
/// the legend answers "how much, exactly".
private struct BreakdownBar: View {
    let breakdown: [FolderSummary.CategoryBreakdown]
    let total: Int64

    private func color(for category: FileCategory) -> Color {
        switch category {
        case .images: return .blue
        case .documents: return .teal
        case .archives: return .purple
        case .installers: return .orange
        case .other: return .gray
        }
    }

    private func fraction(_ bytes: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(bytes) / Double(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(breakdown) { item in
                        color(for: item.category)
                            .frame(width: max(2, geometry.size.width * fraction(item.bytes)))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            .accessibilityHidden(true)

            // Wraps rather than truncating, so a narrow window doesn't hide a row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.l) { legendItems }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) { legendItems }
            }
        }
    }

    @ViewBuilder
    private var legendItems: some View {
        ForEach(breakdown) { item in
            HStack(spacing: Theme.Spacing.xs) {
                Circle()
                    .fill(color(for: item.category))
                    .frame(width: 8, height: 8)
                Text(item.category.folderName)
                    .font(.callout)
                Text(Formatting.bytes(item.bytes))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(item.category.folderName): \(Formatting.count(item.count, singular: "file")), \(Formatting.bytes(item.bytes))"
            )
        }
    }
}

private struct SuggestionRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let isActionable: Bool
    var actionLabel: String = "Open"
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .frame(width: 20)
                .foregroundStyle(isActionable ? Theme.Palette.accent : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.m)
            Button(actionLabel, action: action)
                .disabled(!isActionable)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

private struct FileHighlightList: View {
    let entries: [FileEntry]
    let detail: (FileEntry) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(entries) { entry in
                HStack(spacing: Theme.Spacing.s) {
                    FileIcon(url: entry.url, size: 18)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.Spacing.m)
                    Text(detail(entry))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .fileContextMenu(for: [entry.url])
            }
        }
    }
}
