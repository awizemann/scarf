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

    // MARK: - Fixtures

    private static func fixtureJob(lastError: String?) -> HermesCronJob {
        HermesCronJob(
            id: "test-job",
            name: "Test Job",
            prompt: "noop",
            schedule: CronSchedule(kind: "cron", expression: "0 9 * * *"),
            enabled: true,
            state: lastError != nil ? "failed" : "scheduled",
            lastError: lastError
        )
    }
}
