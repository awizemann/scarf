import Testing
import Foundation
@testable import scarf
import ScarfCore

/// Round-6 P53 — the `auth logout` verdict's third branch.
///
/// P47b's lesson, one verdict over: "a three-state verdict needs three
/// branches at the call site, not two." `HermesAuthLogoutVerdict.judge`
/// returns `.unconfirmed` for exit 0 with neither `Logged out of {provider}.`
/// (`hermes_cli/auth.py:2189` @ `v2026.9.7`) nor either idle line (`:2180`,
/// `:2185`) — C5's "we do not know". The credential-pool pane had a two-way
/// `if`, so that arm landed in the failure branch and, on a run that printed
/// nothing at all, rendered "Remove failed: exit 0": the exit code the
/// verdict had just declared meaningless, quoted at the user.
@Suite("`auth logout` answers its third state (P53)")
@MainActor
struct AuthLogoutUnconfirmedP53Tests {

    /// Exit 0, no output at all — the shape that produced "exit 0".
    @Test("a silent exit-0 logout says Hermes printed nothing, never `exit 0`")
    func aSilentRunNamesNoExitCode() {
        let outcome = HermesAuthLogoutVerdict.judge(output: "", exitCode: 0)
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .unconfirmed)
        let text = CredentialPoolsViewModel.removeFailureSummary(outcome: outcome, exitCode: 0)
        #expect(!text.contains("exit 0"), """
            The strip quotes an exit code the verdict has already declared \
            meaningless: \(text)
            """)
        #expect(text.contains("printed no result"), "got: \(text)")
    }

    /// Exit 0 with output Hermes did print but neither marker matched: the
    /// line IS the only thing worth showing, and still no exit code.
    @Test("an unconfirmed run with output quotes the output, not the status")
    func anUnconfirmedRunQuotesItsLine() {
        let outcome = HermesAuthLogoutVerdict.judge(
            output: "Provider anthropic is managed by your administrator.", exitCode: 0)
        #expect(outcome.confidence == .unconfirmed)
        let text = CredentialPoolsViewModel.removeFailureSummary(outcome: outcome, exitCode: 0)
        #expect(text.contains("managed by your administrator"), "got: \(text)")
        #expect(!text.contains("exit 0"), "got: \(text)")
    }

    /// A real non-zero failure is unchanged — it keeps quoting Hermes's own
    /// reason, which is what tells a refusal from a missing verb.
    @Test("a non-zero failure still surfaces the CLI's reason")
    func aRealFailureKeepsItsReason() {
        let outcome = HermesAuthLogoutVerdict.judge(
            output: "Error: unknown provider 'nope'", exitCode: 2)
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence != .unconfirmed)
        let text = CredentialPoolsViewModel.removeFailureSummary(outcome: outcome, exitCode: 2)
        #expect(text.contains("unknown provider"), "got: \(text)")
    }

    /// The last resort, and the only arm that may name a status: a non-zero
    /// exit whose output was empty. There is nothing else to say.
    @Test("a silent non-zero failure falls back to the exit code")
    func aSilentNonZeroFailureNamesItsExitCode() {
        let outcome = HermesAuthLogoutVerdict.judge(output: "", exitCode: 127)
        let text = CredentialPoolsViewModel.removeFailureSummary(outcome: outcome, exitCode: 127)
        #expect(text.contains("127"), "got: \(text)")
    }

    /// Both idle arms stay a SUCCESS with a neutral note (round-5 decision 2)
    /// — the formatter must never see them.
    @Test("the idle arms never reach the failure formatter")
    func theIdleArmsAreStillSuccesses() {
        for line in ["No provider is currently logged in.", "No auth state found for anthropic."] {
            let outcome = HermesAuthLogoutVerdict.judge(output: line, exitCode: 0)
            #expect(outcome.succeeded, "\(line) stopped being a success")
            #expect(outcome.warning != nil, "\(line) lost its neutral note")
        }
    }
}
