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
          Waiting for approval...

        """) == nil)
    }

    /// **A chunk boundary inside the `Code:` line must not latch a truncated
    /// code.** `availableData` splits on a byte count, so the pane can hold
    /// `…\n  Code: WDJB-MJ` with no newline after it — and `WDJB-MJ` is a
    /// perfectly non-empty string. The old parser returned it, the sheet
    /// showed it, and `MCPLoginController` never re-parsed because it only
    /// re-parses while `devicePrompt == nil`. The user then types a code that
    /// cannot work, with nothing on screen saying so.
    ///
    /// Fails without the fix: the first three expectations returned a prompt
    /// carrying a truncated code or a code with no sentinel behind it.
    @Test func devicePromptRefusesAnUnterminatedCodeLine() {
        let head = "\n  MCP OAuth: open https://github.com/login/device on any device.\n"
        // Mid-code, no newline yet.
        #expect(HermesMCPDevicePrompt.parse(head + "  Code: WDJB-MJ") == nil)
        // The code line is complete, but the block is not: Hermes writes all
        // three lines in ONE print, so until the sentinel lands the buffer is
        // still mid-write.
        #expect(HermesMCPDevicePrompt.parse(head + "  Code: WDJB-MJHT\n") == nil)
        // Sentinel line itself still unterminated.
        #expect(HermesMCPDevicePrompt.parse(
            head + "  Code: WDJB-MJHT\n  Waiting for approv") == nil)
        // Complete block — now, and only now, a prompt.
        let done = HermesMCPDevicePrompt.parse(
            head + "  Code: WDJB-MJHT\n  Waiting for approval...\n")
        #expect(done?.userCode == "WDJB-MJHT")
        #expect(done?.verificationURL == "https://github.com/login/device")
    }

    /// Re-parsing chunk by chunk, exactly as `MCPLoginController.append`
    /// does, must yield the WHOLE code and never an intermediate value.
    @Test func devicePromptSurvivesByteWiseAccumulation() {
        let block = """

          MCP OAuth: open https://github.com/login/device on any device.
          Code: WDJB-MJHT
          Waiting for approval...

        """
        var accumulated = ""
        var seen: [HermesMCPDevicePrompt] = []
        for character in block {
            accumulated.append(character)
            if let prompt = HermesMCPDevicePrompt.parse(accumulated) {
                seen.append(prompt)
            }
        }
        #expect(!seen.isEmpty)
        // Every prompt the accumulation ever produced is the correct one.
        #expect(seen.allSatisfy { $0.userCode == "WDJB-MJHT" })
        #expect(seen.allSatisfy { $0.verificationURL == "https://github.com/login/device" })
    }

    /// A remote `stop()` reaps by `pkill -f <pattern>`; the pattern embeds a
    /// user-chosen server name, so every ERE metacharacter in it must be
    /// escaped or the pattern widens to processes Scarf has no business
    /// signalling.
    @Test func remoteReapPatternEscapesRegexMetacharacters() {
        #expect(MCPLoginController.regexEscaped("my.server") == "my\\.server")
        #expect(MCPLoginController.regexEscaped("a|b") == "a\\|b")
        #expect(MCPLoginController.regexEscaped("x(1)*") == "x\\(1\\)\\*")
        #expect(MCPLoginController.regexEscaped("plain-name") == "plain-name")
    }
}
