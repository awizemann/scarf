#if !os(iOS)
import Testing
import Foundation
@testable import ScarfCore

/// Round-6 P58 — ``ProcessACPChannel/close()``'s watchdog insists.
///
/// The close path is SIGINT (so a Python child raises `KeyboardInterrupt`
/// and flushes instead of aborting mid-JSON-write), then a watchdog whose
/// comment promised to "force-kill if still running". It did not: it sent
/// SIGTERM and stopped. A child that traps or ignores both — a Python whose
/// interrupt handler is itself wedged, an `ssh` blocked in an
/// uninterruptible read on a half-open connection — survived the close
/// entirely, holding the pipes and the pid for as long as the app ran.
///
/// The escalation the rest of the app already uses ends in a pid-guarded
/// SIGKILL (`Process.waitUntilExit(timeout:)`, `HermesProxyService.stop()`,
/// round-5 P48b's proxy Stop shape). Now this one does too.
@Suite("ACP close escalates to SIGKILL (P58)")
struct ACPCloseWatchdogP58Tests {

    /// A child that ignores BOTH the interrupt and the terminate, so only
    /// SIGKILL can end it. `sh` resets ignored dispositions for its own
    /// children, so the trap has to be in the shell that stays alive.
    @Test("a child that ignores SIGINT and SIGTERM is killed anyway")
    func watchdogEscalatesPastAnIgnoredSIGTERM() async throws {
        let channel = try await ProcessACPChannel(
            executable: "/bin/sh",
            args: ["-c", "trap '' INT TERM; echo ready; while :; do sleep 1; done"],
            env: [:]
        )
        // Wait for the child to have installed the trap before closing —
        // otherwise the test can pass by racing it.
        var iterator = channel.incoming.makeAsyncIterator()
        #expect(try await iterator.next() == "ready")

        await channel.close()

        // Two graces plus slack. The bound matters: with the old watchdog
        // this NEVER comes true, so the test must fail rather than hang.
        let ceiling = ProcessACPChannel.closeGrace * 3 + 8
        let deadline = Date().addingTimeInterval(ceiling)
        var alive = true
        while Date() < deadline, alive {
            alive = await channel.childIsRunning
            if alive { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        #expect(!alive, """
            The child ignored SIGINT and SIGTERM and is still running after \
            \(ceiling) s. `close()`'s watchdog stops at SIGTERM again — the \
            comment promises a force-kill that does not happen.
            """)
    }

    /// The grace is a named constant rather than an inline `2_000_000_000`,
    /// because the test above computes its own ceiling from it.
    @Test("the close grace is bounded and short")
    func closeGraceIsSane() {
        #expect(ProcessACPChannel.closeGrace > 0)
        #expect(ProcessACPChannel.closeGrace <= 5)
    }
}
#endif
