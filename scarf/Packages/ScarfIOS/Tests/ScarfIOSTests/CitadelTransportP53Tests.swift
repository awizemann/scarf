import Testing
import Foundation
import Citadel
import NIOCore
@testable import ScarfIOS

/// Round-6 P53 — the two C10 holes the sweeps could not see, because
/// `scarf/Packages/ScarfIOS/Sources` was in none of their roots.
///
/// Both live in `CitadelServerTransport`, and both are the iOS half of a
/// rule the macOS transport already follows:
///
/// 1. `runSync`'s `semaphore.wait()` had no deadline. Charter C10 says every
///    subprocess has a timeout; this is the one bridge where a remote command
///    could stall a thread forever — and the work it waits on runs on a
///    `Task.detached`, i.e. the cooperative pool, so a caller that is itself
///    on a pool thread blocks one of the few threads the work needs.
/// 2. The exec's timeout arm threw `.timeout(partialStdout: Data())` while
///    the drain task, in the same group, had accumulated the real bytes and
///    built the right error — which `group.cancelAll()` then discarded.
///    `SSHTransport.runLocal`'s timeout arm hands back `drain.collect()`.
@Suite("The iOS transport bounds its wait and keeps its partial output (P53)")
struct CitadelTransportP53Tests {

    private static func transportSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfIOSTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfIOS package root
            .appendingPathComponent("Sources/ScarfIOS/CitadelServerTransport.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Code text with comment-only lines dropped: both fixes left comments
    /// naming the shape they replaced, and a raw `contains` would match those.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - 1. The bridge's wait is bounded

    @Test("`runSync` waits with a deadline, never bare")
    func theSyncBridgeIsBounded() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(!code.contains("semaphore.wait()"), """
            `runSync` is back to an unbounded `semaphore.wait()`. The op it \
            waits on runs on the cooperative pool and the caller's thread is \
            blocked meanwhile, so a connection that never answers is a \
            permanent stall on both sides (charter C10).
            """)
        #expect(code.contains("semaphore.wait(timeout: .now() + deadline)"),
                "the bridge no longer derives its ceiling from the caller's budget")
        #expect(code.contains("deadline: TimeInterval"),
                "`runSync` lost its `deadline` parameter")
        // A parameter that IS the fix gets no default (round-5 lesson 10).
        #expect(!code.contains("deadline: TimeInterval = "),
                "the deadline grew a default — a forgetful caller gets the unbounded bridge back")
    }

    @Test("the process bridge's ceiling outlives the caller's own timeout")
    func theProcessCeilingIsTheCallersBudgetPlusGrace() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(code.contains("runSync(deadline: timeout + Self.syncGrace)"), """
            `runProcess` no longer derives the bridge ceiling from its own \
            timeout. A fixed ceiling below the caller's budget would pre-empt \
            a slow-but-succeeding run.
            """)
        #expect(CitadelServerTransport.syncGrace > 0,
                "the grace is zero — the backstop now races the op it is backing up")
        #expect(CitadelServerTransport.sftpCeiling >= 30,
                "the SFTP ceiling is short enough to fail an ordinary slow round trip")
    }

    @Test("every SFTP verb passes the named ceiling, none is left bare")
    func everySFTPCallSitePassesACeiling() throws {
        let code = Self.codeOnly(try Self.transportSource())
        // Every INVOCATION spells the parameter. `runSync {` (trailing
        // closure, no argument) and `runSync(` without `deadline:` are the
        // two shapes a bare call site can take; the declaration is
        // `runSync<T: Sendable>(`, which matches neither.
        var bare: [String] = []
        for (i, line) in code.components(separatedBy: "\n").enumerated() {
            if line.contains("runSync {") { bare.append("line \(i + 1)") }
            if line.contains("runSync("), !line.contains("runSync(deadline:"),
               !line.contains("runSync<") { bare.append("line \(i + 1)") }
        }
        #expect(bare.isEmpty, Comment(rawValue:
            "a `runSync` call site passes no deadline: \(bare.joined(separator: ", "))"))
        let withDeadline = code.components(separatedBy: "runSync(deadline:").count - 1
        #expect(withDeadline == 8, "expected eight `runSync` call sites, found \(withDeadline)")
    }

    // MARK: - 2. The timeout arm keeps what the drain read

    @Test("the exec timeout reports the drain's partial stdout, not `Data()`")
    func theTimeoutArmReadsTheAccumulator() throws {
        let code = Self.codeOnly(try Self.transportSource())
        #expect(code.contains("partialStdout: partial.bytes()"), """
            The exec timeout arm is back to `partialStdout: Data()`. The \
            drain in the sibling task holds the bytes and `cancelAll()` \
            discards its error, so every iOS timeout would report empty \
            output — `SSHTransport.runLocal`'s timeout arm reports \
            `drain.collect()`.
            """)
        // The drain's own cancellation arm keeps its full local copy: it is
        // the arm that wins when the stream ends, and it is strictly richer.
        #expect(code.contains("throw TransportError.timeout(seconds: timeout, partialStdout: stdout)"),
                "the drain's own cancellation arm stopped carrying its bytes")
    }

    /// The mirror, RUN rather than grepped.
    ///
    /// P53 proved this wiring with `code.contains("partial.append(bytes)")`,
    /// which says nothing about which arm the call sits in: moved into the
    /// `.stderr` arm, or below the loop, the grep still passes and every
    /// timeout still reports empty output. The loop is `absorb`, over any
    /// sequence of chunks, so the real race can be staged: a drain that has
    /// read a chunk and is still waiting, against a budget that wins
    /// (round-6 P53b).
    /// One stdout chunk, then a stream that never finishes — the wedged
    /// remote command the timeout arm exists for.
    private struct OneChunkThenHang: AsyncSequence, Sendable {
        typealias Element = ExecCommandOutput
        static let chunk = "half a JSON payl"
        struct Iterator: AsyncIteratorProtocol {
            var sent = false
            mutating func next() async throws -> ExecCommandOutput? {
                guard sent else {
                    sent = true
                    return .stdout(ByteBuffer(string: OneChunkThenHang.chunk))
                }
                // Hang until cancelled, in short ticks: a single long
                // `Task.sleep` is the fixed-sleep shape
                // `HermesP38SourceSweepTests` sweeps for.
                while true { try await Task.sleep(nanoseconds: 10_000_000) }
            }
        }
        func makeAsyncIterator() -> Iterator { Iterator() }
    }

    @Test("when the budget wins, the timeout arm sees what the drain read")
    func theBudgetArmSeesThePartialStdout() async {
        let partial = PartialStdout()
        let sawBudget: Bool = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await CitadelServerTransport.absorb(
                    OneChunkThenHang(), timeout: 0.2,
                    midStream: .typedError, partial: partial)
                return false
            }
            group.addTask {
                // The budget arm, as `runProcess` spells it.
                try? await Task.sleep(nanoseconds: 200_000_000)
                return true
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(sawBudget, "the drain finished first — the race did not stage")
        #expect(String(data: partial.bytes(), encoding: .utf8) == OneChunkThenHang.chunk, """
            The budget arm cannot see the bytes the drain already read, so \
            `TransportError.timeout(partialStdout:)` would carry `Data()` — \
            the exact defect P53 fixed, back again.
            """)
    }

    @Test("the accumulator survives concurrent appends and reads")
    func theAccumulatorIsThreadSafe() async {
        let partial = PartialStdout()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask {
                    partial.append(Data([UInt8(i % 256)]))
                    _ = partial.bytes()
                }
            }
        }
        #expect(partial.bytes().count == 64,
                "the accumulator lost or duplicated bytes under concurrent appends")
    }

    @Test("an empty accumulator reads as empty, not as a crash")
    func theAccumulatorStartsEmpty() {
        #expect(PartialStdout().bytes().isEmpty)
    }
}
