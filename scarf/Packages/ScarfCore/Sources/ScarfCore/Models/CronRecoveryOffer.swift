import Foundation

/// What Scarf may offer a cron job whose schedule has stopped producing runs
/// — the shared answer both the Mac (`CronViewModel` / `BotRoutinesViewModel`)
/// and iOS (`IOSCronViewModel`) view models compute, so the two platforms
/// cannot make different offers for the same job again.
///
/// Hermes splits recovery three ways and Scarf used to split it two:
///
/// | job | host | Scarf offers |
/// |---|---|---|
/// | paused, any schedule | any | Resume |
/// | paused `once` | v0.20.6+ | Resume, Resume & Run Now |
/// | `error` + `cron`/`interval` | v0.21.0+ | Resume (`_is_recoverable_error_job`) |
/// | `error` + `cron`/`interval` | < v0.21.0 | nothing — `hint` |
/// | terminal `once` | v0.20.6+ | Resume & Run Now (`rearm_oneshot`) |
/// | `completed` + `cron`/`interval` | any | nothing — `hint` |
/// | paused past-deadline `once` | v0.18.1+ | Resume & Run Now only |
/// | paused past-deadline `once` | < v0.18.1 (+ no `--run-now`) | nothing — `hint` |
///
/// The last row is decision 1 of the round-3 product calls: a recurring job
/// that went terminal via `completed` gets no button, because neither
/// `resume_job` (blocked by `_reject_terminal_activation`) nor
/// `rearm_oneshot` (`_REARM_RECURRING_ERROR`) nor `trigger_job` (bare
/// `is_terminal_job`, `cron/jobs.py:2012`) would accept it. Scarf says so
/// instead of offering a dead end.
public struct CronRecoveryOffer: Sendable, Equatable {
    /// Offer plain `hermes cron resume <id>`.
    public let canResume: Bool
    /// Offer `hermes cron resume <id> --run-now` ("Resume & Run Now").
    public let canRearm: Bool
    /// Why there is nothing to offer — shown in place of the buttons.
    public let hint: String?

    public init(canResume: Bool = false, canRearm: Bool = false, hint: String? = nil) {
        self.canResume = canResume
        self.canRearm = canRearm
        self.hint = hint
    }

    /// No affordance at all and nothing to explain (a healthy running job).
    public static let none = CronRecoveryOffer()

    /// A recurring job that reached `completed`. Every Hermes activation door
    /// is shut for it — **including editing the schedule**, which is why this
    /// sentence no longer suggests that. `update_job` arms
    /// `_reject_terminal_activation` twice (`cron/jobs.py:1941` and `:1965` @
    /// `v2026.9.7`, predicate at `:1865-1879`) and the second call sees the
    /// `next_run_at` that `_apply_schedule_update` just wrote for any record
    /// whose `state != "paused"` (`:1899-1910`) — so `hermes cron edit
    /// --schedule …` on a `completed` job raises. Duplicating is the only
    /// door, the same remedy `CronViewModel.friendlyCronFailure` names.
    public static let noFutureOccurrencesHint =
        String(localized: "This job has no runs left — duplicate it to schedule a new one.")

    /// `noFutureOccurrencesHint`, but naming the exhausted repeat limit when
    /// the record carries a finite one. `_advance_after_run` retires a
    /// recurring job as `completed` the moment `repeat.completed >= times`
    /// (`cron/jobs.py:2192-2215` @ `v2026.9.7`), which makes this the common
    /// way a recurring job becomes a dead end — so say which limit ran out.
    public static func noFutureOccurrencesHint(repeatTimes: Int?) -> String {
        guard let times = repeatTimes, times > 0 else { return noFutureOccurrencesHint }
        return String(localized: "This job has run all \(times) of its scheduled times — duplicate it to schedule a new one.")
    }

    /// A paused one-shot whose `run_at` is already past Hermes's grace window.
    /// `resume_job` raises before `update_job` is even reached
    /// (`cron/jobs.py:1991-1996` @ `v2026.9.7`), so plain Resume is a
    /// guaranteed exit 1; only `--run-now` (v0.20.6+) re-arms it. Shown when
    /// the host has neither door.
    public static let pastDeadlineOneShotHint =
        String(localized: "This one-shot's time has passed — duplicate it with a new time.")

    /// A recurring job in `error` on a host older than v0.21.0, where
    /// `_reject_terminal_activation` has no `_is_recoverable_error_job`
    /// exemption yet (`cron/jobs.py:2367-2375` @ `v2026.8.27` vs
    /// `:2583-2595` @ `v2026.8.31`).
    ///
    /// **The remedy is Duplicate, not "edit the schedule".** This sentence
    /// used to name editing the schedule, and that gesture is REFUSED on
    /// exactly the hosts it is shown on: `update_job` @ `v2026.8.27` writes
    /// `next_run_at` for any record whose `state != "paused"`
    /// (`cron/jobs.py:2310`, `:2322`, `:2345`) — an `error` job qualifies —
    /// and the terminal guard immediately below then raises, because
    /// `is_terminal_job` is the bare `state in {completed, error}`
    /// (`:638-640`) with no `_is_recoverable_error_job` exemption at that tag
    /// and `next_run_at is not None` (`:2367-2375`). `cron create` carries no
    /// terminal guard at all (`create_job`, `:1915`), so duplicating is the
    /// one door open — and a Duplicate button is rendered on every surface
    /// that renders this hint: the Mac detail pane and the Bots routines list
    /// both show it for `offer.isDeadEnd`, and the Mac row context menu and
    /// iOS's row context menu show it unconditionally.
    public static let errorNeedsNewerHermesHint =
        String(localized: "This job failed to schedule. Hermes v0.21.0 or newer can resume it — until then, duplicate it to schedule a new one.")

    /// True when the only thing to show is the hint.
    public var isDeadEnd: Bool { !canResume && !canRearm && hint != nil }

    /// True when this offer is an explicit *refusal* of plain Resume, as
    /// opposed to `CronRecoveryOffer.none` — which a healthy running job also
    /// gets, and which must not be read as a refusal (iOS's `setEnabled` is
    /// idempotent and still round-trips an already-enabled job).
    public var refusesResume: Bool { !canResume && (canRearm || hint != nil) }
}
