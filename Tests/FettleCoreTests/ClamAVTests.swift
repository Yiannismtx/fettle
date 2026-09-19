import Testing
import Foundation
@testable import FettleCore

@Suite("clamscan output parsing")
struct ClamAVParsingTests {
    @Test("A FOUND line yields the path and signature")
    func findingLine() {
        let finding = ClamAVService.parseFinding(
            line: "/Users/me/Downloads/bad.exe: Win.Test.EICAR_HDB-1 FOUND"
        )
        #expect(finding?.url.path == "/Users/me/Downloads/bad.exe")
        #expect(finding?.signature == "Win.Test.EICAR_HDB-1")
    }

    @Test("Paths containing a colon still parse")
    func colonInPath() {
        let finding = ClamAVService.parseFinding(
            line: "/Users/me/Downloads/report: final.pdf: Pdf.Exploit.Foo-1 FOUND"
        )
        #expect(finding?.url.lastPathComponent == "report: final.pdf")
        #expect(finding?.signature == "Pdf.Exploit.Foo-1")
    }

    @Test("Clean and summary lines aren't mistaken for findings")
    func nonFindingLines() {
        #expect(ClamAVService.parseFinding(line: "/Users/me/Downloads/ok.txt: OK") == nil)
        #expect(ClamAVService.parseFinding(line: "----------- SCAN SUMMARY -----------") == nil)
        #expect(ClamAVService.parseFinding(line: "Infected files: 1") == nil)
        #expect(ClamAVService.parseFinding(line: "") == nil)
        #expect(ClamAVService.parseFinding(line: "FOUND") == nil)
    }

    @Test("The scanned-file count is read from the summary")
    func scannedCount() {
        #expect(ClamAVService.parseScannedCount(line: "Scanned files: 1234") == 1234)
        #expect(ClamAVService.parseScannedCount(line: "Scanned directories: 12") == nil)
        #expect(ClamAVService.parseScannedCount(line: "Scanned files: not-a-number") == nil)
    }

    @Test("A missing clamscan is reported, not guessed at")
    func missingBinary() async {
        let service = ClamAVService(overridePath: "/tmp/definitely-not-clamscan-\(UUID())")
        #expect(service.locateExecutable() == nil)
        #expect(await service.probe() == .missing)
    }

    @Test("Scanning without clamscan throws a message that says what to install")
    func scanWithoutClamAV() async {
        let service = ClamAVService(overridePath: "/tmp/nope-\(UUID())")
        await #expect(throws: ClamAVError.self) {
            _ = try await service.scan(folder: URL(fileURLWithPath: "/tmp"))
        }
        #expect(
            ClamAVError.notInstalled.errorDescription?.contains("brew install clamav") == true
        )
    }
}

/// Drives the real ClamAVService against a stand-in `clamscan` that prints
/// genuine clamscan-shaped output. ClamAV isn't installed everywhere, and the
/// part of this that can actually be wrong is Fettle's side of the pipe.
@Suite("clamscan integration")
struct ClamAVIntegrationTests {
    private func makeFakeClamscan(
        in folder: TempFolder,
        script: String
    ) throws -> String {
        let url = folder.url.appendingPathComponent("clamscan")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url.path
    }

    @Test("A version probe reports the engine and its signature state")
    func probe() async throws {
        let folder = try TempFolder()
        let path = try makeFakeClamscan(
            in: folder, script: "echo 'ClamAV 1.3.1/27200/Mon Apr 1 09:00:00 2024'"
        )
        let availability = await ClamAVService(overridePath: path).probe()
        guard case .available(let reported, let version, _) = availability else {
            Issue.record("expected available, got \(availability)")
            return
        }
        #expect(reported == path)
        #expect(version.hasPrefix("ClamAV 1.3.1"))
    }

    @Test("A clamscan that can't run is reported as broken, not missing")
    func brokenBinary() async throws {
        let folder = try TempFolder()
        let path = try makeFakeClamscan(
            in: folder, script: "echo 'dyld: library not loaded' >&2\nexit 127"
        )
        let availability = await ClamAVService(overridePath: path).probe()
        guard case .broken = availability else {
            Issue.record("expected broken, got \(availability)")
            return
        }
    }

    @Test("Findings are streamed as they arrive and collected in the report")
    func streamsFindings() async throws {
        let folder = try TempFolder()
        let path = try makeFakeClamscan(in: folder, script: """
            echo "/tmp/a/bad.exe: Win.Test.EICAR_HDB-1 FOUND"
            echo "/tmp/a/worse.js: Js.Trojan.Agent-9 FOUND"
            echo ""
            echo "----------- SCAN SUMMARY -----------"
            echo "Known viruses: 8000000"
            echo "Scanned directories: 3"
            echo "Scanned files: 412"
            echo "Infected files: 2"
            exit 1
            """)

        let streamed = Locked([MalwareFinding]())
        let report = try await ClamAVService(overridePath: path).scan(
            folder: folder.url,
            onProgress: { update in
                if case .found(let finding) = update {
                    streamed.withLock { $0.append(finding) }
                }
            }
        )

        #expect(report.findings.count == 2)
        #expect(report.findings.map(\.signature) == ["Win.Test.EICAR_HDB-1", "Js.Trojan.Agent-9"])
        #expect(report.filesScanned == 412)
        // Exit code 1 means "found something", which is not an error.
        #expect(report.exitCode == 1)
        #expect(!report.hadError)
        #expect(streamed.withLock { $0.count } == 2)
    }

    @Test("A clean scan reports zero findings and exit code 0")
    func cleanScan() async throws {
        let folder = try TempFolder()
        let path = try makeFakeClamscan(in: folder, script: """
            echo "----------- SCAN SUMMARY -----------"
            echo "Scanned files: 7"
            echo "Infected files: 0"
            exit 0
            """)

        let report = try await ClamAVService(overridePath: path).scan(folder: folder.url)
        #expect(report.findings.isEmpty)
        #expect(report.filesScanned == 7)
        #expect(!report.hadError)
    }

    @Test("Exit code 2 is a real error, unlike exit code 1")
    func errorExit() async throws {
        let folder = try TempFolder()
        let path = try makeFakeClamscan(in: folder, script: """
            echo "ERROR: Can't access file" >&2
            exit 2
            """)

        let report = try await ClamAVService(overridePath: path).scan(folder: folder.url)
        #expect(report.hadError)
        #expect(report.errorOutput.contains("Can't access file"))
    }

    @Test("Output larger than the pipe buffer doesn't deadlock")
    func largeOutput() async throws {
        let folder = try TempFolder()
        // Well past the 64 KB pipe buffer: a reader that waits for exit before
        // draining would hang here.
        let path = try makeFakeClamscan(in: folder, script: """
            i=0
            while [ $i -lt 4000 ]; do
              echo "/tmp/file-$i.bin: Test.Signature-$i FOUND"
              i=$((i+1))
            done
            echo "Scanned files: 4000"
            exit 1
            """)

        let report = try await ClamAVService(overridePath: path).scan(folder: folder.url)
        #expect(report.findings.count == 4000)
        #expect(report.filesScanned == 4000)
    }

    @Test("Fettle never hands clamscan a flag that lets it act on a file")
    func neverDelegatesDestruction() async throws {
        let folder = try TempFolder()
        let argsFile = folder.url.appendingPathComponent("args.txt")
        let path = try makeFakeClamscan(
            in: folder, script: "echo \"$@\" > '\(argsFile.path)'\nexit 0"
        )

        _ = try await ClamAVService(overridePath: path).scan(folder: folder.url)
        let args = try String(contentsOf: argsFile, encoding: .utf8)
        #expect(!args.contains("--remove"))
        #expect(!args.contains("--move"))
        #expect(!args.contains("--copy"))
        #expect(args.contains("--infected"))
    }
}

@Suite("Quarantine")
struct QuarantineTests {
    @Test("A quarantined file moves out and leaves a note behind")
    func quarantines() throws {
        let source = try TempFolder()
        let url = try source.write("suspect.bin", contents: "payload")
        let finding = MalwareFinding(url: url, signature: "Win.Test.EICAR_HDB-1")

        let quarantine = Quarantine()
        let result = quarantine.quarantine(finding)
        #expect(result.succeeded)
        #expect(!source.exists("suspect.bin"))

        guard let destination = result.destination else {
            Issue.record("no destination")
            return
        }
        #expect(quarantine.recordedSignature(for: destination) == "Win.Test.EICAR_HDB-1")
        #expect(quarantine.recordedOriginalPath(for: destination) == url.path)

        // A quarantined file can be put back — the user may disagree with ClamAV.
        let restored = quarantine.restore(destination, to: source.url)
        #expect(restored.succeeded)
        #expect(source.exists("suspect.bin"))
        try? FileManager.default.removeItem(at: destination.appendingPathExtension("fettle-quarantine"))
    }

    @Test("Quarantining a file that's already gone reports it")
    func missingFile() throws {
        let source = try TempFolder()
        let finding = MalwareFinding(
            url: source.url.appendingPathComponent("gone.bin"), signature: "Test-1"
        )
        #expect(Quarantine().quarantine(finding).error == .missing)
    }

    @Test("Quarantine lives outside the Trash and outside the scanned folder")
    func location() {
        let path = Quarantine.directory.path
        #expect(path.contains("Application Support/Fettle/Quarantine"))
        #expect(!path.contains(".Trash"))
    }
}
