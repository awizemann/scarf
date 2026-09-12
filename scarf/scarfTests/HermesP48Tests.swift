import Testing
import Foundation
@testable import scarf

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

    /// `run()` threw, so there was no fork and Foundation closed the parent's
    /// copy of NEITHER end. Nilling the readability handler — which was the
    /// whole of the old teardown, under a comment claiming it avoided the
    /// leak — releases no descriptor at all, so every failed Start (a port
    /// already in use is the common one) cost two fds for the life of the
    /// process.
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
    @Test("stop escalates through the bounded primitive, off the main actor")
    func stopEscalatesOffTheMainActor() throws {
        let code = Self.codeOnly(try Self.source(Self.proxyPath))
        #expect(code.contains("waitUntilExit(timeout: ceiling)"))
        // A THREAD, not `Task.detached`: the primitive is a `Thread.sleep`
        // poll loop and `Task.detached` is the same cooperative pool (P43c).
        #expect(code.contains("Thread.detachNewThread"))
        #expect(!code.contains("Task.detached {\n            _ = proc.waitUntilExit"))
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
        // Bounded escalation on the overrun arm, not a bare `terminate()`.
        #expect(code.contains("proc.waitUntilExit(timeout: 0)"))
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
