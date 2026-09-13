import Foundation
import os
import ScarfCore
import Testing
@testable import scarf

/// Round-4 P43: the remaining C10 residue in the app target — an undrained
/// stdout pipe on a long-lived child, an env probe that read after the wait,
/// an auth flow with no deadline and handlers left hooked, and a relaunch
/// that leaked the write ends of its pipes.
@Suite("Spawn discipline residue (P43)")
struct SpawnDisciplineP43Tests {

    static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // scarfTests
        .deletingLastPathComponent()   // scarf
        .appendingPathComponent("scarf")

    static func source(_ relative: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - The hazard these fixes are about

    /// The claim every fix in this suite rests on, demonstrated once with a
    /// real child rather than asserted: a pipe nobody reads is not a discard.
    /// The writer blocks in `write()` as soon as the 64 KB buffer fills, and
    /// the parent waits for an exit that can no longer come.
    @Test("an undrained pipe stalls a child past the buffer; nullDevice does not")
    func undrainedPipeStallsTheChild() throws {
        func run(stdout: Any) throws -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "head -c 200000 /dev/zero | tr '\\000' 'x'"]
            p.standardOutput = stdout
            p.standardError = FileHandle.nullDevice
            try p.run()
            let exited = p.waitUntilExit(timeout: 2)
            if !exited { return false }
            return true
        }
        // A pipe with no reader: the child cannot finish inside the budget.
        let pipe = Pipe()
        #expect(try !run(stdout: pipe))
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        // `/dev/null` swallows any volume.
        #expect(try run(stdout: FileHandle.nullDevice))
    }

    // MARK: - HermesProxyService

    /// The proxy child is meant to run for hours. Its stdout was a `Pipe()`
    /// with the comment "discard" — but nothing read it, so the proxy wedged
    /// the moment it had printed 64 KB.
    @Test("the proxy discards stdout to /dev/null, not to an unread pipe")
    func proxyStdoutIsNullDevice() throws {
        let src = try Self.source("Core/Services/HermesProxyService.swift")
        #expect(src.contains("proc.standardOutput = FileHandle.nullDevice"))
        #expect(!src.contains("proc.standardOutput = Pipe()"))
        // stderr IS read — a `readabilityHandler` streams it into the log —
        // so it stays a pipe. This pins the asymmetry as deliberate.
        #expect(src.contains("proc.standardError = pipe"))
    }

    // MARK: - HermesFileService.runShellProbe

    /// The probe read stdout after the wait with `errPipe` never drained, so
    /// an rc file noisy enough to fill 64 KB of stderr — `nvm` warnings, a
    /// `compaudit` line per insecure directory — ran the budget out and the
    /// env probe returned nil for a shell that was working fine.
    @Test("a probe whose shell floods stderr still returns its stdout")
    func shellProbeSurvivesAChattyStderr() throws {
        let script = "head -c 200000 /dev/zero | tr '\\000' 'x' 1>&2; "
            + "printf 'SCARF_P43\\000yes\\000'"
        let result = try #require(
            HermesFileService.runShellProbe(script: script, interactive: false, timeout: 20),
            "the probe came back nil — stderr is stalling the child again")
        #expect(result["SCARF_P43"] == "yes")
    }

    @Test("a probe whose shell never exits is bounded")
    func shellProbeIsBounded() {
        let started = Date()
        let result = HermesFileService.runShellProbe(
            script: "sleep 30", interactive: false, timeout: 0.5)
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    // MARK: - SpotifyAuthFlow

    /// C10's timeout half, grounded in Hermes's own numbers rather than a
    /// guess: `_spotify_wait_for_callback` waits 180 s
    /// (`hermes_cli/auth_spotify.py:154`, passed at `:420` @ v2026.9.7) and
    /// the token exchange adds 20 s (`:433`), so a healthy run always ends
    /// by itself well inside Scarf's ceiling.
    @Test("the Spotify flow's deadline sits above Hermes's own")
    func spotifyDeadlineClearsHermesOwnBudget() {
        #expect(SpotifyAuthFlow.authTimeout > 180 + 20)
        // And is still short enough to be an escape hatch rather than a wait.
        #expect(SpotifyAuthFlow.authTimeout <= 600)
    }

    @Test("the Spotify flow unhooks its readers on EOF and cancels its deadline")
    func spotifyTearsDownItsReaders() throws {
        let src = try Self.source("Core/Services/SpotifyAuthFlow.swift")
        // EOF is an empty `availableData`; the handler must unhook there
        // rather than waiting for a `cancel()` that a successful run never
        // makes. Both pipes go through one `streamHandler`.
        #expect(src.contains("handle.readabilityHandler = nil"))
        // P43b replaced the single shared `streamHandler` with one handler per
        // pipe, each owning its own inbox and EOF latch (see
        // `spotifyVerdictWaitsForEOF`).
        #expect(src.contains("stdoutPipe.fileHandleForReading.readabilityHandler = makeHandler(inbox: stdoutInbox)"))
        #expect(src.contains("stderrPipe.fileHandleForReading.readabilityHandler = makeHandler(inbox: stderrInbox)"))
        // And the EOF latch itself: the verdict waits for both.
        #expect(src.contains("inbox.markEOF()"))
        // The deadline must not outlive the run it was watching.
        #expect(src.contains("deadlineTask?.cancel()"))
    }

    /// `NousAuthFlow` is the sibling this flow was modelled on. It already
    /// unhooked on EOF; pin that so the pair cannot drift apart again.
    @Test("the Nous flow still unhooks on EOF too")
    func nousFlowUnhooksOnEOF() throws {
        let src = try Self.source("Core/Services/NousAuthFlow.swift")
        #expect(src.contains("handle.readabilityHandler = nil"))
    }

    // MARK: - SpotifyAuthFlow's verdict (P43b)

    /// The race the EOF latch removes: `hermes auth spotify` writes the line
    /// that explains a failure immediately before it exits, so the exit status
    /// and the last chunk are in flight together. Judging inside
    /// `terminationHandler` — which is what this flow did — takes the verdict
    /// on output that does not contain the explanation yet.
    @Test("a last stderr line written just before exit 1 reaches the verdict")
    @MainActor
    func spotifyVerdictWaitsForEOF() async throws {
        let flow = SpotifyAuthFlow(context: .local)
        flow.makeAuthProcess = {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Some volume first, so the last line cannot be the only read, and
            // then the distinctive line with nothing after it but the exit.
            p.arguments = [
                "-c",
                "i=0; while [ $i -lt 400 ]; do echo \"filler line $i\" 1>&2; i=$((i+1)); done;"
                + " echo 'SCARF-P43B-LAST-LINE' 1>&2; exit 1",
            ]
            return p
        }
        flow.start()

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if case .failure = flow.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .failure(let reason) = flow.state else {
            Issue.record("the flow never reached a verdict: \(flow.state)")
            return
        }
        #expect(reason.contains("status 1"), Comment(rawValue: reason))
        // `tail(output, lines: 6)` — so the distinctive line has to be in the
        // LAST six, which it is, provided the drain finished before the
        // verdict was taken.
        #expect(reason.contains("SCARF-P43B-LAST-LINE"),
                Comment(rawValue: "the verdict was taken before the last stderr chunk arrived: \(reason)"))
        #expect(flow.output.contains("SCARF-P43B-LAST-LINE"))
    }

    /// `cancel()` was a bare `terminate()` — no escalation on the one path
    /// that exists because the child would not stop — and it closed the READ
    /// ends while a `readabilityHandler` could still be running on them.
    @Test("cancel stops a child that ignores SIGTERM")
    @MainActor
    func spotifyCancelEscalates() async throws {
        let flow = SpotifyAuthFlow(context: .local)
        flow.makeAuthProcess = {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Ignores SIGTERM outright: `terminate()` alone cannot end this.
            p.arguments = ["-c", "trap '' TERM; while true; do sleep 0.1; done"]
            return p
        }
        flow.start()
        // Let it reach the trap.
        try await Task.sleep(nanoseconds: 300_000_000)
        let pid = flow.runningPIDForTesting
        #expect(pid > 0)

        flow.cancel()
        // SIGTERM (ignored) → 2 s grace → SIGKILL → grace. Give it room.
        let deadline = Date().addingTimeInterval(15)
        var gone = false
        while Date() < deadline {
            if kill(pid, 0) != 0 { gone = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(gone, "cancel() left a SIGTERM-ignoring child running")
    }

    /// The launch-failure arm. `start()` had already stored the `Process` and
    /// both pipes on `self` by the time `run()` threw, then returned with a
    /// `.failure` state and every one of them still hooked up: nothing would
    /// ever reach EOF or report an exit, so the run could not end itself, and
    /// the write ends — which on THIS path really are still the parent's,
    /// since Foundation only closes its copies as part of a spawn that
    /// happened — stayed open until the next `start()` replaced them.
    @Test("a launch that fails releases the process and its pipes")
    @MainActor
    func spotifyLaunchFailureReleases() async throws {
        let flow = SpotifyAuthFlow(context: .local)
        flow.makeAuthProcess = {
            let p = Process()
            // Guaranteed absent: a path under a directory that is itself a
            // file in the temp dir would still be a race, so use a name no
            // installer writes.
            p.executableURL = URL(fileURLWithPath: "/var/empty/scarf-p43c-no-such-binary")
            return p
        }
        flow.start()

        guard case .failure(let reason) = flow.state else {
            Issue.record("a missing executable must fail the flow, not start it: \(flow.state)")
            return
        }
        #expect(reason.contains("Couldn't start"), Comment(rawValue: reason))
        #expect(!flow.retainsRunForTesting,
                "the launch-failure arm kept the process and pipes of a run that never happened")
        #expect(flow.runningPIDForTesting == 0)
    }

    // MARK: - What actually leaks at a piped spawn (P43b)

    /// The rationale two call sites carried — "each spawn leaks 4 fds unless
    /// the write ends are closed" — was false, and a false rationale is how a
    /// close gets moved somewhere it raises. Measured here rather than
    /// asserted: it is the READ ends that leak.
    ///
    /// P60: the measurement is the SMALLEST delta over three trials, not one
    /// before/after pair. `/dev/fd` is a PROCESS-global measure and the Mac
    /// suite is run serially only by convention — under parallel load a
    /// single pair also counts whatever a neighbouring suite's spawn happened
    /// to be holding across the window, which is how this test failed on this
    /// branch with the flat arm reading well above its threshold of 10. The
    /// leak under test is DETERMINISTIC (2 descriptors per spawn, so every
    /// trial pays the same +100) while a neighbour's are transient and will
    /// not be open across all three windows, so the minimum separates the two
    /// signals; widening the threshold cannot, because the noise is the same
    /// size as the leak. This is `HermesP48Tests.minimumFDDelta`
    /// (`ScarfCore/Tests/…/HermesP48Tests.swift:117`), reimplemented here
    /// because the two suites live in different targets.
    ///
    /// The minimum is the conservative direction for BOTH assertions: noise
    /// can only ADD descriptors, so it can only inflate the `>= 90` arm and
    /// only inflate the `< 10` one.
    @Test("Foundation closes the parent's write end at spawn; the read end is ours")
    func onlyReadEndsLeak() throws {
        func openFDs() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }
        /// Spawn `/bin/echo` 50 times, keeping every `Pipe` alive so ARC
        /// cannot do the closing for us.
        func spawn50(closeReadEnds: Bool, closeWriteEnds: Bool) -> Int {
            var kept: [Pipe] = []
            let before = openFDs()
            for _ in 0..<50 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/echo")
                p.arguments = ["hi"]
                let out = Pipe()
                let err = Pipe()
                p.standardOutput = out
                p.standardError = err
                try? p.run()
                _ = out.fileHandleForReading.readDataToEndOfFile()
                _ = err.fileHandleForReading.readDataToEndOfFile()
                _ = p.waitUntilExit(timeout: 10)
                if closeReadEnds {
                    try? out.fileHandleForReading.close()
                    try? err.fileHandleForReading.close()
                }
                if closeWriteEnds {
                    try? out.fileHandleForWriting.close()
                    try? err.fileHandleForWriting.close()
                }
                kept.append(out)
                kept.append(err)
            }
            let after = openFDs()
            kept.removeAll()
            return after - before
        }

        /// The smallest delta `body` produced over `trials` runs.
        func minimumFDDelta(trials: Int = 3, _ body: () -> Int) -> Int {
            var smallest = Int.max
            for _ in 0..<trials { smallest = min(smallest, body()) }
            return smallest
        }

        // Read ends left open: 2 per spawn.
        let leaked = minimumFDDelta { spawn50(closeReadEnds: false, closeWriteEnds: true) }
        #expect(leaked >= 90, "smallest fd delta over three trials was \(leaked)")
        // Read ends closed, write ends NOT: flat. Foundation closed the
        // parent's copy of the write end as part of `run()`, so the closes in
        // `AppRelauncher` / `ProjectTemplateService` are no-ops after a
        // successful spawn — kept only because they are the real release on
        // the launch-failure path, where `run()` never spawned.
        let flat = minimumFDDelta { spawn50(closeReadEnds: true, closeWriteEnds: false) }
        #expect(flat < 10, "smallest fd delta over three trials was \(flat)")
    }

    // MARK: - AppRelauncher

    /// Foundation `dup()`s a pipe's ends into the child on `run()`, but the
    /// parent's copies stay open. `waitDraining` closes the READ ends (each
    /// reader closes the handle it drained); the write ends are the caller's,
    /// and nothing was closing these two — 2 fds per relaunch attempt.
    @Test("the relauncher closes the write ends it owns")
    func relauncherClosesItsWriteEnds() throws {
        let src = try Self.source("Core/Services/AppRelauncher.swift")
        #expect(src.contains("try? stderrPipe.fileHandleForWriting.close()"))
        #expect(src.contains("try? stdoutPipe.fileHandleForWriting.close()"))
        // It must NOT close the read ends on the success path: `waitDraining`
        // owns those, and closing a handle a reader is blocked on raises.
        let afterWait = try #require(src.range(of: "let (exited, drained) = await proc.waitDrainingAsync"))
        let tail = String(src[afterWait.upperBound...])
        #expect(!tail.contains("stderrPipe.fileHandleForReading.close()"))
    }

    /// t-b15ba4c3: the 20 s bound was the easy half. The wait ran ON the main
    /// actor, so a wedged LaunchServices froze the window for the whole
    /// budget.
    @Test("the relaunch wait is off the main actor")
    func relaunchIsNonisolated() throws {
        let src = try Self.source("Core/Services/AppRelauncher.swift")
        // `async` since round-5 P48 (t-12d04477): `nonisolated` got it off the
        // MAIN actor, and `waitDrainingAsync` gets the block off the
        // cooperative POOL, which the caller's `Task.detached` never did.
        #expect(src.contains("nonisolated static func relaunch() async throws {"))
        // Its one caller must not have put it back inside a `MainActor.run`.
        let caller = try Self.source("Features/Profiles/ViewModels/ProfilesViewModel.swift")
        let call = try #require(caller.range(of: "try await AppRelauncher.relaunch()"))
        let before = String(caller[..<call.lowerBound])
        let lastRun = before.range(of: "await MainActor.run", options: .backwards)
        let lastClose = before.range(of: "guard switched else { return }", options: .backwards)
        let runAt = lastRun.map { before.distance(from: before.startIndex, to: $0.lowerBound) } ?? -1
        let closeAt = lastClose.map { before.distance(from: before.startIndex, to: $0.lowerBound) } ?? -1
        #expect(closeAt > runAt, "relaunch() is back inside a MainActor.run block")
    }
}
