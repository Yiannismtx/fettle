import SwiftUI
import FettleCore

struct OrganizeView: View {
    @Environment(AppModel.self) private var app
    @State private var model = OrganizeModel()
    @State private var confirming = false

    private var scanContext: ScanContext {
        ScanContext(folder: app.folder, settings: app.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Organize", subtitle: subtitle) {
                Button {
                    model.plan(folder: app.folder, settings: app.settings)
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(model.state == .planning)
                .keyboardShortcut("r", modifiers: .command)
            }

            Divider()

            content
        }
        .task(id: scanContext.organizeKey) {
            model.planIfNeeded(context: scanContext, settings: app.settings)
        }
        .confirmationDialog(
            "Move \(Formatting.count(model.selection.count, singular: "file")) into type folders?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Move Files") { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files move inside \(app.folder.lastPathComponent). Nothing is renamed over anything else — a name that's already taken gets a number.")
        }
    }

    private var subtitle: String {
        if case .ready(let summary) = model.state, summary.total > 0 {
            return "\(Formatting.count(summary.total, singular: "loose file")) to sort into \(FileCategory.allCases.count) type folders"
        }
        return "Sort loose files into Images, Documents, Archives, Installers and Other"
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            EmptyStateView(
                systemImage: "folder.badge.gearshape",
                title: "Ready when you are",
                message: "Fettle will sort the loose files at the top level of \(app.folder.lastPathComponent) into type folders. Nothing moves until you approve the plan.",
                actionTitle: "Scan",
                action: { model.plan(folder: app.folder, settings: app.settings) }
            )
        case .planning:
            VStack(spacing: Theme.Spacing.m) {
                ProgressView()
                Text("Reading \(app.folder.lastPathComponent)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't read that folder",
                message: message,
                actionTitle: "Try Again",
                action: { model.plan(folder: app.folder, settings: app.settings) }
            )
        case .ready(let summary):
            if model.items.isEmpty {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "Nothing loose to sort",
                    message: summary.alreadyOrganized > 0
                        ? "Everything at the top level of \(app.folder.lastPathComponent) is already in a type folder."
                        : "There are no loose files at the top level of \(app.folder.lastPathComponent)."
                )
            } else {
                plan(summary: summary)
            }
        }
    }

    private func plan(summary: OrganizeSummary) -> some View {
        VStack(spacing: 0) {
            // A List with sections, not nested VStacks: it keeps rows lazy, so
            // a folder with hundreds of loose files renders only what's on
            // screen instead of building every row up front.
            List {
                ForEach(FileCategory.allCases, id: \.self) { category in
                    let categoryItems = model.items.filter { $0.category == category }
                    if !categoryItems.isEmpty {
                        Section {
                            ForEach(categoryItems) { item in
                                PlanRow(
                                    item: item,
                                    isSelected: model.selection.contains(item.source),
                                    onToggle: { model.toggle(item.source) }
                                )
                            }
                        } header: {
                            CategoryHeader(
                                category: category,
                                items: categoryItems,
                                allSelected: categoryItems.allSatisfy {
                                    model.selection.contains($0.source)
                                },
                                onToggleAll: { model.toggleCategory(category) }
                            )
                        }
                    }
                }

                if summary.skippedDirectories > 0 {
                    Label(
                        "\(Formatting.count(summary.skippedDirectories, singular: "folder")) left where \(summary.skippedDirectories == 1 ? "it is" : "they are") — Fettle only sorts loose files.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()

            Divider()

            ReviewFooter(
                selectedCount: model.selection.count,
                totalCount: model.items.count,
                selectedBytes: model.selectedBytes,
                actionTitle: "Move Files",
                actionSystemImage: "folder",
                isDestructive: false,
                isBusy: model.isApplying,
                onSelectAll: { model.selectAll() },
                onSelectNone: { model.selectNone() },
                action: { confirming = true }
            )
        }
    }

    private func apply() {
        Task {
            let results = await model.apply()
            app.reportResults(results, verb: "Moved")
        }
    }
}

/// A section header that also acts on the whole section — the control sits
/// next to exactly what it changes.
private struct CategoryHeader: View {
    let category: FileCategory
    let items: [OrganizePlanItem]
    let allSelected: Bool
    let onToggleAll: () -> Void

    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: category.systemImageName)
                .foregroundStyle(Theme.Palette.accent)
            Text(category.folderName)
                .font(.headline)
            Text("\(Formatting.count(items.count, singular: "file")) · \(Formatting.bytes(totalBytes))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Spacing.m)
            Button(allSelected ? "Deselect All" : "Select All", action: onToggleAll)
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

private struct PlanRow: View {
    let item: OrganizePlanItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .labelsHidden()
                .frame(width: 18)
                .accessibilityLabel("Move \(item.name) into \(item.category.folderName)")

            FileIcon(url: item.source, size: 20)

            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)

            if item.willBeRenamed {
                Text("will be renamed")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.caution)
                    .help("A file with this name is already in \(item.category.folderName), so this one gets a number appended.")
            }

            Spacer(minLength: Theme.Spacing.m)

            Text(Formatting.bytes(item.size))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .fileContextMenu(for: [item.source])
    }
}
