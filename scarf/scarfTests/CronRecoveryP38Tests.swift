import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P38 — the Mac half of the round-4 cron residue.
///
/// * `friendlyCronFailure` named "Resume & Run Now" for EVERY terminal
///   refusal, recurring included, though `rearm_oneshot` raises
///   `_REARM_RECURRING_ERROR` for anything but `once`
///   (`cron/jobs.py:2040-2042`, `:2065-2066` @ `v2026.9.7`).
/// * The row context menu was a fourth offer site that read `job.enabled`
///   raw instead of the shared `recoveryOffer`.
/// * `resumeJob`'s pre-check was `job.isTerminal && !canResume`, so a
///   one-shot that was merely PAST its deadline fell through to the CLI and
///   the user got `resume_job`'s raw Python tail (`:1991-1996`).
@MainActor
@Suite struct CronRecoveryP38Tests {

    private static func job(
        state: String,
        kind: String = "cron",
        enabled: Bool = false,
        runAt: String = "2099-01-01T09:00:00+00:00"
    ) -> HermesCronJob {
        HermesCronJob(
            id: "j1", name: "Nightly", prompt: "p",
            schedule: kind == "once"
                ? CronSchedule(kind: "once", runAt: runAt)
                : CronSchedule(kind: "cron", expression: "0 9 * * *"),
            enabled: enabled,
            state: state
        )
    }

    private static func viewModel() -> CronViewModel {
        let vm = CronViewModel()
        vm.isV0206OrLater = true
        vm.isV021OrLater = true
        vm.isV0181OrLater = true
        return vm
    }

    // MARK: - friendlyCronFailure is no longer static over the job

    private static let updateRefusal =
        "ValueError: Cannot activate terminal cron job 'Nightly' "
        + "through update_job; use cron resume --run-now or --at."
    private static let triggerRefusal =
        "ValueError: Cannot run: job 'Nightly' is completed (terminal). "
        + "Create a new occurrence with 'hermes cron resume Nightly --run-now'."

    @Test("a recurring job's terminal refusal never names re-arm")
    func recurringTerminalRefusalDropsTheRearmClause() {
        let vm = Self.viewModel()
        let offer = vm.recoveryOffer(for: Self.job(state: "completed", kind: "cron"))
        #expect(!offer.canRearm)

        for output in [Self.updateRefusal, Self.triggerRefusal] {
            let message = CronViewModel.friendlyCronFailure(output, offer: offer)
            #expect(message?.contains("Resume & Run Now") == false, Comment(rawValue: message ?? "nil"))
            #expect(message?.lowercased().contains("duplicate") == true,
                    Comment(rawValue: message ?? "nil"))
        }
    }

    @Test("a one-shot's terminal refusal still names re-arm")
    func oneShotTerminalRefusalKeepsTheRearmClause() {
        let vm = Self.viewModel()
        let offer = vm.recoveryOffer(for: Self.job(state: "completed", kind: "once"))
        #expect(offer.canRearm)
        for output in [Self.updateRefusal, Self.triggerRefusal] {
            #expect(CronViewModel.friendlyCronFailure(output, offer: offer)?
                .contains("Resume & Run Now") == true)
        }
    }

    /// With no job in hand (the `cron edit` race: the record turned terminal
    /// between load and click, so `jobs.first { $0.id == id }` came back nil)
    /// P38 defaulted to naming re-arm, on the reasoning that the caller could
    /// not rule it out. Round-4 reversed that: "cannot rule it out" is not
    /// evidence, and for a RECURRING job the button named is a guaranteed
    /// exit 1 (`_REARM_RECURRING_ERROR`, `cron/jobs.py:2065-2066` @
    /// `v2026.9.7`). The unknown-offer arm now asserts only what holds for
    /// every terminal record — duplicating, which no terminal guard touches.
    /// The P42 suite owns the positive assertions.
    @Test("with no offer the sentence names no door it cannot prove")
    func noOfferNamesOnlyWhatItCanProve() {
        let message = CronViewModel.friendlyCronFailure(Self.updateRefusal)
        #expect(message?.contains("Resume & Run Now") == false)
        #expect(message?.lowercased().contains("duplicate") == true)
        #expect(CronViewModel.friendlyCronFailure("error: no such job 'x'") == nil)
    }

    // MARK: - resumeJob's pre-check is the whole offer

    /// A paused one-shot past its deadline: `resume_job` raises before
    /// `update_job` is reached, so Scarf must refuse locally rather than
    /// shelling out and surfacing the ValueError tail.
    @Test("a past-deadline one-shot is refused before the CLI round-trip")
    func pastDeadlineOneShotIsRefusedLocally() throws {
        let vm = Self.viewModel()
        vm.resumeJob(Self.job(state: "paused", kind: "once",
                              runAt: "2020-01-01T09:00:00+00:00"))
        let message = try #require(vm.message)
        #expect(message.contains("is in the past"), Comment(rawValue: message))
        #expect(message.contains("Resume & Run Now"), Comment(rawValue: message))
    }

    /// C1: below v0.18.1 the host has no such raise, so the click must reach
    /// the CLI (no local refusal posted).
    @Test("below the v0.18.1 floor the same job is not pre-refused")
    func pastDeadlineOneShotIsNotPreRefusedBelowTheFloor() {
        let vm = Self.viewModel()
        vm.isV0181OrLater = false
        let offer = vm.recoveryOffer(for: Self.job(state: "paused", kind: "once",
                                                   runAt: "2020-01-01T09:00:00+00:00"))
        #expect(offer.canResume)
        #expect(!offer.refusesResume)
    }

    // MARK: - the row context menu is the fourth offer site

    /// The menu is built inside a `@ViewBuilder` and is not reachable from a
    /// unit test, so this is a source pin on the thing that went wrong: the
    /// context menu reading `job.enabled` raw instead of the shared offer.
    /// The a11y tree cannot see an unopened `contextMenu` either, so a UI
    /// test would not catch a regression here.
    @Test("the row context menu is driven off recoveryOffer, not job.enabled")
    func rowContextMenuUsesTheSharedOffer() throws {
        let source = try String(contentsOf: Self.cronViewURL, encoding: .utf8)
        let start = try #require(source.range(of: ".contextMenu {"))
        let menu = String(source[start.upperBound...].prefix(2200))

        #expect(menu.contains("viewModel.recoveryOffer(for: job)"),
                "the context menu must compute the shared offer")
        #expect(menu.contains("offer.canResume"))
        #expect(menu.contains("offer.canRearm"))
        #expect(menu.contains("refusesTerminalJobLocally(job)"),
                "Run Now must be disabled for a terminal job, as in BotRoutinesView")
        #expect(!menu.contains("job.enabled ? \"Pause\" : \"Resume\""),
                "the raw enabled flag was the bug")
    }

    private static var cronViewURL: URL {
        URL(fileURLWithPath: #filePath)          // …/scarf/scarfTests/<this file>
            .deletingLastPathComponent()         // …/scarf/scarfTests
            .deletingLastPathComponent()         // …/scarf
            .appendingPathComponent("scarf/Features/Cron/Views/CronView.swift")
    }

    // MARK: - both platforms' refusal wording comes from one shape

    /// The Mac and iOS refusal sentences must agree on WHICH affordance they
    /// name for the same job and offer — they differ only in where the button
    /// lives ("use …" vs "re-arm it from the Mac app …").
    @Test("Mac and iOS name the same affordance for every refused shape")
    func macAndIOSNameTheSameAffordance() throws {
        let vm = Self.viewModel()
        let shapes: [HermesCronJob] = [
            Self.job(state: "completed", kind: "once"),
            Self.job(state: "completed", kind: "cron"),
            Self.job(state: "error", kind: "once"),
            Self.job(state: "paused", kind: "once", runAt: "2020-01-01T09:00:00+00:00"),
        ]
        for job in shapes {
            let offer = vm.recoveryOffer(for: job)
            guard offer.refusesResume else { continue }
            let mac = CronViewModel.resumeRefusalMessage(job, offer: offer)
            let ios = IOSCronViewModel.resumeRefusalMessage(job, offer: offer)
            let label = "\(job.state)/\(job.schedule.kind)"
            #expect(mac.contains("Resume & Run Now") == ios.contains("Resume & Run Now"),
                    Comment(rawValue: "\(label): mac=\(mac) ios=\(ios)"))
            #expect(mac.contains("Resume & Run Now") == offer.canRearm,
                    Comment(rawValue: "\(label): \(mac)"))
        }
    }
}
