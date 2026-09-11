import Testing
import Foundation
@testable import ScarfCore

/// P38 — the three cron-recovery defects P30 left behind.
///
/// 1. The dead-end hint told the user to "edit the schedule to run it again",
///    which Hermes refuses on a `completed` job: `_apply_schedule_update`
///    writes `next_run_at` for any record whose `state != "paused"`
///    (`cron/jobs.py:1899-1910` @ `v2026.9.7`) and the second
///    `_reject_terminal_activation` (`:1965`, predicate `:1865-1879`) raises
///    on exactly that. Duplicating is the only door.
/// 2. `_advance_after_run` retires a recurring job as `completed` the moment
///    `repeat.completed >= repeat.times` (`:2192-2215`), so the hint should
///    name the exhausted limit when the record carries a finite one.
/// 3. The past-deadline one-shot rule lived only on iOS, ahead of the shared
///    offer, where it shadowed the offer's own `canRearm` branch. It is now
///    the offer's third door — gated on `hasCronPastOneShotResumeRefusal`
///    (v0.18.1, `resume_job`'s `"Cannot resume: one-shot time …"` raise at
///    `:1991-1996`, absent at `v2026.7.1`).
@Suite struct HermesCronRecoveryP38Tests {

    private func job(
        state: String,
        kind: String,
        enabled: Bool = false,
        runAt: String = "2099-01-01T09:00:00+00:00",
        repeatSpec: String? = nil
    ) throws -> HermesCronJob {
        let schedule: String
        switch kind {
        case "cron":     schedule = #"{"kind":"cron","expr":"0 9 * * *"}"#
        case "interval": schedule = #"{"kind":"interval","minutes":30}"#
        default:         schedule = #"{"kind":"once","run_at":"\#(runAt)"}"#
        }
        let rep = repeatSpec.map { ",\"repeat\":\($0)" } ?? ""
        let json = """
            {"id":"j1","name":"Nightly","prompt":"p","enabled":\(enabled),
             "state":"\(state)","schedule":\(schedule)\(rep)}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

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

    // MARK: - 1: the hint names a remedy Hermes accepts

    @Test("the dead-end hint never tells the user to edit the schedule")
    func deadEndHintDoesNotSuggestEditingTheSchedule() throws {
        let hints = [
            CronRecoveryOffer.noFutureOccurrencesHint,
            CronRecoveryOffer.noFutureOccurrencesHint(repeatTimes: nil),
            CronRecoveryOffer.noFutureOccurrencesHint(repeatTimes: 3),
        ]
        for hint in hints {
            #expect(!hint.lowercased().contains("edit the schedule"), Comment(rawValue: hint))
            #expect(hint.lowercased().contains("duplicate"), Comment(rawValue: hint))
        }
    }

    // MARK: - 2: the exhausted repeat is named

    @Test("a finite repeat is named in the hint; an infinite one is not")
    func finiteRepeatIsNamedInTheHint() throws {
        let finite = offer(try job(state: "completed", kind: "cron",
                                   repeatSpec: #"{"times":4,"completed":4}"#))
        #expect(finite.hint == CronRecoveryOffer.noFutureOccurrencesHint(repeatTimes: 4))
        #expect(finite.hint?.contains("4") == true)

        // `times: null` is "forever" (`normalize_repeat_value`'s `<= 0 → None`
        // fold too) — there is no limit to name.
        for spec in [#"{"times":null,"completed":9}"#, #"{"times":0,"completed":9}"#] {
            let infinite = offer(try job(state: "completed", kind: "cron", repeatSpec: spec))
            #expect(infinite.hint == CronRecoveryOffer.noFutureOccurrencesHint,
                    Comment(rawValue: spec))
        }
        // No `repeat` key at all.
        let bare = offer(try job(state: "completed", kind: "interval"))
        #expect(bare.hint == CronRecoveryOffer.noFutureOccurrencesHint)
    }

    // MARK: - 3: the past-deadline one-shot is the offer's third door

    /// A paused one-shot whose `run_at` is long past: plain Resume raises
    /// inside `resume_job` before `update_job` is reached, so the offer must
    /// not include it — but `rearm_oneshot` still accepts the job, so
    /// `--run-now` is the door on a v0.20.6+ host.
    @Test("a past-deadline paused one-shot is offered re-arm, not Resume")
    func pastDeadlineOneShotIsOfferedRearmOnly() throws {
        let j = try job(state: "paused", kind: "once", runAt: "2020-01-01T09:00:00+00:00")
        #expect(j.isPastDeadlineOneShot())
        #expect(!j.isTerminal)

        let o = offer(j)
        #expect(!o.canResume)
        #expect(o.canRearm)
        #expect(o.hint == nil)
        #expect(o.refusesResume)
    }

    /// No `--run-now` on the host either → nothing but the hint.
    @Test("with no re-arm verb the past-deadline one-shot is a dead end")
    func pastDeadlineOneShotWithoutRearmIsADeadEnd() throws {
        let j = try job(state: "paused", kind: "once", runAt: "2020-01-01T09:00:00+00:00")
        let o = offer(j, refusesTerminal: false)
        #expect(o.isDeadEnd)
        #expect(o.hint == CronRecoveryOffer.pastDeadlineOneShotHint)
    }

    /// C1: below v0.18.1 `resume_job` has no past-one-shot raise at all
    /// (the sentence is absent from `v2026.7.1` and every earlier tag), so
    /// Scarf must keep offering plain Resume and let the CLI decide.
    @Test("below the v0.18.1 floor the past-deadline door stays open")
    func pastDeadlineDoorIsGatedOnTheFloor() throws {
        let j = try job(state: "paused", kind: "once", runAt: "2020-01-01T09:00:00+00:00")
        let o = offer(j, refusesPastOneShot: false)
        #expect(o.canResume)
        #expect(o.canRearm)          // `--run-now` is a separate floor
        #expect(o.hint == nil)
    }

    /// A one-shot still in the future is untouched by the new door.
    @Test("a future one-shot is still offered plain Resume")
    func futureOneShotIsUnaffected() throws {
        let o = offer(try job(state: "paused", kind: "once"))
        #expect(o.canResume)
        #expect(o.canRearm)
        #expect(o.hint == nil)
    }

    /// `oneShotIsUnresumable` is now exactly the union of the two doors, so
    /// the predicate iOS used to consult on its own cannot drift from the
    /// offer that replaced it.
    @Test("oneShotIsUnresumable is terminal-or-past-deadline, nothing else")
    func oneShotIsUnresumableIsTheUnionOfTheTwoDoors() throws {
        for kind in ["once", "cron", "interval"] {
            for state in ["scheduled", "paused", "completed", "error"] {
                for runAt in ["2020-01-01T09:00:00+00:00", "2099-01-01T09:00:00+00:00"] {
                    let j = try job(state: state, kind: kind, runAt: runAt)
                    let expected = kind == "once" && (j.isTerminal || j.isPastDeadlineOneShot())
                    #expect(j.oneShotIsUnresumable() == expected,
                            Comment(rawValue: "\(state)/\(kind)/\(runAt)"))
                }
            }
        }
    }

    /// `refusesResume` must NOT fire for `CronRecoveryOffer.none` — a healthy
    /// running job — or iOS's idempotent `setEnabled(enabled: true)` would
    /// start refusing calls it is documented to round-trip.
    @Test("a healthy running job is not a resume refusal")
    func noneIsNotARefusal() throws {
        #expect(!CronRecoveryOffer.none.refusesResume)
        #expect(!CronRecoveryOffer.none.isDeadEnd)
        let running = offer(try job(state: "scheduled", kind: "cron", enabled: true))
        #expect(running == .none)
        #expect(!running.refusesResume)
    }
}
