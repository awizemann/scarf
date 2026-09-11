import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P30 — the Mac and iOS view models must make the SAME recovery offer for
/// the same job on the same host.
///
/// They diverged before this phase: the Mac blocked Resume client-side for
/// every terminal job (`refusesTerminalJobLocally`) and pointed at a
/// "Resume & Run Now" that `_REARM_RECURRING_ERROR` refuses, while iOS's
/// `oneShotIsUnresumable` returns early for any non-`once` schedule and let
/// the CLI decide. Both now route through
/// `HermesCronJob.recoveryOffer(hostRefusesTerminalJobs:hostRecoversErrorRecurring:hostRefusesPastOneShotResume:now:)`,
/// and this suite is the alarm if either grows its own opinion again.
@MainActor
@Suite struct CronRecoveryOfferP30Tests {

    private static func job(
        state: String,
        kind: String,
        enabled: Bool = false,
        past: Bool = false
    ) throws -> HermesCronJob {
        let schedule: String
        let runAt = past ? "2020-01-01T09:00:00+00:00" : "2099-01-01T09:00:00+00:00"
        switch kind {
        case "cron":     schedule = #"{"kind":"cron","expr":"0 9 * * *"}"#
        case "interval": schedule = #"{"kind":"interval","minutes":30}"#
        default:         schedule = #"{"kind":"once","run_at":"\#(runAt)"}"#
        }
        let json = """
            {"id":"j1","name":"Nightly","prompt":"p","enabled":\(enabled),
             "state":"\(state)","schedule":\(schedule)}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    /// Every (state × kind × host-floor) cell, on both platforms.
    @Test func macAndIOSMakeTheSameOfferForEveryJobShape() throws {
        let ctx = ServerContext.local(home: FileManager.default.temporaryDirectory)
        // P38 adds the third floor (`hasCronPastOneShotResumeRefusal`) and a
        // past-deadline `run_at` to the grid, because that door is where the
        // two platforms had diverged again.
        for v0206 in [false, true] {
            for v021 in [false, true] {
                for v0181 in [false, true] {
                    let mac = CronViewModel()
                    mac.isV0206OrLater = v0206
                    mac.isV021OrLater = v021
                    mac.isV0181OrLater = v0181
                    let ios = IOSCronViewModel(context: ctx)
                    ios.isV0206OrLater = v0206
                    ios.isV021OrLater = v021
                    ios.isV0181OrLater = v0181

                    for kind in ["once", "cron", "interval"] {
                        for state in ["scheduled", "paused", "completed", "error"] {
                            for enabled in [false, true] {
                                for past in [false, true] {
                                    let j = try Self.job(state: state, kind: kind,
                                                         enabled: enabled, past: past)
                                    let a = mac.recoveryOffer(for: j)
                                    let b = ios.recoveryOffer(for: j)
                                    #expect(a == b,
                                            "\(state)/\(kind)/enabled=\(enabled)/past=\(past) @ 0206=\(v0206) 021=\(v021) 0181=\(v0181): mac \(a) vs iOS \(b)")
                                    // And the two GATES that consume the offer
                                    // must agree, not just the offer itself:
                                    // iOS's `setEnabled` and the Mac's
                                    // `resumeJob` both key on `refusesResume`.
                                    #expect(a.refusesResume == b.refusesResume)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - the two HIGHs, at the view-model level

    /// HIGH 1: "Resume & Run Now" is one-shot-only. It must never be offered
    /// for a paused recurring job, on any host.
    @Test func aPausedRecurringJobIsNeverOfferedRearm() throws {
        let vm = CronViewModel()
        vm.isV0206OrLater = true
        vm.isV021OrLater = true
        for kind in ["cron", "interval"] {
            let offer = vm.recoveryOffer(for: try Self.job(state: "paused", kind: kind))
            #expect(offer.canResume)
            #expect(!offer.canRearm, "\(kind)")
        }
        let oneShot = vm.recoveryOffer(for: try Self.job(state: "paused", kind: "once"))
        #expect(oneShot.canRearm)
    }

    /// HIGH 2: a recurring job in `error` is recoverable by plain Resume on
    /// a v0.21.0+ host, and the Mac must stop blocking it client-side.
    @Test func aRecurringErrorJobIsResumableOnAV021Host() throws {
        let vm = CronViewModel()
        vm.isV0206OrLater = true
        vm.isV021OrLater = true
        let offer = vm.recoveryOffer(for: try Self.job(state: "error", kind: "cron"))
        #expect(offer.canResume)
        #expect(!offer.canRearm)
        #expect(offer.hint == nil)
    }

    /// `trigger_job` has no such exemption (`cron/jobs.py:2012` @
    /// `v2026.9.7`), so Run Now stays refused for the very same job. The
    /// resume gate and the run gate must not be shared.
    @Test func runNowStaysRefusedForARecoverableErrorJob() throws {
        let vm = CronViewModel()
        vm.isV0206OrLater = true
        vm.isV021OrLater = true
        #expect(vm.refusesTerminalJobLocally(try Self.job(state: "error", kind: "cron")))
    }

    /// Decision 1's third arm: a recurring job that reached `completed` gets
    /// no button at all, only the hint.
    @Test func aCompletedRecurringJobGetsOnlyTheHint() throws {
        let vm = CronViewModel()
        vm.isV0206OrLater = true
        vm.isV021OrLater = true
        let offer = vm.recoveryOffer(for: try Self.job(state: "completed", kind: "interval"))
        #expect(offer.isDeadEnd)
        #expect(offer.hint == CronRecoveryOffer.noFutureOccurrencesHint)
    }
}
