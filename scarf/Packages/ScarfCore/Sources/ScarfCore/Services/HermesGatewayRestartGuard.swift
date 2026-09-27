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
/// An s6 container (the official Hermes Docker image, Fly) is also a service
/// Hermes's status can't see: `_cmd_status` picks its branch from
/// `_installed_service_kind_for` (systemd unit, launchd plist, Windows task),
/// so an s6-supervised gateway prints the no-service lines too — but
/// `_cmd_restart` dispatches to s6 before any of that
/// (`_dispatch_via_service_manager_if_s6`, `gateway.py:4925-4926`). The one
/// output that names s6 is `hermes status`'s `Manager: s6 (container
/// supervisor)` row (`status.py:232`, `gateway.py:1468-1469`), which arrives
/// in the same tag as the s6 dispatch (v2026.5.28). So on the no-service
/// branch Scarf asks `hermes status` too — through the same transport and
/// wrapper as every other `hermes` call, so it runs where Hermes runs — and
/// restarts when it names s6.
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
/// killed. That hand-back drains in-flight runs first (a 60 s floor,
/// `_get_restart_exit_wait_budget`, `gateway.py:3103-3114`) and then waits
/// up to 15 s for the supervisor's new PID, so it can outlast Scarf's CLI
/// timeout; ``decide(run:stateJSON:capabilities:stopThenStart:timeout:)``
/// says when a restart is that one, so the caller can report a timeout as
/// "still restarting" rather than a failure.
///
/// ## A parked profile
///
/// On v0.21.5 `gateway status` for a parked named profile prints only
/// `Profile '<name>': parked (hermes -p <name> gateway start)` and returns
/// (`print_parked_status`, `gateway_profile_lifecycle.py:82-88`, called
/// first in `_cmd_status`, `gateway.py:5020-5023`). That hides whether a
/// service stands behind it, and `gateway restart` for a parked profile the
/// host gateway does not serve falls through `profile_lifecycle`
/// (`gateway_profile_lifecycle.py:52-55`) to the same foreground
/// `run_gateway` — for a `gateway.standalone` profile with no service it
/// runs inside Scarf's spawn. A parked profile is stopped on purpose, so
/// there is nothing to restart: Scarf refuses and says Start serves it
/// again. A stop + start is left alone — its start unparks the profile
/// (`:32-47`), which is what Start does.
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
        /// A named profile that is parked: status printed only its parked
        /// line.
        case parkedProfile
    }

    /// What a caller should do.
    public enum Decision: Equatable, Sendable {
        /// Show this outcome instead of sending anything.
        case refuse(HermesCLIOutcome)
        /// Send the restart. `externallySupervised` is true when it is the
        /// v0.21.4+ hand-back to an external supervisor, which can outlast
        /// the caller's timeout while in-flight runs drain.
        case restart(externallySupervised: Bool)
    }

    /// `_cmd_status`'s no-service running line (`gateway.py:5057`).
    static let manualRunningMarker = "(Running manually, not as a system service)"
    /// `_cmd_status`'s no-service stopped hint: `hermes gateway run      #
    /// Run in foreground` from v2026.4.13 (`gateway.py:5068`),
    /// `hermes gateway          # Run in foreground` before it.
    static let manualStoppedMarker = "# Run in foreground"

    /// `print_parked_status`'s line for the current profile
    /// (`gateway_profile_lifecycle.py:87`).
    static func isParkedLine(_ line: String) -> Bool {
        line.hasPrefix("Profile '") && line.contains("': parked (hermes -p ")
            && line.hasSuffix(" gateway start)")
    }

    /// - Parameter profileName: the named profile this home is
    ///   (``HermesProfileScope/profileName(forHome:)``), when Scarf knows it.
    ///   Then only a parked line naming it counts, whatever else the run
    ///   printed (a stray warning on stderr, which the runner merges in). A
    ///   default home never takes the early return: the default profile
    ///   lists each parked SIBLING above its own status
    ///   (`gateway_profile_lifecycle.py:89-98`), which says nothing about
    ///   it. `nil` (not known — a local window follows the sticky
    ///   `active_profile`): the output must be parked lines only.
    public static func mode(statusOutput: String, profileName: String? = nil) -> Mode {
        let text = HermesCLIVerdict.stripANSI(statusOutput)
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let profileName {
            if lines.contains(where: { isParkedLine($0) && $0.hasPrefix("Profile '\(profileName)': parked (") }) {
                return .parkedProfile
            }
        } else if !lines.isEmpty, lines.allSatisfy(isParkedLine) {
            return .parkedProfile
        }
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

    /// `hermes status`'s service-manager row under s6.
    static let s6ManagerMarker = "s6 (container supervisor)"

    /// True when `hermes status` shows the s6 container supervisor.
    static func isS6Supervised(statusOutput: String?) -> Bool {
        guard let statusOutput else { return false }
        return HermesCLIVerdict.stripANSI(statusOutput).contains(s6ManagerMarker)
    }

    /// Runs the probes and decides, in one place, for every caller.
    ///
    /// - Parameters:
    ///   - run: a `hermes` runner with a timeout (the caller's own; it
    ///     is called with `gateway status`, and with `status` only on the
    ///     no-service branch).
    ///   - stateJSON: reads this home's own `gateway_state.json`.
    ///   - stopThenStart: the caller restarts by `gateway stop` + `gateway
    ///     start` rather than `gateway restart` (Health, the menu bar). There
    ///     a stopped no-service gateway is not a hazard — the stop finds
    ///     nothing and the start does what Start does — so only a running
    ///     one is refused: the stop would kill it and the start can't bring a
    ///     hand-run gateway back. A parked profile is not refused either:
    ///     the start unparks it.
    ///
    /// Call it off the main actor: it spawns (charter C10).
    public static func decide(
        run: (_ args: [String], _ timeout: TimeInterval) -> (output: String, exitCode: Int32),
        stateJSON: () -> Data?,
        capabilities: HermesCapabilities,
        stopThenStart: Bool = false,
        timeout: TimeInterval = 30,
        profileName: String? = nil
    ) -> Decision {
        let status = run(["gateway", "status"], timeout)
        guard status.exitCode != -1,
              !(status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status.exitCode != 0)
        else {
            return .refuse(HermesCLIOutcome(succeeded: false, detail: statusUnreadableNote))
        }
        let mode = mode(statusOutput: status.output, profileName: profileName)
        if mode == .restartable { return .restart(externallySupervised: false) }
        if stopThenStart, mode == .stoppedWithoutService || mode == .parkedProfile {
            return .restart(externallySupervised: false)
        }
        if mode == .parkedProfile {
            return .refuse(HermesCLIOutcome(succeeded: false, detail: parkedProfileNote))
        }
        let manager = run(["status"], timeout)
        // The external-supervisor hand-back is `gateway restart`'s own arm;
        // a stop + start never takes it, so there it proves nothing.
        return decision(
            statusOutput: status.output, statusExitCode: status.exitCode,
            stateJSON: stopThenStart ? nil : stateJSON(), capabilities: capabilities,
            managerStatusOutput: manager.exitCode == -1 ? nil : manager.output, profileName: profileName)
    }

    /// ``decide(run:stateJSON:capabilities:stopThenStart:timeout:)`` for a
    /// caller that only needs the refusal: `nil` when the restart may go
    /// ahead.
    public static func check(
        run: (_ args: [String], _ timeout: TimeInterval) -> (output: String, exitCode: Int32),
        stateJSON: () -> Data?,
        capabilities: HermesCapabilities,
        stopThenStart: Bool = false,
        timeout: TimeInterval = 30,
        profileName: String? = nil
    ) -> HermesCLIOutcome? {
        if case .refuse(let outcome) = decide(
            run: run, stateJSON: stateJSON, capabilities: capabilities,
            stopThenStart: stopThenStart, timeout: timeout, profileName: profileName) {
            return outcome
        }
        return nil
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
    ///   - managerStatusOutput: `hermes status`, for the s6 case; `nil`
    ///     when it was not run or did not answer.
    public static func refusal(
        statusOutput: String, statusExitCode: Int32, stateJSON: Data?, capabilities: HermesCapabilities,
        managerStatusOutput: String? = nil
    ) -> HermesCLIOutcome? {
        if case .refuse(let outcome) = decision(
            statusOutput: statusOutput, statusExitCode: statusExitCode, stateJSON: stateJSON,
            capabilities: capabilities, managerStatusOutput: managerStatusOutput) {
            return outcome
        }
        return nil
    }

    /// The decision for probes already run: see
    /// ``refusal(statusOutput:statusExitCode:stateJSON:capabilities:managerStatusOutput:)``.
    public static func decision(
        statusOutput: String, statusExitCode: Int32, stateJSON: Data?, capabilities: HermesCapabilities,
        managerStatusOutput: String? = nil, profileName: String? = nil
    ) -> Decision {
        let trimmed = statusOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        // No answer at all: a restart might be the destructive kind, so it
        // is not sent blind.
        if statusExitCode == -1 || (trimmed.isEmpty && statusExitCode != 0) {
            return .refuse(HermesCLIOutcome(succeeded: false, detail: statusUnreadableNote))
        }
        let mode = mode(statusOutput: statusOutput, profileName: profileName)
        switch mode {
        case .restartable:
            return .restart(externallySupervised: false)
        case .parkedProfile:
            return .refuse(HermesCLIOutcome(succeeded: false, detail: parkedProfileNote))
        case .runningWithoutService, .stoppedWithoutService:
            break
        }
        if isS6Supervised(statusOutput: managerStatusOutput) { return .restart(externallySupervised: false) }
        if mode == .runningWithoutService {
            if capabilities.hasSupervisedGatewayRestart,
               isExternallySupervised(stateJSON: stateJSON, runningPIDs: runningPIDs(statusOutput: statusOutput)) {
                return .restart(externallySupervised: true)
            }
            return .refuse(HermesCLIOutcome(succeeded: false, detail: runningWithoutServiceNote))
        }
        return .refuse(HermesCLIOutcome(succeeded: false, detail: stoppedWithoutServiceNote))
    }

    public static let runningWithoutServiceNote = String(
        localized: "The gateway on this host was started by hand (for example `hermes gateway run` in a terminal), not as a service. Restarting it from Scarf would stop it and could not keep a new one running, so Scarf left it alone. Restart it where it runs, or install it as a service with `hermes gateway install` so Scarf can restart it."
    )

    public static let stoppedWithoutServiceNote = String(
        localized: "The gateway isn't running and isn't installed as a service on this host, so there is nothing Scarf can restart in the background. Start it with `hermes gateway run` in a terminal, or install it as a service with `hermes gateway install`."
    )

    public static let parkedProfileNote = String(
        localized: "This profile is parked: its gateway was stopped on purpose, so there is nothing for Scarf to restart. Start the gateway to serve it again; saved changes take effect then."
    )

    public static let statusUnreadableNote = String(
        localized: "Scarf couldn't read the gateway's status, so it didn't restart it. A restart of a gateway that isn't a service would stop it for good."
    )
}
