import SwiftUI
import FettleCore

struct DuplicatesView: View {
    @Environment(AppModel.self) private var app
    @State private var model = DuplicatesModel()
    @State private var confirmingTrash = false

    private var scanContext: ScanContext {
        ScanContext(folder: app.folder, settings: app.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Duplicates", subtitle: subtitle) {
                Button {
                    model.scan(folder: app.folder, settings: app.settings)
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(isScanning)
                .keyboardShortcut("r", modifiers: .command)
            }

            Divider()

            content
        }
        .task(id: scanContext.duplicateKey) {
            model.scanIfNeeded(context: scanContext, settings: app.settings)
        }
        .confirmationDialog(
            "Move \(Formatting.count(model.selection.count, singular: "duplicate")) to the Trash?",
            isPresented: $confirmingTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One copy of each file stays exactly where it is. The rest go to the Trash, where you can put them back.")
        }
    }

    private var isScanning: Bool {
        if case .scanning = model.state { return true }
        return false
    }

    private var subtitle: String {
        if case .loaded(let summary) = model.state, summary.groupCount > 0 {
            return "\(Formatting.count(summary.groupCount, singular: "set")) of identical files · \(Formatting.bytes(summary.reclaimableBytes)) reclaimable"
        }
        return "Matched by SHA-256 content hash, not by filename"
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            EmptyStateView(
                systemImage: "doc.on.doc",
                title: "Ready when you are",
                message: "Fettle compares file contents, so it finds identical files even when they're named differently. Large folders are hashed in the background.",
                actionTitle: "Scan",
                action: { model.scan(folder: app.folder, settings: app.settings) }
            )
        case .scanning(let progress):
            VStack(spacing: Theme.Spacing.l) {
                Spacer()
                ProgressView(value: progress.fraction) {
                    Text(progress.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 420)
                Button("Cancel") { model.cancelScan() }
                Spacer()
            }
            .padding(Theme.Spacing.xxl)
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
            if model.groups.isEmpty {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "No duplicates",
                    message: "Fettle compared \(Formatting.count(summary.filesConsidered, singular: "file")) and found no two with identical contents."
                )
            } else {
                list
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(model.groups) { group in
                        DuplicateGroupCard(
                            group: group,
                            isExpanded: model.expandedGroups.contains(group.contentHash),
                            isSelected: { model.selection.contains($0) },
                            onToggleExpansion: { model.toggleExpansion(group.contentHash) },
                            onToggle: { model.toggle($0) },
                            onKeepInstead: { model.keepInstead($0, in: group) }
                        )
                    }
                }
                .padding(Theme.Spacing.l)
            }

            Divider()

            ReviewFooter(
                selectedCount: model.selection.count,
                totalCount: model.selectableCount,
                selectedBytes: model.selectedBytes,
                actionTitle: "Move to Trash",
                actionSystemImage: "trash",
                isBusy: model.isApplying,
                onSelectAll: { model.selectAll() },
                onSelectNone: { model.selectNone() },
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

/// One set of identical files: the copy being kept, then the copies on offer.
private struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    let isExpanded: Bool
    let isSelected: (URL) -> Bool
    let onToggleExpansion: () -> Void
    let onToggle: (URL) -> Void
    let onKeepInstead: (FileEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleExpansion) {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    FileIcon(url: group.original.url, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.original.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(Formatting.count(group.totalCount, singular: "copy", plural: "copies")) · \(Formatting.bytes(group.fileSize)) each")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Spacing.m)
                    Text("Frees \(Formatting.bytes(group.reclaimableBytes))")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.Spacing.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(group.original.name), \(group.totalCount) identical copies, \(Formatting.bytes(group.fileSize)) each"
            )
            .accessibilityHint(isExpanded ? "Collapse this set" : "Expand this set")

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    KeptRow(entry: group.original)
                    ForEach(group.duplicates) { duplicate in
                        Divider().padding(.leading, Theme.Spacing.xl)
                        DuplicateRow(
                            entry: duplicate,
                            isSelected: isSelected(duplicate.url),
                            onToggle: { onToggle(duplicate.url) },
                            onKeepInstead: { onKeepInstead(duplicate) }
                        )
                    }
                }
                .transition(.opacity)
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .fettleAnimation(Theme.standardSpring, value: isExpanded)
    }
}

private struct KeptRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(Theme.Palette.safe)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Keeping this one — oldest copy, \(entry.url.deletingLastPathComponent().lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .fileContextMenu(for: [entry.url])
    }
}

private struct DuplicateRow: View {
    let entry: FileEntry
    let isSelected: Bool
    let onToggle: () -> Void
    let onKeepInstead: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .labelsHidden()
                .frame(width: 18)
                .accessibilityLabel("Trash \(entry.name)")
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Theme.Spacing.m)
            Button("Keep This Instead", action: onKeepInstead)
                .buttonStyle(.link)
                .font(.callout)
                .help("Keep this copy and offer the current one for trashing instead")
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .fileContextMenu(for: [entry.url])
    }
}
