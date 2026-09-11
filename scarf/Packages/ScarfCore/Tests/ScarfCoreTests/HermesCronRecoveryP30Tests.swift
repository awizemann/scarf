import Testing
import Foundation
@testable import ScarfCore

/// P30 — cron recovery semantics. Scarf's port of the two Hermes predicates
/// that decide what a wedged job may be offered:
///
/// * `_is_recoverable_error_job` (`cron/jobs.py:509-522` @ `v2026.9.7`) —
///   `state == "error"` AND `schedule.kind in {"cron","interval"}`. Exempted
///   from `_reject_terminal_activation` (`:1865-1878`), so plain
///   `hermes cron resume` genuinely recovers such a job.
///   **Floor v0.21.0**: the symbol first exists at `v2026.8.31`
///   (`pyproject.toml version = "0.21.0"`); at `v2026.8.27` (0.20.6) the
///   terminal block in `update_job` is unconditional.
/// * `rearm_oneshot`'s own-schedule guard (`cron/jobs.py:2065-2066`,
///   `_REARM_RECURRING_ERROR` `:2040-2042`) — re-arm raises
///   "Cannot re-arm recurring jobs…" unless the JOB's schedule is `once`,
///   and `cron_resume` turns that into exit 1 (`hermes_cli/cron.py:691-695`).
///   Present verbatim inside `rearm_oneshot` since the function's first tag,
///   `v2026.8.27` (0.20.6) — the same floor as `hasCronResumeRunNow` — so
///   it needs no flag of its own.
@Suite struct HermesCronRecoveryP30Tests {

    /// A record shaped like one element of `hermes cron list --json`.
    private func job(
        state: String,
        kind: String,
        enabled: Bool = false,
        pausedAt: String = "null",
        extra: String = ""
    ) throws -> HermesCronJob {
        let schedule: String
        switch kind {
        case "cron":     schedule = #"{"kind":"cron","expr":"0 9 * * *","display":"every day at 09:00"}"#
        case "interval": schedule = #"{"kind":"interval","minutes":30,"display":"every 30 minutes"}"#
        default:         schedule = #"{"kind":"once","run_at":"2099-01-01T09:00:00+00:00","display":"2099-01-01 09:00"}"#
        }
        let json = """
            {"id":"j1","name":"Nightly","prompt":"p","enabled":\(enabled),
             "state":"\(state)","paused_at":\(pausedAt),
             "schedule":\(schedule)\(extra.isEmpty ? "" : ",\(extra)")}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    // MARK: - _is_recoverable_error_job, both directions

    @Test func recoverableErrorJobIsErrorPlusRecurringKind() throws {
        // TRUE: the two kinds Hermes names.
        #expect(try job(state: "error", kind: "cron").isRecoverableErrorJob)
        #expect(try job(state: "error", kind: "interval").isRecoverableErrorJob)
    }

    @Test func recoverableErrorJobRejectsEveryOtherShape() throws {
        // FALSE: a one-shot in error is genuinely terminal (no future occurrence).
        #expect(try !job(state: "error", kind: "once").isRecoverableErrorJob)
        // FALSE: `completed` is never recoverable, whatever the kind.
        #expect(try !job(state: "completed", kind: "cron").isRecoverableErrorJob)
        #expect(try !job(state: "completed", kind: "interval").isRecoverableErrorJob)
        #expect(try !job(state: "completed", kind: "once").isRecoverableErrorJob)
        // FALSE: non-terminal states.
        #expect(try !job(state: "scheduled", kind: "cron", enabled: true).isRecoverableErrorJob)
        #expect(try !job(state: "paused", kind: "cron").isRecoverableErrorJob)
    }

    // MARK: - re-arm is one-shot-only, both directions

    @Test func onlyAOneShotIsRearmable() throws {
        #expect(try job(state: "completed", kind: "once").isRearmableOneShot)
        #expect(try job(state: "error", kind: "once").isRearmableOneShot)
        #expect(try job(state: "paused", kind: "once").isRearmableOneShot)
    }

    @Test func noRecurringJobIsRearmable() throws {
        for kind in ["cron", "interval"] {
            for state in ["scheduled", "paused", "completed", "error"] {
                #expect(try !job(state: state, kind: kind).isRearmableOneShot,
                        "\(state)/\(kind) must not be offered re-arm")
            }
        }
    }

    // MARK: - the offer the two platforms share

    private func offer(
        _ j: HermesCronJob,
        refusesTerminal: Bool = true,
        recoversError: Bool = true,
        refusesPastOneShot: Bool = true,
        now: Date = Date()
    ) -> CronRecoveryOffer {
        j.recoveryOffer(hostRefusesTerminalJobs: refusesTerminal,
                        hostRecoversErrorRecurring: recoversError,
                        hostRefusesPastOneShotResume: refusesPastOneShot,
                        now: now)
    }

    @Test func recurringErrorJobIsOfferedPlainResumeOnly() throws {
        let o = offer(try job(state: "error", kind: "cron"))
        #expect(o.canResume)
        #expect(!o.canRearm)          // `rearm_oneshot` would raise
        #expect(o.hint == nil)
    }

    @Test func recurringCompletedJobIsOfferedNothingButAHint() throws {
        let o = offer(try job(state: "completed", kind: "cron"))
        #expect(!o.canResume)
        #expect(!o.canRearm)
        #expect(o.hint == CronRecoveryOffer.noFutureOccurrencesHint)
        #expect(o.hint.map { !$0.contains("edit the schedule") } == true)
    }

    @Test func terminalOneShotKeepsTheRearmEscapeHatch() throws {
        let o = offer(try job(state: "completed", kind: "once"))
        #expect(!o.canResume)         // `_reject_terminal_activation` refuses
        #expect(o.canRearm)
        #expect(o.hint == nil)
    }

    @Test func pausedRecurringJobIsNotOfferedRearm() throws {
        // The HIGH: Scarf used to show "Resume & Run Now" for ANY paused job.
        let o = offer(try job(state: "paused", kind: "cron"))
        #expect(o.canResume)
        #expect(!o.canRearm)
        #expect(o.hint == nil)
    }

    @Test func pausedOneShotKeepsBothOffers() throws {
        let o = offer(try job(state: "paused", kind: "once"))
        #expect(o.canResume)
        #expect(o.canRearm)
    }

    @Test func aRunningJobIsOfferedNeither() throws {
        let o = offer(try job(state: "scheduled", kind: "cron", enabled: true))
        #expect(!o.canResume)
        #expect(!o.canRearm)
        #expect(o.hint == nil)
    }

    // MARK: - C1: pre-floor hosts

    /// Below v0.21.0 the exemption does not exist, so `cron resume` on an
    /// error-state recurring job is refused by `_reject_terminal_activation`
    /// exactly like a completed one — and re-arm was never possible for a
    /// recurring job either. Scarf offers no dead end; it explains.
    @Test func preV021HostGetsNoRecoveryOfferForARecurringError() throws {
        let o = offer(try job(state: "error", kind: "cron"), recoversError: false)
        #expect(!o.canResume)
        #expect(!o.canRearm)
        #expect(o.hint == CronRecoveryOffer.errorNeedsNewerHermesHint)
    }

    /// Below v0.20.6 neither `update_job` nor `trigger_job` refuses a
    /// terminal job, and `--run-now` does not exist — so Scarf pre-refuses
    /// nothing and shows no re-arm button. Byte-identical to the offer the
    /// prior Scarf release made on such a host (charter C1).
    @Test func preV0206HostLetsTheCLIDecideAndShowsNoRearm() throws {
        for kind in ["cron", "interval", "once"] {
            for state in ["completed", "error"] {
                let o = offer(try job(state: state, kind: kind),
                              refusesTerminal: false, recoversError: false)
                #expect(o.canResume, "\(state)/\(kind)")
                #expect(!o.canRearm, "\(state)/\(kind)")
                #expect(o.hint == nil, "\(state)/\(kind)")
            }
        }
        let paused = offer(try job(state: "paused", kind: "once"),
                           refusesTerminal: false, recoversError: false)
        #expect(paused.canResume)
        #expect(!paused.canRearm)
    }

    // MARK: - pause-marker truthiness (LOW)

    /// Hermes's `_has_pause_marker` is `bool(job.get("paused_at"))`
    /// (`cron/jobs.py:479` @ `v2026.9.7`), so a falsy marker is NO marker.
    /// Scarf treated any non-`null` value as one, which made `paused_at: ""`
    /// read "paused" in Scarf while the host kept firing the job — the exact
    /// divergence `effective_job_state` exists to prevent.
    @Test func falsyPausedAtIsNotAPauseMarker() throws {
        // `enabled: false` + a NON-paused stored state is the discriminating
        // shape: Hermes falls through to `return stored or "paused"` and
        // renders "scheduled"; Scarf's any-non-null reading rendered "paused".
        for falsy in ["\"\"", "0", "false", "[]", "{}"] {
            let j = try job(state: "scheduled", kind: "cron",
                            enabled: false, pausedAt: falsy)
            #expect(j.effectiveState == "scheduled", "paused_at: \(falsy)")
        }
    }

    @Test func truthyPausedAtStillReadsAsAPauseMarker() throws {
        let j = try job(state: "scheduled", kind: "cron", enabled: false,
                        pausedAt: "\"2026-09-10T09:00:00+00:00\"")
        #expect(j.effectiveState == "paused")
    }
}
