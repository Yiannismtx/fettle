import Foundation

/// An explicit cancellation flag shared with a detached task.
///
/// Scans run on `Task.detached` so they don't inherit the caller's actor, but a
/// detached task is not a child either — cancelling the task that spawned it
/// does nothing. This flag is the channel that actually stops the work.
public final class CancellationFlag: @unchecked Sendable {
    private var cancelled = false
    private let lock = NSLock()

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}
