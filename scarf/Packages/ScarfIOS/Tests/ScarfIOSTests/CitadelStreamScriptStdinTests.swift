import Testing
import Foundation
import ScarfCore
@testable import ScarfIOS

/// `CitadelServerTransport.streamScript` sends the script on the exec
/// channel's stdin, never in argv. The base64-in-argv form it replaced left
/// the whole script — for Live Voice, the SDP offer with its ICE credentials
/// and DTLS fingerprint — readable in the host's `ps` for up to 45 s.
@Suite("iOS streamScript keeps the script out of argv")
struct CitadelStreamScriptStdinTests {

    @Test func theCommandCarriesOnlyTheByteCount() {
        let command = CitadelServerTransport.streamScriptCommand(byteCount: 6269)
        #expect(command == #"PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" head -c 6269 | /bin/sh"#)
    }

    /// Code-only scan (comments dropped), the P53 convention: the stdin path
    /// is what `_streamScriptImpl` uses, and no script bytes are encoded into
    /// the command anywhere in the transport.
    @Test func streamScriptWritesTheScriptToStdin() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ScarfIOS/CitadelServerTransport.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("Self.streamScriptCommand(byteCount: scriptBytes.count)"))
        #expect(code.contains("runScript(cmd, stdin: scriptBytes, timeout: timeout)"))
        #expect(code.contains("Self.writeStdin(stdin) { chunk in"))
        #expect(code.contains("writer.value.write(ByteBuffer(bytes: chunk))"))
        #expect(!code.contains("base64EncodedString()"))
        #expect(!code.contains("base64 -d"))
    }

    /// A failed stdin write (the remote already exited — e.g. a login shell
    /// that rejected the command) must not hide the remote's exit status and
    /// stderr: the drain still runs, and the write error is reported only
    /// when the drain has nothing. Code scan (no fake SSH channel exists).
    @Test func aFailedWriteStillDrainsTheRemotesAnswer() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ScarfIOS/CitadelServerTransport.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // The write's error is parked in the shared box by its own task, and
        // only the drain arm — which has already run by then — reports it.
        let caught = try #require(code.range(of: "catch { writeFailure.record(error) }"))
        let drain = try #require(code.range(of: "let result = try await drain()", range: caught.upperBound..<code.endIndex))
        let report = try #require(code.range(of: "Failed to send the script over SSH", range: drain.upperBound..<code.endIndex))
        #expect(drain.lowerBound < report.lowerBound, "the drain must run before the write error is reported")
        #expect(code.contains("if let failure = writeFailure.error, result.exitCode == 0,"))
    }

    #if os(macOS)
    /// The remote half, run locally: Citadel can't send EOF on the channel,
    /// so the command must finish WITHOUT stdin ever closing. `head -c`
    /// reads exactly the script and hands `sh` its EOF; the heredoc and
    /// quoting inside arrive intact. The test keeps stdin OPEN throughout.
    @Test func headDashCRunsTheScriptWithoutAnEOFOnTheChannel() throws {
        let script = """
        printf 'line one\\n'
        cat <<'SCARF_JSON'
        {"sdp":"v=0\\r\\n","q":"it's"}
        SCARF_JSON
        echo "$((6 * 7))"
        """
        let bytes = Data(script.utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CitadelServerTransport.streamScriptCommand(byteCount: bytes.count)]
        let input = Pipe()
        let outputFile = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-headc-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputFile) }
        let output = try FileHandle(forWritingTo: outputFile)
        defer { try? output.close() }
        process.standardInput = input
        process.standardOutput = output
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        input.fileHandleForWriting.write(bytes)          // and never close it
        let finished = done.wait(timeout: .now() + 10) == .success
        if !finished { process.terminate() }
        try? input.fileHandleForWriting.close()
        #expect(finished, "the script must finish while stdin is still open")
        let printed = try String(contentsOf: outputFile, encoding: .utf8)
        #expect(printed == "line one\n{\"sdp\":\"v=0\\r\\n\",\"q\":\"it's\"}\n42\n")
        #expect(process.terminationStatus == 0)
    }
    #endif
}

/// The stdin write, the drain and the timeout budget run CONCURRENTLY
/// (`execArms`). The write used to sit at the head of the drain's own task:
/// the drain couldn't start until it finished, and because NIO's
/// `writeAndFlush` ignores cancellation, a write parked on a full channel
/// window held the task group open past the deadline — charter C10 says
/// every subprocess has a timeout that can actually fire.
@Suite("iOS exec: stdin write, drain and timeout run concurrently")
struct CitadelExecStdinConcurrencyTests {

    /// Stands in for a `writeAndFlush` parked on a full channel window:
    /// it ignores cancellation (`Task.sleep` would not — it throws), so a
    /// structure that awaits the write is held for the whole 3 s.
    private static func park() async {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline { await Task.yield() }
    }

    /// The drain's answer arrives while the write is still parked.
    @Test func theDrainStartsBeforeTheStdinWriteCompletes() async throws {
        let started = Date()
        let result = try await CitadelServerTransport.execArms(
            writeStdin: { await Self.park() },
            drain: { ProcessResult(exitCode: 0, stdout: Data("ok".utf8), stderr: Data()) },
            timeout: 30
        )
        #expect(String(data: try #require(result).stdout, encoding: .utf8) == "ok")
        #expect(Date().timeIntervalSince(started) < 1, "the drain waited for the stdin write to finish")
    }

    /// A write parked past the deadline must not outlive the budget.
    @Test func aStalledWriteDoesNotPreventTheTimeoutFromFiring() async throws {
        let started = Date()
        let result = try await CitadelServerTransport.execArms(
            writeStdin: { await Self.park() },
            drain: {
                // A cancellable read loop that never sees EOF, like the
                // real drain; the write is what cancellation can't reach.
                for _ in 0..<50 { try await Task.sleep(nanoseconds: 100_000_000) }
                return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
            },
            timeout: 0.2
        )
        #expect(result == nil, "the budget arm must win")
        #expect(Date().timeIntervalSince(started) < 1, "a parked write held the group past the timeout")
    }

    /// The write error is reported only when the drain came back with
    /// nothing — the remote's own exit status and stderr are the better
    /// diagnosis (kept from the pre-split behaviour).
    @Test func aFailedWriteIsReportedOnlyWhenTheDrainSaidNothing() async throws {
        struct Broken: Error {}
        let answered = try await CitadelServerTransport.execArms(
            writeStdin: { throw Broken() },
            drain: {
                try await Task.sleep(nanoseconds: 20_000_000)
                return ProcessResult(exitCode: 127, stdout: Data(), stderr: Data("no such command\n".utf8))
            },
            timeout: 30
        )
        #expect(answered?.exitCode == 127)

        await #expect(throws: TransportError.self) {
            _ = try await CitadelServerTransport.execArms(
                writeStdin: { throw Broken() },
                drain: {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
                },
                timeout: 30
            )
        }
    }

    /// The write goes out in chunks and gives cancellation a look in
    /// between, so a cancelled exec stops feeding a remote that stopped
    /// reading instead of parking on one huge `writeAndFlush`.
    @Test func theStdinWriteIsChunkedAndCancellableBetweenChunks() async throws {
        let payload = Data(repeating: 0x61, count: 40)
        let chunks = Chunks()
        try await CitadelServerTransport.writeStdin(payload, chunkSize: 16) { chunk in
            chunks.add(chunk.count)
        }
        #expect(chunks.sizes == [16, 16, 8])

        // A cancelled write stops at the next chunk boundary.
        let seen = Chunks()
        let task = Task {
            try await CitadelServerTransport.writeStdin(payload, chunkSize: 16) { chunk in
                seen.add(chunk.count)
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(seen.sizes == [16], "the write kept going after cancellation")
    }

    private final class Chunks: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Int] = []
        func add(_ size: Int) { lock.lock(); stored.append(size); lock.unlock() }
        var sizes: [Int] { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
