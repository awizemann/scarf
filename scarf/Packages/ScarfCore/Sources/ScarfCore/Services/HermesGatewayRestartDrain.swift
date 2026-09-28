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
/// `run_shutdown.py:1511-1547`). Only a drain with `restart_requested: true`
/// counts (see ``Snapshot/isDrainingForRestart``): that flag is set only by
/// the SIGUSR1 in-band restart, the one drain the service manager follows
/// with a new gateway. `active_work` (v2026.7.20+) is read when present, so
/// an older host shows the same wait without the per-unit lines, and a host
/// whose state file says neither keeps the old failure verdict.
public enum HermesGatewayRestartDrain {

    /// What `gateway_state.json` says, reduced to what a drain watch needs.
    public struct Snapshot: Equatable, Sendable {
        public var pid: Int?
        public var state: String?
        public var exitReason: String?
        /// One human line per `active_work` unit; `nil` when the gateway did
        /// not publish the key (not draining, or a pre-v2026.7.20 host).
        public var activeWork: [String]?
        /// `restart_requested` — true only on the SIGUSR1 `request_restart`
        /// path (`gateway/run_shutdown.py:1609-1617`, written by
        /// `_update_runtime_status`, `gateway/run.py:4012` @ v2026.9.24).
        public var restartRequested: Bool
        /// `updated_at` as written — compared only with ITSELF across polls
        /// (never with this Mac's clock, which may not match the host's).
        public var updatedAt: String?

        public init(pid: Int?, state: String?, exitReason: String? = nil,
                    activeWork: [String]? = nil, restartRequested: Bool = false,
                    updatedAt: String? = nil) {
            self.pid = pid
            self.state = state
            self.exitReason = exitReason
            self.activeWork = activeWork
            self.restartRequested = restartRequested
            self.updatedAt = updatedAt
        }

        /// The gateway is waiting on work before it stops, for any reason.
        public var isDraining: Bool { state == "draining" }

        /// The gateway accepted an IN-BAND RESTART and is waiting on work —
        /// the only drain the service manager follows with a new gateway.
        ///
        /// `draining` alone is not enough. A SIGTERM stop drains too (the
        /// pre-v2026.8.31 launchd restart was SIGTERM, then the CLI's own
        /// `launchctl kickstart -k`, which never runs once Scarf's timer kills
        /// the CLI), and so do a scale-to-zero suspend (`run_shutdown.py:542`)
        /// and a dashboard drain request (`:698`). None of those sets
        /// `restart_requested`, and none of them is a restart Hermes will
        /// finish by itself.
        public var isDrainingForRestart: Bool { isDraining && restartRequested }
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
            activeWork: work,
            restartRequested: (json["restart_requested"] as? Bool) ?? false,
            updatedAt: json["updated_at"] as? String
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

    /// The one question both restart call sites ask after the CLI returns:
    /// did the run end at Scarf's timer while the gateway drains FOR A
    /// RESTART? Then the snapshot to watch from and Hermes's wait budget
    /// (the announced one when the output got through, else computed from
    /// config.yaml). The readers are only called on a timeout; both run off
    /// the main actor at the call sites.
    public static func afterTimeout(
        output: String, exitCode: Int32,
        stateJSON: () -> Data?, configYAML: () -> String?
    ) -> (snapshot: Snapshot, budgetSeconds: Int)? {
        guard timedOut(output: output, exitCode: exitCode),
              let snap = snapshot(stateJSON: stateJSON()), snap.isDrainingForRestart
        else { return nil }
        return (snap, budgetSeconds(fromOutput: output) ?? budgetSeconds(configYAML: configYAML()))
    }

    /// Hermes's own staleness window for `gateway_state.json`: the
    /// housekeeping thread re-stamps `updated_at` every 60 s tick and a
    /// record older than 2x that is suspect (`_RUNTIME_STATUS_STALE_TTL_S =
    /// 120`, `gateway/status.py:1170-1175` @ v2026.9.24, since v2026.7.30).
    /// Hermes itself treats a stale heartbeat as a health warning, NOT death
    /// (`derive_gateway_busy`, `:1210-1212`), so the watcher only acts on it
    /// when it cannot prove the process is alive.
    public static let heartbeatStaleSeconds = 120

    /// `sh -c 'kill -0 <pid>'` on the host: exit 0 = alive; "No such
    /// process" = gone; anything else (a permission refusal, a transport
    /// error) = unknown. POSIX `kill`, present on macOS and Linux.
    public static func livenessArgv(pid: Int) -> [String] { ["-c", "kill -0 \(pid)"] }

    public static func liveness(exitCode: Int32, stderr: String) -> Bool? {
        if exitCode == 0 { return true }
        if stderr.lowercased().contains("no such process") { return false }
        return nil
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

    /// Hermes's own wait, computed the way the CLI does
    /// (`_get_restart_exit_wait_budget`, `hermes_cli/gateway.py:3103-3114`;
    /// `resolve_restart_exit_wait_budget`, `gateway/restart.py:358-361` @
    /// v2026.9.24): `agent.restart_drain_timeout` (default 0) +
    /// `agent.restart_after_turn_timeout` (default 1800) + 15. The
    /// `HERMES_RESTART_*` env overrides live in the gateway's process
    /// environment, which Scarf cannot see; config.yaml is the documented
    /// home for both keys.
    public static func budgetSeconds(configYAML: String?) -> Int {
        let values = configYAML.map { HermesYAML.parseNestedYAML($0).values } ?? [:]
        func seconds(_ key: String, _ fallback: Double) -> Double {
            guard let raw = values["agent." + key].map(HermesYAML.stripYAMLQuotes),
                  let value = Double(raw.trimmingCharacters(in: .whitespaces)), value >= 0
            else { return fallback }
            return value
        }
        return Int(seconds("restart_drain_timeout", 0) + seconds("restart_after_turn_timeout", 1800) + 15)
    }

    /// The ceiling for Scarf's `gateway restart` spawn.
    ///
    /// 60 s where the restart is in band (the service manager, not the CLI,
    /// starts the replacement — killing the CLI then cancels nothing). Below
    /// ``HermesCapabilities/hasLaunchdInBandRestart`` a launchd restart is
    /// SIGTERM, a wait of `agent.restart_drain_timeout`, then the CLI's own
    /// `launchctl kickstart -k` (90 s cap) — a spawn killed before that left
    /// the gateway stopped. There the ceiling covers the configured drain
    /// (180 s when the key is absent — the default up to v2026.5.7, a safe
    /// upper bound after) plus the kickstart and a margin. A ceiling, not a
    /// wait: the CLI still returns as soon as it is done.
    public static func restartSpawnTimeout(capabilities: HermesCapabilities, configYAML: String?) -> TimeInterval {
        let inBand: TimeInterval = 60
        guard !capabilities.hasLaunchdInBandRestart else { return inBand }
        let values = configYAML.map { HermesYAML.parseNestedYAML($0).values } ?? [:]
        let drain = values["agent.restart_drain_timeout"]
            .map(HermesYAML.stripYAMLQuotes)
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .map { max(0, $0) } ?? 180
        return max(inBand, drain + 120)
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
