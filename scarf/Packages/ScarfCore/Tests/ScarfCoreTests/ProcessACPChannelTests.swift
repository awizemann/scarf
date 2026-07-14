#if !os(iOS)

import Testing
import Foundation
@testable import ScarfCore

/// Real-subprocess coverage for `ProcessACPChannel`'s reader path
/// (t-5451bd1b sub-fix c). The channel's blocking `availableData`
/// loops were reworked onto `DispatchSourceRead` (see `PipeLineReader`)
/// so live channels no longer park two cooperative-pool threads each;
/// these tests pin the framing semantics the rework must preserve:
/// `\n` line splitting, empty-line skipping, EOF → stream finish,
/// stderr capture, trailing-partial-line drop, and stop-mid-read.
///
/// Uses `/bin/sh` and `/bin/cat` — local, harmless, and deterministic.
@Suite struct ProcessACPChannelTests {

    /// Drain a stream to completion, bounded by `timeout` so a broken
    /// EOF path fails the test instead of hanging the suite.
    private static func collect(
        _ stream: AsyncThrowingStream<String, Error>,
        timeout: TimeInterval = 10
    ) async throws -> [String] {
        let collector = Task { () -> [String] in
            var lines: [String] = []
            for try await line in stream { lines.append(line) }
            return lines
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            collector.cancel()
        }
        defer { watchdog.cancel() }
        return try await collector.value
    }

    private static func shChannel(_ script: String) async throws -> ProcessACPChannel {
        try await ProcessACPChannel(
            executable: "/bin/sh",
            args: ["-c", script],
            env: [:]
        )
    }

    // MARK: - Line framing

    @Test func splitsLinesAndSkipsEmptyOnes() async throws {
        let ch = try await Self.shChannel(#"printf 'one\ntwo\n\nthree\n'"#)
        let lines = try await Self.collect(ch.incoming)
        #expect(lines == ["one", "two", "three"])
        await ch.close()
    }

    @Test func trailingPartialLineWithoutNewlineIsDropped() async throws {
        // Matches the pre-rework loop reader: a final unterminated
        // fragment is never yielded.
        let ch = try await Self.shChannel(#"printf 'full\npartial-without-newline'"#)
        let lines = try await Self.collect(ch.incoming)
        #expect(lines == ["full"])
        await ch.close()
    }

    // MARK: - Large frames (past the 64KB pipe buffer)

    @Test func largeSingleFrameRoundTripsThroughCat() async throws {
        let ch = try await ProcessACPChannel(
            executable: "/bin/cat",
            args: [],
            env: [:]
        )
        // > 64KB in one frame: exceeds the kernel pipe buffer in both
        // directions, so this exercises partial writes (send's POSIX
        // write loop) AND multi-chunk reads reassembling one line.
        let payload = String(repeating: "x", count: 300_000)
        try await ch.send(payload)

        var iterator = ch.incoming.makeAsyncIterator()
        let echoTask = Task { try await iterator.next() }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            echoTask.cancel()
        }
        let echoed = try await echoTask.value
        watchdog.cancel()
        #expect(echoed == payload)
        await ch.close()
    }

    // MARK: - stdout / stderr interleaving

    @Test func stderrIsCapturedSeparatelyFromStdout() async throws {
        let ch = try await Self.shChannel(
            "echo o1; echo e1 1>&2; echo o2; echo e2 1>&2"
        )
        let out = try await Self.collect(ch.incoming)
        let err = try await Self.collect(ch.stderr)
        #expect(out == ["o1", "o2"])
        #expect(err == ["e1", "e2"])
        await ch.close()
    }

    // MARK: - EOF

    @Test func childExitFinishesBothStreams() async throws {
        let ch = try await Self.shChannel("echo done")
        let out = try await Self.collect(ch.incoming)
        #expect(out == ["done"])
        // stderr must ALSO finish (child gone → write ends closed),
        // not just stdout. collect() would throw/hang-cancel otherwise.
        let err = try await Self.collect(ch.stderr)
        #expect(err.isEmpty)
        await ch.close()
    }

    // MARK: - Stop mid-read

    @Test func closeMidReadFinishesStreamsAndRejectsWrites() async throws {
        // /bin/cat stays alive until stdin EOF — the channel is
        // mid-conversation when we close it.
        let ch = try await ProcessACPChannel(
            executable: "/bin/cat",
            args: [],
            env: [:]
        )
        try await ch.send("hello")

        var iterator = ch.incoming.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == "hello")

        await ch.close()

        // The stream must finish (nil), not hang, after close.
        let drainTask = Task { try await iterator.next() }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            drainTask.cancel()
        }
        let rest = try? await drainTask.value
        watchdog.cancel()
        #expect(rest == nil)

        // Writes after close throw writeEndClosed.
        do {
            try await ch.send("too late")
            Issue.record("expected writeEndClosed after close()")
        } catch let error as ACPChannelError {
            if case .writeEndClosed = error {} else {
                Issue.record("expected .writeEndClosed, got \(error)")
            }
        }
    }
}

#endif // !os(iOS)
