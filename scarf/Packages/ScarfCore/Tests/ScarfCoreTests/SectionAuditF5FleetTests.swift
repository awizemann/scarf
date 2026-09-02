import Testing
import Foundation
@testable import ScarfCore

/// Section-audit fix package **F5** — the pure halves of the PROJECTS FLEET
/// sub-cluster: the per-host model-preset skip, preview/executor agreement on
/// which cron jobs get copied, the structured `cron create` schedule
/// argument, and rename keeping (never re-deriving) the stable identifier.
@Suite struct SectionAuditF5FleetTests {

    static let projectID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    static func materialization(
        serverId: String,
        modelPresetId: String? = nil,
        board: String? = nil,
        cronJobIds: [String] = []
    ) -> FleetMaterialization {
        FleetMaterialization(
            serverId: serverId,
            serverDisplayName: serverId,
            project: ScarfProject(
                id: projectID,
                name: "Proj",
                rootPath: "/p/\(serverId)",
                modelPresetId: modelPresetId,
                board: board,
                cronJobIds: cronJobIds
            )
        )
    }

    static func job(
        _ name: String,
        schedule: CronSchedule = CronSchedule(kind: "cron", expression: "0 9 * * *"),
        noAgent: Bool? = nil
    ) -> HermesCronJob {
        HermesCronJob(
            id: "id-\(name)", name: name, prompt: "run",
            schedule: schedule, enabled: true, state: "scheduled", noAgent: noAgent
        )
    }

    // MARK: - Finding 1 — per-host model presets are not pushed blindly

    @Test func presetIsSkippedOnHostsWhoseStoreLacksIt() {
        let preset = "11111111-1111-1111-1111-111111111111"
        let source = Self.materialization(serverId: "src", modelPresetId: preset)
        let hasIt = Self.materialization(serverId: "a")
        let lacksIt = Self.materialization(serverId: "b")

        let plan = FleetApplyPlan.make(
            source: source,
            targets: [hasIt, lacksIt],
            fields: [.modelPreset],
            presetHosts: ["src", "a"]
        )

        let applied = plan.targets.first { $0.serverId == "a" }!.actions[0].disposition
        #expect(applied.isApply)

        let skipped = plan.targets.first { $0.serverId == "b" }!.actions[0].disposition
        #expect(!skipped.isApply)
        // The skip must EXPLAIN itself — a silent drop is the bug.
        #expect(skipped.detail.contains("per-host"))
        #expect(skipped.detail.contains(String(preset.prefix(8))))
    }

    /// A host that lacks the preset contributes no applicable change, so the
    /// plan must not present it as an effective target ("Apply" would be a
    /// silent no-op that still reported success).
    @Test func presetOnlyPushIsNotEffectiveOnHostsLackingThePreset() {
        let source = Self.materialization(serverId: "src", modelPresetId: "11111111-1111-1111-1111-111111111111")
        let plan = FleetApplyPlan.make(
            source: source,
            targets: [Self.materialization(serverId: "b")],
            fields: [.modelPreset],
            presetHosts: ["src"]
        )
        #expect(plan.effectiveTargets.isEmpty)
    }

    /// Unknown availability (probe failed) stays permissive — a failed probe
    /// must not block a legitimate apply.
    @Test func presetAvailabilityUnknownStillApplies() {
        let source = Self.materialization(serverId: "src", modelPresetId: "p")
        let plan = FleetApplyPlan.make(
            source: source, targets: [Self.materialization(serverId: "a")], fields: [.modelPreset])
        #expect(plan.targets[0].actions[0].disposition.isApply)
    }

    // MARK: - Finding 5 — preview and executor agree on the cron set

    @Test func copyableCronJobsSelectsOnlyTheProjectTaggedAgentJobs() {
        let tag = FleetApplyPlan.projectCronTag(Self.projectID)
        let jobs = [
            Self.job("\(tag) daily"),
            Self.job("\(tag) weekly"),
            Self.job("\(tag) watchdog", noAgent: true),                       // script-only
            Self.job("\(tag) broken", schedule: CronSchedule(kind: "cron")),  // no rebuildable schedule
            Self.job("[tmpl:acme/kit] installed"),                            // legacy template tag
            Self.job("unrelated job")
        ]

        let set = FleetApplyPlan.copyableCronJobs(from: jobs, projectID: Self.projectID)
        #expect(set.copyable.map(\.name) == ["\(tag) daily", "\(tag) weekly"])
        #expect(set.scriptOnly.count == 1)
        #expect(set.unsupportedSchedule.count == 1)
    }

    /// The preview count comes from the same partition the executor iterates.
    /// `cronJobIds` (the record's broader attribution, which also indexes
    /// `[tmpl:]` jobs) must not drive the preview.
    @Test func cronPreviewCountsTheCopyableSetNotTheRecordIds() {
        let tag = FleetApplyPlan.projectCronTag(Self.projectID)
        // Record claims four attributed jobs; only two are actually copyable.
        let source = Self.materialization(serverId: "src", cronJobIds: ["j1", "j2", "j3", "j4"])
        let jobs = [
            Self.job("\(tag) a"),
            Self.job("\(tag) b"),
            Self.job("\(tag) c", noAgent: true),
            Self.job("[tmpl:kit] d")
        ]
        let set = FleetApplyPlan.copyableCronJobs(from: jobs, projectID: Self.projectID)

        let plan = FleetApplyPlan.make(
            source: source,
            targets: [Self.materialization(serverId: "a")],
            fields: [.cron],
            copyableCronCount: set.copyable.count
        )
        #expect(plan.targets[0].actions[0].disposition.detail == "recreate up to 2 cron jobs")
    }

    @Test func cronFieldSkipsWhenNothingIsCopyable() {
        let source = Self.materialization(serverId: "src", cronJobIds: ["j1", "j2"])
        let plan = FleetApplyPlan.make(
            source: source,
            targets: [Self.materialization(serverId: "a")],
            fields: [.cron],
            copyableCronCount: 0
        )
        #expect(!plan.targets[0].actions[0].disposition.isApply)
        #expect(plan.effectiveTargets.isEmpty)
    }

    // MARK: - Finding 6 — structured schedule argument

    @Test func scheduleArgumentResolvesByKind() {
        #expect(CronScheduleArgument.resolve(CronSchedule(kind: "cron", display: "every day at 9am", expression: "0 9 * * *"))
                == .cronExpression("0 9 * * *"))
        #expect(CronScheduleArgument.resolve(CronSchedule(kind: "interval", display: "hourly-ish", minutes: 30))
                == .intervalMinutes(30))
        #expect(CronScheduleArgument.resolve(CronSchedule(kind: "once", runAt: "2026-02-03T14:00", display: "tomorrow"))
                == .once("2026-02-03T14:00"))
    }

    /// The human `display` is NEVER the argument — a prose label round-tripped
    /// into `cron create` is a guess about the cadence, not the cadence.
    @Test func scheduleArgumentNeverFallsBackToDisplayText() {
        let prose = CronSchedule(kind: "cron", display: "Every weekday, first thing")
        #expect(CronScheduleArgument.resolve(prose) == nil)
    }

    /// A missing/unknown `kind` still resolves from the modeled fields.
    @Test func scheduleArgumentFallsThroughModeledFields() {
        #expect(CronScheduleArgument.resolve(CronSchedule(kind: "", expression: "*/5 * * * *"))
                == .cronExpression("*/5 * * * *"))
        #expect(CronScheduleArgument.resolve(CronSchedule(kind: "weird", minutes: 15)) == .intervalMinutes(15))
        #expect(CronScheduleArgument.resolve(CronSchedule(kind: "interval", minutes: 0)) == nil)
    }

    /// The argv values match what `cron/jobs.py::parse_schedule` accepts.
    @Test func scheduleArgumentValuesMatchHermesGrammar() {
        #expect(CronScheduleArgument.intervalMinutes(30).argumentValue == "every 30m")
        #expect(CronScheduleArgument.cronExpression("0 9 * * *").argumentValue == "0 9 * * *")
        #expect(CronScheduleArgument.once("2026-02-03T14:00").argumentValue == "2026-02-03T14:00")
    }

    @Test func cronCreateArgsCarriesTheStructuredScheduleAsThePositional() {
        let (args, _) = FleetApplyPlan.cronCreateArgs(
            copying: Self.job("[proj:x] a"),
            schedule: .intervalMinutes(45),
            caps: .empty,
            sourceRoot: "/s",
            targetRoot: "/t"
        )
        // …schedule then prompt, both positional and last.
        #expect(args.dropLast().last == "every 45m")
        #expect(args.last == "run")
    }

    // MARK: - Finding 4 — rename keeps the identifier

    /// `ProjectEntry`'s Equatable deliberately ignores `uuid`, so the identity
    /// carry-over has to be asserted on the field itself.
    @MainActor
    @Test func renameKeepsTheStableIdentifierInsteadOfReDerivingIt() throws {
        let id = UUID()
        try ProjectStoreTests.withTempHome { ctx, _ in
            let service = ProjectDashboardService(context: ctx)
            try service.saveRegistry(ProjectRegistry(projects: [
                ProjectEntry(name: "OldName", path: "/p", folder: "Work", archived: false, uuid: id)
            ]))

            let vm = ProjectsViewModel(context: ctx)
            vm.load()
            #expect(vm.renameProject(vm.projects[0], to: "NewName") == true)

            let reloaded = service.loadRegistry().projects[0]
            #expect(reloaded.name == "NewName")
            #expect(reloaded.uuid == id)          // identity survives the rename
            #expect(reloaded.folder == "Work")
        }
    }
}
