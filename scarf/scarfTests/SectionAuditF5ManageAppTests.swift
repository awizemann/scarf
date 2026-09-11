import Testing
import Foundation
import ScarfCore
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
        #expect(HermesMCPTestVerdict.judge(output: output, exitCode: 0).succeeded)
    }

    @Test func aConnectionFailureIsStillTheFailureSignal() {
        let output = """
          Testing 'flaky'...
            Transport: HTTP → https://example.invalid/mcp
          ✗ Connection failed (5001ms): timed out
        """
        #expect(!HermesMCPTestVerdict.judge(output: output, exitCode: 0).succeeded)
    }

    @Test func serverNotFoundIsAFailure() {
        #expect(!HermesMCPTestVerdict.judge(
            output: "  ✗ Server 'nope' not found in config.", exitCode: 0
        ).succeeded)
    }

    // MARK: - `hermes mcp test` tool rows (P12)

    /// **Verbatim `hermes mcp test` success output**, reproduced from
    /// `cmd_mcp_test` (`hermes_cli/mcp_config.py:583-620` at `v2026.9.7`)
    /// with `color()` a no-op — which is what it is for Scarf, since
    /// `hermes_cli/colors.py::should_use_color()` is `sys.stdout.isatty()`
    /// and Scarf always pipes. Tool rows are `_print_tools`'s
    /// `    {name:36s} {desc[:55]}...` (`:49-52`), called with width 36 and
    /// desc_max 55 (`:619`).
    ///
    /// Note the `    X-Api-Key: …` line ABOVE the count: the masked-header
    /// arm at `:605` is also four-space-indented, which is why the parser
    /// anchors on `Tools discovered: N` rather than on indentation alone.
    static let mcpTestSuccessFixture = """

      Testing 'files'...
      Transport: stdio → npx
        X-Api-Key: sk-1***cdef
      ✓ Connected (412ms)
      ✓ Tools discovered: 3

        read_file                            Read a file from disk; returns Error: ENOENT when the p...
        write_text_file                      Write UTF-8 text to a path
        list_dir                             List a directory

    """

    /// Fails without the fix: the old parser looked for `- ` / `* ` bullets,
    /// which Hermes has never printed, so the tool chips were empty on every
    /// host and for every server.
    @Test func toolRowsAreParsedFromTheIndentedBlockUnderTheCount() {
        #expect(HermesFileService.parseToolListFromTestOutput(Self.mcpTestSuccessFixture)
            == ["read_file", "write_text_file", "list_dir"])
    }

    /// The masked-header line is four-space-indented too, but it sits ABOVE
    /// the count — a header value must never be surfaced as a tool name.
    @Test func maskedAuthHeaderIsNotMistakenForATool() {
        let tools = HermesFileService.parseToolListFromTestOutput(Self.mcpTestSuccessFixture)
        #expect(!tools.contains { $0.lowercased().contains("api") })
        #expect(!tools.contains("X-Api-Key"))
    }

    /// A server with no tools reports the count and prints no block; the
    /// parser must return nothing rather than reach for the next line.
    @Test func zeroToolsDiscoveredParsesToNoTools() {
        let output = """
          ✓ Connected (88ms)
          ✓ Tools discovered: 0

        """
        #expect(HermesFileService.parseToolListFromTestOutput(output).isEmpty)
    }

    /// The count bounds the block: a wrapped description line cannot add a
    /// phantom tool beyond N.
    @Test func theDiscoveredCountBoundsTheBlock() {
        let output = """
          ✓ Tools discovered: 1

            read_file                            Read a file
            phantom_wrap                         continuation-looking line
        """
        #expect(HermesFileService.parseToolListFromTestOutput(output) == ["read_file"])
    }

    /// A failed probe never prints the count, so nothing is parsed.
    @Test func failedProbeYieldsNoTools() {
        let output = """
          Testing 'flaky'...
          ✗ Connection failed (5001ms): timed out
        """
        #expect(HermesFileService.parseToolListFromTestOutput(output).isEmpty)
    }

    /// `color()` is a no-op on a pipe, but if a host ever hands Scarf a TTY
    /// (or a wrapper injects colour) the names must still come through.
    @Test func ansiColouredToolRowsStillParse() {
        let esc = "\u{1B}"
        let output = """
          \(esc)[32m✓\(esc)[0m Tools discovered: 2

            \(esc)[32mread_file\(esc)[0m                    Read a file
            \(esc)[32mlist_dir\(esc)[0m                     List a directory
        """
        #expect(HermesFileService.parseToolListFromTestOutput(output) == ["read_file", "list_dir"])
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
