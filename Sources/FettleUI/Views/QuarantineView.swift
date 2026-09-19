import SwiftUI
import FettleCore

/// The quarantine folder, with a way back out of it.
///
/// Quarantining is the most consequential thing Fettle does, and a signature
/// match isn't proof. Without somewhere to undo it, a false positive would
/// leave a file the user cares about stranded in a folder they'd have to find
/// in the Finder.
struct QuarantineView: View {
    @Environment(AppModel.self) private var app
    @State private var model = QuarantineModel()

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Quarantine",
                subtitle: model.items.isEmpty
                    ? "Files moved aside by a malware scan"
                    : "\(Formatting.count(model.items.count, singular: "file")) held in \(Quarantine.directory.lastPathComponent)"
            ) {
                Button {
                    NSWorkspace.shared.open(Quarantine.directory)
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .disabled(model.items.isEmpty)
            }

            Divider()

            if model.isLoading && model.items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                EmptyStateView(
                    systemImage: "lock.open.rotation",
                    title: "Nothing in quarantine",
                    message: "Files flagged by a malware scan end up here, with a note saying what matched. Nothing is deleted — you can always put a file back."
                )
            } else {
                List(model.items) { item in
                    QuarantinedRow(
                        item: item,
                        onRestore: { restore(item) },
                        onTrash: { trash(item) }
                    )
                }
                .listStyle(.inset)
                .disabled(model.isApplying)
            }
        }
        .task { await model.load() }
    }

    private func restore(_ item: QuarantinedItem) {
        if let directory = item.originalDirectory,
           FileManager.default.fileExists(atPath: directory.path) {
            perform(item, to: directory)
        } else {
            // The original folder is gone, or the note is missing. Ask rather
            // than picking somewhere on the user's behalf.
            FolderPicker.choose(startingAt: app.folder) { perform(item, to: $0) }
        }
    }

    private func perform(_ item: QuarantinedItem, to directory: URL) {
        Task {
            let result = await model.restore(item, to: directory)
            if result.succeeded {
                app.show(
                    AppModel.Banner(
                        kind: .success,
                        title: "Put \(item.entry.name) back.",
                        detail: directory.path
                    )
                )
            } else {
                app.show(
                    AppModel.Banner(
                        kind: .failure,
                        title: "Couldn't restore \(item.entry.name).",
                        detail: result.error?.description
                    )
                )
            }
        }
    }

    private func trash(_ item: QuarantinedItem) {
        Task {
            let result = await model.trash(item)
            app.reportResults([result], verb: "Trashed")
        }
    }
}

private struct QuarantinedRow: View {
    let item: QuarantinedItem
    let onRestore: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            FileIcon(url: item.entry.url, size: 22, wantsThumbnail: false)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.originalPath ?? "Original location unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: Theme.Spacing.m)

            if let signature = item.signature {
                Text(signature)
                    .font(.caption.monospaced())
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, 3)
                    .background(Theme.Palette.danger.opacity(0.15), in: Capsule())
                    .foregroundStyle(Theme.Palette.danger)
                    .textSelection(.enabled)
            }

            Button("Put Back", action: onRestore)
                .help("Move this file back to where it came from")
            Button {
                onTrash()
            } label: {
                Image(systemName: "trash")
            }
            .help("Move this file to the Trash")
            .accessibilityLabel("Move \(item.entry.name) to the Trash")
        }
        .padding(.vertical, 2)
        .fileContextMenu(for: [item.entry.url])
    }
}
