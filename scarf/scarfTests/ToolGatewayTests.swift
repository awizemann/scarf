import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Invariants around Hermes v0.10.0 Tool Gateway integration:
/// overlay-provider merge, Nous Portal subscription detection, and
/// `platform_toolsets` YAML parsing.
@Suite struct ToolGatewayTests {

    // MARK: - Fixtures

    /// Minimal models.dev cache with exactly two providers so the overlay
    /// merge is easy to reason about — none of them are overlays.
    private func writeCacheFixture() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("models_dev_cache.json").path
        let json = """
        {
          "anthropic": {
            "name": "Anthropic",
            "models": {
              "claude-sonnet-4-5-20250929": { "name": "Claude Sonnet 4.5" }
            }
          },
          "openai": {
            "name": "OpenAI",
            "models": {
              "gpt-4o": { "name": "GPT-4o" }
            }
          }
        }
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func writeAuthFixture(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scarf-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("auth.json").path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - ModelCatalogService overlay merge

    @Test func overlayOnlyProvidersAppearInPicker() throws {
        let path = try writeCacheFixture()
        let service = ModelCatalogService(path: path)
        let providers = service.loadProviders()

        let ids = providers.map(\.providerID)
        #expect(ids.contains("nous"), "Nous Portal must appear after overlay merge")
        #expect(ids.contains("openai-codex"), "OpenAI Codex overlay must appear")
        #expect(ids.contains("qwen-oauth"), "Qwen OAuth overlay must appear")
        // v0.12 additions — IDs must match HERMES_OVERLAYS in
        // hermes-agent/hermes_cli/providers.py exactly. Drift here
        // means the picker can't reach the new providers.
        #expect(ids.contains("gmi"), "GMI Cloud overlay must appear (v0.12)")
        #expect(ids.contains("azure-foundry"), "Azure AI Foundry overlay must appear (v0.12)")
        #expect(ids.contains("lmstudio"), "LM Studio overlay must appear (v0.12)")
        #expect(ids.contains("minimax-oauth"), "MiniMax OAuth overlay must appear (v0.12)")
        #expect(ids.contains("tencent-tokenhub"), "Tencent TokenHub overlay must appear (v0.12)")
        // Cached providers still present.
        #expect(ids.contains("anthropic"))
        #expect(ids.contains("openai"))
    }

    @Test func v012OverlayProvidersCarryCorrectAuthTypes() throws {
        // The auth-type drives whether Settings shows an API-key field,
        // an OAuth flow, or external-process wiring. Locking the v0.12
        // additions here so a typo doesn't quietly land users in the
        // wrong setup flow.
        let overlays = ModelCatalogService.overlayOnlyProviders
        #expect(overlays["gmi"]?.authType == .apiKey)
        #expect(overlays["azure-foundry"]?.authType == .apiKey)
        #expect(overlays["lmstudio"]?.authType == .apiKey)
        #expect(overlays["minimax-oauth"]?.authType == .oauthExternal)
        #expect(overlays["tencent-tokenhub"]?.authType == .apiKey)
        // None of the v0.12 additions are subscription-gated (only Nous
        // Portal is).
        for id in ["gmi", "azure-foundry", "lmstudio", "minimax-oauth", "tencent-tokenhub"] {
            #expect(overlays[id]?.subscriptionGated == false, "\(id) shouldn't be subscription-gated")
        }
    }

    @Test func nousPortalSortsFirst() throws {
        let path = try writeCacheFixture()
        let service = ModelCatalogService(path: path)
        let providers = service.loadProviders()
        #expect(providers.first?.providerID == "nous",
                "Subscription-gated providers must sort before the alphabetical block")
    }

    @Test func overlayProvidersCarryMetadata() throws {
        let path = try writeCacheFixture()
        let service = ModelCatalogService(path: path)
        let providers = service.loadProviders()

        let nous = providers.first { $0.providerID == "nous" }
        #expect(nous?.isOverlay == true)
        #expect(nous?.subscriptionGated == true)
        #expect(nous?.providerName == "Nous Portal")
        #expect(nous?.modelCount == 0, "Overlay-only providers have no models in the cache")

        let codex = providers.first { $0.providerID == "openai-codex" }
        #expect(codex?.isOverlay == true)
        #expect(codex?.subscriptionGated == false,
                "Only Nous is subscription-gated today")
    }

    @Test func cachedProvidersAreNotMarkedOverlay() throws {
        let path = try writeCacheFixture()
        let service = ModelCatalogService(path: path)
        let providers = service.loadProviders()

        let anthropic = providers.first { $0.providerID == "anthropic" }
        #expect(anthropic?.isOverlay == false)
        #expect(anthropic?.subscriptionGated == false)
    }

    @Test func providerByIDReturnsOverlayWhenCacheMisses() throws {
        let path = try writeCacheFixture()
        let service = ModelCatalogService(path: path)

        let nous = service.providerByID("nous")
        #expect(nous?.providerName == "Nous Portal")
        #expect(nous?.isOverlay == true)

        let missing = service.providerByID("definitely-not-a-provider")
        #expect(missing == nil)
    }

    // MARK: - NousSubscriptionService

    @Test func subscriptionAbsentWhenAuthFileMissing() throws {
        let path = "/tmp/this-file-should-not-exist-\(UUID().uuidString).json"
        let service = NousSubscriptionService(path: path)
        let state = service.loadState()
        #expect(state == .absent)
    }

    @Test func subscriptionAbsentWhenProvidersEmpty() throws {
        let path = try writeAuthFixture("""
        { "version": 1, "providers": {}, "active_provider": null }
        """)
        let state = NousSubscriptionService(path: path).loadState()
        #expect(state.present == false)
        #expect(state.subscribed == false)
    }

    /// T3-F2: the Tool Gateway keys on Portal sign-in (plus an entitlement
    /// Scarf cannot see), never on the active provider
    /// (`tools/tool_backend_helpers.py:18-28` @ v2026.9.24). This used to
    /// expect `subscribed == false` here, which pinned the wrong rule.
    @Test func signedInCountsWhateverProviderIsActive() throws {
        for active in ["\"anthropic\"", "null", "\"nous\""] {
            let path = try writeAuthFixture("""
            {
              "version": 1,
              "providers": { "nous": { "access_token": "tok-12345" } },
              "active_provider": \(active)
            }
            """)
            let state = NousSubscriptionService(path: path).loadState()
            #expect(state.present == true, "active_provider \(active)")
            #expect(state.subscribed == true, "active_provider \(active)")
        }
    }

    /// `active_provider: nous` without a token is not a sign-in.
    @Test func activeProviderAloneIsNotASignIn() throws {
        let path = try writeAuthFixture("""
        { "version": 1, "providers": {}, "active_provider": "nous" }
        """)
        let state = NousSubscriptionService(path: path).loadState()
        #expect(state.subscribed == false)
    }

    @Test func subscriptionAbsentWhenTokenEmpty() throws {
        let path = try writeAuthFixture("""
        {
          "version": 1,
          "providers": { "nous": { "access_token": "" } },
          "active_provider": "nous"
        }
        """)
        let state = NousSubscriptionService(path: path).loadState()
        #expect(state.present == false,
                "Empty token is as good as no token — don't claim subscription")
    }

    @Test func subscriptionAbsentOnMalformedJSON() throws {
        let path = try writeAuthFixture("{ this is not valid json")
        let state = NousSubscriptionService(path: path).loadState()
        #expect(state == .absent)
    }

    // MARK: - platform_toolsets YAML parse

    @Test func platformToolsetsParsed() throws {
        let yaml = """
        model:
          default: claude-sonnet-4.5
          provider: anthropic
        platform_toolsets:
          cli:
          - browser
          - messaging
          slack:
          - messaging
        """
        let parsed = HermesFileService.parseNestedYAML(yaml)
        #expect(parsed.lists["platform_toolsets.cli"] == ["browser", "messaging"])
        #expect(parsed.lists["platform_toolsets.slack"] == ["messaging"])
    }

    @Test func platformToolsetsEmptyWhenMissing() throws {
        // HermesConfig.empty should have no platform toolsets.
        let config = HermesConfig.empty
        #expect(config.platformToolsets.isEmpty)
    }
}
