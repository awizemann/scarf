import Foundation
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
        #expect(src.contains("stdoutPipe.fileHandleForReading.readabilityHandler = streamHandler"))
        #expect(src.contains("stderrPipe.fileHandleForReading.readabilityHandler = streamHandler"))
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
        let afterWait = try #require(src.range(of: "let (exited, drained) = proc.waitDraining"))
        let tail = String(src[afterWait.upperBound...])
        #expect(!tail.contains("stderrPipe.fileHandleForReading.close()"))
    }

    /// t-b15ba4c3: the 20 s bound was the easy half. The wait ran ON the main
    /// actor, so a wedged LaunchServices froze the window for the whole
    /// budget.
    @Test("the relaunch wait is off the main actor")
    func relaunchIsNonisolated() throws {
        let src = try Self.source("Core/Services/AppRelauncher.swift")
        #expect(src.contains("nonisolated static func relaunch() throws {"))
        // Its one caller must not have put it back inside a `MainActor.run`.
        let caller = try Self.source("Features/Profiles/ViewModels/ProfilesViewModel.swift")
        let call = try #require(caller.range(of: "try AppRelauncher.relaunch()"))
        let before = String(caller[..<call.lowerBound])
        let lastRun = before.range(of: "await MainActor.run", options: .backwards)
        let lastClose = before.range(of: "guard switched else { return }", options: .backwards)
        let runAt = lastRun.map { before.distance(from: before.startIndex, to: $0.lowerBound) } ?? -1
        let closeAt = lastClose.map { before.distance(from: before.startIndex, to: $0.lowerBound) } ?? -1
        #expect(closeAt > runAt, "relaunch() is back inside a MainActor.run block")
    }
}
