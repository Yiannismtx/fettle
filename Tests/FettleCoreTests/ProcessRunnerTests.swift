import Testing
import Foundation
@testable import FettleCore

@Suite("Streaming a child process")
struct ProcessStreamingTests {
    private func makeScript(in folder: TempFolder, _ body: String) throws -> String {
        let url = folder.url.appendingPathComponent("script")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url.path
    }

    @Test("A terminal delivers lines while the child is still running")
    func streamsBeforeExit() async throws {
        let folder = try TempFolder()
        // Without a terminal, a C program's stdio holds this until exit. The
        // shell flushes per line either way, but the read side is the part
        // being checked: lines must surface before the process is done.
        let path = try makeScript(in: folder, """
            echo "first"
            sleep 3
            echo "second"
            """)

        let firstLineAt = Locked<Date?>(nil)
        let result = try await Process.runStreaming(
            executable: path,
            arguments: [],
            usePseudoTerminal: true,
            onStandardOutputLine: { line in
                guard line == "first" else { return }
                firstLineAt.withLock { $0 = Date() }
            }
        )
        let finishedAt = Date()

        #expect(result.exitCode == 0)
        guard let arrived = firstLineAt.withLock({ $0 }) else {
            Issue.record("the first line never arrived")
            return
        }
        // Measured backwards from the end rather than forwards from the start:
        // how long the child took to launch varies with what else the machine
        // is doing, but the gap it sleeps for does not.
        let lead = finishedAt.timeIntervalSince(arrived)
        #expect(lead > 2, "the first line only arrived \(lead)s before the process exited")
    }

    @Test("Carriage-return updates arrive as separate lines")
    func carriageReturnsAreLineBreaks() async throws {
        let folder = try TempFolder()
        // A progress bar redraws in place with \r and never emits a newline
        // until it's finished. Each redraw is an update worth seeing.
        let path = try makeScript(in: folder, """
            printf 'Loading: 1\\rLoading: 2\\rLoading: 3\\n'
            """)

        let lines = Locked([String]())
        _ = try await Process.runStreaming(
            executable: path,
            arguments: [],
            usePseudoTerminal: true,
            onStandardOutputLine: { line in lines.withLock { $0.append(line) } }
        )
        #expect(lines.withLock { $0 } == ["Loading: 1", "Loading: 2", "Loading: 3"])
    }

    @Test("Terminal escape sequences are stripped, the text is kept")
    func stripsEscapes() {
        #expect(
            Process.stripTerminalEscapes("\u{1B}[?7lLoading: 5\u{1B}[?7h") == "Loading: 5"
        )
        #expect(Process.stripTerminalEscapes("\u{1B}[31mred\u{1B}[0m text") == "red text")
        // Nothing to strip is the common case and must come back untouched.
        #expect(Process.stripTerminalEscapes("/tmp/a.txt: OK") == "/tmp/a.txt: OK")
    }

    @Test("A terminal doesn't mangle the output of a normal run")
    func outputIsIntactThroughATerminal() async throws {
        let folder = try TempFolder()
        let path = try makeScript(in: folder, """
            i=0
            while [ $i -lt 500 ]; do
              echo "/some/path/with spaces/file-$i.bin: OK"
              i=$((i+1))
            done
            exit 3
            """)

        let lines = Locked([String]())
        let result = try await Process.runStreaming(
            executable: path,
            arguments: [],
            usePseudoTerminal: true,
            onStandardOutputLine: { line in lines.withLock { $0.append(line) } }
        )

        let collected = lines.withLock { $0 }
        #expect(collected.count == 500)
        #expect(collected.first == "/some/path/with spaces/file-0.bin: OK")
        #expect(collected.last == "/some/path/with spaces/file-499.bin: OK")
        // The exit code still has to come back through, terminal or not.
        #expect(result.exitCode == 3)
    }
}
