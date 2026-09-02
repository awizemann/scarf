import Testing
import Foundation
@testable import scarf

/// Fix package F5 — MANAGE sub-cluster (section audit 2026-09), app-level
/// halves: the `hermes mcp test` verdict and the gateway liveness verdict.
@Suite("SectionAuditF5ManageApp")
struct SectionAuditF5ManageAppTests {

    // MARK: - `hermes mcp test` verdict

    /// The false positive. A successful probe lists one line per discovered
    /// tool as `{name} {description}` — and a filesystem-ish server's
    /// descriptions legitimately contain the exact prose the old check
    /// treated as a failure marker ("Error:", "No such file or directory").
    /// Every REAL failure goes through `mcp_config.py::_error`, which prints
    /// `  ✗ …`, so the prose tests bought nothing and cost correct results.
    @Test func toolDescriptionsMentioningErrorsAreNotAFailure() {
        let output = """
          Testing 'files'...
            Transport: stdio → npx
            Auth: none
          ✓ Connected (412ms)
          ✓ Tools discovered: 2
            read_file                            Read a file; returns Error: ENOENT when missing
            list_dir                             Fails with No such file or directory on a bad path
        """
        #expect(HermesFileService.mcpTestReportsFailure(output) == false)
    }

    @Test func theCrossMarkIsStillTheFailureSignal() {
        let output = """
          Testing 'flaky'...
            Transport: HTTP → https://example.invalid/mcp
          ✗ Connection failed (5001ms): timed out
        """
        #expect(HermesFileService.mcpTestReportsFailure(output))
    }

    @Test func serverNotFoundIsAFailure() {
        #expect(HermesFileService.mcpTestReportsFailure("  ✗ Server 'nope' not found in config."))
    }

    // MARK: - Gateway liveness

    /// `gateway_state.json` is never rewritten on a crash or a failed start,
    /// so `state == "running"` outlives the process. The live probe wins.
    @Test func staleRunningStateLosesToTheLiveProbe() {
        #expect(MessagingGatewayViewModel.isGatewayRunning(
            state: "running",
            statusOutput: "✗ Gateway is not running\n"
        ) == false)
    }

    @Test func liveProbeCanAlsoOverrideAStaleStoppedState() {
        #expect(MessagingGatewayViewModel.isGatewayRunning(
            state: "stopped",
            statusOutput: "✓ Gateway is running (PID: 4242)\n  (Running manually, not as a system service)\n"
        ))
    }

    /// systemd/launchd/Windows branches print neither marker — there the
    /// stored state is all we have, and the old behaviour is preserved.
    @Test func serviceManagedOutputFallsBackToTheStoredState() {
        let launchd = "com.hermes.gateway is loaded\n"
        #expect(MessagingGatewayViewModel.isGatewayRunning(state: "running", statusOutput: launchd))
        #expect(MessagingGatewayViewModel.isGatewayRunning(state: "stopped", statusOutput: launchd) == false)
    }
}
