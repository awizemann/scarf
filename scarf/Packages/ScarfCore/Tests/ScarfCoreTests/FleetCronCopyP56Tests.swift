import Testing
import Foundation
@testable import ScarfCore

/// P56, round-6 decisions 7 and 8 — the two fields a fleet cron copy dropped:
/// `repeat` (now forwarded) and the model pin (now a downgrade note).
@Suite struct FleetCronRepeatP56Tests {

    private static func job(repeatExtra: JSONValue?, model: String? = nil) -> HermesCronJob {
        HermesCronJob(
            id: "j1", name: "n", prompt: "p", skills: nil, model: model,
            schedule: CronSchedule(kind: "cron", runAt: nil, display: nil,
                                   expression: "0 9 * * *", minutes: nil, extra: [:]),
            enabled: true, state: "scheduled", deliver: nil, nextRunAt: nil,
            lastRunAt: nil, lastError: nil, preRunScript: nil,
            deliveryFailures: nil, lastDeliveryError: nil, timeoutType: nil,
            timeoutSeconds: nil, silent: nil, workdir: nil, contextFrom: nil,
            noAgent: nil, attachToSession: nil,
            extra: repeatExtra.map { ["repeat": $0] } ?? [:])
    }

    private static func copyArgv(_ job: HermesCronJob, caps: HermesCapabilities) -> [String] {
        let schedule = CronScheduleArgument.resolve(job.schedule)!
        return FleetApplyPlan.cronCreateArgs(
            copying: job, schedule: schedule, caps: caps,
            sourceRoot: "/src", targetRoot: "/dst", paused: false).args
    }

    private static let modern = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
    /// The charter's minimum supported Hermes.
    private static let floor = HermesCapabilities.parseLine("Hermes Agent v0.6.0 (2026.3.30)")

    /// Decision 7. A bounded source job used to be copied UNBOUNDED, running
    /// forever on every target under a green "created".
    @Test func aBoundedJobCarriesItsRepeatLimit() {
        let job = Self.job(repeatExtra: .object(["times": .int(3), "completed": .int(2)]))
        let argv = Self.copyArgv(job, caps: Self.modern)
        #expect(HermesCLIOption.value(of: "--repeat", in: argv) == "3")
    }

    /// `repeat.completed` is Hermes's own counter and must NOT travel: a
    /// fresh job has run zero times, and `create_job` stamps
    /// `{"times": repeat, "completed": 0}` regardless (`cron/jobs.py:1779`).
    @Test func theCompletedCounterDoesNotTravel() {
        let job = Self.job(repeatExtra: .object(["times": .int(3), "completed": .int(2)]))
        let argv = Self.copyArgv(job, caps: Self.modern)
        #expect(!argv.contains { $0.contains("completed") })
        #expect(HermesCLIOption.value(of: "--repeat", in: argv) != "2")
    }

    /// `nil` times means "run forever" on both sides, so an unbounded source
    /// still emits no flag — the copy of an unbounded job is unchanged.
    @Test(arguments: [nil, JSONValue.object(["times": .null, "completed": .int(0)])])
    func anUnboundedJobEmitsNoFlag(_ raw: JSONValue?) {
        let argv = Self.copyArgv(Self.job(repeatExtra: raw), caps: Self.modern)
        #expect(!HermesCLIOption.contains("--repeat", in: argv))
    }

    /// No capability gate, and this is the proof it needs none:
    /// `cron_create.add_argument("--repeat", type=int, …)` is present at
    /// `hermes_cli/main.py:3936` @ `v2026.3.30` (0.6.0, the charter floor)
    /// and at `hermes_cli/subcommands/cron.py:38` @ `v2026.9.7`. An older
    /// target renders it identically.
    @Test func theOldestSupportedTargetGetsTheSameFlag() {
        let job = Self.job(repeatExtra: .object(["times": .int(5), "completed": .int(0)]))
        #expect(HermesCLIOption.value(of: "--repeat", in: Self.copyArgv(job, caps: Self.floor)) == "5")
        // …and with `.empty` caps, which is what a FAILED version probe
        // yields — the conservative path must not lose a bounded limit.
        #expect(HermesCLIOption.value(of: "--repeat", in: Self.copyArgv(job, caps: .empty)) == "5")
    }
}

@Suite struct FleetModelPinP56Tests {

    private static func job(model: String?, provider: String? = nil, effort: String? = nil) -> HermesCronJob {
        var extra: [String: JSONValue] = [:]
        if let provider { extra["provider"] = .string(provider) }
        if let effort { extra["reasoning_effort"] = .string(effort) }
        return HermesCronJob(
            id: "j1", name: "n", prompt: "p", skills: nil, model: model,
            schedule: CronSchedule(kind: "cron", runAt: nil, display: nil,
                                   expression: "0 9 * * *", minutes: nil, extra: [:]),
            enabled: true, state: "scheduled", deliver: nil, nextRunAt: nil,
            lastRunAt: nil, lastError: nil, preRunScript: nil,
            deliveryFailures: nil, lastDeliveryError: nil, timeoutType: nil,
            timeoutSeconds: nil, silent: nil, workdir: nil, contextFrom: nil,
            noAgent: nil, attachToSession: nil, extra: extra)
    }

    /// Decision 8. Any one of the three axes is a pin.
    @Test func anyPinnedAxisCounts() {
        #expect(Self.job(model: "hermes-4").hasModelPin)
        #expect(Self.job(model: nil, provider: "nousresearch").hasModelPin)
        #expect(Self.job(model: nil, effort: "high").hasModelPin)
        #expect(Self.job(model: nil).hasModelPin == false)
    }

    /// `""` means "not set", exactly as `_normalize_job_optional_text`
    /// (`cron/jobs.py:1522-1527` @ `v2026.9.7`) reads it — an empty pin must
    /// not produce a note about a pin that isn't there.
    @Test func anEmptyPinIsNoPin() {
        #expect(!Self.job(model: "").hasModelPin)
        #expect(!Self.job(model: "   ").hasModelPin)
        #expect(!Self.job(model: nil, provider: "").hasModelPin)
        #expect(!Self.job(model: nil, effort: "  ").hasModelPin)
    }

    /// The labels the note names — empty exactly when there is no pin.
    @Test func theFieldsListNamesEveryPinnedAxis() {
        #expect(Self.job(model: "m", provider: "p", effort: "high").modelPinFields
                == ["model", "provider", "reasoning effort"])
        #expect(Self.job(model: nil).modelPinFields.isEmpty)
    }

    /// The other half of the decision: the job is **still copied**, and the
    /// pin is still NOT forwarded. An accepted flag (`--model` exists at
    /// `hermes_cli/subcommands/cron.py:66-72` @ `v2026.9.7`) is not a
    /// copyable field when the value names something only the source host
    /// resolves — the P50 `--script` lesson.
    @Test func aPinnedJobIsCopiedWithoutItsPin() {
        let job = Self.job(model: "hermes-4-405b", provider: "nousresearch", effort: "high")
        let schedule = CronScheduleArgument.resolve(job.schedule)!
        let argv = FleetApplyPlan.cronCreateArgs(
            copying: job, schedule: schedule,
            caps: HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)"),
            sourceRoot: "/src", targetRoot: "/dst", paused: false).args
        for flag in ["--model", "--provider", "--reasoning-effort"] {
            #expect(!HermesCLIOption.contains(flag, in: argv), "\(flag) was forwarded")
        }
        // Still a real create — the note is a note, not a refusal.
        #expect(argv.starts(with: ["cron", "create"]))
        // And it stays in the copy set rather than being skipped.
        #expect(!FleetApplyPlan.shouldSkipMonitorJob(job))
    }
}
