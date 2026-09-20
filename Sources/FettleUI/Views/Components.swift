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

/// A loading indicator that only appears if the wait is long enough to need one.
///
/// Opening a page in Fettle usually resolves in well under a second. A spinner
/// that flashes up for 200ms doesn't read as "loading" — it reads as the window
/// glitching, and it makes a fast app look unsteady. So the indicator is held
/// back until the wait is long enough that silence would be the confusing
/// choice instead.
///
/// This is for work that starts on its own when a page opens. Work the user
/// explicitly asked for — pressing Scan — gets feedback immediately, because
/// there a press with no response reads as a press that didn't land.
struct DelayedProgressView<Content: View>: View {
    /// Long enough that a normal page open never shows a spinner at all.
    var delay: Duration = .seconds(3)
    /// Announced to VoiceOver straight away, whether or not the spinner is up:
    /// the reason for hiding it is visual restlessness, which doesn't apply.
    var accessibilityLabel: String
    @ViewBuilder var content: Content

    @State private var isVisible = false

    var body: some View {
        ZStack {
            if isVisible {
                content.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fettleAnimation(Theme.quickFade, value: isVisible)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isVisible = true
        }
    }
}

/// The standard "this page is still working" state: nothing at all for the
/// first few seconds, then a spinner, a line of explanation and a way out.
struct LoadingIndicator: View {
    let label: String
    var delay: Duration = .seconds(3)
    var onCancel: (() -> Void)?

    var body: some View {
        DelayedProgressView(delay: delay, accessibilityLabel: label) {
            VStack(spacing: Theme.Spacing.m) {
                ProgressView()
                Text(label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let onCancel {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

/// A determinate progress bar with a percentage and a rotating status line.
///
/// Used where the work is long enough that "how much is left?" is the question
/// on the user's mind. The bar goes indeterminate rather than showing a made-up
/// number while the total is still unknown.
struct ScanProgressPanel: View {
    let title: String
    let fraction: Double?
    let percentText: String?
    let status: String
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.l) {
                    Text(title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .tracking(-0.2)
                    Spacer(minLength: 0)
                    if let percentText {
                        // Monospaced digits: proportional ones re-lay-out the
                        // row every time the number ticks over, which reads as
                        // the text twitching.
                        Text(percentText)
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }

                ProgressView(value: fraction)
                    .progressViewStyle(.linear)

                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: 460)
            // The bar eases to each new value instead of jumping, and the
            // status cross-fades. Both are critically damped: nothing here was
            // thrown by a gesture, so nothing should overshoot.
            .fettleAnimation(Theme.standardSpring, value: fraction)
            .fettleAnimation(Theme.quickFade, value: status)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(percentText.map { "\($0). \(status)" } ?? status)

            if let onCancel {
                Button("Cancel", action: onCancel)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xxl)
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

