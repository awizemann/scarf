import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Hermes v0.21.1 `oauth.flow` (`hermes_cli/mcp_config.py:639-641`) and the
/// device-code prompt (`tools/mcp_oauth_device.py::_authorize`).
///
/// The property that matters most here is NOT that the flow round-trips —
/// it's that writing it leaves the rest of the `oauth:` block alone. That
/// block holds `client_id` and `client_secret`, which the user cannot
/// recover if a block-style writer rebuilds the mapping from Scarf's model.
struct HermesMCPOAuthFlowTests {

    private static let fixtureYAML = """
    mcp_servers:
      gated_api:
        url: https://gated.example.com/mcp
        auth: oauth
        oauth:
          client_id: "abc123"
          client_secret: "s3cr3t"
          scope: "read write"
        timeout: 180
        enabled: true
      no_oauth_block:
        url: https://plain.example.com/mcp
        auth: oauth
        timeout: 60
        enabled: true
    """

    private func loadFixture() throws -> (service: HermesFileService, home: TempHermesHome) {
        let home = try TempHermesHome()
        try Self.fixtureYAML.write(
            toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        return (HermesFileService(context: home.context), home)
    }

    @Test func readerParsesOAuthFlowAndDefaultsToNil() throws {
        let (service, home) = try loadFixture()
        defer { home.cleanup() }
        let servers = service.loadMCPServers()
        // The fixture declares no `flow:`, so both read as nil — which is how
        // "Hermes's own default (browser)" is expressed, distinct from an
        // explicit `browser`.
        #expect(servers.first(where: { $0.name == "gated_api" })?.oauthFlow == nil)
        #expect(servers.first(where: { $0.name == "no_oauth_block" })?.oauthFlow == nil)
    }

    @Test func writingFlowPreservesTheRestOfTheOAuthBlock() throws {
        let (service, home) = try loadFixture()
        defer { home.cleanup() }
        #expect(service.setMCPServerOAuthFlow(name: "gated_api", flow: "device"))

        let written = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        // THE assertion: the user's credentials are still there verbatim.
        #expect(written.contains("client_id: \"abc123\""))
        #expect(written.contains("client_secret: \"s3cr3t\""))
        #expect(written.contains("scope: \"read write\""))
        #expect(written.contains("flow: device"))
        // Siblings outside the block, and the OTHER server, are untouched.
        #expect(written.contains("timeout: 180"))
        #expect(written.contains("no_oauth_block:"))

        let reloaded = service.loadMCPServers()
        #expect(reloaded.first(where: { $0.name == "gated_api" })?.oauthFlow == "device")
        #expect(reloaded.first(where: { $0.name == "no_oauth_block" })?.oauthFlow == nil)
    }

    @Test func writingFlowCreatesTheBlockWhenAbsentAndClearingRemovesIt() throws {
        let (service, home) = try loadFixture()
        defer { home.cleanup() }
        #expect(service.setMCPServerOAuthFlow(name: "no_oauth_block", flow: "browser"))
        #expect(service.loadMCPServers()
                    .first(where: { $0.name == "no_oauth_block" })?.oauthFlow == "browser")

        // Clearing the only child drops the whole `oauth:` header too: an
        // emptied mapping is a YAML null, which is not the same as absent.
        #expect(service.setMCPServerOAuthFlow(name: "no_oauth_block", flow: nil))
        let written = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        #expect(!written.contains("flow: browser"))
        let reloaded = service.loadMCPServers()
        #expect(reloaded.first(where: { $0.name == "no_oauth_block" })?.oauthFlow == nil)
        // The other server's real oauth block is untouched by any of this.
        #expect(written.contains("client_secret: \"s3cr3t\""))
    }

    /// M4 — an INLINE FLOW `oauth: {…}` is legal YAML and PyYAML reads it
    /// exactly like the block form, but the patcher only ever matched a bare
    /// `oauth:` header. It used to miss this shape and INSERT a second
    /// `oauth:` block; PyYAML keeps the last duplicate key, so the user's
    /// client_id/secret would stop existing as far as Hermes is concerned —
    /// without one byte of them being deleted from the file. Refuse instead.
    @Test func writingFlowRefusesAnInlineFlowOAuthMappingAndChangesNothing() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let yaml = """
        mcp_servers:
          inline_api:
            url: https://inline.example.com/mcp
            auth: oauth
            oauth: {client_id: "abc123", client_secret: "s3cr3t"}
            enabled: true
        """
        try yaml.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let service = HermesFileService(context: home.context)

        #expect(!service.setMCPServerOAuthFlow(name: "inline_api", flow: "device"))
        let written = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        // No second header, no lost credentials, no `flow:` anywhere.
        #expect(written.components(separatedBy: "oauth:").count - 1 == 1)
        #expect(written.contains("client_secret: \"s3cr3t\""))
        #expect(!written.contains("flow:"))
    }

    /// …but a header with only a trailing COMMENT after the colon is still
    /// an ordinary block, and must not be refused.
    @Test func writingFlowAcceptsAHeaderWithATrailingComment() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let yaml = """
        mcp_servers:
          noted_api:
            url: https://noted.example.com/mcp
            auth: oauth
            oauth:  # set up 2026-08
              client_id: "abc123"
            enabled: true
        """
        try yaml.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        let service = HermesFileService(context: home.context)
        #expect(service.setMCPServerOAuthFlow(name: "noted_api", flow: "device"))
        let written = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        #expect(written.contains("flow: device"))
        #expect(written.contains("client_id: \"abc123\""))
        #expect(written.components(separatedBy: "oauth:").count - 1 == 1)
    }

    /// Drift alarm. This is the byte-exact block Hermes prints on the device
    /// branch, from `tools/mcp_oauth_device.py::_authorize` at v2026.9.7:
    ///
    ///     print(f"\n  MCP OAuth: open {verification} on any device.\n"
    ///           f"  Code: {authorization['user_code']}\n"
    ///           "  Waiting for approval...\n", file=sys.stderr, flush=True)
    ///
    /// If Hermes rewords it, this fails rather than Scarf showing a spinner.
    @Test func devicePromptParsesTheVerbatimHermesOutput() {
        let verbatim = """

          MCP OAuth: open https://github.com/login/device on any device.
          Code: WDJB-MJHT
          Waiting for approval...

        """
        let prompt = HermesMCPDevicePrompt.parse(verbatim)
        #expect(prompt?.verificationURL == "https://github.com/login/device")
        #expect(prompt?.userCode == "WDJB-MJHT")
    }

    @Test func devicePromptIsNilUntilBothLinesArrive() {
        // Streamed output: the URL can land in one read and the code in the
        // next. A half-built prompt would render a code-less card.
        #expect(HermesMCPDevicePrompt.parse("\n  MCP OAuth: open https://x.test/d on any device.\n") == nil)
        #expect(HermesMCPDevicePrompt.parse("  Code: ABCD-1234\n") == nil)
        // Unrelated CLI chatter parses to nothing rather than to a guess.
        #expect(HermesMCPDevicePrompt.parse("Starting OAuth flow for 'gated_api'...") == nil)
        // A non-http token in the URL slot is refused, not surfaced.
        #expect(HermesMCPDevicePrompt.parse("""
          MCP OAuth: open <unavailable> on any device.
          Code: ABCD
        """) == nil)
    }
}
