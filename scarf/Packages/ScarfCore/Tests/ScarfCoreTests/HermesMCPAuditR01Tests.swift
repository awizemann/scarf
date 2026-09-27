import Testing
import Foundation
@testable import ScarfCore

/// Hermes v0.21.5 audit, phase R01 (MCP): the ScarfCore halves of S09-F2
/// (`mcp install` verdict + the OAuth capability floor), S09-F3 (timeouts as
/// floats) and S09-F6 (the `mcp test` kill budget).
@Suite struct HermesMCPAuditR01Tests {

    // MARK: S09-F2 — `hermes mcp install <id>` verdict

    /// Captured from the real CLI (`hermes mcp install -- linear` against a
    /// scratch HERMES_HOME, v2026.9.24, stdin = /dev/null). The OAuth probe
    /// fails without a TTY and the install still completes.
    static let installedOutput = """
      Installing MCP 'linear'
      Find, create, and update Linear issues, projects, and comments.
      Source: https://linear.app/docs/mcp

      This MCP uses native OAuth 2.1; tokens will be acquired on first connection (browser flow).

      Probing 'linear' for available tools...
      Probe failed: MCP server 'linear' requires HTTP transport but mcp.client.streamable_http is not available.
      Couldn't probe server; installed with no tool filter (all tools enabled when reachable). Run `hermes mcp configure linear` after first connect to prune.

      ✓ Installed 'linear' (enabled). Start a new Hermes session to load its tools.

      On first connection, Hermes will open a browser to authenticate with Linear.
    """

    @Test func installArgvEndsOptionsBeforeTheIdentifier() {
        #expect(HermesMCPInstallVerdict.argv(identifier: "linear") == ["mcp", "install", "--", "linear"])
    }

    @Test func installSuccessIsTheInstalledLineForThisIdentifier() {
        #expect(HermesMCPInstallVerdict.judge(
            output: Self.installedOutput, exitCode: 0, identifier: "linear") == .installed)
        // Another entry's success line proves nothing about this one.
        #expect(HermesMCPInstallVerdict.judge(
            output: Self.installedOutput, exitCode: 0, identifier: "asana") != .installed)
    }

    @Test func notInCatalogIsReportedSoTheCallerCanFallBack() {
        // Verbatim, v2026.9.24, exit 1.
        let output = "  ✗ 'no-such-entry-xyz' is not in the catalog. Run `hermes mcp catalog` to see available entries.\n"
        #expect(HermesMCPInstallVerdict.judge(
            output: output, exitCode: 1, identifier: "no-such-entry-xyz") == .notInCatalog)
        // Before v2026.9.7 the dispatcher dropped the return code: exit 0.
        #expect(HermesMCPInstallVerdict.judge(
            output: output, exitCode: 0, identifier: "no-such-entry-xyz") == .notInCatalog)
    }

    @Test func installFailedIsAFailureNotAFallback() {
        let output = "  Installing MCP 'x'\n  ✗ install failed: catalog entry 'x' rejected: suspicious command/args configuration\n"
        guard case .failed(let detail) = HermesMCPInstallVerdict.judge(
            output: output, exitCode: 1, identifier: "x") else {
            Issue.record("expected .failed"); return
        }
        #expect(detail?.contains("install failed") == true)
    }

    @Test func managedRefusalBeatsTheSuccessLineItPrintsAnyway() {
        // `install_entry` does not see `save_config`'s managed refusal and
        // prints its success line regardless.
        let output = "  Cannot save configuration: this install is managed.\n  ✓ Installed 'linear' (enabled).\n"
        if case .installed = HermesMCPInstallVerdict.judge(output: output, exitCode: 0, identifier: "linear") {
            Issue.record("a managed refusal must not read as installed")
        }
    }

    @Test func silentExitZeroIsUnconfirmedNeverInstalled() {
        #expect(HermesMCPInstallVerdict.judge(output: "", exitCode: 0, identifier: "linear")
            == .unconfirmed(nil))
    }

    @Test func oauthDirectWriteFloorIsV017() {
        #expect(!HermesCapabilities.parseLine("Hermes Agent v0.16.0 (2026.6.5)").hasMCPOAuthAddNeedsDirectWrite)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.17.0 (2026.6.19)").hasMCPOAuthAddNeedsDirectWrite)
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)").hasMCPOAuthAddNeedsDirectWrite)
        #expect(!HermesCapabilities.empty.hasMCPOAuthAddNeedsDirectWrite)
    }

    // MARK: S09-F3 — float timeouts

    @Test func secondsFormatKeepsWholeNumbersIntegral() {
        #expect(HermesMCPServer.formatSeconds(45.0) == "45")
        #expect(HermesMCPServer.formatSeconds(90) == "90")
        #expect(HermesMCPServer.formatSeconds(45.5) == "45.5")
    }

    @Test func secondsParseRefusesWhatHermesCannotUse() {
        #expect(HermesMCPServer.parseSeconds(" 90 ") == 90)
        #expect(HermesMCPServer.parseSeconds("12.5") == 12.5)
        #expect(HermesMCPServer.parseSeconds("0") == nil)
        #expect(HermesMCPServer.parseSeconds("-3") == nil)
        #expect(HermesMCPServer.parseSeconds("inf") == nil)
        #expect(HermesMCPServer.parseSeconds("nan") == nil)
        #expect(HermesMCPServer.parseSeconds("abc") == nil)
        #expect(HermesMCPServer.parseSeconds("") == nil)
    }

    @Test func includeListIsExplicitByDefaultOnlyWhenNonEmpty() {
        func server(_ include: [String], explicit: Bool? = nil) -> HermesMCPServer {
            HermesMCPServer(
                name: "s", transport: .stdio, command: "x", args: [], url: nil, auth: nil,
                env: [:], headers: [:], timeout: nil, connectTimeout: nil, enabled: true,
                toolsInclude: include, toolsExclude: [], resourcesEnabled: true,
                promptsEnabled: true, hasOAuthToken: false, toolsIncludeIsExplicit: explicit
            )
        }
        #expect(server(["a"]).toolsIncludeIsExplicit)
        #expect(!server([]).toolsIncludeIsExplicit)
        #expect(server([], explicit: true).toolsIncludeIsExplicit)
    }

    // MARK: S09-F6 — `mcp test` kill budget

    @Test func testTimeoutCoversHermesOwnProbeBudget() {
        // Default connect_timeout 30 → Hermes allows 30 + 10 plus start-up.
        #expect(HermesMCPTestVerdict.timeout(connectTimeout: nil) == 50)
        #expect(HermesMCPTestVerdict.timeout(connectTimeout: 5) == 50)
        #expect(HermesMCPTestVerdict.timeout(connectTimeout: 90) == 110)
        #expect(HermesMCPTestVerdict.timeout(connectTimeout: .infinity) == 50)
        // Always strictly longer than Hermes's own `connect_timeout + 10`.
        for ct in [1.0, 30, 45.5, 60, 300] {
            #expect(HermesMCPTestVerdict.timeout(connectTimeout: ct) > max(1, ct) + 10)
        }
    }
}
