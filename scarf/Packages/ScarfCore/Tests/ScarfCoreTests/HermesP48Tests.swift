#if !os(iOS)
import Foundation
import Testing
@testable import ScarfCore

/// Round-5 P48, decisions 4 and 5: the two Mac transports stop carrying their
/// own drain and their own unbounded waits.
///
/// Every test here spawns a REAL child, because every defect being pinned is
/// a property of a real pipe and a real signal disposition — the shapes that
/// used to wedge a caller forever, held to short budgets so the suite stays
/// fast.
@Suite("Transport drain + bounded waits (P48)")
struct TransportDrainP48Tests {

    /// Source text with comment LINES removed.
    ///
    /// Every scan below is looking for a call, and each of these fixes left a
    /// comment naming the shape it removed — so a raw `contains` would match
    /// the explanation and the sweep would be red for the fix that closed it.
    /// Comment-only lines are dropped; a trailing comment on a code line
    /// stays, which is the conservative direction.
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - Decision 4: one drain primitive

    /// `ProcessPipeDrainer` is deleted, not merely unused. A second drain
    /// implementation is how the two defects below survived a whole round of
    /// C10 work in `ProcessPipeDrain` without ever reaching the transports.
    @Test("no second drain implementation survives in ScarfCore")
    func onlyOneDrainPrimitive() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ScarfCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // ScarfCore
            .appendingPathComponent("Sources/ScarfCore")
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            if Self.codeOnly(text).contains("ProcessPipeDrainer") {
                offenders.append(url.lastPathComponent)
            }
        }
        // A premise floor: an enumeration that walked nothing would report an
        // empty offender list just as happily (round-4 P43b).
        #expect(scanned > 100, "only \(scanned) ScarfCore sources scanned")
        #expect(offenders.isEmpty, "ProcessPipeDrainer still referenced in \(offenders)")
    }

    /// The headline. `ProcessPipeDrainer.Capture.wait()` was a bare
    /// `group.wait()` and the transports' overrun arm was
    /// `terminate()` → bare `waitUntilExit()`, so a child that ignores
    /// SIGTERM **and** leaves a grandchild holding the pipe's write end hung
    /// the TIMEOUT path forever — the one path that exists because something
    /// already went wrong.
    ///
    /// The child here is exactly that: `sh` with SIGTERM trapped to ignore,
    /// and a `sleep` grandchild that inherits stdout and outlives everything.
    /// Against the old code this call never returns. Against the new one the
    /// escalation reaches SIGKILL and `collect(grace:)` gives up on the
    /// inherited fd, so it comes back inside a few seconds.
    @Test("a SIGTERM-proof child holding an inherited pipe still ends the timeout arm", .timeLimit(.minutes(1)))
    func overrunArmIsBoundedEvenWhenTheChildIgnoresSIGTERM() throws {
        let start = Date()
        var threw: TransportError?
        do {
            _ = try LocalTransport().runProcess(
                executable: "/bin/sh",
                args: ["-c", "trap '' TERM; sleep 45 & sleep 45"],
                stdin: nil,
                timeout: 0.5
            )
        } catch let error as TransportError {
            threw = error
        }
        let elapsed = Date().timeIntervalSince(start)
        guard case .timeout = try #require(threw) else {
            Issue.record("expected TransportError.timeout, got \(String(describing: threw))")
            return
        }
        // 0.5 s budget + two 2 s signal graces + a 1 s drain grace ≈ 5.5 s
        // worst case. Anything near the 45 s the child asked for means an
        // unbounded wait is back.
        #expect(elapsed < 20, "timeout arm took \(elapsed)s")
    }

    // MARK: - The fd leaks

    /// Open descriptors in this process. `/dev/fd` is the cheap, exact
    /// measure P43b used for the same question.
    static func openFDCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// A spawn that passes no stdin used to build a `Pipe()` anyway and close
    /// only the arm guarded by `stdin != nil` — so the read end was never
    /// released on ANY path, once per spawn, for the life of the process.
    @Test("a stdin-less spawn leaks no descriptors")
    func stdinLessSpawnLeaksNothing() throws {
        let transport = LocalTransport()
        // Warm up: the first spawn allocates one-time machinery.
        _ = try transport.runProcess(
            executable: "/bin/echo", args: ["warm"], stdin: nil, timeout: 10)
        let before = Self.openFDCount()
        for _ in 0..<30 {
            _ = try transport.runProcess(
                executable: "/bin/echo", args: ["hi"], stdin: nil, timeout: 10)
        }
        let after = Self.openFDCount()
        // 30 spawns × 1 leaked read end = +30 against the old code; a couple
        // of descriptors of slack for unrelated machinery.
        #expect(after - before < 10, "fd count went \(before) → \(after)")
    }

    /// The launch-failure arm: `run()` threw, so there was no fork and
    /// Foundation closed nothing. Both stdin ends stayed open.
    @Test("a spawn that fails to launch leaks no descriptors")
    func failedLaunchLeaksNothing() throws {
        let transport = LocalTransport()
        _ = try? transport.runProcess(
            executable: "/nonexistent/warm", args: [], stdin: Data("x".utf8), timeout: 10)
        let before = Self.openFDCount()
        for _ in 0..<30 {
            _ = try? transport.runProcess(
                executable: "/nonexistent/binary",
                args: [],
                stdin: Data("payload".utf8),
                timeout: 10
            )
        }
        let after = Self.openFDCount()
        #expect(after - before < 10, "fd count went \(before) → \(after)")
    }

    /// Stdin still reaches the child — the pipe became conditional, and a
    /// conditional that got the condition backwards would be silent.
    @Test("stdin still arrives when there is stdin to send")
    func stdinStillReachesTheChild() throws {
        let result = try LocalTransport().runProcess(
            executable: "/bin/cat",
            args: [],
            stdin: Data("through the pipe\n".utf8),
            timeout: 10
        )
        #expect(result.exitCode == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "through the pipe\n")
    }

    // MARK: - Decision 5: the timeout is required

    /// The compile-time half of decision 5 cannot be asserted at runtime — a
    /// `nil` no longer type-checks — so what is pinned is that the signature
    /// stayed non-optional on every conformer the package can see.
    @Test("the transport signature takes a required timeout")
    func timeoutIsNotOptional() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ScarfCore/Transport")
        for name in ["ServerTransport.swift", "LocalTransport.swift", "SSHTransport.swift"] {
            let text = try String(
                contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            #expect(
                !Self.codeOnly(text).contains("timeout: TimeInterval?"),
                "\(name) still declares an optional transport timeout")
        }
    }
}
#endif

#if !os(iOS)
/// Round-5 P48, decision 6: the four streaming spawns.
///
/// Both defects are properties of a real child and a real pipe, so both tests
/// here spawn one. Each hangs forever against the pre-P48 code, which is why
/// each carries its own time limit.
@Suite("Streaming spawns own their child (P48)")
struct StreamingSpawnP48Tests {

    /// Code text with comment-only lines dropped.
    static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    static var transportSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ScarfCore/Transport")
    }

    /// A child that writes 200 KB of stderr — past the 64 KB pipe buffer —
    /// BEFORE it writes anything to stdout.
    ///
    /// Against the old code this is a deadlock by construction: nothing drains
    /// stderr during the run (it was `readToEnd()` after the wait, and only on
    /// a non-zero exit), so the child blocks in `write()` at 64 KB while the
    /// producer task sits in `availableData` on a stdout that will never
    /// produce. `ssh -v` on a slow ProxyCommand reaches that size, and a log
    /// tail is exactly this shape.
    @Test("a child with more than a pipe buffer of stderr still streams its stdout",
          .timeLimit(.minutes(1)))
    func stderrPastThePipeBufferDoesNotWedgeTheStream() async throws {
        let script = "head -c 200000 /dev/zero | tr '\\000' 'x' 1>&2; echo alpha; echo beta"
        var lines: [String] = []
        for try await line in LocalTransport().streamLines(
            executable: "/bin/sh", args: ["-c", script]
        ) {
            lines.append(line)
        }
        #expect(lines == ["alpha", "beta"])
    }

    /// A consumer that stops iterating must stop the child. Without
    /// `onTermination` the spawn was simply orphaned: still running, still
    /// holding its pipes, with nobody left to read them — and on the SSH
    /// transport that is an `ssh` holding a ControlMaster channel.
    @Test("abandoning the stream reaps the child", .timeLimit(.minutes(1)))
    func abandoningTheStreamReapsTheChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("p48-stream-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // Announce the pid, then talk forever. `trap '' TERM` is deliberate:
        // the reap has to be an ESCALATION, not a polite request.
        let script = """
            trap '' TERM
            printf '%s' "$$" > \(pidFile.path)
            while :; do echo tick; sleep 0.05; done
            """
        var seen = 0
        for try await _ in LocalTransport().streamRawBytes(
            executable: "/bin/sh", args: ["-c", script]
        ) {
            seen += 1
            if seen >= 2 { break }  // the consumer gives up
        }
        #expect(seen >= 2)

        let text = try #require(try? String(contentsOf: pidFile, encoding: .utf8))
        let pid = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Bounded poll: SIGTERM is ignored, so this is waiting for the
        // primitive's grace window to run out and SIGKILL to land.
        let deadline = Date().addingTimeInterval(30)
        var alive = true
        while Date() < deadline {
            if kill(pid, 0) != 0 { alive = false; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if alive { kill(pid, SIGKILL) }
        #expect(alive == false, "child \(pid) outlived the abandoned stream")
    }

    /// Neither transport reaches for the unbounded spelling any more — the
    /// four streaming spawns were the last four sites.
    @Test("neither transport calls the unbounded waitUntilExit")
    func noBareWaitInEitherTransport() throws {
        var scanned = 0
        for name in ["LocalTransport.swift", "SSHTransport.swift"] {
            let text = try String(
                contentsOf: Self.transportSources.appendingPathComponent(name),
                encoding: .utf8)
            scanned += 1
            #expect(
                !Self.codeOnly(text).contains("waitUntilExit()"),
                "\(name) still calls the unbounded waitUntilExit()")
        }
        #expect(scanned == 2)
    }

    /// All four streaming spawns install the termination hook — the count is
    /// the guard against a fifth being added without one.
    @Test("every streaming spawn installs a termination hook")
    func everyStreamingSpawnHasATerminationHook() throws {
        var hooks = 0
        for name in ["LocalTransport.swift", "SSHTransport.swift"] {
            let text = Self.codeOnly(try String(
                contentsOf: Self.transportSources.appendingPathComponent(name),
                encoding: .utf8))
            hooks += text.components(separatedBy: "child.cancel()").count - 1
            #expect(text.components(separatedBy: "child.adopt(proc)").count - 1 == 2,
                    "\(name) should adopt its child in both streaming spawns")
        }
        #expect(hooks == 4, "expected four streaming spawns, found \(hooks)")
    }
}
#endif

#if !os(iOS)
/// Round-5 P48: `SSHScriptRunner`'s two arms move onto the one drain
/// primitive.
///
/// **What these prove, honestly.** The defect fixed is that the old code
/// judged at EXIT rather than at EOF — it nilled both `readabilityHandler`s
/// the instant `isRunning` went false and snapshotted whatever had landed, so
/// a chunk still on the pipe's queue was dropped. That is a RACE, and it did
/// not reproduce on demand: both behavioural tests below pass against the
/// pre-P48 code as well. They are kept as regression guards on the
/// replacement — a drain that collected short, or collected the pipes in the
/// wrong order, would fail them — and the shape sweep is what actually goes
/// red on the old code. The SSH arm needs a remote, so the local arm carries
/// the behaviour and the sweep carries the pair.
@Suite("SSHScriptRunner drains to EOF (P48)")
struct ScriptRunnerDrainP48Tests {

    /// Exit is not EOF; `collect(grace:)` waits for the last EOF. The script
    /// writes several pipe-buffers' worth and then a marker, immediately
    /// before exiting — the window the old snapshot-at-exit could miss.
    @Test("output written immediately before exit arrives whole", .timeLimit(.minutes(1)))
    func theLastChunkSurvivesTheExit() async throws {
        // 400 KB: several pipe-buffers' worth, so there is always a chunk in
        // flight when the process goes.
        let script = "head -c 400000 /dev/zero | tr '\\000' 'z'; printf 'FINAL-LINE'"
        let outcome = await SSHScriptRunner.run(
            script: script, context: .local, timeout: 30)
        guard case .completed(let stdout, _, let exitCode) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(exitCode == 0)
        #expect(stdout.count == 400_010, "got \(stdout.count) bytes")
        #expect(stdout.hasSuffix("FINAL-LINE"))
    }

    /// Repeated so a drop that only happens sometimes cannot pass by luck.
    @Test("the tail survives across repeated runs", .timeLimit(.minutes(2)))
    func theTailSurvivesRepeatedly() async throws {
        for i in 0..<8 {
            let outcome = await SSHScriptRunner.run(
                script: "head -c 100000 /dev/zero | tr '\\000' 'z'; printf 'TAIL-\(i)'",
                context: .local,
                timeout: 30)
            guard case .completed(let stdout, _, _) = outcome else {
                Issue.record("run \(i): expected .completed, got \(outcome)")
                return
            }
            #expect(stdout.hasSuffix("TAIL-\(i)"), "run \(i) lost its tail")
        }
    }

    /// Both arms are on the primitive, and neither hand-rolls a reader any
    /// more — the accumulator class that went with them is gone too.
    @Test("neither arm hand-rolls a reader")
    func bothArmsUseTheSharedDrain() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ScarfCore/Transport/SSHScriptRunner.swift")
        let code = StreamingSpawnP48Tests.codeOnly(try String(contentsOf: url, encoding: .utf8))
        #expect(code.components(separatedBy: "Process.startDraining").count - 1 == 2)
        #expect(!code.contains("readabilityHandler"))
        #expect(!code.contains("LockedData"))
        // One guard spelling per file. ScarfCore's spawn files are all
        // `#if !os(iOS)`; this one alone said `#if os(macOS)`, which is the
        // same set today and a different one the moment ScarfCore builds for
        // anything else.
        #expect(!code.contains("#if os(macOS)"))
    }
}
#endif
