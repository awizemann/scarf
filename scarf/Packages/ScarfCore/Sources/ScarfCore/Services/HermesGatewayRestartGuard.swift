import Foundation

/// Decides, from `hermes gateway status`, whether Scarf may run
/// `hermes gateway restart` at all.
///
/// ## Why a restart can't always be sent
///
/// With no installed gateway service — no systemd unit, no launchd plist —
/// `_cmd_restart` stops the running gateway and then calls
/// `run_gateway(verbose=0, force=force)` (`hermes_cli/gateway.py:4977-4981`
/// @ v2026.9.24), which runs the new gateway INSIDE the `hermes` process
/// Scarf spawned, in the foreground, until that process ends. Scarf's CLI
/// timeout (30 s from Platforms and MCP, 60 s from the Gateway view) then
/// kills that process and the gateway with it; over SSH the ssh client dies
/// and takes the gateway's stdout with it. So a gateway the user started by
/// hand (`hermes gateway run` in tmux, or with nohup) was stopped by
/// Restart and never came back, and nothing said Scarf had stopped it. The
/// shape is the same back to the v0.6 floor (`hermes_cli/gateway.py`
/// `restart` @ v2026.3.12: kill, then `run_gateway`).
///
/// Hermes has no detached restart for this state: `gateway start` either
/// drives a service manager or, on macOS, writes and loads a launchd plist
/// (`launchd_start`, `gateway_launchd.py:656-682`) — it installs a service
/// rather than restarting a hand-run gateway — and its only detached spawn
/// (`_spawn_detached_gateway`, `:263-284`) is a launchd fallback, not a CLI
/// verb. So Scarf does not restart it: the gateway keeps running and the
/// user is told to restart it where it runs, or to install it as a service.
///
/// ## How the state is read
///
/// `_cmd_status` prints two lines only from its no-service branch
/// (`gateway.py:5054-5069`), unchanged in meaning since v2026.3.12:
/// `(Running manually, not as a system service)` under a running gateway,
/// and the `… # Run in foreground` hint under `✗ Gateway is not running`.
/// Every service branch (systemd/launchd/Windows), the multiplexer
/// satellite branch and the v0.21.5 parked early return print neither, and
/// for those `gateway restart` goes through the service manager or the host
/// gateway, so it is sent as before.
///
/// One no-service gateway restarts safely: one launched for an external
/// supervisor (`gateway run --external-supervisor` under a custom launchd
/// agent or systemd unit). From v0.21.4 `_cmd_restart` hands that one back
/// to its supervisor instead of running it in the foreground
/// (`gateway_supervised_restart.py`, `gateway.py:4966-4975`). Scarf sees it
/// the way Hermes's fallback does: the argv the gateway stamped into
/// `gateway_state.json` (`gateway/status.py:679`) for the PID status shows.
/// A supervisor Hermes detects only through the control socket is not
/// visible here, and such a gateway is treated as hand-run: refused, never
/// killed.
public enum HermesGatewayRestartGuard {

    /// What the status probe showed.
    public enum Mode: Equatable, Sendable {
        /// A service manager, the host multiplexer or a parked profile owns
        /// the lifecycle, or the output is not the no-service branch.
        case restartable
        /// No service, gateway running by hand.
        case runningWithoutService
        /// No service, and no gateway running.
        case stoppedWithoutService
    }

    /// `_cmd_status`'s no-service running line (`gateway.py:5057`).
    static let manualRunningMarker = "(Running manually, not as a system service)"
    /// `_cmd_status`'s no-service stopped hint: `hermes gateway run      #
    /// Run in foreground` from v2026.4.13 (`gateway.py:5068`),
    /// `hermes gateway          # Run in foreground` before it.
    static let manualStoppedMarker = "# Run in foreground"

    public static func mode(statusOutput: String) -> Mode {
        let text = HermesCLIVerdict.stripANSI(statusOutput)
        if text.contains(manualRunningMarker) { return .runningWithoutService }
        if text.contains("✗ Gateway is not running"), text.contains(manualStoppedMarker) {
            return .stoppedWithoutService
        }
        return .restartable
    }

    /// The PIDs of `✓ Gateway is running (PID: 12, 34)` (`gateway.py:5056`).
    static func runningPIDs(statusOutput: String) -> [Int] {
        let text = HermesCLIVerdict.stripANSI(statusOutput)
        guard let open = text.range(of: "Gateway is running (PID: "),
              let close = text[open.upperBound...].firstIndex(of: ")") else { return [] }
        return text[open.upperBound..<close]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// True when `gateway_state.json` records that one of the running PIDs
    /// was launched with `--external-supervisor`.
    static func isExternallySupervised(stateJSON: Data?, runningPIDs: [Int]) -> Bool {
        guard let stateJSON,
              let json = try? JSONSerialization.jsonObject(with: stateJSON) as? [String: Any],
              let pid = json["pid"] as? Int, runningPIDs.contains(pid),
              let argv = json["argv"] as? [String] else { return false }
        return argv.contains("--external-supervisor")
    }

    /// `nil` when Scarf may send `gateway restart`; otherwise the outcome to
    /// show instead of sending it.
    ///
    /// - Parameters:
    ///   - statusOutput / statusExitCode: the `gateway status` run.
    ///     `statusExitCode` is `-1` when the transport failed or timed out.
    ///   - stateJSON: this home's own `gateway_state.json`, for the
    ///     external-supervisor case.
    ///   - capabilities: the host's; the supervisor hand-back exists from
    ///     v0.21.4 only.
    public static func refusal(
        statusOutput: String, statusExitCode: Int32, stateJSON: Data?, capabilities: HermesCapabilities
    ) -> HermesCLIOutcome? {
        let trimmed = statusOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        // No answer at all: a restart might be the destructive kind, so it
        // is not sent blind.
        if statusExitCode == -1 || (trimmed.isEmpty && statusExitCode != 0) {
            return HermesCLIOutcome(succeeded: false, detail: statusUnreadableNote)
        }
        switch mode(statusOutput: statusOutput) {
        case .restartable:
            return nil
        case .runningWithoutService:
            if capabilities.hasSupervisedGatewayRestart,
               isExternallySupervised(stateJSON: stateJSON, runningPIDs: runningPIDs(statusOutput: statusOutput)) {
                return nil
            }
            return HermesCLIOutcome(succeeded: false, detail: runningWithoutServiceNote)
        case .stoppedWithoutService:
            return HermesCLIOutcome(succeeded: false, detail: stoppedWithoutServiceNote)
        }
    }

    public static let runningWithoutServiceNote = String(
        localized: "The gateway on this host was started by hand (for example `hermes gateway run` in a terminal), not as a service. Restarting it from Scarf would stop it and could not keep a new one running, so Scarf left it alone. Restart it where it runs, or install it as a service with `hermes gateway install` so Scarf can restart it."
    )

    public static let stoppedWithoutServiceNote = String(
        localized: "The gateway isn't running and isn't installed as a service on this host, so there is nothing Scarf can restart in the background. Start it with `hermes gateway run` in a terminal, or install it as a service with `hermes gateway install`."
    )

    public static let statusUnreadableNote = String(
        localized: "Scarf couldn't read the gateway's status, so it didn't restart it. A restart of a gateway that isn't a service would stop it for good."
    )
}
