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
    ///
    /// `usePseudoTerminal` decides *when* those lines arrive, and for some
    /// tools that is the difference between progress and no progress at all.
    /// A C program writing to a pipe gets block buffering from stdio: it
    /// accumulates output and flushes it when the buffer fills or the process
    /// exits. clamscan is one of these — piped, a thirteen-second scan delivers
    /// every one of its lines in the last few milliseconds, which is useless
    /// for a progress bar. Handing it a terminal instead switches stdio to line
    /// buffering, and the lines arrive as the work happens.
    ///
    /// The cost is that a tool talking to a terminal may also draw for one:
    /// carriage returns and ANSI escapes. Both are dealt with here, so the
    /// caller still sees one clean line per update.
    public static func runStreaming(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        mergeStandardError: Bool = false,
        usePseudoTerminal: Bool = false,
        onStandardOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.notExecutable(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        // The end we read from, and — with a terminal — the end the child
        // writes to, which the parent has to close itself.
        let readHandle: FileHandle
        var childWriteEnd: FileHandle?
        let outPipe = Pipe()

        if usePseudoTerminal {
            var parentFD: Int32 = 0
            var childFD: Int32 = 0
            // A wide terminal: a tool that fits its output to the window would
            // otherwise truncate the file paths we need to parse.
            var size = winsize(ws_row: 24, ws_col: 1000, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&parentFD, &childFD, nil, nil, &size) == 0 else {
                throw ProcessRunnerError.launchFailed("Couldn't allocate a terminal for \(executable).")
            }
            readHandle = FileHandle(fileDescriptor: parentFD, closeOnDealloc: true)
            let writeEnd = FileHandle(fileDescriptor: childFD, closeOnDealloc: false)
            childWriteEnd = writeEnd
            process.standardOutput = writeEnd
        } else {
            readHandle = outPipe.fileHandleForReading
            process.standardOutput = outPipe
        }

        // Tools that narrate their progress — brew and freshclam both do — write
        // much of it to stderr. When the caller is showing that narration to the
        // user, both streams have to arrive interleaved in the order they were
        // written, which means one destination.
        let errPipe = Pipe()
        if mergeStandardError {
            process.standardError = childWriteEnd ?? outPipe
        } else {
            process.standardError = errPipe
        }
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            if let childWriteEnd { close(childWriteEnd.fileDescriptor) }
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        // The child has its own copy now. Until the parent's copy is closed the
        // terminal never reaches end-of-file, and the reader below never stops.
        if let childWriteEnd { close(childWriteEnd.fileDescriptor) }

        // Read stdout to EOF on a background queue rather than through
        // `readabilityHandler`. The handler fires concurrently, so tearing it
        // down at exit races with an invocation already in flight and silently
        // loses output — which only shows up once a scan produces more than a
        // pipe buffer's worth of findings.
        //
        // The read itself is `read(2)` rather than `FileHandle.read(upToCount:)`
        // because the latter keeps reading until it has the full count or hits
        // end-of-file. That turns a live stream back into one delivery at exit,
        // which is exactly what the terminal above is here to avoid.
        //
        // The dispatch happens here, synchronously, rather than from inside an
        // `async let`. A child task only starts when the cooperative pool has a
        // thread for it, and under load — a test suite running in parallel, say
        // — that can be after the child process has already finished, which
        // collapses the stream back into one delivery at the end.
        let descriptor = readHandle.fileDescriptor
        let keepAlive = readHandle
        let splitOnCarriageReturn = usePseudoTerminal
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            func isBreak(_ byte: UInt8) -> Bool {
                byte == UInt8(ascii: "\n")
                    || (splitOnCarriageReturn && byte == UInt8(ascii: "\r"))
            }
            func emit(_ data: Data) {
                var line = String(decoding: data, as: UTF8.self)
                if splitOnCarriageReturn { line = stripTerminalEscapes(line) }
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { onStandardOutputLine(line) }
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            reading: while true {
                let count = buffer.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                if count < 0 {
                    // A terminal reports the child's exit as a read error
                    // rather than a clean end-of-file; anything else that
                    // isn't a signal interrupting us is equally final.
                    if errno == EINTR { continue reading }
                    break reading
                }
                if count == 0 { break reading }
                pending.append(contentsOf: buffer[0..<count])
                while let newline = pending.firstIndex(where: isBreak) {
                    emit(pending[pending.startIndex..<newline])
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            // Whatever's left after EOF without a trailing newline.
            emit(pending)
            // Keeps the handle — and so the descriptor — alive for as long as
            // the loop above is using it.
            _ = keepAlive
            readerFinished.signal()
        }

        async let errData: Data = mergeStandardError ? Data() : readToEnd(errPipe)

        await withTaskCancellationHandler {
            await waitForExit(process)
        } onCancel: {
            process.terminate()
        }

        // Wait for the reader to reach EOF, not just for the process to exit:
        // output written just before exit is still in the pipe.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                readerFinished.wait()
                continuation.resume()
            }
        }

        let err = await errData
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: "",
            standardError: String(decoding: err, as: UTF8.self)
        )
    }

    /// Drop ANSI control sequences — colour, cursor moves, the line-wrap
    /// toggles a progress bar puts around itself — leaving the text.
    static func stripTerminalEscapes(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        var output = ""
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            guard character == "\u{1B}" else {
                output.append(character)
                continue
            }
            // CSI: ESC [ parameters, then one letter that ends the sequence.
            guard let next = iterator.next() else { break }
            if next == "[" {
                while let parameter = iterator.next() {
                    if parameter.isLetter { break }
                }
            }
        }
        return output
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
