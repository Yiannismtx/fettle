import SwiftUI
import FettleCore

/// Shown when ClamAV isn't usable.
///
/// The spec accepts a one-time Homebrew dependency rather than bundling a
/// 100 MB+ engine (§3.4). That leaves the user with a terminal errand, so this
/// screen does it for them where it legitimately can: with Homebrew present,
/// installing ClamAV is one button and a live log. Where it can't — Homebrew's
/// own installer needs an admin password, which it must ask for itself — it
/// says so plainly and hands over exact, copyable commands.
struct ClamAVSetupView: View {
    /// Non-nil when clamscan was found but wouldn't run.
    let brokenReason: String?
    let clamscanOverride: String
    /// Owned by the parent. An install runs for minutes, and a model held as
    /// this view's own `@State` would be thrown away — losing the running
    /// install and its log — any time the parent rebuilt this branch.
    let model: ClamAVSetupModel
    let onFinished: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header

                if model.readiness.hasHomebrew {
                    automaticInstall
                } else {
                    homebrewMissing
                }

                ManualInstructions(
                    prefix: model.readiness.homebrewPath.map {
                        Homebrew(executablePath: $0).prefix
                    } ?? "/opt/homebrew"
                )
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { model.refreshReadiness(clamscanOverride: clamscanOverride) }
        .onChange(of: model.phase) { _, phase in
            if case .finished = phase { onFinished() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: "shield.slash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(brokenReason == nil ? "ClamAV isn't installed" : "ClamAV isn't working")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .tracking(-0.3)
                    Text("Fettle doesn't write its own detection engine — it uses ClamAV's.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let brokenReason {
                Text(brokenReason)
                    .font(.callout)
                    .foregroundStyle(Theme.Palette.caution)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - The button

    private var automaticInstall: some View {
        SetupCard(
            title: "Install it for me",
            subtitle: "Fettle runs the three commands below through Homebrew and shows you the output as it goes."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(ClamAVInstallStep.allCases, id: \.self) { step in
                    StepRow(
                        step: step,
                        state: state(for: step)
                    )
                }

                if case .failed(_, let message) = model.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.Palette.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .finished = model.phase {
                    Label("ClamAV is ready. You can scan now.", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(Theme.Palette.safe)
                }

                if !model.log.isEmpty {
                    InstallLogView(lines: model.log)
                }

                HStack(spacing: Theme.Spacing.m) {
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                        Text("This takes a few minutes. You can keep using the rest of Fettle.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Theme.Spacing.m)
                        Button("Cancel") { model.cancel() }
                    } else if model.phase != .finished {
                        // Nothing to offer once it has worked — the page is
                        // about to be replaced by the scan UI.
                        Button {
                            model.install()
                        } label: {
                            Label(
                                model.phase == .idle ? "Install ClamAV" : "Try Again",
                                systemImage: "arrow.down.circle"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.readiness.hasClamAV && model.phase == .idle)

                        if model.readiness.hasClamAV {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text("Already installed — if the scan still can't find it, re-check from Settings › Scanning.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                SettingsLink {
                                    Label("Open Settings", systemImage: "gearshape")
                                }
                                .controlSize(.small)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func state(for step: ClamAVInstallStep) -> StepRow.State {
        if case .failed(let failedStep, _) = model.phase, failedStep == step { return .failed }
        if model.completedSteps.contains(step) { return .done }
        if case .running(let current) = model.phase, current == step { return .running }
        return .waiting
    }

    // MARK: - No Homebrew

    private var homebrewMissing: some View {
        SetupCard(
            title: "Homebrew isn't installed",
            subtitle: "Fettle can install ClamAV for you, but not Homebrew itself: Homebrew's installer needs your administrator password, and it has to ask you for that directly rather than through another app."
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Paste this into Terminal, then come back and press Check Again:")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                CommandRow(
                    command: #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
                    note: "the official Homebrew installer"
                )

                Text("Homebrew will also print two commands to add it to your PATH — run those before coming back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: Theme.Spacing.m) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                    } label: {
                        Label("Open brew.sh", systemImage: "safari")
                    }
                    Button {
                        openTerminal()
                    } label: {
                        Label("Open Terminal", systemImage: "terminal")
                    }
                    Spacer(minLength: 0)
                    Button("Check Again") {
                        model.refreshReadiness(clamscanOverride: clamscanOverride)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func openTerminal() {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminal, configuration: .init())
    }
}

// MARK: - Pieces

private struct SetupCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
        }
    }
}

private struct StepRow: View {
    enum State { case waiting, running, done, failed }

    let step: ClamAVInstallStep
    let state: State

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s) {
            Group {
                switch state {
                case .waiting:
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                case .running:
                    ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Palette.safe)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.danger)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .fontWeight(state == .running ? .semibold : .regular)
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .fettleAnimation(Theme.standardSpring, value: state)
    }
}

/// The tail of the install output, pinned to the bottom as it grows.
private struct InstallLogView: View {
    let lines: [ClamAVSetupModel.LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(Theme.Spacing.s)
            }
            .frame(height: 160)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .onChange(of: lines.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .accessibilityLabel("Install output")
        }
    }
}

/// Everything the automatic path does, spelled out — for anyone who'd rather
/// run it themselves, or needs to debug it when it goes wrong.
private struct ManualInstructions: View {
    let prefix: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Step(number: 1, title: "Install the engine") {
                    CommandRow(command: "brew install clamav", note: "a few hundred MB")
                }

                Step(
                    number: 2,
                    title: "Create freshclam.conf",
                    note: "Homebrew only installs a sample. freshclam refuses to start without the real file — this is the usual reason a fresh install seems broken."
                ) {
                    CommandRow(
                        command: "cp \(prefix)/etc/clamav/freshclam.conf.sample \(prefix)/etc/clamav/freshclam.conf",
                        note: "copy the sample"
                    )
                    CommandRow(
                        command: "sed -i '' 's/^Example$/# Example/' \(prefix)/etc/clamav/freshclam.conf",
                        note: "comment out the Example line"
                    )
                }

                Step(
                    number: 3,
                    title: "Download the signatures",
                    note: "Without a signature database the scan runs but matches nothing. Re-run this occasionally; Fettle warns when the database is over a week old."
                ) {
                    CommandRow(command: "freshclam", note: "fetches the database")
                }

                Step(
                    number: 4,
                    title: "Point Fettle at it, if needed",
                    note: "Fettle looks in \(prefix)/bin and the other standard locations. If your clamscan lives somewhere else, paste the path into Settings › Scanning."
                ) {
                    CommandRow(command: "which clamscan", note: "prints the path to use")
                    // A step that ends by naming a window the reader has no way
                    // to open is a step that doesn't finish.
                    SettingsLink {
                        Label("Open Settings › Scanning", systemImage: "gearshape")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.top, Theme.Spacing.s)
        } label: {
            Text("Do it manually instead")
                .font(.headline)
        }
    }

    private struct Step<Content: View>: View {
        let number: Int
        let title: String
        var note: String?
        @ViewBuilder var content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    Text("\(number)")
                        .font(.caption.weight(.bold))
                        .frame(width: 18, height: 18)
                        .background(.quaternary, in: Circle())
                    Text(title)
                        .fontWeight(.medium)
                }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 26)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    content
                }
                .padding(.leading, 26)
            }
        }
    }
}

/// A command with a copy button. Selectable as well as copyable, because a
/// command you can't select is a command you have to retype.
///
/// The note sits under the command rather than beside it: some of these
/// commands are a full line long, and a side-by-side note gets squeezed into a
/// one-character column.
struct CommandRow: View {
    let command: String
    let note: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.s)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "Copied" : "Copy \(command)")
            .fettleAnimation(Theme.standardSpring, value: copied)
        }
    }
}
