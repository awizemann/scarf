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
    /// so when it says "✗ Gateway is not running"
    /// (`hermes_cli/gateway.py:6133` @ `v2026.9.7`) the
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

    // MARK: - v0.21.1: the default-profile multiplexer branch (A6)

    /// Verbatim from `_cmd_status`'s FIRST branch
    /// (`hermes_cli/gateway.py:6112-6115` at tag `v2026.9.7`): a satellite
    /// profile whose own snapshot says "not running" but which
    /// `named_profile_served_by_running_multiplexer()` reports as served.
    /// Note it prints NO PID — the pid belongs to the default profile.
    private static let multiplexerStatus = """
    ✓ Gateway is running via the default-profile multiplexer
      Manage it from the default profile: hermes gateway status

    Other profiles:
      ✓ default          — PID 44417
    """

    @Test func multiplexedProfileIsRunning() {
        // The branch reuses the `✓ Gateway is running` prefix, so liveness
        // was already right; pinned so a future prefix change is caught.
        #expect(MessagingGatewayViewModel.isGatewayRunning(
            state: "stopped", statusOutput: Self.multiplexerStatus) == true)
    }

    /// The A6 bug: `isServiceLoaded` fell through to `pid != nil`, and the
    /// satellite's `gateway_state.json` has no live pid of its own — so a
    /// profile that IS being served was badged "not loaded".
    @Test func multiplexedProfileIsLoadedWithoutAPIDOfItsOwn() {
        #expect(MessagingGatewayViewModel.isServiceLoaded(
            pid: nil, statusOutput: Self.multiplexerStatus) == true)
        #expect(MessagingGatewayViewModel.isServedByMultiplexer(
            statusOutput: Self.multiplexerStatus) == true)
    }

    /// The multiplexer test must not fire on any pre-v0.21.1 output — that
    /// is what keeps a pre-target host byte-identical.
    @Test func preTargetOutputsAreNeverReadAsMultiplexed() {
        for output in [
            "✓ Gateway is running (PID: 4821)\n  (Running manually, not as a system service)\n",
            "✗ Gateway is not running\n",
            "✓ User gateway service is running\n",
            "",
        ] {
            #expect(MessagingGatewayViewModel.isServedByMultiplexer(statusOutput: output) == false)
        }
    }

    /// `✗ Gateway is not running` still wins: the two branches are mutually
    /// exclusive in Hermes, but the ordering is load-bearing if a future
    /// release ever prints both, and "dead" must never lose to "served".
    @Test func notRunningStillBeatsTheMultiplexerMarker() {
        let contradictory = """
        ✗ Gateway is not running
        ✓ Gateway is running via the default-profile multiplexer
        """
        #expect(MessagingGatewayViewModel.isServiceLoaded(
            pid: nil, statusOutput: contradictory) == false)
    }

    // MARK: - The old bug, regression-pinned

    /// The retired check looked for `service is loaded`, a string that
    /// appears nowhere in real `gateway status` output — it existed only as
    /// a comment in gateway.py. So it answered "not loaded" for a gateway
    /// that was plainly running. Assert the CURRENT function on that output
    /// rather than the absence of a substring: the old form passed with
    /// `isServiceLoaded` deleted outright.
    @Test func serviceLoadednessIsDecidedByTheRealMarkers() {
        // Manually run: a live PID, but explicitly NOT a service.
        let manualOutput = "✓ Gateway is running (PID: 4821)\n  (Running manually, not as a system service)\n"
        #expect(MessagingGatewayViewModel.isServiceLoaded(
            pid: 4821, statusOutput: manualOutput) == false)
        // Service-managed: no manual marker, and a PID ⇒ loaded.
        #expect(MessagingGatewayViewModel.isServiceLoaded(
            pid: 4821, statusOutput: "✓ Gateway is running (PID: 4821)\n") == true)
        // …and the retired marker really is absent from real output, which
        // is why the check it drove could only ever answer "no".
        #expect(manualOutput.contains("service is loaded") == false)
    }
}
