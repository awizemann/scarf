import Testing
import Foundation

/// Round-5 P48b — the iOS remote exec must CLOSE its channel on a timeout.
///
/// P48 gave both `CitadelServerTransport` execs a ceiling, but the ceiling was
/// raced OUTSIDE the stream: `executeCommandStream` returns only the
/// `AsyncThrowingStream` and discards the `Channel` Citadel created for it
/// (`Sources/Citadel/TTY/Client/TTY.swift:269-339`), and that stream installs
/// no `onTermination` — so cancelling the reading task stopped the READER and
/// left the remote command and its SSH channel running until the command ended
/// on its own. One orphan per timed-out call, on the exact host that has
/// stopped answering.
///
/// `withExec` is the public API that owns the channel and closes it when its
/// closure returns OR throws. There is no in-process double for a live SSH
/// channel, so what is pinned is the shape: the drain goes through `withExec`,
/// and the timeout arm THROWS from inside it (returning would close the
/// channel too, but would also report a success the caller does not have).
@Suite("The iOS exec drain closes its channel (P48b)")
struct CitadelExecChannelP48bTests {

    private static func transportSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfIOSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfIOS package root
            .appendingPathComponent("Sources/ScarfIOS/CitadelServerTransport.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Code text with comment-only lines dropped — the fix left a comment
    /// naming the call it removed, and a raw `contains` would match that.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                      && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
    }

    @Test("no exec drives the channel-discarding executeCommandStream")
    func noRawExecuteCommandStream() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(!code.contains("executeCommandStream("), """
            A remote exec is back on `executeCommandStream`, which discards the \
            channel: its timeout can only abandon the remote command, not end it.
            """)
    }

    @Test("the drain runs inside withExec and the timeout throws out of it")
    func theTimeoutThrowsFromInsideWithExec() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(code.contains("client.withExecTolerantClose(cmd)"))
        // BRACE-MATCHED, not line-sliced. This read the literal
        // `throw TransportError.timeout(seconds: timeout` and the end of the
        // closure as a newline plus exactly eight spaces — so wrapping the
        // throw across two lines (round-6 P53 gave it a partial-stdout
        // argument) made the `#require` find the DRAIN's throw instead, far
        // past the closure, and the test failed on a formatting change rather
        // than on the property it names.
        let opened = try #require(code.range(of: "client.withExecTolerantClose(cmd)"))
        let chars = Array(code[opened.upperBound...])
        let open = try #require(chars.firstIndex(of: "{"), "the withExec closure is gone")
        var depth = 0
        var body = ""
        var i = open
        while i < chars.count {
            if chars[i] == "{" { depth += 1 }
            if chars[i] == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            body.append(chars[i])
            i += 1
        }
        #expect(depth == 0, "the withExec closure never closes — the slice is wrong")
        #expect(body.contains("throw TransportError.timeout(") , """
            The timeout no longer throws from INSIDE the withExec closure. \
            Returning, or throwing outside it, abandons the channel again.
            """)
    }

    /// Both execs share the one drain now: a fix applied to one arm of a
    /// two-arm family and not the other is the round-4 lesson this round keeps
    /// re-learning.
    @Test("both execs go through the single drain")
    func bothExecsShareTheDrain() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(code.contains("runExec(cmd, stdin: stdin, timeout: timeout, midStream: .typedError)"))
        // `asyncRunProcessImpl`'s exec now forwards its own `stdin` too
        // (t-c7a7b1d4) — `runProcess`/`asyncRunProcess` no longer reject a
        // non-nil `stdin`, they plumb it through this same call.
        #expect(code.contains("runExec(cmd, stdin: stdin, timeout: timeout, midStream: .exitMinusOne)"))
    }
}
