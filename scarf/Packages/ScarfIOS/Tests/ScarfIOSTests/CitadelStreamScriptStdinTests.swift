import Testing
import Foundation
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
        #expect(code.contains("writer.value.write(ByteBuffer(bytes: stdin))"))
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
        let write = try #require(code.range(of: "writer.value.write(ByteBuffer(bytes: stdin))"))
        let caught = try #require(code.range(of: "writeFailure = error", range: write.upperBound..<code.endIndex))
        let drain = try #require(code.range(of: "Self.drain(", range: caught.upperBound..<code.endIndex))
        let report = try #require(code.range(of: "Failed to send the script over SSH", range: write.upperBound..<code.endIndex))
        #expect(drain.lowerBound < report.lowerBound, "the drain must run before the write error is reported")
        #expect(code.contains("if let writeFailure, result.exitCode == 0, result.stdout.isEmpty, result.stderr.isEmpty"))
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
