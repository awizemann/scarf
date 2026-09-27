import Testing
import Foundation
@testable import scarf
import ScarfCore

/// S08-F2: the project dashboard's cron-status widget badges the job's
/// EFFECTIVE state — the same one the Cron tab shows — not the raw
/// `enabled` flag. Records are decoded from `jobs.json` shapes Hermes
/// actually writes (`cron/jobs.py` @ v2026.9.24).
@MainActor
@Suite struct CronStatusWidgetBadgeTests {

    private static func job(_ fields: String) throws -> HermesCronJob {
        let json = #"{"jobs": [{"id": "j1", "name": "Nightly", "prompt": "p", "schedule": {"kind": "cron", "expr": "0 9 * * *", "display": "0 9 * * *"}, \#(fields)}]}"#
        return try #require(try JSONDecoder().decode(CronJobsFile.self, from: Data(json.utf8)).jobs.first)
    }

    /// `pause_job` (`:2073-2076`) writes enabled=false + state=paused + paused_at.
    @Test func pausedJobReadsPausedNotDisabled() throws {
        let badge = CronStatusWidgetView.badge(for: try Self.job(
            #""enabled": false, "state": "paused", "paused_at": "2026-09-26T09:00:00+00:00""#))
        #expect(badge.label == "PAUSED")
        #expect(badge.status == .warning)
    }

    /// A finished one-shot (`:1563`) writes enabled=false + state=completed.
    @Test func finishedOneShotReadsCompleted() throws {
        let badge = CronStatusWidgetView.badge(for: try Self.job(#""enabled": false, "state": "completed""#))
        #expect(badge.label == "COMPLETED")
        #expect(badge.status != .danger)
    }

    @Test func errorReadsDanger() throws {
        let badge = CronStatusWidgetView.badge(for: try Self.job(#""enabled": false, "state": "error""#))
        #expect(badge.label == "ERROR")
        #expect(badge.status == .danger)
    }

    /// enabled=true is authoritative: a stale "paused" state on an enabled
    /// job must not read as paused (`effective_job_state`, `:537-540`).
    @Test func enabledJobWithStalePausedStateReadsScheduled() throws {
        let badge = CronStatusWidgetView.badge(for: try Self.job(#""enabled": true, "state": "paused""#))
        #expect(badge.label == "SCHEDULED")
        #expect(badge.status == .success)
    }

    @Test func runningReadsInfo() throws {
        let badge = CronStatusWidgetView.badge(for: try Self.job(#""enabled": true, "state": "running""#))
        #expect(badge.label == "RUNNING")
        #expect(badge.status == .info)
    }

    /// The widget and the Cron tab agree for every state Hermes writes.
    @Test func badgeMatchesEffectiveState() throws {
        for fields in [#""enabled": false, "state": "paused""#, #""enabled": false, "state": "completed""#,
                       #""enabled": true, "state": "scheduled""#, #""enabled": false, "state": "error""#] {
            let job = try Self.job(fields)
            #expect(CronStatusWidgetView.badge(for: job).label == job.effectiveState.uppercased())
        }
    }
}
