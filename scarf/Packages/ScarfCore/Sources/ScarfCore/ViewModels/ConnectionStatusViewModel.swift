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
        /// Healthy: SSH connected AND we can read `~/.hermes/config.yaml`.
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
        /// `config.yaml` is missing entirely. Most common cause: Hermes
        /// hasn't run `setup` yet on this remote.
        case configMissing
        /// `~/.hermes` itself doesn't exist. Hermes isn't installed for
        /// the SSH user on this host.
        case homeMissing
        /// File exists but the SSH user can't read it. Permission /
        /// ownership mismatch.
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

    /// Manual probe — also invoked by the toolbar "Retry" button on error.
    public func retry() {
        Task { await probeOnce() }
    }

    private func probeOnce() async {
        let snapshot = context
        let hermesHome = context.paths.home
        // Two-tier probe in one SSH round-trip:
        //   tier 1: `true` — raw connectivity / auth / ControlMaster path
        //   tier 2: `test -r $HERMESHOME/config.yaml` — can we actually
        //           read the file Dashboard reads on every tick? Green pill
        //           only if both pass; yellow "degraded" if tier 1 passes
        //           but tier 2 fails (the exact symptom in issue #19).
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
        // surface a specific hint (issue #53) instead of the prior
        // collapsed-to-binary "can't read config.yaml". Causes:
        //   no-home — $H itself doesn't exist
        //   missing — config.yaml absent
        //   perm    — exists but unreadable by SSH user
        //   profile:<name> — config missing AND ~/.hermes/active_profile
        //                    points at a Hermes profile, suggesting Scarf
        //                    is reading the wrong dir
        let script = """
        echo TIER1:0
        H=\(homeArg)
        if [ -r "$H/config.yaml" ]; then
          echo TIER2:0
        elif [ ! -d "$H" ]; then
          echo TIER2:1:no-home
        elif [ ! -e "$H/config.yaml" ]; then
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
                        await self?.probeOnce()
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
                "Hermes hasn't been set up yet",
                "`\(hermesHome)/config.yaml` is missing. Run `hermes setup` (or your first `hermes chat`) on the remote to create it. Scarf will go green automatically once it appears."
            )
        case .configUnreadable:
            return (
                "Permission denied on config.yaml",
                "`\(hermesHome)/config.yaml` exists but the SSH user can't read it. Check ownership: `ls -l \(hermesHome)/config.yaml`. Either run Hermes as the SSH user, `chmod a+r` the file, or SSH as the Hermes user."
            )
        case .profileActive(let name):
            return (
                "Hermes profile \"\(name)\" is active",
                "The remote is using Hermes profile `\(name)` — its config lives at `~/.hermes/profiles/\(name)/config.yaml`, not `\(hermesHome)/config.yaml`. Either set this server's Hermes home to `~/.hermes/profiles/\(name)` in Manage Servers → Edit, or run `hermes profile use default` on the remote to revert."
            )
        case .unknown:
            return (
                "Can't read Hermes state",
                "SSH is fine but Scarf can't reach `\(hermesHome)/config.yaml`. Run diagnostics for a full breakdown."
            )
        }
    }
}
