import Testing
import Foundation
@testable import ScarfCore

/// Decision 12 — the fleet-copied pre-run script.
@Suite struct FleetPreRunScriptP50Tests {

    private static func job(script: String?, noAgent: Bool?) -> HermesCronJob {
        HermesCronJob(
            id: "j1", name: "n", prompt: "p", skills: nil, model: nil,
            schedule: CronSchedule(kind: "cron", runAt: nil, display: nil,
                                   expression: "0 9 * * *", minutes: nil, extra: [:]),
            enabled: true, state: "scheduled", deliver: nil, nextRunAt: nil,
            lastRunAt: nil, lastError: nil, preRunScript: script,
            deliveryFailures: nil, lastDeliveryError: nil, timeoutType: nil,
            timeoutSeconds: nil, silent: nil, workdir: nil, contextFrom: nil,
            noAgent: noAgent, attachToSession: nil, extra: [:])
    }

    /// An AGENT job with a script is the downgrade case; a `no_agent` job is
    /// the DECLINE case and must not be double-counted as both.
    @Test func onlyAnAgentJobWithAScriptIsADowngrade() {
        #expect(Self.job(script: "/h/scripts/check.py", noAgent: nil).hasPreRunScript)
        #expect(Self.job(script: "/h/scripts/check.py", noAgent: false).hasPreRunScript)
        #expect(!Self.job(script: "/h/scripts/check.py", noAgent: true).hasPreRunScript)
        #expect(!Self.job(script: nil, noAgent: nil).hasPreRunScript)
        // Hermes writes an unset optional text field as `None` OR `""`
        // (`_normalize_job_optional_text`, `cron/jobs.py:1583-1584`).
        #expect(!Self.job(script: "", noAgent: nil).hasPreRunScript)
        #expect(!Self.job(script: "   ", noAgent: nil).hasPreRunScript)
    }

    /// The decision's other half: the job is **still copied**. A scripted
    /// agent job stays in `copyable`, unlike a monitor or `no_agent` job.
    @Test func aScriptedAgentJobIsStillCopied() {
        let projectID = UUID()
        let tag = FleetApplyPlan.projectCronTag(projectID)
        func tagged(_ id: String, script: String?, noAgent: Bool?) -> HermesCronJob {
            let base = Self.job(script: script, noAgent: noAgent)
            return HermesCronJob(
                id: id, name: tag + id, prompt: base.prompt, skills: nil, model: nil,
                schedule: base.schedule, enabled: true, state: "scheduled", deliver: nil,
                nextRunAt: nil, lastRunAt: nil, lastError: nil, preRunScript: script,
                deliveryFailures: nil, lastDeliveryError: nil, timeoutType: nil,
                timeoutSeconds: nil, silent: nil, workdir: nil, contextFrom: nil,
                noAgent: noAgent, attachToSession: nil, extra: [:])
        }
        let set = FleetApplyPlan.copyableCronJobs(
            from: [tagged("scripted", script: "/h/scripts/c.py", noAgent: nil),
                   tagged("watchdog", script: "/h/scripts/c.py", noAgent: true),
                   tagged("plain", script: nil, noAgent: nil)],
            projectID: projectID)
        #expect(set.copyable.map(\.id).sorted() == ["plain", "scripted"])
        #expect(set.scriptOnly.map(\.id) == ["watchdog"])
        #expect(set.copyable.filter(\.hasPreRunScript).map(\.id) == ["scripted"])
    }
}
