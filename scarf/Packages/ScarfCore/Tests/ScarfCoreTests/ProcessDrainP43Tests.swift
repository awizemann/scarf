#if !os(iOS)
import Foundation
import os
import Testing
@testable import ScarfCore

/// Round-4 P43, decision 15: `Process.waitDraining` lives in ScarfCore now,
/// and the package's own `unzip`/`zip` spawns use it.
///
/// Every test here spawns a REAL child. The shapes that matter are the two
/// that used to wedge a caller forever:
///
/// * a child that writes more than the 64 KB pipe buffer before exiting — the
///   classic `run` → `waitUntilExit` → `readToEnd` deadlock, where the child
///   blocks in `write()` and the parent blocks in `wait()`;
/// * a child that never exits at all.
///
/// Both are held to short budgets so the suite stays fast.
@Suite("Process drain + timeout (P43)")
struct ProcessDrainP43Tests {

    /// 200 KB — comfortably past the 64 KB pipe buffer that makes the
    /// deadlock reachable, small enough to produce in milliseconds.
    static let chattyBytes = 200_000

    /// Emit `chattyBytes` of `x` on stderr, then do `then`.
    static func chattyChild(then: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [
            "-c",
            "head -c \(chattyBytes) /dev/zero | tr '\\000' 'x' 1>&2; \(then)",
        ]
        return p
    }

    // MARK: - The primitive, now in ScarfCore

    @Test("a chatty child past the pipe buffer exits and its output arrives whole")
    func chattyChildDoesNotDeadlock() throws {
        let proc = Self.chattyChild(then: "exit 3")
        let err = Pipe()
        let out = Pipe()
        proc.standardError = err
        proc.standardOutput = out
        try proc.run()

        let (exited, drained) = proc.waitDraining(timeout: 20, pipes: [err, out])
        try? err.fileHandleForWriting.close()
        try? out.fileHandleForWriting.close()

        #expect(exited, "the child exits on its own; only an undrained pipe could stop it")
        let stderrData = try #require(drained.first)
        #expect(stderrData.count == Self.chattyBytes)
        #expect(proc.terminationStatus == 3)
    }

    @Test("a child that never exits is given up on inside the budget")
    func hangingChildIsBounded() throws {
        let proc = Self.chattyChild(then: "sleep 30")
        let err = Pipe()
        proc.standardError = err
        try proc.run()

        let started = Date()
        let (exited, drained) = proc.waitDraining(timeout: 0.5, pipes: [err])
        let elapsed = Date().timeIntervalSince(started)
        try? err.fileHandleForWriting.close()

        #expect(!exited)
        // 0.5 s budget + the SIGTERM grace + the drain grace. The point is
        // that it RETURNED: a bare `waitUntilExit()` here waits forever.
        #expect(elapsed < 10, "waitDraining took \(elapsed)s")
        // A slot per pipe comes back either way — the caller indexes it
        // unconditionally. What it HOLDS is deliberately not asserted: under
        // a loaded test host a 0.5 s budget can expire before the child is
        // scheduled at all, so any floor here is a flake. That the drain runs
        // concurrently with the wait is proved by the test above, on a child
        // that is given time to finish.
        #expect(drained.count == 1)
    }

    // MARK: - The three ScarfCore archive spawns

    /// A zip holding one member of `bytes`.
    ///
    /// The overrun tests need extraction to take longer than ONE poll turn,
    /// not longer than the budget: `waitUntilExit(timeout:)` sleeps
    /// `pollInterval` (50 ms) before it re-checks, so a sub-millisecond
    /// budget is really "50 ms or the first turn, whichever is later". 24 MB
    /// of zeros is written and zipped in milliseconds and takes well past
    /// that to unpack, which is the property these tests need.
    static func makeZip(in dir: URL, bytes: Int) throws -> URL {
        let staging = dir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: staging.appendingPathComponent("fat.bin"))
        let archive = dir.appendingPathComponent("fat.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-rqX", archive.path, "."]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        #expect(zip.waitUntilExit(timeout: 60))
        return archive
    }

    static func scratchDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-p43-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A path that a reader can never finish opening: `open(2)` on a FIFO with
    /// no writer blocks in the kernel until one appears, and nothing here ever
    /// writes. That is what makes this deterministic — the child PROVABLY
    /// cannot exit, rather than being given work a fast host might finish
    /// inside the budget.
    static func makeBlockingFIFO(in dir: URL) throws -> URL {
        let fifo = dir.appendingPathComponent("never.zip")
        #expect(mkfifo(fifo.path, 0o600) == 0, "mkfifo failed: \(errno)")
        return fifo
    }

    @Test("restore's unzip refuses instead of hanging when it outstays its budget")
    func unzipArchiveIsBounded() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Was a 24 MB zip against a 1 ms budget — a bet that unpacking is
        // slower than one poll turn, which is a race, not a proof. A FIFO
        // nobody writes to cannot be read at all (round-4 P43b).
        let archive = try Self.makeBlockingFIFO(in: dir)
        let dest = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        var thrown: Error?
        do {
            try await RemoteRestoreService.unzipArchive(at: archive, into: dest, timeout: 0.5)
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "unzip cannot finish reading a FIFO with no writer")
        #expect("\(error)".contains("did not finish"))
    }

    @Test("restore's unzip still succeeds on a sane archive within its budget")
    func unzipArchiveSucceeds() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = try Self.makeZip(in: dir, bytes: 4096)
        let dest = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try await RemoteRestoreService.unzipArchive(at: archive, into: dest, timeout: 60)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("fat.bin").path))
    }

    @Test("backup's zip refuses instead of hanging when it outstays its budget")
    func zipDirectoryIsBounded() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Incompressible, so `zip` cannot shortcut its way under the budget.
        //
        // **8 MB against a 25 ms budget** (round-5 decision 8), down from
        // P43c's 64 MB against 300 ms. Two things changed. The budget now
        // starts BEFORE `Process.run()`, so the scheduling hop in front of
        // the reap is spent out of the budget rather than handed to `zip` as
        // a free head start — which is the bet P43c was losing when it had to
        // reach for 64 MB. And the fixture is sized to the BOUND rather than
        // to that head start: `zip` takes ~200 ms over 8 MB of
        // `/dev/urandom`, so the budget is still beaten by 8x, while writing
        // and compressing the fixture costs an eighth of what it did. The
        // suite's own wall time is the reason — these four fixture-heavy
        // suites were about half the serial run.
        let urandom = try #require(FileHandle(forReadingAtPath: "/dev/urandom"))
        defer { try? urandom.close() }
        let bytes = urandom.readData(ofLength: 8 * 1024 * 1024)
        try bytes.write(to: work.appendingPathComponent("noise.bin"))

        // **What this proves, exactly.** The budget now starts BEFORE
        // `Process.run()` (decision 8), so on a loaded machine the 25 ms can
        // be spent on the fork+exec rather than on `zip`'s compression — the
        // refusal is then of a child that had barely started. That is still
        // the property under test: the call REFUSES within a bounded time
        // instead of running to completion or hanging, wherever the budget
        // went. It is not a measurement of `zip`'s throughput, and the
        // comment above about 8 MB taking ~200 ms is why the fixture is
        // sized as it is, not a claim about which side of the budget won
        // (round-5 P48b).
        var thrown: Error?
        let started = Date()
        do {
            try await RemoteBackupService.zipDirectory(
                workDir: work, into: dir.appendingPathComponent("o.zip"), timeout: 0.025)
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        let error = try #require(thrown, "zipping 8 MB of noise cannot finish inside 25 ms")
        #expect("\(error)".contains("did not finish"))
        // **What the ceiling is for, and why it is 30 s** (round-6 P59).
        //
        // It was 8 s and it is the recurring load flake in the full parallel
        // `swift test` — which is a sign the assertion was being read as a
        // measurement. It is not one, and it cannot be: the UNBOUNDED zip of
        // this fixture takes ~200 ms, i.e. FASTER than the refusal path, so
        // no elapsed threshold can tell "bounded" from "ran to completion".
        // The discriminator is that it THREW `did not finish`, which is
        // asserted above. All this ceiling can catch is the one failure the
        // throw cannot — a HANG, where the wait never returns at all.
        //
        // So the number is sized to the primitive's worst case plus room for
        // a loaded grader, not shaved to it: `timeout` 0.025 + the SIGTERM
        // grace (2 s, `ProcessTimeout.swift:80`) + the SIGKILL grace (2 s,
        // same constant, applied twice) + `Process.drainGrace` (1 s,
        // `:246`) ≈ 5.03 s of bounded waiting. 30 s leaves ~25 s of slack for
        // fork/exec and scheduling on a machine running the rest of this
        // suite in parallel, and still fails a wait that never returns
        // (P58b's rule: raise the ceiling, and write down the reason).
        #expect(elapsed < 30, "the refusal took \(elapsed)s — that is not a bounded budget")
    }

    @Test("the archive budgets are named and ordered")
    func budgetsAreNamed() {
        // The remote extract begins only after the whole tarball is already
        // through the pipe, so it is the shorter of the two by construction.
        #expect(RemoteRestoreService.remoteExtractTimeout < RemoteRestoreService.unzipTimeout)
        #expect(RemoteBackupService.zipTimeout == RemoteRestoreService.unzipTimeout)
    }

    // MARK: - inspect()'s temp dir (P43b)

    /// `inspect()` creates `scarf-restore-<uuid>` before it unzips anything
    /// and hands it to the caller inside `InspectionResult` — on the SUCCESS
    /// path. On every throwing path it was simply left behind, holding
    /// however much of a multi-GB archive had landed before the refusal, once
    /// per attempt.
    @Test("a refused inspect leaves no temp directory behind")
    func inspectCleansUpAfterARefusal() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Not a zip at all: `unzip` refuses it in milliseconds.
        let notAnArchive = dir.appendingPathComponent("nope.scarfbackup")
        try Data("this is not a zip".utf8).write(to: notAnArchive)

        func restoreTempDirs() -> Set<String> {
            let temp = FileManager.default.temporaryDirectory.path
            let all = (try? FileManager.default.contentsOfDirectory(atPath: temp)) ?? []
            return Set(all.filter { $0.hasPrefix("scarf-restore-") })
        }

        let before = restoreTempDirs()
        var thrown: Error?
        do {
            _ = try await RemoteRestoreService(context: .local).inspect(archiveURL: notAnArchive)
        } catch {
            thrown = error
        }
        _ = try #require(thrown, "a file that is not a zip cannot be inspected")
        #expect(restoreTempDirs().subtracting(before).isEmpty,
                "inspect() left its work directory behind on a throwing path")
    }

    // MARK: - The tarball pump (P43b)

    /// The reviewer's reproduction, exactly: a child that floods stderr past
    /// the 64 KB buffer and only THEN starts reading its stdin. With the
    /// drains installed after the pump — the shape P43 shipped — the child
    /// blocks in `write()`, stops reading stdin, and the parent blocks in
    /// `writer.write()` forever: `extractTimeout` is never reached, because
    /// the code never gets as far as the wait.
    @Test("a remote that floods stderr before reading stdin does not wedge the pump")
    func pumpSurvivesAChattyChild() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 1 MB, comfortably past both pipe buffers.
        let tarball = dir.appendingPathComponent("payload.bin")
        try Data(count: 1_000_000).write(to: tarball)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = [
            "-c",
            "head -c \(Self.chattyBytes) /dev/zero | tr '\\000' 'x' 1>&2; cat > /dev/null",
        ]

        let progressed = OSAllocatedUnfairLock(initialState: Int64(0))
        try await RemoteRestoreService.streamTarball(
            into: child,
            tarball: tarball,
            extractTimeout: 20,
            stallTimeout: 8
        ) { written in progressed.withLock { $0 = written } }

        #expect(progressed.withLock { $0 } == 1_000_000)
        #expect(child.terminationStatus == 0)
    }

    /// A child that never reads its stdin at all. The pump fills the pipe
    /// buffer, blocks, and can never make progress again — so the stall
    /// ceiling is the only thing that can end this, and it must.
    @Test("a remote that never reads stdin is stopped by the stall ceiling")
    func pumpStallCeilingFires() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tarball = dir.appendingPathComponent("payload.bin")
        try Data(count: 4_000_000).write(to: tarball)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `exec sleep` so the shell itself is replaced: nothing in this child
        // ever reads a byte of stdin.
        child.arguments = ["-c", "exec sleep 120"]

        let started = Date()
        var thrown: Error?
        do {
            try await RemoteRestoreService.streamTarball(
                into: child, tarball: tarball, extractTimeout: 20, stallTimeout: 1
            ) { _ in }
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(started)
        let error = try #require(thrown, "a child that never reads stdin cannot be pumped")
        #expect("\(error)".contains("stopped reading"), "\(error)")
        #expect(elapsed < 30, "the stall ceiling took \(elapsed)s to fire")
    }

    /// The third archive site's launch failure. It threw without closing a
    /// single handle and without reaping anything — six fds per attempt on the
    /// one path where no drain owns them.
    @Test("a push whose child cannot launch closes its pipes and refuses")
    func pumpLaunchFailureIsClean() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tarball = dir.appendingPathComponent("payload.bin")
        try Data(count: 1024).write(to: tarball)

        func openFDs() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }

        func attempt() async -> Error? {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/nonexistent/scarf-p43b-no-such-binary")
            do {
                try await RemoteRestoreService.streamTarball(
                    into: child, tarball: tarball, extractTimeout: 5, stallTimeout: 5
                ) { _ in }
                return nil
            } catch {
                return error
            }
        }

        let first = await attempt()
        let error = try #require(first)
        #expect("\(error)".contains("start remote tar"), "\(error)")

        let before = openFDs()
        for _ in 0..<20 { _ = await attempt() }
        let after = openFDs()
        // Six handles per attempt would be +120 here.
        #expect(after - before < 12, "launch failures leaked fds: \(before) -> \(after)")
    }

    // MARK: - The pump's throughput (P43c)

    /// **Why this is a mechanism test and not a throughput test.** A fixed
    /// 20 ms nap per `EAGAIN` is a correctness fix that costs three orders of
    /// magnitude — a pump that naps whenever the pipe is full moves one
    /// pipe-full per tick no matter how fast the machine is, and the reviewer
    /// measured 4138 MB/s blocking against 2.8 MB/s with the sleep on a 64 MB
    /// payload. The obvious test is a throughput floor, and it was written
    /// three ways and thrown away three times:
    ///
    /// * 64 MB into `cat > /dev/null` under a 5 s bound — the pipe is only
    ///   intermittently full there, so `EAGAIN` is intermittent and the
    ///   sleeping pump measured anywhere from 3 to 16 MB/s. 3.9 s of that
    ///   range passes the bound;
    /// * 32 MB into a reader that takes one pipe-full and pauses 1 ms, which
    ///   DOES pin the sleeping pump to the tick (7.2 s against 1.3 s) — but
    ///   the polling pump's own floor is the reader's pace, and under a full
    ///   parallel `swift test` that floor inflates past the bound;
    /// * the same, normalised against a blocking-`write` baseline measured in
    ///   the same test. The ratios overlap: 8.6x for the sleep in isolation,
    ///   6.6x for `poll` under load.
    ///
    /// Wall-clock throughput is simply not a stable signal on a machine also
    /// running 2900 other tests. What IS stable is the property the fix is
    /// about, asserted directly below: the wait ends when the reader takes a
    /// byte. A sleep cannot do that at all — it ends when the clock says so —
    /// so the first half of this test fails against the sleep for the same
    /// reason the throughput test did, with a 40x margin instead of a 2x one.
    ///
    /// Both halves are asserted, because the second — the cap — is what the
    /// stall ceiling and `Task.checkCancellation()` rest on.
    @Test("the writability wait ends on the byte, and is capped when no byte comes")
    func waitWritableWakesOnTheByte() throws {
        /// A pipe filled to the brim, plus its write fd in non-blocking mode.
        func fullPipe() -> (Pipe, Int32) {
            let pipe = Pipe()
            let fd = pipe.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let chunk = [UInt8](repeating: 0x78, count: 64 * 1024)
            while true {
                let n = chunk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
            }
            return (pipe, fd)
        }

        // 1. Nobody reads: the pipe is genuinely NOT writable — asserted
        //    through the mechanism `waitWritable` blocks on, a `poll` for
        //    `POLLOUT` with a zero timeout, which reports no ready
        //    descriptor — and the wait is nonetheless capped by its budget
        //    and returns.
        //
        //    This used to assert `idleElapsed >= 0.15` against a 0.2 budget:
        //    a duration floor with a 50 ms margin over a `poll` timeout the
        //    kernel rounds to its own tick and may return early from. The
        //    stopwatch was never the property under test; not-writable is.
        let (idle, idleFD) = fullPipe()
        var idleProbe = pollfd(fd: idleFD, events: Int16(POLLOUT), revents: 0)
        #expect(poll(&idleProbe, 1, 0) == 0,
                "a pipe filled to the brim with no reader reported writable")
        let idleStarted = Date()
        RemoteRestoreService.waitWritable(idleFD, upTo: 0.2)
        let idleElapsed = Date().timeIntervalSince(idleStarted)
        #expect(idleElapsed < 5, "the wait is capped, so cancellation gets a turn")
        try? idle.fileHandleForReading.close()
        try? idle.fileHandleForWriting.close()

        // 2. A reader takes one chunk 5 ms in: the wait ends THERE, not at the
        //    end of the budget. A 200 ms budget against a 5 ms byte is a 40x
        //    gap, so scheduling noise cannot flip the answer.
        let (live, liveFD) = fullPipe()
        let reader = live.fileHandleForReading
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.005)
            _ = reader.readData(ofLength: 64 * 1024)
        }
        let liveStarted = Date()
        RemoteRestoreService.waitWritable(liveFD, upTo: 5)
        let liveElapsed = Date().timeIntervalSince(liveStarted)
        #expect(liveElapsed < 1,
                Comment(rawValue: String(
                    format: "the wait took %.3fs for a byte that arrived at 0.005s — it is "
                        + "sleeping on a clock, not watching the fd", liveElapsed)))
        try? live.fileHandleForWriting.close()
    }

    // MARK: - A give-up arm quotes the child (P43c)

    /// The give-up arms threw the drain away (`_ = proc.waitDraining(…)`), so
    /// a `tar` that had already explained itself on stderr and exited was
    /// reported to the user as "Broken pipe" — the mechanical consequence,
    /// with the cause discarded one line earlier.
    ///
    /// The child here is the shape that actually happens: `tar -x` cannot open
    /// its destination, says so, and exits before reading the archive. The
    /// push is multi-MB, so the write outlives the child and lands on EPIPE.
    @Test("a push whose remote died explaining itself quotes the explanation")
    func pumpGiveUpQuotesTheChild() async throws {
        let dir = try Self.scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tarball = dir.appendingPathComponent("payload.bin")
        try Data(count: 8 * 1024 * 1024).write(to: tarball)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "echo 'tar: /nope: Cannot open: Permission denied' 1>&2; exit 2"]

        var thrown: Error?
        do {
            try await RemoteRestoreService.streamTarball(
                into: child, tarball: tarball, extractTimeout: 20, stallTimeout: 10
            ) { _ in }
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "a remote that exits 2 without reading cannot succeed")
        let message = "\(error)"
        #expect(message.contains("Cannot open"),
                Comment(rawValue: "the drained stderr was discarded: \(message)"))
    }

    /// The tail helper itself: last lines only, blanks dropped, indentation
    /// trimmed, and nothing appended when the child said nothing.
    @Test("the error tail takes the last lines and says nothing when there are none")
    func outputTailIsATail() {
        let err = Data("one\n  two  \n\nthree\nfour\nfive\n".utf8)
        let tail = RemoteRestoreService.outputTail([err, Data()], lines: 2)
        #expect(tail == "four / five")
        #expect(RemoteRestoreService.outputTail([Data(), Data()]).isEmpty)
        #expect(RemoteRestoreService.appendingTail("boom", "") == "boom")
        #expect(RemoteRestoreService.appendingTail("boom", "why").contains("why"))
    }

    /// The audit's actual finding was textual: three `proc.waitUntilExit()`
    /// calls with a `readToEnd` after them. Pin the shape so a future edit
    /// cannot quietly re-introduce it in these two files.
    @Test("no unbounded wait survives in the archive services")
    func noBareWaitInArchiveServices() throws {
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScarfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ScarfCore
            .appendingPathComponent("Sources/ScarfCore/Services")
        for name in ["RemoteRestoreService.swift", "RemoteBackupService.swift"] {
            let text = try String(contentsOf: services.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains(".waitUntilExit()"), "\(name) still holds an unbounded wait")
            #expect(!text.contains("readToEnd()"), "\(name) still reads a pipe after the wait")
        }
    }
}
#endif
