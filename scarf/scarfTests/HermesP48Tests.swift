import Testing
import Foundation
@testable import scarf
import ScarfCore

/// Round-5 P48 — the Mac target's share of the C10 residue.
///
/// `HermesProxyService` is `@MainActor` and owns its `Process` privately, and
/// both defects here live on paths a test cannot drive without a real
/// `hermes proxy` child (a launch that FAILS, and a Stop against a child that
/// refuses SIGTERM). The shape in the source is the available alarm, which is
/// the P42c `buildJob` precedent; each was watched reporting the old text
/// before the fix went in.
@Suite("Hermes proxy lifecycle (P48)")
struct HermesProxyLifecycleP48Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/scarfTests
            .deletingLastPathComponent()   // …/scarf
            .deletingLastPathComponent()   // repo root
    }

    private static func source(_ relative: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Code text with comment-only lines dropped — every fix below left a
    /// comment naming the shape it removed, and a raw `contains` would match
    /// the explanation instead of the code.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static let proxyPath = "scarf/scarf/Core/Services/HermesProxyService.swift"

    /// The old teardown nilled the readability handler under a comment
    /// claiming it avoided an fd leak, which is not what that line does.
    ///
    /// **The leak itself was not real**, and this says so: `run()` threw, so
    /// nothing spawned, and a `Pipe` nobody keeps closes both descriptors in
    /// `deinit` — measured at 50 dropped pipes leaving `/dev/fd` at 4. The
    /// closes are the explicit release at a point the code states, and the
    /// comment no longer claims something the line does not do. Like the
    /// ScarfCore twins, this test therefore pins the shape rather than a
    /// behavioural fix.
    @Test("a failed proxy launch closes both ends of its pipe")
    func failedLaunchClosesThePipe() throws {
        let code = Self.codeOnly(try Self.source(Self.proxyPath))
        #expect(code.contains("try? pipe.fileHandleForReading.close()"))
        #expect(code.contains("try? pipe.fileHandleForWriting.close()"))
    }

    /// `stop()` was a bare `terminate()`: no escalation, no ceiling. A
    /// `hermes proxy` that ignores SIGTERM or is wedged left the Stop button
    /// looking like it had worked while the child kept port 8645 against the
    /// next Start.
    ///
    /// **And the ask comes FIRST.** P48's first attempt handed the ceiling to
    /// `waitUntilExit(timeout:)` and nothing else — but that primitive signals
    /// only once its budget is SPENT, so Stop polled a child nobody had asked
    /// to leave for the whole three seconds and only then sent SIGTERM. This
    /// pins the order inside `stop()` itself: a `terminate()` above the
    /// detached wait. The old shape had no `terminate()` in the function at
    /// all, so it fails this outright (round-5 P48b).
    @Test("stop asks first, then escalates through the bounded primitive off the main actor")
    func stopEscalatesOffTheMainActor() throws {
        let code = Self.codeOnly(try Self.source(Self.proxyPath))
        let body = try #require(
            code.range(of: "func stop() {").map { String(code[$0.upperBound...]) },
            "stop() is gone from the proxy service")
        let terminate = try #require(
            body.range(of: "proc.terminate()"),
            "stop() never sends SIGTERM — the ceiling is grace AFTER the ask")
        let wait = try #require(
            body.range(of: "waitUntilExit(timeout: ceiling)"),
            "stop() no longer escalates through the bounded primitive")
        #expect(terminate.lowerBound < wait.lowerBound,
                "stop() waits out its whole ceiling before asking the child to leave")
        // A THREAD, not `Task.detached`: the primitive is a `Thread.sleep`
        // poll loop and `Task.detached` is the same cooperative pool (P43c).
        #expect(code.contains("Thread.detachNewThread"))
        #expect(!code.contains("Task.detached {\n            _ = proc.waitUntilExit"))
    }

    /// Why the order is worth a test: the primitive's budget is a POLL, not a
    /// grace period. Same child, same ceiling — the only difference is whether
    /// it was asked to leave first, and that difference is the whole ceiling.
    @Test("the primitive's budget is time spent waiting, not time spent dying")
    func theCeilingIsGraceOnlyAfterTheAsk() throws {
        func spawnSleeper() throws -> Process {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", "sleep 30"]
            try proc.run()
            return proc
        }

        let unasked = try spawnSleeper()
        defer { if unasked.isRunning { unasked.terminate() } }
        var clock = Date()
        _ = unasked.waitUntilExit(timeout: 1)
        let polled = Date().timeIntervalSince(clock)

        let asked = try spawnSleeper()
        asked.terminate()
        clock = Date()
        _ = asked.waitUntilExit(timeout: 1)
        let signalled = Date().timeIntervalSince(clock)

        #expect(polled >= 0.9, "a child that was never asked should burn the budget, took \(polled)s")
        #expect(signalled < 0.5, "a child already sent SIGTERM should go at once, took \(signalled)s")
    }

    /// The P22 main-actor sweep learned `Thread.detachNewThread` as an
    /// opt-out in P48, because `stop()` is main-actor-isolated by default and
    /// the escalation inside it is not. The opt-out must stay NARROW: a
    /// thread has no actor, but `Task.detached` is the same cooperative pool
    /// the caller was on and must keep counting as a hit.
    @Test("the main-actor sweep excuses a thread, never a detached task")
    func theP22OptOutIsNarrow() throws {
        let sweep = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("MainActorSpawnDisciplineP22Tests.swift"),
            encoding: .utf8)
        #expect(sweep.contains("""
            if trimmed.contains("Thread.detachNewThread") { optedOut = true; break }
            """.trimmingCharacters(in: .whitespaces)))
        #expect(!sweep.contains("""
            if trimmed.contains("Task.detached") { optedOut = true; break }
            """.trimmingCharacters(in: .whitespaces)))
    }

    /// The ceiling is a named constant with a stated reason, not a literal
    /// buried in the call — the house rule for every C10 budget since P43.
    @Test("the stop ceiling is a named budget")
    func stopCeilingIsNamed() throws {
        #expect(HermesProxyService.stopCeiling > 0)
        #expect(HermesProxyService.stopCeiling <= 10)
    }
}

/// Round-5 P48: the SSH connection probe.
///
/// `TestConnectionProbe.run()` dials a real host, so the behaviour cannot be
/// driven from a unit test. What is pinned is the shape that made the bug —
/// two `readToEnd()` calls AFTER the wait, on pipes nothing drained during
/// the run — and the named budget that replaced the two drifting literals.
@Suite("Connection probe drains while it runs (P48)")
struct ConnectionProbeDrainP48Tests {

    private static var probeSource: String {
        (try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "scarf/Features/Servers/ViewModels/TestConnectionProbe.swift"),
            encoding: .utf8)) ?? ""
    }

    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The probe runs `ssh -vvv`, so a stderr trace past the 64 KB pipe
    /// buffer is the EXPECTED case: undrained, ssh blocked in `write()`, the
    /// poll ran its full twenty seconds, and a working connection was
    /// reported as "Timed out after 20s" — the probe manufacturing the
    /// failure it exists to diagnose.
    @Test("both pipes are drained for the whole run, not read after the wait")
    func probeDrainsDuringTheRun() throws {
        let code = Self.codeOnly(Self.probeSource)
        #expect(code.contains("Process.startDraining(pipes: [stdoutPipe, stderrPipe])"))
        #expect(!code.contains("readToEnd()"))
        // Bounded escalation on the overrun arm, not a bare `terminate()` —
        // and through the ASYNC twin, because this closure is `async` and the
        // synchronous form would park a cooperative-pool thread.
        #expect(code.contains("waitDrainingAsync(timeout: 0, drain: drain)"))
        #expect(!code.contains("proc.terminate()"))
    }

    /// The deadline and the sentence the user reads were two independent
    /// literals — `20` and "Timed out after 20s" — and
    /// `AnalyticsConnectionEventsTests` classifies a timeout by that prefix.
    @Test("the probe budget is one named constant")
    func theBudgetIsNamed() throws {
        #expect(TestConnectionProbe.probeTimeout == 20)
        let code = Self.codeOnly(Self.probeSource)
        #expect(code.contains("Self.probeTimeout"))
        #expect(!code.contains("\"Timed out after 20s"))
    }
}

