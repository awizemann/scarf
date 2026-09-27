import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Hermes v0.21.5 audit remediation, phase R03 — the app-target halves.

@Suite struct AuxiliaryTaskRowsR03Tests {
    private func keys(_ line: String?) -> [String] {
        AuxiliaryTab.tasks(capabilities: line.map(HermesCapabilities.parseLine)).map { $0.key }
    }

    /// S05-F1: Hermes stopped reading `auxiliary.session_search.*` at
    /// v2026.5.28 (0.15.0), so the row must be gone from then on.
    @Test func sessionSearchIsHiddenOnCurrentHosts() {
        let current = keys("Hermes Agent v0.21.5 (2026.9.24)")
        #expect(!current.contains("session_search"))
        #expect(current == ["vision", "compression", "skills_hub", "approval", "mcp", "curator"])
    }

    /// Older hosts render the rows they always did, in the historical order.
    @Test func olderHostsKeepTheirRowsAndOrder() {
        #expect(keys("Hermes Agent v0.14.0 (2026.5.16)") == [
            "vision", "web_extract", "compression", "session_search",
            "skills_hub", "approval", "mcp", "curator",
        ])
        #expect(keys("Hermes Agent v0.15.0 (2026.5.28)") == [
            "vision", "web_extract", "compression",
            "skills_hub", "approval", "mcp", "curator",
        ])
        #expect(keys("Hermes Agent v0.11.0 (2026.4.23)") == [
            "vision", "web_extract", "compression", "session_search",
            "skills_hub", "approval", "mcp", "flush_memories",
        ])
    }

    @Test func unprobedHostShowsTheBaseRowsOnly() {
        #expect(keys(nil) == ["vision", "compression", "skills_hub", "approval", "mcp"])
    }
}

@Suite struct OAuthURLDetectionR03Tests {
    /// S06-F6: OpenRouter's PKCE URL has no client_id, /authorize or /oauth/.
    /// Output shape from `hermes_cli/auth_openrouter.py:77-79` @ v2026.9.24.
    @Test func detectsOpenRouterLoopbackURL() {
        let text = """
        Open this URL to authorize Hermes with OpenRouter:
          https://openrouter.ai/auth?callback_url=http%3A%2F%2F127.0.0.1%3A53121%2Fcallback%2Fabc&code_challenge=XyZ_123&code_challenge_method=S256

        Docs: https://openrouter.ai/docs/guides/overview/auth/oauth
        """
        #expect(OAuthFlowController.extractAuthURL(from: text)
                == "https://openrouter.ai/auth?callback_url=http%3A%2F%2F127.0.0.1%3A53121%2Fcallback%2Fabc&code_challenge=XyZ_123&code_challenge_method=S256")
    }

    /// The headless variant (`auth_openrouter.py:60-64`) omits callback_url.
    @Test func detectsOpenRouterHeadlessURL() {
        let text = """
        Remote session detected — using OpenRouter's headless flow.
        Open this URL in a browser on any machine, authorize, then paste the code shown:
          https://openrouter.ai/auth?code_challenge=abc&code_challenge_method=S256

        Authorization code:
        """
        #expect(OAuthFlowController.extractAuthURL(from: text)
                == "https://openrouter.ai/auth?code_challenge=abc&code_challenge_method=S256")
    }

    @Test func docsURLAloneIsNotAnAuthURL() {
        #expect(OAuthFlowController.extractAuthURL(
            from: "Docs: https://openrouter.ai/docs/guides/overview/auth/oauth") == nil)
    }

    @Test func clientIDURLStillWinsOverAPKCEOnlyOne() {
        let text = """
        https://example.test/auth?code_challenge=a
        https://claude.ai/oauth/authorize?code=true&client_id=abc&code_challenge=b
        """
        #expect(OAuthFlowController.extractAuthURL(from: text)
                == "https://claude.ai/oauth/authorize?code=true&client_id=abc&code_challenge=b")
    }
}
