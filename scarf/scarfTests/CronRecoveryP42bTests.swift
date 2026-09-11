import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P42b · the two `rearm_oneshot` refusal families that fell through
/// `friendlyCronFailure` to the generic `prefix(200)` truncation of raw CLI
/// text.
///
/// Both reach the user the same way: `rearm_oneshot` raises `ValueError` and
/// `cron_resume` catches it, prints `Failed to re-arm job: {exc}` and returns
/// 1 (`hermes_cli/cron.py:691-695` @ `v2026.9.7`).
@MainActor
@Suite struct CronRearmRefusalP42bTests {

    /// `_REARM_RECURRING_ERROR` (`cron/jobs.py:2040-2042`), raised both on the
    /// parsed schedule (`:2054`) and on the stored record (`:2066`).
    /// Reachable whenever the offer was computed against a record since
    /// edited to a recurring schedule.
    @Test func theRecurringRearmRefusalGetsItsOwnSentence() throws {
        let output = "Failed to re-arm job: Cannot re-arm recurring jobs: re-arm is one-shot-only; use plain resume or cron run."
        let text = try #require(CronViewModel.friendlyCronFailure(output))
        #expect(text.contains("one-shot"))
        #expect(text.contains("repeats"))
        // The point of the arm: it is not the raw CLI line.
        #expect(text != output)
    }

    /// The live-claim refusals (`cron/jobs.py:2061-2064`). The remedy was
    /// verified against the claim logic rather than assumed: `_claim_is_live`
    /// (`:2031-2037`) is true only for a well-formed claim aged within
    /// `[0, ttl)` — run-claim TTL ≥ 1800s (`ONESHOT_RUN_CLAIM_TTL_SECONDS`,
    /// `:154`, applied as a floor by `max(timeout * 3, 1800)`, `:174`; the
    /// 600 beside it is the INACTIVITY timeout, `:161`), fire-claim TTL 300s
    /// (`:891`) — and a future-dated or malformed claim counts as STALE, so
    /// the claim cannot outlive the run and "try again after it finishes" is
    /// an honest remedy.
    @Test func bothLiveClaimRefusalsShareOneHonestSentence() throws {
        for line in ["Failed to re-arm job: Cannot re-arm one-shot over a live run claim.",
                     "Failed to re-arm job: Cannot re-arm one-shot over a live fire claim."] {
            let text = try #require(CronViewModel.friendlyCronFailure(line))
            #expect(text.contains("in progress"))
            #expect(text != line)
        }
    }

    /// The two new arms must not swallow the arms around them. The terminal
    /// refusal, the `Blocked:` sentence and the past-one-shot create refusal
    /// all still answer for themselves, and unrelated output still falls
    /// through to `nil` so the caller's own truncation runs.
    @Test func theNewArmsDoNotShadowTheExistingOnes() {
        #expect(CronViewModel.friendlyCronFailure("Cannot activate terminal cron job")?
            .contains("already finished") == true)
        #expect(CronViewModel.friendlyCronFailure("Failed to create job: Blocked: cloud path")?
            .hasPrefix("Blocked: ") == true)
        #expect(CronViewModel.friendlyCronFailure(
            "Requested one-shot time 2020-01-01 is more than 120s in the past and cannot be scheduled.")?
            .contains("in the past") == true)
        #expect(CronViewModel.friendlyCronFailure("connection refused") == nil)
        // A re-arm refusal must not be read as a terminal-job refusal: the
        // terminal arm is tested first, and neither of its markers appears
        // in either new line.
        #expect(CronViewModel.friendlyCronFailure(
            "Failed to re-arm job: Cannot re-arm recurring jobs: re-arm is one-shot-only; use plain resume or cron run.")?
            .contains("already finished") == false)
    }
}
