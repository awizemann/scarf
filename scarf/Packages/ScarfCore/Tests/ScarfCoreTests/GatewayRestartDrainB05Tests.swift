import Testing
import Foundation
@testable import ScarfCore

/// S07-F3: a launchd/systemd `gateway restart` sent while an agent turn runs
/// is held by Hermes until the turn ends (up to ~30 min). Scarf's 60 s spawn
/// ends first; the gateway's own `gateway_state.json` says it is draining.
@Suite struct GatewayRestartDrainB05Tests {

    /// Written by Hermes's own writer at v2026.9.24 against a scratch
    /// HERMES_HOME (`gateway.status._prepare_runtime_status_update(
    /// gateway_state="draining", restart_requested=True, active_work=[…])`),
    /// byte-for-byte what `json.dumps(payload, sort_keys=True)` printed.
    static let hermesDrainingRecord = #"""
    {"active_agents": 2, "active_work": [{"current_tool": "terminal", "elapsed_s": 130.4, "kind": "chat", "model": "m", "pid": 4242, "session": "agent:main:telegram:dm:1"}, {"elapsed_s": 12.0, "external": true, "job_id": "abc123", "kind": "cron", "pid": 999, "wedged": false}, {"kind": "api", "pid": 4242}], "argv": ["-"], "code_sha": "f97608f178d1ffeca59860195ab7da295f7c8e5f", "code_version": "0.21.5", "exit_reason": null, "gateway_state": "draining", "hermes_home": "/tmp/scratch", "kind": "hermes-gateway", "pid": 74654, "platforms": {}, "restart_requested": true, "session_store": {"status": "unknown"}, "start_time": 179055310754, "updated_at": "2026-09-27T23:51:48.253063+00:00"}
    """#

    static func record(pid: Int?, state: String?, exitReason: String? = nil) -> Data {
        var json: [String: Any] = [:]
        if let pid { json["pid"] = pid }
        if let state { json["gateway_state"] = state }
        if let exitReason { json["exit_reason"] = exitReason }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    static let timedOut = "Command timed out after 60s."

    // MARK: - Reading the state file

    @Test func readsHermesOwnDrainingRecord() throws {
        let snap = try #require(HermesGatewayRestartDrain.snapshot(stateJSON: Data(Self.hermesDrainingRecord.utf8)))
        #expect(snap.pid == 74654)
        #expect(snap.isDraining)
        #expect(snap.exitReason == nil)
        let work = try #require(snap.activeWork)
        #expect(work.count == 3)
        #expect(work[0].hasPrefix("chat turn"))
        #expect(work[0].contains("2m10s"))
        #expect(work[0].contains("terminal"))
        #expect(work[1].hasPrefix("cron job abc123"))
        #expect(work[1].contains("12s"))
        #expect(work[2].hasPrefix("api run"))
    }

    /// A pre-v2026.7.20 host drains without `active_work`: the wait is still
    /// recognised, just without the per-unit lines.
    @Test func olderHostWithoutActiveWorkStillReadsAsDraining() throws {
        let snap = try #require(HermesGatewayRestartDrain.snapshot(stateJSON: Self.record(pid: 10, state: "draining")))
        #expect(snap.isDraining)
        #expect(snap.activeWork == nil)
    }

    @Test func unreadableOrMissingFileIsNil() {
        #expect(HermesGatewayRestartDrain.snapshot(stateJSON: nil) == nil)
        #expect(HermesGatewayRestartDrain.snapshot(stateJSON: Data("not json".utf8)) == nil)
    }

    // MARK: - Phases of a watched restart

    @Test func phasesFollowThePidAndState() {
        func phase(_ data: Data?) -> HermesGatewayRestartDrain.Phase {
            HermesGatewayRestartDrain.phase(
                of: HermesGatewayRestartDrain.snapshot(stateJSON: data), drainingPID: 100)
        }
        #expect(phase(Self.record(pid: 100, state: "draining")) == .draining(work: nil))
        // The old process wrote its exit and nothing has replaced it yet.
        #expect(phase(Self.record(pid: 100, state: "stopped")) == .waitingForServiceManager)
        #expect(phase(nil) == .waitingForServiceManager)
        #expect(phase(Self.record(pid: 200, state: "starting")) == .starting)
        #expect(phase(Self.record(pid: 200, state: "running")) == .restarted(pid: 200))
        #expect(phase(Self.record(pid: 200, state: "degraded")) == .restarted(pid: 200))
        #expect(phase(Self.record(pid: 200, state: "startup_failed", exitReason: "no platforms"))
            == .failed(reason: "no platforms"))
    }

    // MARK: - The verdict

    @Test func aTimedOutRestartWhileDrainingIsWaitingNotFailed() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart, output: Self.timedOut, exitCode: -1, drainingAfterTimeout: true)
        #expect(outcome.succeeded == false)
        #expect(outcome.confidence == .unconfirmed)
        #expect(outcome.detail == HermesGatewayRestartDrain.pendingNote)
    }

    /// Without the state file's word, a timeout stays the failure it was —
    /// the pre-fix behaviour, unchanged.
    @Test func aTimedOutRestartWithoutDrainEvidenceStillFails() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart, output: Self.timedOut, exitCode: -1)
        #expect(outcome.confidence == .failed)
    }

    /// A transport failure (no timeout line) is never "waiting", even if a
    /// stale state file happens to say draining.
    @Test func aTransportFailureIsNotWaiting() {
        for output in ["", "Can't reach host. Check the hostname, network, and SSH config."] {
            let outcome = HermesGatewayServiceVerdict.judge(
                verb: .restart, output: output, exitCode: -1, drainingAfterTimeout: true)
            #expect(outcome.confidence == .failed, "\(output)")
        }
        #expect(!HermesGatewayRestartDrain.timedOut(output: "", exitCode: -1))
        #expect(!HermesGatewayRestartDrain.timedOut(output: Self.timedOut, exitCode: 1))
        #expect(HermesGatewayRestartDrain.timedOut(output: "→ Stopping gateway\n" + Self.timedOut, exitCode: -1))
    }

    /// A run that printed a real refusal keeps it.
    @Test func aRefusalBeforeTheTimeoutWins() {
        let output = "✗ Gateway service restart failed.\n" + Self.timedOut
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .restart, output: output, exitCode: -1, drainingAfterTimeout: true)
        #expect(outcome.confidence == .failed)
    }

    /// Only `restart` has the arm.
    @Test func stopIsNotReinterpreted() {
        let outcome = HermesGatewayServiceVerdict.judge(
            verb: .stop, output: Self.timedOut, exitCode: -1, drainingAfterTimeout: true)
        #expect(outcome.confidence == .failed)
    }

    // MARK: - The announced budget

    @Test func budgetIsReadFromEachBackendsAnnouncement() {
        // gateway_launchd.py:763 @ v2026.9.24
        #expect(HermesGatewayRestartDrain.budgetSeconds(
            fromOutput: "→ Stopping gateway (PID 812) — draining in-flight runs (up to 1815s)...\n" + Self.timedOut) == 1815)
        // gateway.py:3330-3333 @ v2026.9.24
        #expect(HermesGatewayRestartDrain.budgetSeconds(
            fromOutput: "⏳ User service restarting gracefully (PID 812) — waiting up to 1875s for in-flight turns + drain...") == 1875)
        #expect(HermesGatewayRestartDrain.budgetSeconds(fromOutput: Self.timedOut) == nil)
    }
}
