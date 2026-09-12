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
        #expect(code.contains("client.withExec(cmd)"))
        let opened = try #require(code.range(of: "client.withExec(cmd)"))
        let tail = String(code[opened.upperBound...])
        let thrown = try #require(
            tail.range(of: "throw TransportError.timeout(seconds: timeout"),
            "the timeout no longer throws out of the withExec closure")
        let closureEnd = try #require(tail.range(of: "\n        }"),
                                      "could not find the end of the withExec closure")
        #expect(thrown.lowerBound < closureEnd.lowerBound,
                "the timeout throw escaped the withExec closure — the channel is abandoned again")
    }

    /// Both execs share the one drain now: a fix applied to one arm of a
    /// two-arm family and not the other is the round-4 lesson this round keeps
    /// re-learning.
    @Test("both execs go through the single drain")
    func bothExecsShareTheDrain() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(code.contains("runExec(cmd, timeout: timeout, midStream: .typedError)"))
        #expect(code.contains("runExec(cmd, timeout: timeout, midStream: .exitMinusOne)"))
    }
}
