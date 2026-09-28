import Foundation

/// A service-managed `hermes gateway restart` that is waiting for the
/// current agent turn to finish — read from `gateway_state.json`, not from
/// the CLI's output (S07-F3).
///
/// ## What Hermes does
///
/// `launchd_restart` and `systemd_restart` do not bounce the gateway at
/// once. They send SIGUSR1 and wait for the process to exit
/// (`hermes_cli/gateway_launchd.py:744-790`, `hermes_cli/gateway.py:3303-3335`
/// @ v2026.9.24); the gateway refuses new turns, waits for in-flight work
/// (up to `agent.restart_after_turn_timeout`, 1800 s by default), then stops
/// with the restart exit code, and launchd's `KeepAlive`/systemd's
/// `RestartForceExitStatus` start the replacement. The CLI's own wait is
/// `restart_drain_timeout + restart_after_turn_timeout + 15`
/// (`gateway/restart.py:358-361`) — about 30 minutes by default.
///
/// Scarf's restart spawn is capped at 60 s (charter C10), so a restart sent
/// while a chat turn or cron job ran used to end in "Gateway restart
/// failed: Command timed out…" while Hermes was in fact doing exactly what
/// was asked. Killing the CLI there does not cancel anything: the signal is
/// already delivered, and the service manager, not the CLI, starts the
/// replacement.
///
/// ## Why the state file, not the output
///
/// The CLI does print the wait (`→ Stopping gateway (PID …) — draining
/// in-flight runs (up to Ns)...`), but through a pipe Python block-buffers
/// stdout, so a run Scarf kills at its timeout usually hands back none of
/// it. The gateway itself publishes the wait: `request_restart` marks
/// `gateway_state: "draining"` while it waits (`gateway/run_shutdown.py:1577`,
/// `:1597`) and, while draining, names each unit it is holding for in
/// `active_work` (`gateway/run.py:4007-4013`, `_describe_active_work`
/// `run_shutdown.py:1511-1547`). `"draining"` has been written since
/// v2026.4.13 and `active_work` since v2026.7.20; both are read only when
/// present, so an older host shows the same wait without the per-unit
/// lines, and a host that writes neither keeps the old failure verdict.
public enum HermesGatewayRestartDrain {

    /// What `gateway_state.json` says, reduced to what a drain watch needs.
    public struct Snapshot: Equatable, Sendable {
        public var pid: Int?
        public var state: String?
        public var exitReason: String?
        /// One human line per `active_work` unit; `nil` when the gateway did
        /// not publish the key (not draining, or a pre-v2026.7.20 host).
        public var activeWork: [String]?

        public init(pid: Int?, state: String?, exitReason: String? = nil, activeWork: [String]? = nil) {
            self.pid = pid
            self.state = state
            self.exitReason = exitReason
            self.activeWork = activeWork
        }

        /// The gateway accepted a restart/stop and is waiting on work.
        public var isDraining: Bool { state == "draining" }
    }

    /// Parse `gateway_state.json`. `nil` for a missing or unreadable file.
    public static func snapshot(stateJSON: Data?) -> Snapshot? {
        guard let stateJSON,
              let json = (try? JSONSerialization.jsonObject(with: stateJSON)) as? [String: Any]
        else { return nil }
        let work = (json["active_work"] as? [Any])?.compactMap { $0 as? [String: Any] }.map(describe(unit:))
        return Snapshot(
            pid: (json["pid"] as? NSNumber)?.intValue,
            state: json["gateway_state"] as? String,
            exitReason: json["exit_reason"] as? String,
            activeWork: work
        )
    }

    /// One `active_work` entry in words — the same reading as Hermes's own
    /// `describe_active_work_unit` (`hermes_cli/update_cmd_drain_report.py:47-68`
    /// @ v2026.9.24); an unknown `kind` degrades to its name.
    public static func describe(unit: [String: Any]) -> String {
        let kind = (unit["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "work"
        let elapsed = (unit["elapsed_s"] as? NSNumber).map { formatElapsed($0.doubleValue) }
        let running = elapsed.map { String(localized: ", running \($0)") } ?? ""
        switch kind {
        case "cron":
            let job = scalarString(unit["job_id"]) ?? "?"
            return String(localized: "cron job \(job)") + running
        case "chat":
            var line = String(localized: "chat turn") + running
            if let tool = unit["current_tool"] as? String, !tool.isEmpty {
                line += String(localized: " (tool \(tool))")
            }
            return line
        default:
            return String(localized: "\(kind) run") + running
        }
    }

    /// Where a watched restart has got to.
    public enum Phase: Equatable, Sendable {
        /// The old gateway is still up, waiting on in-flight work.
        case draining(work: [String]?)
        /// The old gateway has gone and no replacement has written yet.
        case waitingForServiceManager
        /// A replacement process is starting.
        case starting
        /// A replacement process is running.
        case restarted(pid: Int)
        /// The replacement failed to start.
        case failed(reason: String?)
    }

    /// The phase of a restart that began while `drainingPID` was draining.
    public static func phase(of snapshot: Snapshot?, drainingPID: Int?) -> Phase {
        guard let snapshot else { return .waitingForServiceManager }
        let replaced = snapshot.pid != nil && snapshot.pid != drainingPID
        if replaced {
            switch snapshot.state {
            case "running", "degraded": return .restarted(pid: snapshot.pid ?? 0)
            case "startup_failed": return .failed(reason: snapshot.exitReason)
            default: return .starting
            }
        }
        if snapshot.isDraining { return .draining(work: snapshot.activeWork) }
        return .waitingForServiceManager
    }

    /// True when a `gateway restart` run ended at Scarf's own timer — the
    /// only case the state file is consulted for. A missing binary or an
    /// SSH failure also answers -1, but without the timeout line.
    public static func timedOut(output: String, exitCode: Int32) -> Bool {
        exitCode == -1
            && HermesCLIVerdict.significantLines(output).last?
                .hasPrefix(HermesGatewayServiceVerdict.transportTimeoutPrefix) == true
    }

    /// The CLI's own wait, when its announcement did reach Scarf:
    /// `(up to Ns)` (launchd, `gateway_launchd.py:763`; external supervisor,
    /// `gateway_supervised_restart.py:86-87`) or `waiting up to Ns`
    /// (systemd, `gateway.py:3330-3333`).
    public static func budgetSeconds(fromOutput output: String) -> Int? {
        let pattern = #"(?:\(up to|waiting up to) (\d+)s"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.matches(in: output, range: range).last,
              let r = Range(match.range(at: 1), in: output) else { return nil }
        return Int(output[r])
    }

    /// Hermes's default wait: `restart_drain_timeout` (0) +
    /// `restart_after_turn_timeout` (1800, `hermes_cli/config_defaults.py:103`)
    /// + 15 s headroom (`gateway/restart.py:358-361`) @ v2026.9.24.
    public static let defaultBudgetSeconds = 1815

    /// The verdict's note for a restart Hermes is holding for in-flight work.
    public static let pendingNote = String(
        localized: "Waiting for the current turn to finish — Hermes restarts the gateway as soon as it ends."
    )

    static func formatElapsed(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 60 ? String(format: "%dm%02ds", total / 60, total % 60) : "\(total)s"
    }

    private static func scalarString(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
}
