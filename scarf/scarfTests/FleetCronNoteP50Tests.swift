import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P50 — round-5 decision 12: a fleet-copied agent job with a pre-run script
/// is a **downgrade note**, not a silent loss and not a refusal.
///
/// The two seams are the ones round-4 decision 8 established for monitor jobs
/// and P42's lesson names: `FleetApplyViewModel`'s caveats (what the user
/// APPROVES) and `FleetApplyExecutor`'s success-arm count (what the pass
/// REPORTS). A note in only one of them is the "fix at the executor is a fix
/// in one of two places" bug, so both are pinned here.
///
/// Neither is reachable without a live plan and a transport, so the alarm is
/// the shape in the source — the `CronScheduleDisplayP42cTests` precedent.
@Suite struct FleetCronNoteP50Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The preview the user approves says the script does not travel.
    @Test func theApplyPreviewNamesThePreRunScriptLoss() throws {
        let source = try Self.source(
            "scarf/scarf/Features/Projects/ViewModels/FleetApplyViewModel.swift")
        #expect(source.contains("cronCopySet.copyable.filter(\\.hasPreRunScript)"),
                "the preview no longer counts scripted agent jobs")
        #expect(source.contains("the script file stays on this host"))
    }

    /// And the pass REPORTS it, on the success arm — the copy landed, it just
    /// wakes without the script's stdout. Same rule as the continuity and
    /// cross-job notes it sits beside.
    @Test func theExecutorCountsThePreRunScriptDowngradeOnTheSuccessArm() throws {
        let source = try Self.source(
            "scarf/scarf/Features/Projects/ViewModels/FleetApplyExecutor.swift")
        #expect(source.contains("if job.hasPreRunScript { preRunScriptDowngrades += 1 }"),
                "the executor no longer counts the downgrade")
        #expect(source.contains("w/o their pre-run script"),
                "the count is no longer surfaced in the result message")
        // On the SUCCESS arm: the count must sit after `created += 1`, beside
        // the other two downgrade counters, not on the failure arm where it
        // would double-count a job that never landed.
        let counted = try #require(source.range(of: "if job.hasPreRunScript"))
        // The nearest `created += 1` BEFORE it, and the nearest `failed += 1`
        // AFTER it — scoped this way because the file has several of each and
        // the first of either belongs to another field's pass.
        let before = source[..<counted.lowerBound]
        let after = source[counted.upperBound...]
        #expect(before.range(of: "created += 1", options: .backwards) != nil,
                "the count no longer sits on the success arm")
        #expect(after.range(of: "failed += 1") != nil,
                "the count no longer precedes the failure arm of the create loop")
    }

    /// The decision's boundary, in the executor's own terms: a `no_agent` job
    /// is DECLINED (`scriptOnly`) and never reaches the create loop, so it can
    /// never be counted as a downgrade too.
    @Test func aScriptOnlyJobIsDeclinedRatherThanDowngraded() {
        let projectID = UUID()
        let tag = FleetApplyPlan.projectCronTag(projectID)
        func job(_ id: String, noAgent: Bool?) -> HermesCronJob {
            HermesCronJob(
                id: id, name: tag + id, prompt: "p", skills: nil, model: nil,
                schedule: CronSchedule(kind: "cron", runAt: nil, display: nil,
                                       expression: "0 9 * * *", minutes: nil, extra: [:]),
                enabled: true, state: "scheduled", deliver: nil, nextRunAt: nil,
                lastRunAt: nil, lastError: nil, preRunScript: "/h/scripts/c.py",
                deliveryFailures: nil, lastDeliveryError: nil, timeoutType: nil,
                timeoutSeconds: nil, silent: nil, workdir: nil, contextFrom: nil,
                noAgent: noAgent, attachToSession: nil, extra: [:])
        }
        let set = FleetApplyPlan.copyableCronJobs(
            from: [job("agent", noAgent: nil), job("watchdog", noAgent: true)],
            projectID: projectID)
        #expect(set.copyable.map(\.id) == ["agent"])
        #expect(set.scriptOnly.map(\.id) == ["watchdog"])
        #expect(set.declined.filter(\.hasPreRunScript).isEmpty)
    }
}
