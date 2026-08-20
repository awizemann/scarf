import Foundation
import Observation
#if canImport(os)
import os
#endif

/// Tracks connection health for the current window's server. Remote contexts
/// get a lightweight 15s heartbeat (a no-op `true` remote command) that
/// flips the status between green / yellow / red. Local contexts are always
/// green since there's no connection to lose.
@Observable
@MainActor
public final class ConnectionStatusViewModel {
    #if canImport(os)
    private let logger = Logger(subsystem: "com.scarf", category: "ConnectionStatus")
    #endif

    public enum Status: Equatable {
        /// Healthy: SSH connected AND we can read `~/.hermes/state.db`.
        case connected
        /// SSH connects but the follow-up read-access probe failed. Data
        /// views will be empty until this is resolved.
        ///
        /// `reason` is the short pill copy (e.g. `"can't read ~/.hermes/
        /// config.yaml"`); `hint` is a longer actionable string surfaced
        /// in the pill's quick popover so users see *why* and *what to do*
        /// without diving into the diagnostics sheet (issue #53). `cause`
        /// classifies the failure for UI branching.
        case degraded(reason: String, hint: String, cause: DegradedCause)
        /// No probe yet or the previous probe timed out but we haven't
        /// confirmed failure. Shown as yellow to tell the user "checking…".
        case idle
        /// Last probe failed. `message` is a terse human summary; `stderr`
        /// is the raw diagnostic text for a disclosure panel.
        case error(message: String, stderr: String)
    }

    /// Specific tier-2 failure mode emitted by the probe script. Used to
    /// drive both the pill copy and the popover hint (issue #53).
    public enum DegradedCause: Equatable {
        /// `state.db` is missing entirely. Most common cause: Hermes
        /// is installed but no session has run on this remote yet.
        /// Case name kept as `configMissing` for back-compat with
        /// callers that pattern-match on it; "config" here is loose
        /// for "Scarf's required state file."
        case configMissing
        /// `~/.hermes` itself doesn't exist. Hermes isn't installed for
        /// the SSH user on this host.
        case homeMissing
        /// File exists but the SSH user can't read it. Permission /
        /// ownership mismatch. Same back-compat note as above.
        case configUnreadable
        /// `~/.hermes/active_profile` points at a non-default Hermes
        /// profile and the configured Hermes home doesn't carry the
        /// real config — the user is reading the wrong directory.
        /// Carries the active profile name so the hint can name it.
        case profileActive(name: String)
        /// Probe couldn't classify the failure precisely (e.g. older
        /// remote returned a binary `TIER2:1` without a tag). Falls
        /// back to a generic hint.
        case unknown
    }

    public private(set) var status: Status = .idle
    /// Timestamp of the last successful probe. Used by the UI to show how
    /// fresh the status indicator is ("just now", "2m ago"…).
    public private(set) var lastSuccess: Date?
    /// Number of consecutive probe failures. Surfaced as a yellow "Reconnecting…"
    /// state for the first failure (silent retry), then promoted to red after
    /// `consecutiveFailureThreshold` failures so flaky connections don't
    /// flap the indicator on every dropped packet.
    public private(set) var consecutiveFailures = 0
    private let consecutiveFailureThreshold = 2

    public let context: ServerContext
    private var probeTask: Task<Void, Never>?

    public init(context: ServerContext) {
        self.context = context
        if !context.isRemote {
            // Local contexts are always considered connected — no network
            // or auth can fail.
            self.status = .connected
            self.lastSuccess = Date()
        }
    }

    /// Kick off a background heartbeat loop. Safe to call multiple times;
    /// subsequent calls cancel the prior task and restart.
    public func startMonitoring() {
        guard context.isRemote else { return }
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeOnce()
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s
            }
        }
    }

    public func stopMonitoring() {
        probeTask?.cancel()
        probeTask = nil
    }

    /// The in-flight user-initiated reconnect, if any.
    ///
    /// `token` identifies the *specific* probe ``retry()`` launched. The
    /// heartbeat runs every 15s, so at the moment the user hits Retry there
    /// is very often a background probe already awaiting its SSH round-trip;
    /// keying only on a start date let that older probe's completion consume
    /// the attribution and emit `reconnect_succeeded{manual}` with a duration
    /// that measured the heartbeat, not the user's wait. Only the probe
    /// carrying this token may resolve it.
    private struct ManualReconnect {
        let token: UUID
        let start: Date
    }
    private var pendingManualReconnect: ManualReconnect?

    /// Open a manual-reconnect attempt and return the token identifying it,
    /// or `nil` when this tap isn't a reconnect at all.
    ///
    /// Split out of ``retry()`` (and `internal`, not `private`) so the
    /// attribution can be tested without an SSH round-trip.
    @discardableResult
    func beginManualReconnect() -> UUID? {
        // The pill routes a plain tap here even when it's already green (a
        // "refresh now"), so only a probe launched from a *non-connected*
        // state is a reconnect. Without this guard, idly clicking a healthy
        // pill would manufacture reconnect events.
        guard status != .connected else { return nil }
        let token = UUID()
        pendingManualReconnect = ManualReconnect(token: token, start: Date())
        ScarfAnalytics.record("reconnect_attempted", ["trigger": "manual"])
        return token
    }

    /// Manual probe — also invoked by the toolbar "Retry" button on error.
    public func retry() {
        let token = beginManualReconnect()
        Task { await probeOnce(manualToken: token) }
    }

    /// Emit the degraded/reconnect events for a probe outcome. Called only
    /// from `probeOnce`, and deliberately edge-triggered: the heartbeat runs
    /// every 15s (slower when backgrounded) and a host that sits degraded for
    /// an hour must produce one event, not 240.
    ///
    /// `manualToken` is the token of the probe reporting this transition —
    /// `nil` for every background heartbeat tick. A pending manual attempt is
    /// only ever resolved by its own probe.
    func recordStatusTransition(from previous: Status, to next: Status, manualToken: UUID?) {
        if case .degraded(_, _, let cause) = next {
            let wasSameCause: Bool
            if case .degraded(_, _, let old) = previous { wasSameCause = old == cause } else { wasSameCause = false }
            if !wasSameCause {
                ScarfAnalytics.record("connection_degraded", ["cause": Self.analyticsCause(cause)])
            }
        }
        // A degraded outcome still proves SSH itself came back, so it counts
        // as a successful reconnect just like `.connected` does.
        if let pending = pendingManualReconnect, pending.token == manualToken {
            switch next {
            case .connected, .degraded:
                pendingManualReconnect = nil
                ScarfAnalytics.record("reconnect_succeeded", [
                    "trigger": "manual",
                    "duration_bucket": ScarfAnalytics.durationBucket(Date().timeIntervalSince(pending.start)),
                ])
            case .error:
                pendingManualReconnect = nil
            case .idle:
                break  // still retrying — the attempt isn't resolved yet
            }
        }
    }

    /// Bounded token for the `cause` prop. Note `profileActive`'s associated
    /// profile name is dropped on the floor — it's user-chosen text.
    nonisolated static func analyticsCause(_ cause: DegradedCause) -> String {
        switch cause {
        case .configMissing:    return "config_missing"
        case .homeMissing:      return "home_missing"
        case .configUnreadable: return "config_unreadable"
        case .profileActive:    return "profile_active"
        case .unknown:          return "unknown"
        }
    }

    /// - Parameter manualToken: non-`nil` only for the probe ``retry()``
    ///   launched for a user-initiated reconnect. Carried through the
    ///   short self-heal re-probe below, which is a continuation of the same
    ///   attempt, so the reported duration covers the user's whole wait.
    private func probeOnce(manualToken: UUID? = nil) async {
        let snapshot = context
        let hermesHome = context.paths.home
        // Two-tier probe in one SSH round-trip:
        //   tier 1: `true` — raw connectivity / auth / ControlMaster path
        //   tier 2: `test -r $HERMESHOME/state.db` — can we actually read
        //           the file Dashboard / Sessions / Activity all hit on
        //           every tick? Green pill only if both pass.
        //
        // Probe historically targeted `config.yaml`, but Hermes v0.11+
        // doesn't materialize that file eagerly — it ships with sane
        // defaults and only writes config.yaml when the user actually
        // changes something. Result: a freshly-installed Hermes that's
        // running, persisting sessions, and serving Scarf was being
        // marked "degraded — config missing" indefinitely. `state.db`
        // is created on first agent run and is the actual surface
        // Scarf depends on, so we probe that instead.
        // Script emits two lines: TIER1:<exitcode> and TIER2:<exitcode>.
        let homeArg: String
        if hermesHome.hasPrefix("~/") {
            homeArg = "\"$HOME/\(hermesHome.dropFirst(2))\""
        } else if hermesHome == "~" {
            homeArg = "\"$HOME\""
        } else {
            homeArg = "\"\(hermesHome.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        // Probe emits a granular `TIER2:1:<cause>` code so the pill can
        // surface a specific hint (issue #53). Causes:
        //   no-home — $H itself doesn't exist
        //   missing — state.db absent (Hermes hasn't been run yet)
        //   perm    — exists but unreadable by SSH user
        //   profile:<name> — state.db missing AND ~/.hermes/active_profile
        //                    points at a Hermes profile, suggesting Scarf
        //                    is reading the wrong dir
        let script = """
        echo TIER1:0
        H=\(homeArg)
        if [ -r "$H/state.db" ]; then
          echo TIER2:0
        elif [ ! -d "$H" ]; then
          echo TIER2:1:no-home
        elif [ ! -e "$H/state.db" ]; then
          ACTIVE=""
          if [ -r "$HOME/.hermes/active_profile" ]; then
            ACTIVE=$(head -n1 "$HOME/.hermes/active_profile" 2>/dev/null | tr -d ' \\t\\r\\n')
          fi
          if [ -n "$ACTIVE" ] && [ "$ACTIVE" != "default" ]; then
            echo TIER2:1:profile:$ACTIVE
          else
            echo TIER2:1:missing
          fi
        else
          echo TIER2:1:perm
        fi
        """

        enum ProbeOutcome {
            case connected
            case degraded(reason: String, hint: String, cause: DegradedCause)
            case failure(TransportError)
        }

        // Issue #44: previously this used `transport.runProcess(executable:
        // "/bin/sh", args: ["-c", script])`, which goes through
        // SSHTransport's `remotePathArg` quoting. That mangles multi-line
        // shell scripts containing `"$VAR"` references and nested
        // quotes — the remote received a scrambled string and the if-test
        // for config.yaml readability silently failed even when the file
        // was readable. Result: 14/14 diagnostics passing AND a stuck
        // "Connected — can't read Hermes state" pill, simultaneously,
        // because diagnostics had its own runOverSSH workaround. Now
        // both paths use SSHScriptRunner so they always agree.
        let outcome: ProbeOutcome = await {
            let result = await SSHScriptRunner.run(script: script, context: snapshot, timeout: 10)
            switch result {
            case .connectFailure(let msg):
                return .failure(.other(message: msg))
            case .completed(let out, let stderr, let exitCode):
                guard exitCode == 0 else {
                    return .failure(.commandFailed(exitCode: exitCode, stderr: stderr))
                }
                let tier1 = out.contains("TIER1:0")
                let tier2 = out.contains("TIER2:0")
                if !tier1 {
                    return .failure(.commandFailed(exitCode: 1, stderr: out))
                }
                if tier2 {
                    return .connected
                }
                let cause = Self.parseDegradedCause(stdout: out)
                let (reason, hint) = Self.describe(cause: cause, hermesHome: hermesHome)
                return .degraded(reason: reason, hint: hint, cause: cause)
            }
        }()

        let previousStatus = status
        defer { recordStatusTransition(from: previousStatus, to: status, manualToken: manualToken) }

        switch outcome {
        case .connected:
            status = .connected
            lastSuccess = Date()
            consecutiveFailures = 0
        case .degraded(let reason, let hint, let cause):
            status = .degraded(reason: reason, hint: hint, cause: cause)
            lastSuccess = Date()   // SSH itself is fine, reset failure count
            consecutiveFailures = 0
        case .failure(let err):
            consecutiveFailures += 1
            // First failure → silent yellow "Reconnecting…" while we try
            // again on the next 15s tick. Only flip to red after we've
            // failed `consecutiveFailureThreshold` times in a row, so a
            // single dropped packet (laptop sleep/wake, transient WiFi)
            // doesn't visually scare the user.
            if consecutiveFailures < consecutiveFailureThreshold {
                status = .idle
                // Try again sooner than the regular tick — gives the
                // typical "WiFi reconnected within 5s" case a chance to
                // self-heal before the next 15s heartbeat.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if self?.consecutiveFailures ?? 0 > 0 {
                        await self?.probeOnce(manualToken: manualToken)
                    }
                }
            } else {
                status = .error(
                    message: err.errorDescription ?? "Unreachable",
                    stderr: err.diagnosticStderr
                )
            }
        }
    }

    /// Pull a `DegradedCause` out of the probe stdout. Looks for the
    /// `TIER2:1:<code>[:detail]` line; falls back to `.unknown` when
    /// only the legacy binary `TIER2:1` is present (older remotes,
    /// future-proofs against accidental tag drops).
    nonisolated static func parseDegradedCause(stdout: String) -> DegradedCause {
        for raw in stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("TIER2:1:") else { continue }
            let body = String(line.dropFirst("TIER2:1:".count))
            if body == "no-home" { return .homeMissing }
            if body == "missing" { return .configMissing }
            if body == "perm"    { return .configUnreadable }
            if body.hasPrefix("profile:") {
                let name = String(body.dropFirst("profile:".count))
                if !name.isEmpty {
                    return .profileActive(name: name)
                }
            }
        }
        return .unknown
    }

    /// Map a `DegradedCause` into the pill's short `reason` (single line,
    /// fits in a tooltip) and longer `hint` (popover body, can carry
    /// commands the user can copy).
    nonisolated static func describe(cause: DegradedCause, hermesHome: String) -> (reason: String, hint: String) {
        switch cause {
        case .homeMissing:
            return (
                "Hermes not installed on remote",
                "`\(hermesHome)` doesn't exist on the remote. Install Hermes for the SSH user, or — if Hermes is already installed under a different path — set this server's Hermes home in Manage Servers."
            )
        case .configMissing:
            return (
                "Hermes hasn't been run yet",
                "`\(hermesHome)/state.db` is missing — Hermes creates it on first agent run. Start any session on the remote (e.g. `hermes chat`) and Scarf will go green automatically."
            )
        case .configUnreadable:
            return (
                "Permission denied on state.db",
                "`\(hermesHome)/state.db` exists but the SSH user can't read it. Check ownership: `ls -l \(hermesHome)/state.db`. Either run Hermes as the SSH user, `chmod a+r` the file, or SSH as the Hermes user."
            )
        case .profileActive(let name):
            return (
                "Hermes profile \"\(name)\" is active",
                "The remote is using Hermes profile `\(name)` — its state lives at `~/.hermes/profiles/\(name)/state.db`, not `\(hermesHome)/state.db`. Either set this server's Hermes home to `~/.hermes/profiles/\(name)` in Manage Servers → Edit, or run `hermes profile use default` on the remote to revert."
            )
        case .unknown:
            return (
                "Can't read Hermes state",
                "SSH is fine but Scarf can't reach `\(hermesHome)/state.db`. Run diagnostics for a full breakdown."
            )
        }
    }
}
