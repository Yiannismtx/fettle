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
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
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
        environment: [String: String]? = nil,
        mergeStandardError: Bool = false,
        onStandardOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        // Tools that narrate their progress — brew and freshclam both do — write
        // much of it to stderr. When the caller is showing that narration to the
        // user, both streams have to arrive interleaved in the order they were
        // written, which means one pipe.
        let errPipe = mergeStandardError ? outPipe : Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // Read stdout to EOF on a background queue rather than through
        // `readabilityHandler`. The handler fires concurrently, so tearing it
        // down at exit races with an invocation already in flight and silently
        // loses output — which only shows up once a scan produces more than a
        // pipe buffer's worth of findings.
        let handle = outPipe.fileHandleForReading
        async let streamed: Void = withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var pending = Data()
                while true {
                    guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty
                    else { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let lineData = pending[pending.startIndex..<newline]
                        pending.removeSubrange(pending.startIndex...newline)
                        let line = String(decoding: lineData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !line.isEmpty { onStandardOutputLine(line) }
                    }
                }
                // Whatever's left after EOF without a trailing newline.
                let tail = String(decoding: pending, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { onStandardOutputLine(tail) }
                continuation.resume()
            }
        }

        async let errData: Data = mergeStandardError ? Data() : readToEnd(errPipe)

        await withTaskCancellationHandler {
            await waitForExit(process)
        } onCancel: {
            process.terminate()
        }

        // Wait for the reader to reach EOF, not just for the process to exit:
        // output written just before exit is still in the pipe.
        await streamed

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
