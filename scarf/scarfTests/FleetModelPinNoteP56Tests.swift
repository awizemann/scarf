import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P56, round-6 decision 8 — the fleet model-pin downgrade note, pinned at
/// BOTH seams in the shape P50 established for `pre_run_script`: the caveat
/// the user APPROVES and the counter the pass REPORTS. A note in one of them
/// is a number that does not match the outcome (P42's lesson).
@Suite struct FleetModelPinNoteP56Tests {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func theApplyPreviewNamesTheModelPinLoss() throws {
        let source = try Self.source(
            "scarf/scarf/Features/Projects/ViewModels/FleetApplyViewModel.swift")
        #expect(source.contains("cronCopySet.copyable.filter(\\.hasModelPin)"),
                "the preview no longer counts model-pinned jobs")
        #expect(source.contains("the copy follows the target host's defaults"))
    }

    @Test func theExecutorCountsTheModelPinDowngradeOnTheSuccessArm() throws {
        let source = try Self.source(
            "scarf/scarf/Features/Projects/ViewModels/FleetApplyExecutor.swift")
        #expect(source.contains("if job.hasModelPin { modelPinDowngrades += 1 }"),
                "the executor no longer counts the downgrade")
        #expect(source.contains("w/o their model pin"),
                "the count is no longer surfaced in the result message")
        // On the SUCCESS arm, beside its three siblings — never on the
        // failure arm, where it would count a job that did not land.
        let counted = try #require(source.range(of: "if job.hasModelPin"))
        #expect(source[..<counted.lowerBound].range(of: "created += 1", options: .backwards) != nil,
                "the count no longer sits on the success arm")
        #expect(source[counted.upperBound...].range(of: "failed += 1") != nil,
                "the count no longer precedes the failure arm of the create loop")
    }

    /// The pin is a DOWNGRADE, not a refusal: the job must still be in the
    /// copy set. (A monitor or `no_agent` job is the decline case.)
    @Test func aPinnedJobStaysInTheCopySet() {
        let projectID = UUID()
        let tag = FleetApplyPlan.projectCronTag(projectID)
        let job = HermesCronJob(
            id: "j1", name: tag + "pinned", prompt: "p", skills: nil, model: "hermes-4",
            schedule: CronSchedule(kind: "cron", runAt: nil, display: nil,
                                   expression: "0 9 * * *", minutes: nil, extra: [:]),
            enabled: true, state: "scheduled", deliver: nil, nextRunAt: nil,
            lastRunAt: nil, lastError: nil, preRunScript: nil,
            deliveryFailures: nil, lastDeliveryError: nil, timeoutType: nil,
            timeoutSeconds: nil, silent: nil, workdir: nil, contextFrom: nil,
            noAgent: nil, attachToSession: nil, extra: [:])
        let set = FleetApplyPlan.copyableCronJobs(from: [job], projectID: projectID)
        #expect(set.copyable.map(\.id) == ["j1"])
        #expect(set.scriptOnly.isEmpty)
        #expect(set.monitor.isEmpty)
    }
}
