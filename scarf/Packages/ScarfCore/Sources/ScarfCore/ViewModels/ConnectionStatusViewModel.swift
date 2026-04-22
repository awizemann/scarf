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
        /// views will be empty until this is resolved. `reason` is shown
        /// in the pill tooltip; users click the pill to open diagnostics.
        case degraded(reason: String)
        /// No probe yet or the previous probe timed out but we haven't
        /// confirmed failure. Shown as yellow to tell the user "checking…".
        case idle
        /// Last probe failed. `message` is a terse human summary; `stderr`
        /// is the raw diagnostic text for a disclosure panel.
        case error(message: String, stderr: String)
    }

    private(set) var status: Status = .idle
    /// Timestamp of the last successful probe. Used by the UI to show how
    /// fresh the status indicator is ("just now", "2m ago"…).
    private(set) var lastSuccess: Date?
    /// Number of consecutive probe failures. Surfaced as a yellow "Reconnecting…"
    /// state for the first failure (silent retry), then promoted to red after
    /// `consecutiveFailureThreshold` failures so flaky connections don't
    /// flap the indicator on every dropped packet.
    private(set) var consecutiveFailures = 0
    private let consecutiveFailureThreshold = 2

    public let context: ServerContext
    private let transport: any ServerTransport
    private var probeTask: Task<Void, Never>?

    public init(context: ServerContext) {
        self.context = context
        self.transport = context.makeTransport()
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
        let snapshot = transport
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
        let script = """
        echo TIER1:0
        H=\(homeArg)
        if [ -r "$H/config.yaml" ]; then echo TIER2:0; else echo TIER2:1; fi
        """

        enum ProbeOutcome {
            case connected
            case degraded(reason: String)
            case failure(TransportError)
        }

        let outcome: ProbeOutcome = await Task.detached {
            do {
                let probe = try snapshot.runProcess(
                    executable: "/bin/sh",
                    args: ["-c", script],
                    stdin: nil,
                    timeout: 10
                )
                guard probe.exitCode == 0 else {
                    return .failure(.commandFailed(exitCode: probe.exitCode, stderr: probe.stderrString))
                }
                let out = probe.stdoutString
                let tier1 = out.contains("TIER1:0")
                let tier2 = out.contains("TIER2:0")
                if !tier1 {
                    // The script itself didn't reach tier 1 — treat as connection failure.
                    return .failure(.commandFailed(exitCode: 1, stderr: out))
                }
                if tier2 {
                    return .connected
                }
                // Connected but can't read config.yaml — the core issue #19
                // symptom. Give the pill a short reason; the full story goes
                // into Remote Diagnostics.
                return .degraded(reason: "can't read ~/.hermes/config.yaml")
            } catch let e as TransportError {
                return .failure(e)
            } catch {
                return .failure(.other(message: error.localizedDescription))
            }
        }.value

        switch outcome {
        case .connected:
            status = .connected
            lastSuccess = Date()
            consecutiveFailures = 0
        case .degraded(let reason):
            status = .degraded(reason: reason)
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
}
