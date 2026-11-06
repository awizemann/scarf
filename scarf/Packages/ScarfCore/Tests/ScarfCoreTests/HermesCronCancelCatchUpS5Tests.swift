import Testing
import Foundation
@testable import ScarfCore

/// S5 — v0.22.6 `cron cancel`, the `cancelled` last_status, and the
/// catch-up/grace/timezone authored fields. Cited @ v0.23.0.
@Suite struct HermesCronCancelCatchUpS5Tests {
    static let v0225 = HermesCapabilities.parseLine("Hermes Agent v0.22.5 (2026.10.20)")
    static let v0226 = HermesCapabilities.parseLine("Hermes Agent v0.22.6 (2026.10.27)")

    // MARK: - cancel argv (hermes_cli/subcommands/cron.py:200-204)

    @Test func cancelArgvEndsWithJobIDBehindDoubleDash() {
        #expect(HermesCronCancelVerdict.argv(jobID: "abc123") == ["cron", "cancel", "--", "abc123"])
        #expect(HermesCronCancelVerdict.argv(jobID: "abc", reason: "-oops")
                == ["cron", "cancel", "--reason=-oops", "--", "abc"])
        #expect(HermesCronCancelVerdict.argv(jobID: "abc", reason: "  ") == ["cron", "cancel", "--", "abc"])
    }

    // MARK: - cancel outcomes (hermes_cli/cron.py:999-1012)

    @Test func failedToCancelIsFailure() {
        let v = HermesCronCancelVerdict.judge(output: "Failed to cancel run: job not found\n", exitCode: 1)
        #expect(v == .failed("Failed to cancel run: job not found"))
    }

    @Test func nothingToCancelIsNotSuccess() {
        let v = HermesCronCancelVerdict.judge(
            output: "\u{1B}[33mNothing to cancel for Nightly (abc123)\u{1B}[0m\n", exitCode: 0)
        #expect(v == .nothingToCancel)
    }

    @Test func cancelRequestedIsSuccess() {
        let out = "Cancel requested for Nightly (abc123)\n  Execution: e1 (pid 42)\n  signalled\n"
        #expect(HermesCronCancelVerdict.judge(output: out, exitCode: 0) == .cancelRequested)
    }

    /// C5: an exit-0 reply with no known marker (e.g. an unknown verb routed
    /// to the agent on an older host) is never success.
    @Test func unknownExitZeroOutputIsUnrecognized() {
        #expect(HermesCronCancelVerdict.judge(output: "Sure! I cancelled it.", exitCode: 0) == .unrecognized)
        #expect(HermesCronCancelVerdict.judge(output: "", exitCode: 0) == .unrecognized)
        if case .failed = HermesCronCancelVerdict.judge(output: "usage: hermes cron …", exitCode: 2) {} else {
            Issue.record("non-zero exit must be a failure")
        }
    }

    // MARK: - model

    static func job(_ extraJSON: String, state: String = "scheduled") throws -> HermesCronJob {
        let json = """
            {"id": "j1", "name": "Nightly", "prompt": "p", "enabled": true, "state": "\(state)",
             "schedule": {"kind": "cron", "expr": "0 9 * * *", "display": "0 9 * * *"}\(extraJSON)}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    @Test func cancelledStatusHasItsOwnIcon() throws {
        let cancelled = try Self.job("", state: "cancelled")
        #expect(cancelled.stateIcon == "stop.circle")
        let last = try Self.job(#", "last_status": "cancelled", "last_error": null"#)
        #expect(last.lastRunWasCancelled)
        #expect(last.lastStatus == "cancelled")
        #expect(try !Self.job(#", "last_status": "ok""#).lastRunWasCancelled)
    }

    @Test func catchUpAndLiveClaimRead() throws {
        #expect(try Self.job(#", "catch_up": false"#).catchUp == false)
        #expect(try Self.job(#", "catch_up": true"#).catchUp == true)
        #expect(try Self.job("").catchUp == nil)
        #expect(try Self.job(#", "fire_claim": {"at": "x", "by": "m:1"}"#).hasLiveRunClaim)
        #expect(try !Self.job(#", "fire_claim": null, "run_claim": null"#).hasLiveRunClaim)
    }

    // MARK: - duplicate keys (cron/job_definition.py:13-18)

    static let catchUpExtra = #", "timezone": "Europe/Paris", "grace_minutes": 30, "catch_up": false"#

    @Test func duplicateCarriesCatchUpGraceTimezoneOnV0226() throws {
        let copy = try Self.job(Self.catchUpExtra)
            .duplicatedAsNewJob(id: "j2", existingNames: ["Nightly"], capabilities: Self.v0226)
        #expect(copy.extra["timezone"] == .string("Europe/Paris"))
        #expect(copy.extra["grace_minutes"] == .int(30))
        #expect(copy.extra["catch_up"] == .bool(false))
    }

    /// C1: the v0.22.5 allowlist is unchanged.
    @Test func olderAllowlistUnchanged() throws {
        let copy = try Self.job(Self.catchUpExtra)
            .duplicatedAsNewJob(id: "j2", existingNames: ["Nightly"], capabilities: Self.v0225)
        #expect(copy.extra["timezone"] == nil)
        #expect(copy.extra["grace_minutes"] == nil)
        #expect(copy.extra["catch_up"] == nil)
        #expect(!HermesCronJob.authoredExtraKeys.contains("catch_up"))
    }
}
