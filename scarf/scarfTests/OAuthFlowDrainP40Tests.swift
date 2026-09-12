import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P40 — `t-bd119897`: `OAuthFlowController` judged its run at
/// `terminationHandler` time, nilling the reader as it went, so a failure line
/// written just before the process exited was dropped and
/// `succeeded = exitCode == 0 && !outputFailed` failed toward TRUE.
///
/// The cure is `MCPLoginController`'s choreography, now shared:
/// ``ProcessOutputInbox`` sequences the text where it is PRODUCED, the reader
/// stays installed past termination, and `pump()` judges only once EOF AND the
/// exit status are both in — with `scheduleDrainDeadline` so a pipe held open
/// by something else cannot hang the sheet.
@Suite("OAuthFlowDrainP40")
@MainActor
struct OAuthFlowDrainP40Tests {

    private static func sh(_ script: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        return p
    }

    private static func settle(
        _ controller: OAuthFlowController, timeout: TimeInterval = 30
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The reported bug, made deterministic. The shell exits 0 at once while a
    /// backgrounded subshell — which inherited the pipe's write end — prints
    /// the failure line 400 ms later. Before the fix the verdict was taken in
    /// the termination handler, which had already unhooked the reader, so the
    /// line never arrived and the flow reported SUCCESS on a login that
    /// returned no credentials.
    @Test func aFailureLineWrittenAfterTheExitIsStillJudged() async {
        let proc = Self.sh(
            "( sleep 0.4; printf 'login did not return credentials\\n' ) & exit 0"
        )
        let controller = OAuthFlowController(context: .local, makeAuthProcess: { _ in proc })
        controller.start(provider: "anthropic", label: "")
        await Self.settle(controller)

        #expect(controller.output.contains("did not return credentials"),
                "the late chunk was dropped: \(controller.output.debugDescription)")
        #expect(controller.succeeded == false,
                "an OAuth run that returned no credentials was reported as a success")
        #expect(controller.errorMessage != nil)
    }

    /// The other half: a run that really did succeed must not be failed by the
    /// wait. Nothing holds the pipe, EOF arrives with the exit.
    @Test func aCleanRunStillSucceeds() async {
        let proc = Self.sh("printf 'Saved credential\\n'; exit 0")
        let controller = OAuthFlowController(context: .local, makeAuthProcess: { _ in proc })
        controller.start(provider: "anthropic", label: "")
        await Self.settle(controller)

        #expect(controller.succeeded == true, "errorMessage: \(controller.errorMessage ?? "nil")")
        #expect(controller.output.contains("Saved credential"))
    }

    /// `scheduleDrainDeadline`: a process can exit while something else still
    /// holds the write end (the browser helper `webbrowser.open` spawned), and
    /// then EOF never arrives. Waiting for the reader is right; waiting forever
    /// would leave the sheet spinning with the verdict already knowable.
    @Test func aPipeHeldOpenPastTheGraceIsJudgedAnyway() async {
        let proc = Self.sh("( sleep 20 ) & exit 0")
        let controller = OAuthFlowController(context: .local, makeAuthProcess: { _ in proc })
        controller.start(provider: "anthropic", label: "")
        await Self.settle(controller, timeout: 15)

        #expect(controller.isRunning == false, "the drain deadline did not fire")
        // Exit 0 with nothing printed: the controller's own markers cannot see
        // a failure, so this stays its historical `succeeded == true`. What the
        // test pins is that a verdict was REACHED rather than hung.
        controller.stop()
    }

    /// A retired run's reader must be unhooked and its process terminated, so
    /// its output can never be attributed to the run that replaced it. Same
    /// invariant `MCPLoginController` carries; `stop()` bumps the generation
    /// BEFORE terminating, and the spawn continuation closes the window where
    /// `stop()` saw a nil `stdoutPipe`.
    @Test func aRetiredRunsReaderIsUnhookedWhenItsSpawnResumes() async throws {
        let runA = Self.sh("exec sleep 30")
        let runB = Self.sh("sleep 0.6; printf 'Saved credential b\\n'; exit 0")
        final class Handout { var count = 0 }
        let handout = Handout()
        let controller = OAuthFlowController(context: .local, makeAuthProcess: { _ in
            handout.count += 1
            return handout.count == 1 ? runA : runB
        })
        controller.start(provider: "a", label: "")
        // No `await` between the two: B lands before A's spawn continuation
        // can have resumed, which IS the window.
        controller.start(provider: "b", label: "")

        let pipeA = try #require(runA.standardOutput as? Pipe)
        let deadline = Date().addingTimeInterval(60)
        while pipeA.fileHandleForReading.readabilityHandler != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pipeA.fileHandleForReading.readabilityHandler == nil,
                "the retired run's reader is still installed and feeding the live run")
        #expect(runA.isRunning == false, "the retired run was not terminated")

        await Self.settle(controller)
        #expect(controller.succeeded == true, "run B: \(controller.errorMessage ?? "nil")")
        #expect(controller.output.contains("Saved credential b"))
        controller.stop()
    }
}
