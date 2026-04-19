import Foundation
import os

/// Tracks connection health for the current window's server. Remote contexts
/// get a lightweight 15s heartbeat (a no-op `true` remote command) that
/// flips the status between green / yellow / red. Local contexts are always
/// green since there's no connection to lose.
@Observable
@MainActor
final class ConnectionStatusViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ConnectionStatus")

    enum Status: Equatable {
        /// Healthy: most recent probe succeeded.
        case connected
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

    let context: ServerContext
    private let transport: any ServerTransport
    private var probeTask: Task<Void, Never>?

    init(context: ServerContext) {
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
    func startMonitoring() {
        guard context.isRemote else { return }
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeOnce()
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s
            }
        }
    }

    func stopMonitoring() {
        probeTask?.cancel()
        probeTask = nil
    }

    /// Manual probe — also invoked by the toolbar "Retry" button on error.
    func retry() {
        Task { await probeOnce() }
    }

    private func probeOnce() async {
        let snapshot = transport
        let result: Result<Void, TransportError>
        // Transport IO on a detached task so we don't block MainActor.
        result = await Task.detached {
            do {
                let probe = try snapshot.runProcess(
                    executable: "/bin/sh",
                    args: ["-c", "true"],
                    stdin: nil,
                    timeout: 10
                )
                if probe.exitCode == 0 {
                    return .success(())
                }
                return .failure(.commandFailed(exitCode: probe.exitCode, stderr: probe.stderrString))
            } catch let e as TransportError {
                return .failure(e)
            } catch {
                return .failure(.other(message: error.localizedDescription))
            }
        }.value

        switch result {
        case .success:
            status = .connected
            lastSuccess = Date()
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
