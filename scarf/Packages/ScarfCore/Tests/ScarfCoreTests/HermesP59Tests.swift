import Testing
import Foundation
@testable import ScarfCore

/// Round-6 P59 — `.unconfirmed` is gated on the CONFIDENCE ALONE.
///
/// P54b established the invariant on `backupFailureSummary` and
/// `sessionsOptimizeSummary`: `judge` fills `detail` with `lines.last` on the
/// unconfirmed arm too, so a consumer that reaches its honest sentence only
/// when `detail` is nil/empty renders an unrelated progress line as Hermes's
/// stated reason for a refusal Hermes never made. The cross-phase review found
/// three pre-existing producers still collapsed two ways; the memory-reset one
/// had TWO views doing it, which is why the branches now live here.
@Suite("memory reset's unconfirmed arm is keyed on confidence (P59)")
struct MemoryResetFailureSummaryP59Tests {

    /// The fixture that matters: exit 0, NON-empty output, neither marker.
    /// `_cmd_memory_reset` prints `Memory reset complete.` (`:55`) or
    /// `Nothing to reset — no memory files found in …` (`:33`)
    /// (`hermes_cli/main_agent_cmds.py` @ `v2026.9.7`); anything else at
    /// exit 0 is "we do not know".
    @Test("a non-empty unconfirmed run is not quoted as the reason")
    func unconfirmedWithDetailIsNotQuoted() {
        let outcome = HermesMemoryResetVerdict.judge(
            output: "Scanning ~/.hermes/memories ...\nLoaded profile: default",
            exitCode: 0
        )
        #expect(outcome.confidence == .unconfirmed)
        #expect(outcome.detail?.isEmpty == false,
                "the fixture must carry a tail, or it cannot distinguish the two gates")
        let text = HermesMemoryResetVerdict.failureSummary(outcome: outcome, exitCode: 0)
        #expect(text == "hermes memory reset printed no result. Check the host.", """
            An unconfirmed run's unrelated tail is presented as the alert's \
            reason: "\(text)". The gate is the confidence, not whether there \
            is a line to quote.
            """)
    }

    @Test("an empty unconfirmed run says the same thing")
    func unconfirmedWithoutDetail() {
        let outcome = HermesMemoryResetVerdict.judge(output: "", exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        #expect(HermesMemoryResetVerdict.failureSummary(outcome: outcome, exitCode: 0)
                == "hermes memory reset printed no result. Check the host.")
    }

    /// The other two arms, unchanged: a real failure still quotes Hermes.
    @Test("a non-zero exit still quotes the CLI's own line, or its status")
    func failedArmsAreUnchanged() {
        let spoken = HermesMemoryResetVerdict.judge(
            output: "Error: permission denied on ~/.hermes/memories", exitCode: 1)
        #expect(spoken.confidence == .failed)
        #expect(HermesMemoryResetVerdict.failureSummary(outcome: spoken, exitCode: 1)
                == "Error: permission denied on ~/.hermes/memories")

        let silent = HermesMemoryResetVerdict.judge(output: "", exitCode: 3)
        #expect(silent.confidence == .failed)
        #expect(HermesMemoryResetVerdict.failureSummary(outcome: silent, exitCode: 3)
                == "hermes memory reset exited with status 3.")
    }

    /// And the success arms never reach the formatter.
    @Test("both success markers are successes")
    func successArms() {
        #expect(HermesMemoryResetVerdict.judge(
            output: "Memory reset complete.", exitCode: 0).succeeded)
        let nothing = HermesMemoryResetVerdict.judge(
            output: "Nothing to reset — no memory files found in ~/.hermes", exitCode: 0)
        #expect(nothing.succeeded)
        #expect(nothing.warning == HermesMemoryResetVerdict.nothingToResetNote)
    }
}
