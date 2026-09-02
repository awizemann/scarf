import Testing
import Foundation
@testable import ScarfCore

/// Pure coverage for `FleetApplyPlan` — applicable-field gating, per-field
/// dispositions (incl. the additive board guard), and the boundary-aware
/// cron-prompt path rewriter that the user opted into for cross-host cron
/// apply.
@Suite struct FleetApplyPlanTests {

    static func materialization(
        serverId: String,
        name: String = "Proj",
        rootPath: String = "/p",
        modelPresetId: String? = nil,
        board: String? = nil,
        cronJobIds: [String] = []
    ) -> FleetMaterialization {
        FleetMaterialization(
            serverId: serverId,
            serverDisplayName: serverId,
            project: ScarfProject(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                name: name,
                rootPath: rootPath,
                modelPresetId: modelPresetId,
                board: board,
                cronJobIds: cronJobIds
            )
        )
    }

    // MARK: - Applicable fields

    @Test func applicableFieldsReflectsSourceConfig() {
        let bare = ScarfProject(name: "Bare", rootPath: "/b")
        #expect(FleetApplyPlan.applicableFields(source: bare).isEmpty)

        let full = ScarfProject(name: "Full", rootPath: "/f",
                                modelPresetId: "preset", board: "scarf:f", cronJobIds: ["j1"])
        #expect(FleetApplyPlan.applicableFields(source: full) == [.modelPreset, .board, .cron])
    }

    // MARK: - Dispositions

    @Test func modelPresetApplyAndSkip() {
        let source = Self.materialization(serverId: "src", modelPresetId: "fast")
        let needsIt = Self.materialization(serverId: "a", modelPresetId: nil)
        let hasIt = Self.materialization(serverId: "b", modelPresetId: "fast")

        let plan = FleetApplyPlan.make(source: source, targets: [needsIt, hasIt], fields: [.modelPreset])
        #expect(plan.targets[0].actions.first?.disposition.isApply == true)
        #expect(plan.targets[1].actions.first?.disposition == .skip("already matches"))
    }

    @Test func boardIsAdditiveNeverClobbers() {
        let source = Self.materialization(serverId: "src", board: "scarf:src")
        let empty = Self.materialization(serverId: "a", board: nil)
        let different = Self.materialization(serverId: "b", board: "scarf:other")
        let same = Self.materialization(serverId: "c", board: "scarf:src")

        let plan = FleetApplyPlan.make(source: source, targets: [empty, different, same], fields: [.board])
        #expect(plan.targets[0].actions.first?.disposition.isApply == true)        // empty → set
        // Different existing board is KEPT (protects the target's tasks).
        if case .skip(let reason) = plan.targets[1].actions.first?.disposition {
            #expect(reason.contains("kept"))
        } else {
            Issue.record("expected board skip on host with a different existing board")
        }
        #expect(plan.targets[2].actions.first?.disposition == .skip("already matches"))
    }

    @Test func cronApplyWhenSourceHasJobs() {
        let source = Self.materialization(serverId: "src", cronJobIds: ["j1", "j2"])
        let target = Self.materialization(serverId: "a")
        let plan = FleetApplyPlan.make(source: source, targets: [target], fields: [.cron])
        #expect(plan.targets[0].actions.first?.disposition.isApply == true)
        #expect(plan.targets[0].actions.first?.disposition.detail.contains("2") == true)
    }

    @Test func effectiveTargetsFiltersNoOpHosts() {
        let source = Self.materialization(serverId: "src", modelPresetId: "fast")
        let noop = Self.materialization(serverId: "a", modelPresetId: "fast")   // already matches
        let change = Self.materialization(serverId: "b", modelPresetId: nil)
        let plan = FleetApplyPlan.make(source: source, targets: [noop, change], fields: [.modelPreset])
        #expect(plan.effectiveTargets.map(\.serverId) == ["b"])
    }

    @Test func planCarriesTargetRootForRewrite() {
        let source = Self.materialization(serverId: "src", rootPath: "/src/proj", cronJobIds: ["j"])
        let target = Self.materialization(serverId: "a", rootPath: "/tgt/proj")
        let plan = FleetApplyPlan.make(source: source, targets: [target], fields: [.cron])
        #expect(plan.sourceRootPath == "/src/proj")
        #expect(plan.targets[0].rootPath == "/tgt/proj")
    }

    // MARK: - Cron prompt rewriting

    @Test func rewriteReplacesPathPrefix() {
        let prompt = "Read /src/proj/.scarf/config.json and update /src/proj/status.md"
        let out = FleetApplyPlan.rewriteCronPrompt(prompt, sourceRoot: "/src/proj", targetRoot: "/tgt/proj")
        #expect(out == "Read /tgt/proj/.scarf/config.json and update /tgt/proj/status.md")
    }

    @Test func rewriteReplacesBareRootAtBoundaries() {
        #expect(FleetApplyPlan.rewriteCronPrompt("cd /src/proj", sourceRoot: "/src/proj", targetRoot: "/tgt/proj") == "cd /tgt/proj")
        #expect(FleetApplyPlan.rewriteCronPrompt("cd /src/proj && go", sourceRoot: "/src/proj", targetRoot: "/tgt/proj") == "cd /tgt/proj && go")
        #expect(FleetApplyPlan.rewriteCronPrompt("at \"/src/proj\"", sourceRoot: "/src/proj", targetRoot: "/tgt/proj") == "at \"/tgt/proj\"")
    }

    @Test func rewriteDoesNotTouchPrefixCollisions() {
        // /src/proj must NOT match inside /src/proj2 — boundary check.
        let prompt = "use /src/proj2/data and /src/projector"
        let out = FleetApplyPlan.rewriteCronPrompt(prompt, sourceRoot: "/src/proj", targetRoot: "/tgt/proj")
        #expect(out == prompt)
    }

    @Test func rewriteHandlesTrailingSlashAndNoOp() {
        // Source root with trailing slash normalizes the same.
        #expect(FleetApplyPlan.rewriteCronPrompt("/src/proj/x", sourceRoot: "/src/proj/", targetRoot: "/tgt/proj") == "/tgt/proj/x")
        // No occurrence → unchanged.
        #expect(FleetApplyPlan.rewriteCronPrompt("nothing here", sourceRoot: "/src/proj", targetRoot: "/tgt/proj") == "nothing here")
        // Empty source → unchanged.
        #expect(FleetApplyPlan.rewriteCronPrompt("/src/proj", sourceRoot: "", targetRoot: "/tgt") == "/src/proj")
        // Same root → unchanged.
        #expect(FleetApplyPlan.rewriteCronPrompt("/src/proj", sourceRoot: "/src/proj", targetRoot: "/src/proj") == "/src/proj")
    }

    @Test func rewriteReplacesEveryOccurrence() {
        let prompt = "/src/proj /src/proj /src/proj"
        let out = FleetApplyPlan.rewriteCronPrompt(prompt, sourceRoot: "/src/proj", targetRoot: "/x")
        #expect(out == "/x /x /x")
    }

    // MARK: - Capability-aware cron-copy args (t-69ccb849)

    static func cronJob(
        name: String = "[proj:x] daily",
        prompt: String = "run",
        deliver: String? = nil,
        skills: [String]? = nil,
        workdir: String? = nil
    ) -> HermesCronJob {
        HermesCronJob(
            id: "id-\(name)", name: name, prompt: prompt, skills: skills,
            schedule: CronSchedule(kind: "cron"), enabled: true, state: "scheduled",
            deliver: deliver, workdir: workdir
        )
    }

    /// `deliver=all` is v0.14+ — on an older (or unknown) target the flag is
    /// dropped so `cron create` doesn't argparse-fail; the job still lands.
    @Test func cronArgsDropsDeliverAllOnPreV014() {
        let job = Self.cronJob(deliver: "all")
        for caps in [HermesCapabilities.parse("Hermes Agent v0.13.0 (2026.5.7)"), .empty] {
            let (args, dropped) = FleetApplyPlan.cronCreateArgs(
                copying: job, schedule: .cronExpression("0 9 * * *"), caps: caps, sourceRoot: "/s", targetRoot: "/t")
            #expect(!args.contains("--deliver"))
            #expect(!args.contains("all"))
            #expect(dropped)
            // The job is still created — name, schedule, prompt all present.
            #expect(args.contains("--name"))
            #expect(args.contains("0 9 * * *"))
            #expect(args.last == "run")
        }
    }

    @Test func cronArgsKeepsDeliverAllOnV014Plus() {
        let job = Self.cronJob(deliver: "all")
        let caps = HermesCapabilities.parse("Hermes Agent v0.14.0 (2026.5.16)")
        let (args, dropped) = FleetApplyPlan.cronCreateArgs(
            copying: job, schedule: .cronExpression("0 9 * * *"), caps: caps, sourceRoot: "/s", targetRoot: "/t")
        #expect(args.contains("--deliver"))
        let i = args.firstIndex(of: "--deliver")!
        #expect(args[args.index(after: i)] == "all")
        #expect(!dropped)
    }

    /// A specific platform (not `all`) is baseline — forwarded verbatim on
    /// every host, even an unknown one, including composite channel forms.
    @Test func cronArgsAlwaysForwardsSpecificPlatformDeliver() {
        for value in ["discord", "discord:general:42", "telegram:chat"] {
            let job = Self.cronJob(deliver: value)
            for caps in [HermesCapabilities.parse("Hermes Agent v0.14.0"), .empty] {
                let (args, dropped) = FleetApplyPlan.cronCreateArgs(
                    copying: job, schedule: .cronExpression("@daily"), caps: caps, sourceRoot: "/s", targetRoot: "/t")
                #expect(args.contains("--deliver"))
                let i = args.firstIndex(of: "--deliver")!
                #expect(args[args.index(after: i)] == value)
                #expect(!dropped)
            }
        }
    }

    /// `--workdir` is v0.12+ and is path-rewritten source→target like the prompt.
    @Test func cronArgsForwardsAndRewritesWorkdirOnV012Plus() {
        let caps = HermesCapabilities.parse("Hermes Agent v0.12.0 (2026.4.30)")
        // Subpath under the project root.
        let sub = FleetApplyPlan.cronCreateArgs(
            copying: Self.cronJob(workdir: "/src/proj/sub"), schedule: .cronExpression("@daily"),
            caps: caps, sourceRoot: "/src/proj", targetRoot: "/tgt/proj").args
        #expect(sub.contains("--workdir"))
        #expect(sub[sub.index(after: sub.firstIndex(of: "--workdir")!)] == "/tgt/proj/sub")
        // The most common case: workdir == the project root itself (end-of-
        // string boundary in the rewriter).
        let root = FleetApplyPlan.cronCreateArgs(
            copying: Self.cronJob(workdir: "/src/proj"), schedule: .cronExpression("@daily"),
            caps: caps, sourceRoot: "/src/proj", targetRoot: "/tgt/proj").args
        #expect(root[root.index(after: root.firstIndex(of: "--workdir")!)] == "/tgt/proj")
    }

    @Test func cronArgsDropsWorkdirOnPreV012() {
        let job = Self.cronJob(workdir: "/src/proj/sub")
        for caps in [HermesCapabilities.parse("Hermes Agent v0.11.0"), .empty] {
            let (args, _) = FleetApplyPlan.cronCreateArgs(
                copying: job, schedule: .cronExpression("@daily"), caps: caps, sourceRoot: "/src/proj", targetRoot: "/tgt/proj")
            #expect(!args.contains("--workdir"))
        }
    }

    @Test func cronArgsForwardsSkillsAndRewritesPrompt() {
        let job = Self.cronJob(prompt: "summarize /src/proj/notes.md", skills: ["research", "writing"])
        let caps = HermesCapabilities.parse("Hermes Agent v0.14.0")
        let (args, _) = FleetApplyPlan.cronCreateArgs(
            copying: job, schedule: .cronExpression("@daily"), caps: caps, sourceRoot: "/src/proj", targetRoot: "/tgt/proj")
        #expect(args.filter { $0 == "--skill" }.count == 2)
        #expect(args.contains("research"))
        #expect(args.contains("writing"))
        // prompt is the trailing positional, path-rewritten; schedule precedes it.
        #expect(args.last == "summarize /tgt/proj/notes.md")
        #expect(args[args.count - 2] == "@daily")
    }
}
