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

    /// The pre-check: resuming a completed/error job never reaches the
    /// CLI, and the message names the affordance that actually works.
    @Test @MainActor func resumingATerminalJobIsRefusedLocally() {
        let vm = CronViewModel()
        vm.supportsResumeRunNow = true
        vm.resumeJob(Self.fixtureJob(lastError: nil, state: "completed"))
        #expect(vm.message?.contains("Resume & Run Now") == true)

        // Pre-0.20.6 host: no run-now escape hatch to point at.
        let old = CronViewModel()
        old.supportsResumeRunNow = false
        old.resumeJob(Self.fixtureJob(lastError: "boom", state: "error"))
        #expect(old.message?.contains("Duplicate it") == true)
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
