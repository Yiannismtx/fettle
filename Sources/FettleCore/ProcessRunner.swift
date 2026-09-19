import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
}

public enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case notExecutable(String)
    case launchFailed(String)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .notExecutable(let path): return "\(path) isn't an executable file."
        case .launchFailed(let message): return message
        case .timedOut(let seconds): return "The command didn't finish within \(Int(seconds))s."
        }
    }
}

extension Process {
    /// Run a command to completion and capture both streams.
    ///
    /// Reads both pipes concurrently: a command that fills the 64KB pipe buffer
    /// on one stream while the reader waits on the other would otherwise deadlock.
    public static func runCapturing(
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        async let outData = readToEnd(outPipe)
        async let errData = readToEnd(errPipe)

        if let timeout {
            let watchdog = Task {
                try await Task.sleep(for: .seconds(timeout))
                if process.isRunning { process.terminate() }
            }
            defer { watchdog.cancel() }
            await waitForExit(process)
        } else {
            await waitForExit(process)
        }

        let out = await outData
        let err = await errData
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: out, as: UTF8.self),
            standardError: String(decoding: err, as: UTF8.self)
        )
    }

    /// Run a command, delivering stdout a line at a time as it arrives.
    ///
    /// Cancelling the surrounding task terminates the child process, so a long
    /// scan stops when the user asks it to.
    public static func runStreaming(
        executable: String,
        arguments: [String],
        onStandardOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let buffer = Locked(Data())
        let handle = outPipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let chunk = fileHandle.availableData
            guard !chunk.isEmpty else { return }
            let lines: [String] = buffer.withLock { pending in
                pending.append(chunk)
                var out: [String] = []
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    out.append(
                        String(decoding: lineData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                return out
            }
            for line in lines { onStandardOutputLine(line) }
        }

        async let errData = readToEnd(errPipe)

        await withTaskCancellationHandler {
            await waitForExit(process)
        } onCancel: {
            process.terminate()
        }

        // Drain whatever arrived between the last readability callback and exit.
        handle.readabilityHandler = nil
        if let remainder = try? handle.readToEnd(), !remainder.isEmpty {
            buffer.withLock { $0.append(remainder) }
        }
        let tail = buffer.withLock { pending -> [String] in
            let text = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        for line in tail { onStandardOutputLine(line) }

        let err = await errData
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: "",
            standardError: String(decoding: err, as: UTF8.self)
        )
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            let resumed = Locked(false)
            process.terminationHandler = { _ in
                let shouldResume = resumed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                if shouldResume { continuation.resume() }
            }
            // A process that exited before the handler was installed never fires it.
            if !process.isRunning {
                let shouldResume = resumed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                if shouldResume { continuation.resume() }
            }
        }
    }
}
