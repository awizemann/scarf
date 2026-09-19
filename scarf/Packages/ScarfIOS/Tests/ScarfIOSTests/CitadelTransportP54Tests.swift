import Testing
import Foundation
@testable import ScarfIOS
import ScarfCore

/// Round-6 P54 — the iOS judged spawns carry `COLUMNS`.
///
/// Scarf judges Hermes runs by matching whole printed LINES. `rich` wraps
/// `console.print` at 80 columns whenever stdout is not a TTY (`Console.width`
/// falls back to `COLUMNS`, then to 80), so an 80-column wrap can split a
/// marker in half. The Mac's two transports have carried a wide `COLUMNS`
/// since P40b — `LocalTransport.subprocessEnvironment` and
/// `SSHTransport.composedRemoteCommand` — and `CitadelServerTransport`, the
/// iOS runtime's exec path, was the third spawn family and the one without.
///
/// Citadel's raw exec channel forwards none of the client's environment, so
/// the value must ride the command's own assignment prefix, exactly as
/// `HERMES_HOME` does.
@Suite("The iOS transport spawns carry a wide COLUMNS (P54)")
struct CitadelTransportColumnsP54Tests {

    private static func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfIOSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfIOS package root
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Comment-only lines dropped: this fix left a comment naming `COLUMNS`
    /// several times, and a raw `contains` would match the prose.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The `asyncRunProcess` region only — the file names `PATH=` twice,
    /// and `_streamScriptImpl`'s copy deliberately has no `COLUMNS`
    /// (see below). Brace-matching would be overkill for a body this
    /// small; slicing from the `func` to the `runExec` call is exact.
    private static func asyncRunProcessBody(_ code: String) throws -> String {
        let start = try #require(code.range(of: "private func asyncRunProcessImpl("))
        let end = try #require(code.range(of: "runExec(cmd, stdin: stdin, timeout: timeout, midStream: .exitMinusOne)",
                                          range: start.upperBound..<code.endIndex))
        return String(code[start.lowerBound..<end.upperBound])
    }

    /// The assignment is built from ``ScarfCore/LocalTransport/wideColumns``
    /// rather than a literal, so the three spawn families cannot drift to
    /// three different widths.
    @Test func asyncRunProcessPrefixesColumnsFromTheSharedConstant() throws {
        let code = Self.codeOnly(try Self.source("Sources/ScarfIOS/CitadelServerTransport.swift"))
        let body = try Self.asyncRunProcessBody(code)
        #expect(body.contains("\"COLUMNS=\\(LocalTransport.wideColumns) \""))
        // A literal width here would be the drift this reads from the shared
        // constant to prevent.
        #expect(!body.contains("COLUMNS=400"))
        // It must come FIRST in the prefix: `sh` reads leading `VAR=value`
        // pairs left to right and stops at the first non-assignment, so
        // `PATH=… COLUMNS=…` would still work but `… hermes COLUMNS=…` would
        // pass the assignment to hermes as an argv token.
        let columns = try #require(body.range(of: "COLUMNS=\\(LocalTransport.wideColumns)"))
        let path = try #require(body.range(of: "PATH=\\\"$HOME/.local/bin"))
        #expect(columns.lowerBound < path.lowerBound)
    }

    /// **The twin walk, written down** (round-6 lesson 3). The file has a
    /// SECOND exec family, `_streamScriptImpl`, with the same `PATH=` guard
    /// and deliberately no `COLUMNS`: it pipes a `/bin/sh` script (sqlite3
    /// `-json`, the bots scan) whose output no verdict matches, and the Mac
    /// twin `SSHTransport.streamScript` carries none either. This pins the
    /// asymmetry as a CHOICE — if a future phase starts judging script
    /// output, this test is what says the decision has to be revisited
    /// rather than the omission simply persisting.
    @Test func theScriptStreamingTwinIsDeliberatelyWithoutColumns() throws {
        let code = Self.codeOnly(try Self.source("Sources/ScarfIOS/CitadelServerTransport.swift"))
        let start = try #require(code.range(of: "private func _streamScriptImpl("))
        // The body runs through `streamScriptCommand(byteCount:)`, which now
        // builds the command (the script itself travels on stdin).
        let end = try #require(code.range(of: #"+ "head -c \(byteCount) | /bin/sh""#,
                                          range: start.upperBound..<code.endIndex))
        let body = String(code[start.lowerBound..<end.upperBound])
        #expect(body.contains("PATH=\\\"$HOME/.local/bin"), "the twin still exists and still guards PATH")
        #expect(!body.contains("COLUMNS"), "if this gained COLUMNS, update the rationale rather than the test")
    }
}
