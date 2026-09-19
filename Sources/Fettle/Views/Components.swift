import SwiftUI
import FettleCore

/// The transient result banner. Translucent so content stays visible underneath,
/// and it leaves on the same path it arrived on.
struct BannerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let banner = model.banner {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Image(systemName: banner.systemImage)
                        .foregroundStyle(banner.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.title).fontWeight(.medium)
                        if let detail = banner.detail {
                            Text(detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: Theme.Spacing.l)
                    Button {
                        model.banner = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .frame(maxWidth: 520, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.large)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                .padding(.bottom, Theme.Spacing.xl)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        )
                )
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(reduceMotion ? Theme.quickFade : Theme.livelySpring, value: model.banner)
        .onChange(of: model.banner) { _, newValue in
            dismissTask?.cancel()
            guard let newValue else { return }
            dismissTask = Task {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                if model.banner?.id == newValue.id { model.banner = nil }
            }
        }
    }
}

/// Shown when a scan found nothing. Answers "what's here?" and "what now?".
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xxl)
    }
}

/// Page header: title, one line of explanation, and the page's primary action.
struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                    // Large text reads too loose at default tracking.
                    .tracking(-0.3)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.m)
    }
}

/// A progress strip that reports what is happening rather than just spinning.
struct ScanProgressBar: View {
    let progress: Double
    let label: String
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ProgressView(value: progress.isFinite ? min(max(progress, 0), 1) : 0)
                .progressViewStyle(.linear)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 150, alignment: .leading)
                .monospacedDigit()
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.s)
    }
}

/// The bar that sits under every review list: what's selected, what it frees,
/// and the single button that commits the change.
struct ReviewFooter: View {
    let selectedCount: Int
    let totalCount: Int
    let selectedBytes: Int64
    let actionTitle: String
    let actionSystemImage: String
    var isDestructive: Bool = true
    var isBusy: Bool = false
    let onSelectAll: () -> Void
    let onSelectNone: () -> Void
    /// An optional third preset, e.g. "just the ones Fettle is confident about".
    var extraSelection: (title: String, help: String, action: () -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button("All", action: onSelectAll)
                .disabled(selectedCount == totalCount || totalCount == 0)
            Button("None", action: onSelectNone)
                .disabled(selectedCount == 0)
            if let extraSelection {
                Button(extraSelection.title, action: extraSelection.action)
                    .help(extraSelection.help)
                    .disabled(totalCount == 0)
            }

            Divider().frame(height: 16)

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())

            Spacer(minLength: Theme.Spacing.l)

            Button(action: action) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Label(actionTitle, systemImage: actionSystemImage)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .tint(isDestructive ? Theme.Palette.danger : Theme.Palette.accent)
            .disabled(selectedCount == 0 || isBusy)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.m)
        .background(.bar)
        .fettleAnimation(Theme.standardSpring, value: selectedCount)
    }

    private var summary: String {
        guard selectedCount > 0 else { return "Nothing selected" }
        let items = Formatting.count(selectedCount, singular: "item")
        guard selectedBytes > 0 else { return "\(items) selected" }
        return "\(items) selected · \(Formatting.bytes(selectedBytes))"
    }
}

/// The Finder's icon for a file.
///
/// `NSWorkspace.icon(forFile:)` returns a multi-representation image whose
/// nominal size is 32pt; handing that straight to SwiftUI makes it pick a
/// representation for the wrong scale and fall back to the generic document
/// glyph. Setting the size explicitly picks the right rep.
struct FileIcon: View {
    let url: URL
    var size: CGFloat = 22

    var body: some View {
        Image(nsImage: Self.icon(for: url, size: size))
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static func icon(for url: URL, size: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: size, height: size)
        return copy
    }
}

/// Icon + name + path, the row identity used by every review list.
struct FileRowLabel: View {
    let url: URL
    var secondary: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            FileIcon(url: url)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(tint ?? .primary)
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Right-click actions shared by every file row.
    func fileContextMenu(for urls: [URL]) -> some View {
        contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            if urls.count == 1, let url = urls.first {
                Button("Quick Look") { QuickLook.preview(url) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        }
    }
}

