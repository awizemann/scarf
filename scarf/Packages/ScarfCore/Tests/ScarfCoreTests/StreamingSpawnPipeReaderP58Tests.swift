#if !os(iOS)
import Testing
import Foundation
@testable import ScarfCore

/// Round-6 P58 (decision 10) — the four streaming spawns read their child's
/// stdout with a `DispatchSourceRead`, not with a blocking loop on the
/// cooperative pool.
///
/// The shape being retired is
/// `Task.detached { while true { handle.availableData } }`: a blocking
/// `read(2)` that holds one of the pool's per-core threads for the whole life
/// of the stream. `HermesLogService` streams `tail -F`, which never ends, so
/// one open Logs pane held one thread forever and a few of them starved every
/// other task in the process — charter C10, and the same mechanism as the
/// 2026-07-13 "Loading session…" wedge that moved `ProcessACPChannel` off the
/// loop in the first place.
@Suite("Streaming spawns read off the cooperative pool (P58)")
struct StreamingSpawnPipeReaderP58Tests {

    // MARK: - The primitive

    /// The streaming-transport framing: blank lines are LINES.
    ///
    /// P58 hoisted this primitive out of `ProcessACPChannel` and carried ACP's
    /// `guard !lineData.isEmpty else { continue }` with it, which silently
    /// deleted every blank separator line from the Logs pane — the only
    /// consumer of `streamLines`. `skipEmpty` is per caller for the same
    /// reason `deliverPartialAtEOF` is.
    @Test("lines arrive, split on newline, with blank lines preserved")
    func linesArrive() async throws {
        let pipe = Pipe()
        let inbox = EventInbox()
        let reader = PipeReader(
            handle: pipe.fileHandleForReading,
            label: "test.lines",
            framing: .lines(
                failOnInvalidUTF8: false, deliverPartialAtEOF: true, skipEmpty: false),
            sink: { inbox.append($0) }
        )
        try pipe.fileHandleForWriting.write(contentsOf: Data("alpha\n\nbeta\n".utf8))
        try #require(inbox.waitForLines(3), "reader never delivered all three lines")
        #expect(inbox.lines == ["alpha", "", "beta"])
        reader.cancel()
        _ = inbox.waitForFinish()
    }

    /// ACP's framing, pinned: an empty JSON-RPC frame is nothing, so the
    /// shared primitive must keep skipping blank lines for ACP even though
    /// the transports now keep them.
    @Test("ACP framing still skips empty frames")
    func acpFramingSkipsEmptyFrames() async throws {
        let pipe = Pipe()
        let inbox = EventInbox()
        let reader = PipeReader(
            handle: pipe.fileHandleForReading,
            label: "test.acp-empty",
            framing: .lines(
                failOnInvalidUTF8: true, deliverPartialAtEOF: false, skipEmpty: true),
            sink: { inbox.append($0) }
        )
        try pipe.fileHandleForWriting.write(contentsOf: Data("alpha\n\nbeta\n".utf8))
        try #require(inbox.waitForLines(2), "reader never delivered both frames")
        PipeReaderTestSupport.settle(0.2) // a third line would have landed by now
        #expect(inbox.lines == ["alpha", "beta"])
        reader.cancel()
        _ = inbox.waitForFinish()
    }

    /// A blank line at EOF with no trailing newline is still nothing to
    /// flush: an empty buffer is not a partial line. Guards the interaction
    /// between the two flags.
    @Test("a trailing newline leaves no partial line to flush")
    func trailingNewlineLeavesNoPartial() async throws {
        let pipe = Pipe()
        let inbox = EventInbox()
        let reader = PipeReader(
            handle: pipe.fileHandleForReading,
            label: "test.blank-eof",
            framing: .lines(
                failOnInvalidUTF8: false, deliverPartialAtEOF: true, skipEmpty: false),
            sink: { inbox.append($0) }
        )
        try pipe.fileHandleForWriting.write(contentsOf: Data("alpha\n\n".utf8))
        try pipe.fileHandleForWriting.close()
        try #require(inbox.waitForFinish(), "reader never finished")
        #expect(inbox.lines == ["alpha", ""])
        withExtendedLifetime(reader) {}
    }

    /// The one semantic this port CHANGES, deliberately. The loop it replaces
    /// dropped whatever sat in its buffer at EOF, so a child whose last line
    /// carried no trailing newline lost it — user-visible output, silently
    /// gone. ACP keeps the old behaviour (`deliverPartialAtEOF: false`),
    /// because half a JSON-RPC frame is not a frame.
    @Test("a trailing unterminated line is delivered at EOF")
    func partialLineIsDeliveredAtEOF() async throws {
        let pipe = Pipe()
        let inbox = EventInbox()
        let reader = PipeReader(
            handle: pipe.fileHandleForReading,
            label: "test.partial",
            framing: .lines(
                failOnInvalidUTF8: false, deliverPartialAtEOF: true, skipEmpty: false),
            sink: { inbox.append($0) }
        )
        try pipe.fileHandleForWriting.write(contentsOf: Data("done\nhalf".utf8))
        try pipe.fileHandleForWriting.close() // EOF
        try #require(inbox.waitForFinish(), "reader never finished")
        #expect(inbox.lines == ["done", "half"])
        withExtendedLifetime(reader) {}
    }

    /// ACP's framing, pinned here so the shared primitive cannot drift into
    /// delivering ACP a half-frame.
    @Test("ACP framing drops the trailing unterminated line")
    func acpFramingDropsThePartialLine() async throws {
        let pipe = Pipe()
        let inbox = EventInbox()
        let reader = PipeReader(
            handle: pipe.fileHandleForReading,
            label: "test.acp-partial",
            framing: .lines(
                failOnInvalidUTF8: true, deliverPartialAtEOF: false, skipEmpty: true),
            sink: { inbox.append($0) }
        )
        try pipe.fileHandleForWriting.write(contentsOf: Data("done\nhalf".utf8))
        try pipe.fileHandleForWriting.close()
        try #require(inbox.waitForFinish(), "reader never finished")
        #expect(inbox.lines == ["done"])
        withExtendedLifetime(reader) {}
    }

    @Test("raw framing yields bytes verbatim with no newline framing")
    func rawChunksAreVerbatim() async throws {
        let pipe = Pipe()
        let inbox = EventInbox()
        let reader = PipeReader(
            handle: pipe.fileHandleForReading,
            label: "test.raw",
            framing: .rawChunks,
            sink: { inbox.append($0) }
        )
        try pipe.fileHandleForWriting.write(contentsOf: Data([0x00, 0x0A, 0xFF]))
        try pipe.fileHandleForWriting.close()
        try #require(inbox.waitForFinish(), "reader never finished")
        #expect(inbox.chunkBytes == [0x00, 0x0A, 0xFF])
        #expect(inbox.lines.isEmpty)
        withExtendedLifetime(reader) {}
    }

    /// `cancel()` must both stop the source and hand the descriptor back.
    ///
    /// The fd is closed in the cancel handler and nowhere else, and
    /// `.finished` is emitted AFTER that close in the same handler — so
    /// observing `.finished` is what proves the handler ran, and the
    /// descriptor check below can be made after it without a window.
    ///
    /// **`errno == EBADF` alone would be a load flake**, and was measured as
    /// one: this suite's own park test opens dozens of pipes at once, the
    /// process reuses the lowest free descriptor number immediately, and a
    /// recycled number is a perfectly valid fd (round-5 P48's `/dev/fd`
    /// lesson, one layer down). So the assertion is the one that survives
    /// recycling: the number must no longer name OUR pipe — either it is
    /// closed, or `fstat` reports a different file.
    @Test("cancel closes the descriptor and finishes exactly once")
    func cancelClosesTheDescriptor() async throws {
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        var before = stat()
        try #require(fstat(fd, &before) == 0, "the read end should start open")
        let inbox = EventInbox()
        let reader = PipeReader(
            handle: pipe.fileHandleForReading,
            label: "test.cancel",
            framing: .lines(
                failOnInvalidUTF8: false, deliverPartialAtEOF: true, skipEmpty: false),
            sink: { inbox.append($0) }
        )
        reader.cancel()
        reader.cancel() // idempotent
        try #require(inbox.waitForFinish(), "cancel never delivered .finished")
        #expect(inbox.finishCount == 1, "`.finished` is delivered exactly once")
        var after = stat()
        let stillOpen = fstat(fd, &after) == 0
        let sameFile = stillOpen && after.st_ino == before.st_ino && after.st_dev == before.st_dev
        #expect(!sameFile,
                "fd \(fd) still names the reader's pipe — the cancel handler did not close it")
        try? pipe.fileHandleForWriting.close()
    }

    // MARK: - The transports

    @Test("LocalTransport.streamLines yields the child's lines")
    func localStreamLinesYieldsLines() async throws {
        var got: [String] = []
        for try await line in LocalTransport().streamLines(
            executable: "/bin/sh", args: ["-c", "printf 'one\\ntwo\\n'"]
        ) {
            got.append(line)
        }
        #expect(got == ["one", "two"])
    }

    @Test("LocalTransport.streamLines delivers the child's last unterminated line")
    func localStreamLinesDeliversPartialTail() async throws {
        var got: [String] = []
        for try await line in LocalTransport().streamLines(
            executable: "/bin/sh", args: ["-c", "printf 'one\\ntwo'"]
        ) {
            got.append(line)
        }
        #expect(got == ["one", "two"])
    }

    /// The Logs-pane regression itself, end to end. `printf 'a\n\nb\n'`
    /// yielded `["a", "", "b"]` before P58 and `["a", "b"]` after it.
    @Test("LocalTransport.streamLines preserves the child's blank lines")
    func localStreamLinesPreservesBlankLines() async throws {
        var got: [String] = []
        for try await line in LocalTransport().streamLines(
            executable: "/bin/sh", args: ["-c", "printf 'a\\n\\nb\\n'"]
        ) {
            got.append(line)
        }
        #expect(got == ["a", "", "b"])
    }

    /// `SSHTransport.streamLines` needs a reachable host, so its half of the
    /// same claim is asserted at the source: both streaming transports must
    /// spell `skipEmpty: false`, and nothing but `acpLines` may spell `true`.
    /// Round-6 lesson 3 — when a fix lands on one member of a family, the
    /// siblings are walked before the commit.
    @Test("both streaming transports ask for blank lines; only ACP skips them")
    func bothStreamingTransportsKeepBlankLines() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/ScarfCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/ScarfCore
            .appendingPathComponent("Sources/ScarfCore")
        for name in ["Transport/LocalTransport.swift", "Transport/SSHTransport.swift"] {
            let text = try String(
                contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains("skipEmpty: false"), """
                \(name) does not state `skipEmpty: false` for its                 `streamLines` framing — its Logs-pane consumer loses every                 blank line.
                """)
            #expect(!text.contains("skipEmpty: true"), "\(name) skips blank lines")
        }
        let reader = try String(
            contentsOf: sources.appendingPathComponent("Transport/PipeReader.swift"),
            encoding: .utf8)
        // Exactly one `skipEmpty: true` in the primitive: the `acpLines`
        // factory. A second would mean a new adopter inherited ACP's
        // semantics without stating it.
        let skippers = reader.components(separatedBy: "skipEmpty: true").count - 1
        #expect(skippers == 1,
                "expected only `acpLines` to skip empty frames, found \(skippers)")
    }

    @Test("LocalTransport.streamRawBytes yields the child's bytes")
    func localStreamRawBytesYieldsBytes() async throws {
        var got = Data()
        for try await chunk in LocalTransport().streamRawBytes(
            executable: "/bin/sh", args: ["-c", "printf 'abc'"]
        ) {
            got.append(chunk)
        }
        #expect(String(data: got, encoding: .utf8) == "abc")
    }

    /// Dropping the consumer stops the child: `onTermination` cancels the
    /// `StreamingChild`, which now cancels the reader too (closing the read
    /// end) as well as reaping the process.
    @Test("abandoning the stream terminates the child")
    func abandoningTheStreamTerminatesTheChild() async throws {
        let marker = "p58-\(UUID().uuidString)"
        do {
            let stream = LocalTransport().streamLines(
                executable: "/bin/sh",
                args: ["-c", "echo ready; while :; do sleep 1; done # \(marker)"]
            )
            var iterator = stream.makeAsyncIterator()
            let first = try await iterator.next()
            #expect(first == "ready")
        } // iterator and stream dropped here → onTermination

        // Bounded poll: the SIGTERM is delivered from the termination
        // handler, so "gone" is not instantaneous, and a regression must fail
        // rather than hang.
        var alive = true
        for _ in 0..<50 where alive {
            alive = Self.processCount(matching: marker) > 0
            if alive { PipeReaderTestSupport.settle(0.1) }
        }
        #expect(!alive, "the child outlived the consumer that dropped its stream")
    }

    // MARK: - The property the whole port exists for

    /// A long-lived stream must park NO cooperative-pool thread.
    ///
    /// Proved by RENDEZVOUS rather than by the clock (round-5 P52's lesson —
    /// a timing bet fails on the grader's load, not on the defect). Open more
    /// long-lived streams than the pool has threads, then enqueue ordinary
    /// pool tasks and require that every one of them makes progress inside a
    /// bounded wait. With the blocking loop, every pool thread is parked
    /// inside `read(2)` on a child that never writes again, and no enqueued
    /// task can run at all.
    ///
    /// **Why the wait is synchronous.** The whole point of the regression is
    /// that the pool cannot schedule anything, so an `await`-based timeout
    /// would need the very thread it is trying to prove is missing — the test
    /// would HANG instead of failing. Blocking this one thread on a
    /// semaphore needs no scheduling, so a regression times out and fails
    /// cleanly.
    @Test("long-lived streams park no cooperative-pool thread")
    func longLivedStreamsParkNoPoolThread() async throws {
        let width = ProcessInfo.processInfo.activeProcessorCount
        let streamCount = max(8, width * 2)
        let marker = "p58-park-\(UUID().uuidString)"
        var streams: [AsyncThrowingStream<String, Error>] = []
        for _ in 0..<streamCount {
            // Writes once, then never again — exactly `tail -F` with nothing
            // arriving, which is what a quiet Logs pane is.
            streams.append(LocalTransport().streamLines(
                executable: "/bin/sh",
                args: ["-c", "echo open; while :; do sleep 1; done # \(marker)"]
            ))
        }
        defer {
            streams.removeAll()
            // Reap: the termination handlers SIGTERM the children.
            PipeReaderTestSupport.settle(0.2)
        }

        // Let the producers reach their read. `Thread.sleep`, not
        // `Task.sleep`: the sleeping thread needs no scheduling.
        PipeReaderTestSupport.settle(0.5)

        let probes = 4
        // A CEILING, not a budget. Under the full suite's load four trivial
        // probes were measured taking 6.5 s of a 10 s bound — a load bet, not
        // a signal. Under the regression the pool can schedule NOTHING, so the
        // probes never arrive and the ceiling is paid in full exactly once;
        // green, it costs whatever the machine actually takes.
        let parkProbeTimeout: TimeInterval = 60
        let arrived = DispatchSemaphore(value: 0)
        for _ in 0..<probes {
            Task.detached { arrived.signal() }
        }
        let allArrived = PipeReaderTestSupport.waitAll(
            arrived, count: probes, timeout: parkProbeTimeout)

        #expect(allArrived, """
            \(streamCount) open streams starved the cooperative pool: \(probes) \
            trivial tasks could not run inside \(parkProbeTimeout) s. The stdout loop is \
            blocking a pool thread per stream again.
            """)
    }

    private static func processCount(matching marker: String) -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Ao", "command"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return 0 }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        _ = proc.waitUntilExit(timeout: 10)
        let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
        // The `ps` child itself never carries the marker; only the `sh` and
        // its `sleep` can, and only the `sh` spells the comment.
        return text.split(separator: "\n").filter {
            $0.contains(marker) && $0.contains("/bin/sh")
        }.count
    }

    /// Collects a `PipeReader`'s events from its serial queue.
    private final class EventInbox: @unchecked Sendable {
        private let lock = NSLock()
        private let progress = DispatchSemaphore(value: 0)
        private var storedLines: [String] = []
        private var storedChunks = Data()
        private var finishes = 0

        func append(_ event: PipeReader.Event) {
            lock.lock()
            switch event {
            case .line(let text): storedLines.append(text)
            case .chunk(let data): storedChunks.append(data)
            case .finished: finishes += 1
            }
            lock.unlock()
            progress.signal()
        }

        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storedLines }
        var chunkBytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return [UInt8](storedChunks) }
        var finishCount: Int { lock.lock(); defer { lock.unlock() }; return finishes }

        /// Bounded so a regression fails instead of hanging the host. The
        /// bound is a CEILING paid only when the reader is broken — under
        /// full-suite load these waits are a load bet at 10 s, so they are
        /// generous (same reasoning as `parkProbeTimeout`).
        func waitForLines(_ count: Int) -> Bool {
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if lines.count >= count { return true }
                _ = progress.wait(timeout: .now() + 0.05)
            }
            return lines.count >= count
        }

        func waitForFinish() -> Bool {
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if finishCount > 0 { return true }
                _ = progress.wait(timeout: .now() + 0.05)
            }
            return finishCount > 0
        }
    }
}

/// Synchronous helpers. They live outside the `async` test bodies on purpose:
/// `DispatchSemaphore.wait` and `Thread.sleep` are `noasync` precisely
/// because they block a thread — which is the one thing this suite needs to
/// do, since the regression it guards against is "no thread is available to
/// schedule anything".
enum PipeReaderTestSupport {
    static func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    static func waitAll(_ semaphore: DispatchSemaphore, count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        for _ in 0..<count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            if semaphore.wait(timeout: .now() + remaining) == .timedOut { return false }
        }
        return true
    }
}
/// Round-6 P58 — the iOS streaming claim, pinned to the code that would have
/// to be true for it.
///
/// `HermesLogService.openLog(path:)`'s remote branch said iOS drove the same
/// `tail -F` "through a Citadel exec channel". It does not:
/// `CitadelServerTransport.streamLines` is an M3 stub that finishes the
/// stream immediately, so on iOS that branch yields nothing at all. P58 fixed
/// the SENTENCE and filed the wiring as `t-78ced4d2` — round-6 lesson 6, "a
/// number or citation in a comment is a claim nobody executes", applied to a
/// claim about a sibling's behaviour.
///
/// This is the executable half: while the stub is a stub, the comment must
/// not say otherwise; and when someone wires it, this test is what tells them
/// the comment is now wrong in the other direction.
@Suite("The iOS streaming claim matches the iOS code (P58)")
struct IOSStreamingClaimP58Tests {

    /// `…/scarf/Packages` — the two sibling package roots live under it.
    private static var packagesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/ScarfCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/ScarfCore
            .deletingLastPathComponent()   // …/Packages
    }

    @Test("the log service does not claim an iOS stream the iOS transport cannot give")
    func theClaimTracksTheStub() throws {
        let citadel = try String(
            contentsOf: Self.packagesRoot.appendingPathComponent(
                "ScarfIOS/Sources/ScarfIOS/CitadelServerTransport.swift"),
            encoding: .utf8)
        let logService = try String(
            contentsOf: Self.packagesRoot.appendingPathComponent(
                "ScarfCore/Sources/ScarfCore/Services/HermesLogService.swift"),
            encoding: .utf8)

        // The stub, located by its declaration rather than by a line number:
        // `streamLines` whose body is the immediate `finish()`.
        let lines = citadel.components(separatedBy: "\n")
        let start = try #require(
            lines.firstIndex { $0.contains("public func streamLines(") },
            "`CitadelServerTransport.streamLines` is gone — re-point this test")
        let body = lines[start..<min(start + 14, lines.count)].joined(separator: "\n")
        let isStub = body.contains("AsyncThrowingStream { $0.finish() }")

        if isStub {
            #expect(!logService.contains("iOS drives it through a Citadel exec channel"), """
                `HermesLogService` still tells the reader that iOS streams \
                through a Citadel exec channel while \
                `CitadelServerTransport.streamLines` is an immediate-finish \
                stub. The comment describes a feature that does not exist.
                """)
            #expect(logService.contains("t-78ced4d2"), """
                The comment says iOS does not stream but names no task, so the \
                gap is documented and unowned.
                """)
        } else {
            #expect(!logService.contains("**iOS does NOT stream.**"), """
                `CitadelServerTransport.streamLines` is no longer a stub, so \
                `HermesLogService`'s "iOS does NOT stream" paragraph is now the \
                wrong claim — update it and close `t-78ced4d2`.
                """)
        }
    }
}

#endif
