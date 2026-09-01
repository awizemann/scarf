import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Invariants around `MessagingGatewayViewModel`'s `hermes gateway status`
/// parsing (Hermes v0.21.0 parity work, W2). The pre-existing bug:
/// `contains("service is loaded")` never matched — that literal string
/// exists only as a code comment in `gateway.py`, never in printed output —
/// and `contains("stale")` matched by accident. Re-anchored on the real
/// printed markers from `hermes_cli/gateway.py`'s `status` subcommand,
/// verified present unchanged at v0.20.5 (v2026.8.19) and v0.21.0
/// (v2026.8.31).
@Suite struct GatewayViewModelTests {

    // MARK: - isServiceLoaded(pid:statusOutput:)

    @Test func manuallyRunningGatewayIsNotLoaded() {
        let output = """
        ✓ Gateway is running (PID: 4821)
          (Running manually, not as a system service)

        To install as a service:
          hermes gateway install
          sudo hermes gateway install --system
        """
        #expect(MessagingGatewayViewModel.isServiceLoaded(pid: 4821, statusOutput: output) == false)
    }

    @Test func notRunningGatewayIsNotLoaded() {
        let output = """
        ✗ Gateway is not running

        To start:
          hermes gateway run      # Run in foreground
          hermes gateway install  # Install as user service
        """
        #expect(MessagingGatewayViewModel.isServiceLoaded(pid: nil, statusOutput: output) == false)
    }

    @Test func serviceManagedRunningGatewayIsLoaded() {
        // Neither systemd_status nor launchd_status ever print "(Running
        // manually, not as a system service)" — only the bare-process
        // branch does. A running gateway (known PID) with that phrase
        // absent must read as service-managed.
        let output = """
        ✓ User gateway service is running
        Configured to run as: alan
        ✓ Systemd linger is enabled (service survives logout)
        """
        #expect(MessagingGatewayViewModel.isServiceLoaded(pid: 4821, statusOutput: output) == true)
    }

    @Test func launchdSupervisedGatewayIsLoaded() {
        let output = """
        Launchd plist: /Users/alan/Library/LaunchAgents/com.hermes.gateway.plist
        ✓ Service definition matches the current Hermes install
        ✓ Gateway is supervised by launchd (PID 4821)
          Auto-start at login and auto-restart on crash are available.
        """
        #expect(MessagingGatewayViewModel.isServiceLoaded(pid: 4821, statusOutput: output) == true)
    }

    /// The pid in `gateway_state.json` is a *last-written* value, not a
    /// liveness signal: a crash or `kill -9` leaves it behind because
    /// nothing rewrites the file on an unclean exit. `hermes gateway
    /// status` derives its answer from `get_gateway_runtime_snapshot()`,
    /// so when it says "✗ Gateway is not running" (gateway.py:8958) the
    /// stale pid must lose — otherwise Scarf badges a dead gateway
    /// "Loaded" and the user has no reason to restart it.
    @Test func aStalePIDLosesToNotRunningStatusOutput() {
        let output = """
        ✗ Gateway is not running

        To start:
          hermes gateway run      # Run in foreground
          hermes gateway install  # Install as user service
        """
        #expect(MessagingGatewayViewModel.isServiceLoaded(pid: 4821, statusOutput: output) == false)
        // …and the same output with no pid at all, unchanged.
        #expect(MessagingGatewayViewModel.isServiceLoaded(pid: nil, statusOutput: output) == false)
    }

    @Test func withoutAKnownPIDNeverReadsAsLoaded() {
        // Service-managed branches print neither marker, so the pid is the
        // only liveness signal there — and its absence still means "not
        // loaded".
        #expect(MessagingGatewayViewModel.isServiceLoaded(pid: nil, statusOutput: "✓ Gateway service is running") == false)
    }

    // MARK: - The old bug, regression-pinned

    @Test func theRetiredCheckWouldNeverHaveMatchedRealOutput() {
        let manualOutput = "✓ Gateway is running (PID: 4821)\n  (Running manually, not as a system service)\n"
        // "service is loaded" is a substring nowhere in real `gateway
        // status` output — it only ever existed as a code comment in
        // gateway.py, never a printed line.
        #expect(manualOutput.contains("service is loaded") == false)
    }
}
