import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Exercises `CronViewModel.selectedErrorClassification` — the bridge
/// between Hermes's cron `last_error` field and the in-app re-auth
/// affordance. Covers the OAuth-revoked path that motivated the surface
/// (real string captured from `~/.hermes/cron/jobs.json` when an
/// OAuth-authed provider's refresh session is invalidated) plus the
/// "no error" + "unrecognized error" branches the UI relies on.
@Suite struct CronViewModelErrorClassificationTests {

    /// The exact `last_error` string Hermes writes to `~/.hermes/cron/jobs.json`
    /// after an OAuth-authed cron run hits a revoked refresh session.
    /// Captured from a live failed run on 2026-05-03 — if Hermes ever
    /// changes the wording, this test breaks loudly so we know to
    /// update the matcher in `ACPErrorHint.classify`.
    private static let revokedErrorString =
        "RuntimeError: Refresh session has been revoked Run `hermes model` to re-authenticate."

    @Test @MainActor func oauthRevokedErrorClassifies() {
        let vm = CronViewModel()
        vm.selectedJob = Self.fixtureJob(lastError: Self.revokedErrorString)

        let classification = vm.selectedErrorClassification
        #expect(classification != nil)
        #expect(classification?.hint.contains("Re-authenticate") == true
                || classification?.hint.contains("re-authenticate") == true
                || classification?.hint.contains("revoked") == true
                || classification?.hint.contains("expired") == true)
        // The classifier returns nil oauthProvider when no provider word
        // is present in the haystack — Hermes's revoked-session line
        // doesn't always include the provider name. Either result is
        // acceptable to the UI: a non-nil provider lets the row render
        // a "Re-authenticate" button; a nil provider still surfaces the
        // human hint without the button.
        _ = classification?.oauthProvider
    }

    @Test @MainActor func noSelectedJobReturnsNil() {
        let vm = CronViewModel()
        #expect(vm.selectedErrorClassification == nil)
    }

    @Test @MainActor func selectedJobWithoutErrorReturnsNil() {
        let vm = CronViewModel()
        vm.selectedJob = Self.fixtureJob(lastError: nil)
        #expect(vm.selectedErrorClassification == nil)
    }

    @Test @MainActor func unrecognizedErrorReturnsNil() {
        // ACPErrorHint returns nil when no pattern matches; the UI
        // falls back to rendering the raw lastError without the
        // re-auth banner.
        let vm = CronViewModel()
        vm.selectedJob = Self.fixtureJob(
            lastError: "RuntimeError: cron-specific failure that doesn't match any known pattern"
        )
        #expect(vm.selectedErrorClassification == nil)
    }

    // MARK: - Terminal-job activation (Hermes v0.20.6+, W7)

    /// `update_job` raises "Cannot activate terminal cron job …"
    /// (cron/jobs.py:2593/2694) and `trigger_job` raises "Cannot run:
    /// … (terminal)" (:2760). Both must land as one plain sentence, not
    /// a Python traceback tail.
    @Test func terminalRefusalsGetAFriendlyMessage() {
        let updateErr = "ValueError: Cannot activate terminal cron job 'Nightly' "
            + "through update_job; use cron resume --run-now or --at."
        #expect(CronViewModel.friendlyCronFailure(updateErr)?.contains("Resume & Run Now") == true)

        let triggerErr = "ValueError: Cannot run: job 'Nightly' is completed (terminal). "
            + "Create a new occurrence with 'hermes cron resume Nightly --run-now'."
        #expect(CronViewModel.friendlyCronFailure(triggerErr)?.contains("Resume & Run Now") == true)

        // Everything else keeps the raw-output path.
        #expect(CronViewModel.friendlyCronFailure("error: no such job 'x'") == nil)
        #expect(CronViewModel.friendlyCronFailure("") == nil)
    }

    /// The pre-check: on a v0.20.6+ host, resuming a completed/error job
    /// never reaches the CLI, and the message names the affordance that
    /// actually works.
    @Test @MainActor func resumingATerminalJobIsRefusedLocallyOnV0206Hosts() {
        let vm = CronViewModel()
        vm.isV0206OrLater = true
        vm.resumeJob(Self.fixtureJob(lastError: nil, state: "completed"))
        #expect(vm.message?.contains("Resume & Run Now") == true)
    }

    /// The refusal is a *mirror* of a host-side guard, not a Scarf policy.
    /// Those guards (`update_job`'s "Cannot activate terminal cron job",
    /// `trigger_job`'s "(terminal)") arrived in v0.20.6: verified absent at
    /// tag `v2026.8.19` and present at `v2026.8.27`. On an older host the
    /// resume/run would have SUCCEEDED, so refusing client-side would deny
    /// an operation the host accepts — a worse failure than the raw Python
    /// tail the pre-check exists to avoid. Asserted on the decision
    /// function rather than by calling `resumeJob`, which would spawn a
    /// real CLI invocation.
    @Test @MainActor func pre0206HostsAreLeftToTheCLI() {
        let old = CronViewModel()
        old.isV0206OrLater = false
        #expect(old.refusesTerminalJobLocally(Self.fixtureJob(lastError: "boom", state: "error")) == false)
        #expect(old.refusesTerminalJobLocally(Self.fixtureJob(lastError: nil, state: "completed")) == false)

        let current = CronViewModel()
        current.isV0206OrLater = true
        #expect(current.refusesTerminalJobLocally(Self.fixtureJob(lastError: "boom", state: "error")))
        // Non-terminal states are never short-circuited on either host.
        #expect(current.refusesTerminalJobLocally(Self.fixtureJob(lastError: nil, state: "scheduled")) == false)
    }

    /// `hermes cron incidents ack` returns **0** even when it acked
    /// nothing: `ack_incident` falsy → yellow "not found or already
    /// closed." → `return 0` (`hermes_cli/cron.py:322-335`). Reporting
    /// that as "Incident acknowledged" tells the user a lie they can't
    /// check.
    @Test func ackMissPathIsNotReportedAsSuccess() {
        #expect(CronViewModel.ackOutcomeMessage(
            exitCode: 0, output: "✓ Incident inc_7 acknowledged (closed).") == "Incident acknowledged")
        #expect(CronViewModel.ackOutcomeMessage(
            exitCode: 0, output: "Incident inc_7 not found or already closed."
        ).contains("already closed"))
        #expect(CronViewModel.ackOutcomeMessage(
            exitCode: 1, output: "✗ Incident ID required"
        ).hasPrefix("Couldn't acknowledge"))
    }

    /// The inverse of the pre-check, asserted on the model rather than
    /// by invoking the VM — `resumeJob` on a non-terminal job spawns a
    /// real CLI call, which has no place in a unit test.
    @Test func nonTerminalStatesAreNotShortCircuited() {
        #expect(Self.fixtureJob(lastError: nil, state: "paused").isTerminal == false)
        #expect(Self.fixtureJob(lastError: nil, state: "scheduled").isTerminal == false)
        #expect(Self.fixtureJob(lastError: nil, state: "running").isTerminal == false)
    }

    // MARK: - Fixtures

    private static func fixtureJob(lastError: String?, state: String? = nil) -> HermesCronJob {
        HermesCronJob(
            id: "test-job",
            name: "Test Job",
            prompt: "noop",
            schedule: CronSchedule(kind: "cron", expression: "0 9 * * *"),
            enabled: true,
            state: state ?? (lastError != nil ? "failed" : "scheduled"),
            lastError: lastError
        )
    }
}
