import Testing
import Foundation
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
        // Cached providers still present.
        #expect(ids.contains("anthropic"))
        #expect(ids.contains("openai"))
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

    @Test func subscriptionPresentButInactiveWhenOtherProviderActive() throws {
        let path = try writeAuthFixture("""
        {
          "version": 1,
          "providers": { "nous": { "access_token": "tok-12345" } },
          "active_provider": "anthropic"
        }
        """)
        let state = NousSubscriptionService(path: path).loadState()
        #expect(state.present == true)
        #expect(state.providerIsNous == false)
        #expect(state.subscribed == false,
                "Auth alone isn't enough — the Tool Gateway only routes when Nous is the active provider")
    }

    @Test func subscriptionActiveWhenAuthAndActiveProviderLineUp() throws {
        let path = try writeAuthFixture("""
        {
          "version": 1,
          "providers": { "nous": { "access_token": "tok-12345" } },
          "active_provider": "nous"
        }
        """)
        let state = NousSubscriptionService(path: path).loadState()
        #expect(state.present == true)
        #expect(state.providerIsNous == true)
        #expect(state.subscribed == true)
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
