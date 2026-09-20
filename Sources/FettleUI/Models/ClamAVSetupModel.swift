import Foundation
import Observation
import FettleCore

@MainActor
@Observable
final class ClamAVSetupModel {
    enum Phase: Equatable {
        case idle
        case running(ClamAVInstallStep)
        case finished
        /// Carries the step that failed, so the checklist can mark it rather
        /// than leaving the user to guess which of the three went wrong.
        case failed(step: ClamAVInstallStep?, message: String)
    }

    private(set) var phase: Phase = .idle
    private(set) var readiness = ClamAVInstaller.Readiness(homebrewPath: nil, clamscanPath: nil)
    /// The tail of the install log. Bounded: `brew install` can emit thousands
    /// of lines, and the user only ever looks at the end of it.
    private(set) var log: [LogLine] = []
    private(set) var completedSteps: Set<ClamAVInstallStep> = []

    private var task: Task<Void, Never>?
    private var cancellation: CancellationFlag?

    static let maxLogLines = 400

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let step: ClamAVInstallStep
        let text: String
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func refreshReadiness(clamscanOverride: String) {
        readiness = ClamAVInstaller().readiness(clamscanOverride: clamscanOverride)
    }

    func install() {
        guard !isRunning else { return }
        log = []
        completedSteps = []
        phase = .running(.install)

        let cancellation = CancellationFlag()
        self.cancellation = cancellation

        // The installer reports from a background thread; buffer into a locked
        // box and drain on a timer rather than hopping to the main actor once
        // per line of brew output.
        let pending = Locked([LogLine]())
        let currentStep = Locked(ClamAVInstallStep.install)

        task = Task {
            let ticker = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    self.drain(pending)
                    let step = currentStep.withLock { $0 }
                    if case .running(let shown) = self.phase, shown != step {
                        // Mark everything before the new step, not just the one
                        // on screen: a step can finish inside a single tick —
                        // writing freshclam.conf takes milliseconds — and would
                        // otherwise be left showing as pending forever.
                        self.completeSteps(before: step)
                        self.phase = .running(step)
                    }
                }
            }
            defer { ticker.cancel() }

            do {
                try await ClamAVInstaller().install(
                    onStepStarted: { step in currentStep.withLock { $0 = step } },
                    onOutput: { step, line in
                        guard !line.isEmpty else { return }
                        pending.withLock { $0.append(LogLine(step: step, text: line)) }
                    },
                    isCancelled: { cancellation.isCancelled }
                )
                drain(pending)
                completedSteps = Set(ClamAVInstallStep.allCases)
                phase = .finished
            } catch {
                drain(pending)
                switch error {
                case ClamAVInstallError.cancelled:
                    phase = .idle
                case ClamAVInstallError.stepFailed(let step, let message):
                    phase = .failed(step: step, message: message)
                default:
                    phase = .failed(
                        step: currentStep.withLock { $0 },
                        message: (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    )
                }
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
        cancellation = nil
        task?.cancel()
        task = nil
        if isRunning { phase = .idle }
    }

    #if DEBUG
    /// Exposed so the step bookkeeping can be checked without running a real
    /// install, which would need Homebrew and several minutes.
    func completeStepsForTesting(before step: ClamAVInstallStep) {
        completeSteps(before: step)
    }
    #endif

    /// Mark every step ahead of `step` as done.
    private func completeSteps(before step: ClamAVInstallStep) {
        guard let index = ClamAVInstallStep.allCases.firstIndex(of: step) else { return }
        for earlier in ClamAVInstallStep.allCases.prefix(index) {
            completedSteps.insert(earlier)
        }
    }

    private func drain(_ pending: Locked<[LogLine]>) {
        let new = pending.withLock { lines -> [LogLine] in
            let copy = lines
            lines.removeAll()
            return copy
        }
        guard !new.isEmpty else { return }
        log.append(contentsOf: new)
        if log.count > Self.maxLogLines {
            log.removeFirst(log.count - Self.maxLogLines)
        }
    }
}
