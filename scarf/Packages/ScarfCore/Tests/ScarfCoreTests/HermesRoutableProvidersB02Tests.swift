import Testing
import Foundation
@testable import ScarfCore

/// Blind re-audit B02 — models & providers.
///
/// S06-F1: the picker listed every models.dev provider, but Hermes routes
/// only the names its own resolver accepts ("Unknown provider 'mistral'"
/// otherwise — `hermes_cli/auth.py:1500-1509` @ v2026.9.24). On hosts the
/// table was derived for, the roster is filtered and preflight warns about an
/// already-saved unroutable provider. Older hosts are untouched (C1).
///
/// S06-F4: the DeepSeek retired-id alias target moved from
/// `deepseek-v4-flash` to `deepseek-flash` at v0.21.2.
struct HermesRoutableProvidersB02Tests {

    static let v0215 = HermesCapabilities.parse("Hermes Agent v0.21.5 (2026.9.24)")
    static let v0214 = HermesCapabilities.parse("Hermes Agent v0.21.4 (2026.9.21)")
    static let v0213 = HermesCapabilities.parse("Hermes Agent v0.21.3 (2026.9.14)")
    static let v0212 = HermesCapabilities.parse("Hermes Agent v0.21.2 (2026.9.11)")
    static let v0211 = HermesCapabilities.parse("Hermes Agent v0.21.1 (2026.9.7)")

    /// A models.dev cache mixing ids Hermes routes (`anthropic`, `google` →
    /// `gemini`, `openai` → a custom endpoint, `vercel` → `ai-gateway`) with
    /// ids it rejects (`mistral`, `groq`, `cerebras`).
    private static func catalog() throws -> (ModelCatalogService, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b02-\(UUID().uuidString).json")
        let json = #"""
        {
          "anthropic": {"id": "anthropic", "name": "Anthropic", "models": {"claude-x": {"name": "Claude X"}}},
          "google": {"id": "google", "name": "Google", "models": {"gemini-x": {"name": "Gemini X"}}},
          "openai": {"id": "openai", "name": "OpenAI", "models": {"gpt-x": {"name": "GPT X"}}},
          "vercel": {"id": "vercel", "name": "Vercel", "models": {"v-x": {"name": "V X"}}},
          "mistral": {"id": "mistral", "name": "Mistral", "models": {"mistral-large-latest": {"name": "Mistral Large"}}},
          "groq": {"id": "groq", "name": "Groq", "models": {"llama-x": {"name": "Llama X"}}},
          "cerebras": {"id": "cerebras", "name": "Cerebras", "models": {"c-x": {"name": "C X"}}},
          "deepseek": {"id": "deepseek", "name": "DeepSeek", "models": {
            "deepseek-flash": {"name": "DeepSeek Flash", "limit": {"context": 1000000}},
            "deepseek-v4-flash": {"name": "DeepSeek V4 Flash", "limit": {"context": 128000}}
          }}
        }
        """#
        try json.write(to: tmp, atomically: true, encoding: .utf8)
        return (ModelCatalogService(path: tmp.path), tmp)
    }

    // MARK: - S06-F1 roster

    @Test func rosterHidesProvidersHermesCannotRoute() throws {
        let (svc, tmp) = try Self.catalog()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ids = Set(svc.loadProviders(capabilities: Self.v0215).map(\.providerID))
        #expect(ids.isSuperset(of: ["anthropic", "google", "openai", "vercel", "deepseek"]))
        #expect(ids.isDisjoint(with: ["mistral", "groq", "cerebras"]))
        // Overlay-only providers (Nous, Codex, MoA, …) all route and stay.
        #expect(ids.isSuperset(of: ["nous", "openai-codex", "moa", "openai-api"]))
    }

    /// The table was derived at v2026.9.21 and v2026.9.24 only (identical
    /// there), so v0.21.4 filters; below that — and for an undetected host —
    /// the roster is the full catalog, as before.
    @Test func rosterFilterStartsAtV0214() throws {
        let (svc, tmp) = try Self.catalog()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(Set(svc.loadProviders(capabilities: Self.v0214).map(\.providerID)).contains("anthropic"))
        #expect(!Set(svc.loadProviders(capabilities: Self.v0214).map(\.providerID)).contains("mistral"))
        for caps in [Self.v0213, HermesCapabilities.empty] {
            let ids = Set(svc.loadProviders(capabilities: caps).map(\.providerID))
            #expect(ids.isSuperset(of: ["mistral", "groq", "cerebras", "anthropic"]))
        }
    }

    /// Every overlay Scarf adds by hand must be a name Hermes routes, or the
    /// filter would silently drop a provider Hermes supports.
    @Test func everyOverlayProviderIsRoutable() {
        for id in ModelCatalogService.overlayOnlyProviders.keys {
            #expect(HermesRoutableProviders.isRoutable(id), "\(id) is an overlay but not routable")
        }
    }

    @Test func routabilityFollowsHermesNormalization() {
        // resolve_requested_provider strips + lowercases.
        #expect(HermesRoutableProviders.isRoutable("  Anthropic "))
        // Aliases that resolve_provider accepts.
        #expect(HermesRoutableProviders.isRoutable("claude"))
        #expect(HermesRoutableProviders.isRoutable("amazon-bedrock"))
        #expect(HermesRoutableProviders.isRoutable("ollama"))
        // Name-only runtime shortcuts outside the registry.
        #expect(HermesRoutableProviders.isRoutable("moa"))
        #expect(HermesRoutableProviders.isRoutable("google-vertex"))
        #expect(HermesRoutableProviders.isRoutable("openai"))
        #expect(HermesRoutableProviders.isRoutable("custom:my-endpoint"))
        // What the live resolver rejected in the audit.
        for id in ["mistral", "groq", "cerebras", "togetherai", "perplexity", "cohere",
                   "moonshotai", "zhipuai", "venice", "siliconflow", "chutes", ""] {
            #expect(!HermesRoutableProviders.isRoutable(id), "\(id)")
        }
        #expect(HermesRoutableProviders.isRoutable("mistral", capabilities: Self.v0213) == nil)
        #expect(HermesRoutableProviders.isRoutable("mistral", capabilities: .empty) == nil)
        #expect(HermesRoutableProviders.isRoutable("mistral", capabilities: Self.v0215) == false)
    }

    // MARK: - S06-F1 preflight (config written as YAML, read back by Scarf)

    @Test func preflightWarnsOnAnUnroutableSavedProvider() {
        let cfg = HermesConfig(yaml: """
        model:
          provider: mistral
          default: mistral-large-latest
        """)
        // The ordinary preflight still calls this configured…
        #expect(ModelPreflight.check(cfg) == .configured)
        // …the routability check is what catches it.
        #expect(ModelPreflight.unroutableProvider(cfg, capabilities: Self.v0215) == "mistral")
        // C1: no warning where the table doesn't apply.
        #expect(ModelPreflight.unroutableProvider(cfg, capabilities: Self.v0213) == nil)
        #expect(ModelPreflight.unroutableProvider(cfg, capabilities: .empty) == nil)
    }

    @Test func preflightIsQuietForRoutableOrUnsetProviders() {
        for provider in ["anthropic", "claude", "openai", "custom", "custom:lab", "auto", "ollama"] {
            let cfg = HermesConfig(yaml: "model:\n  provider: \(provider)\n  default: x\n")
            #expect(ModelPreflight.unroutableProvider(cfg, capabilities: Self.v0215) == nil, "\(provider)")
        }
        #expect(ModelPreflight.unroutableProvider(HermesConfig(yaml: "model:\n  default: x\n"),
                                                  capabilities: Self.v0215) == nil)
        #expect(ModelPreflight.unroutableProvider(.empty, capabilities: Self.v0215) == nil)
    }

    /// A named custom provider routes an otherwise-unknown name through
    /// Hermes's named-custom rung, so the warning must stay quiet — for both
    /// the keyed `providers:` map and the legacy `custom_providers:` list.
    @Test func preflightIsQuietWhenConfigDefinesNamedCustomProviders() {
        let keyed = HermesConfig(yaml: """
        model:
          provider: mistral
          default: mistral-large-latest
        providers:
          mistral:
            base_url: https://api.mistral.ai/v1
            key_env: MISTRAL_API_KEY
        """)
        #expect(keyed.namedCustomProviders == ["mistral"])
        #expect(ModelPreflight.unroutableProvider(keyed, capabilities: Self.v0215) == nil)

        let legacy = HermesConfig(yaml: """
        model:
          provider: groq
          default: llama-x
        custom_providers:
          - name: groq
            base_url: https://api.groq.com/openai/v1
        """)
        #expect(legacy.hasUnreadCustomProviders)
        #expect(ModelPreflight.unroutableProvider(legacy, capabilities: Self.v0215) == nil)

        let flow = HermesConfig(yaml: """
        model:
          provider: groq
        providers: {groq: {base_url: "https://api.groq.com/openai/v1"}}
        """)
        #expect(flow.hasUnreadCustomProviders)
        // Hermes's own default, `providers: {}`, is not a named provider.
        let emptyDefault = HermesConfig(yaml: "model:\n  provider: groq\nproviders: {}\ncustom_providers: []\n")
        #expect(!emptyDefault.hasUnreadCustomProviders && emptyDefault.namedCustomProviders.isEmpty)
        #expect(ModelPreflight.unroutableProvider(emptyDefault, capabilities: Self.v0215) == "groq")

        // An unrelated `tts.providers.*` block is not a named provider.
        let tts = HermesConfig(yaml: """
        model:
          provider: groq
          default: llama-x
        tts:
          providers:
            say:
              command: say
        """)
        #expect(!tts.hasUnreadCustomProviders && tts.namedCustomProviders.isEmpty)
        #expect(ModelPreflight.unroutableProvider(tts, capabilities: Self.v0215) == "groq")
    }

    /// Per-provider knobs under `providers:` (a timeout for a built-in) are
    /// not custom endpoints; they must not silence the warning for a
    /// DIFFERENT, unroutable provider (review finding). An entry matched by
    /// its `name:` field does.
    @Test func onlyAMatchingCustomEndpointSilencesTheWarning() {
        let knobs = HermesConfig(yaml: """
        model:
          provider: mistral
          default: mistral-large-latest
        providers:
          anthropic:
            request_timeout_seconds: 120
          lab:
            base_url: http://10.0.0.5:8000/v1
        """)
        #expect(knobs.namedCustomProviders == ["lab"])
        #expect(ModelPreflight.unroutableProvider(knobs, capabilities: Self.v0215) == "mistral")

        let byName = HermesConfig(yaml: """
        model:
          provider: my lab
          default: x
        providers:
          lab:
            name: My Lab
            base_url: http://10.0.0.5:8000/v1
        """)
        #expect(byName.namedCustomProviders == ["lab", "my-lab"])
        #expect(ModelPreflight.unroutableProvider(byName, capabilities: Self.v0215) == nil)

        let inlineEntry = HermesConfig(yaml: """
        model:
          provider: groq
        providers:
          groq: {base_url: "https://api.groq.com/openai/v1"}
        """)
        #expect(inlineEntry.namedCustomProviders.contains("groq"))
        #expect(ModelPreflight.unroutableProvider(inlineEntry, capabilities: Self.v0215) == nil)
    }

    // MARK: - S06-F4 DeepSeek retired ids

    @Test func deepseekRetiredIdsFollowTheHostVersion() throws {
        let (svc, tmp) = try Self.catalog()
        defer { try? FileManager.default.removeItem(at: tmp) }
        for id in ["deepseek-chat", "deepseek-reasoner"] {
            #expect(svc.resolveModelAlias(providerID: "deepseek", modelID: id, capabilities: Self.v0212) == "deepseek-flash")
            #expect(svc.resolveModelAlias(providerID: "deepseek", modelID: id, capabilities: Self.v0215) == "deepseek-flash")
            // Below the floor (and undetected) Hermes still sent deepseek-v4-flash.
            #expect(svc.resolveModelAlias(providerID: "deepseek", modelID: id, capabilities: Self.v0211) == "deepseek-v4-flash")
            #expect(svc.resolveModelAlias(providerID: "deepseek", modelID: id) == "deepseek-v4-flash")
        }
        // Non-retired ids pass through.
        #expect(svc.resolveModelAlias(providerID: "deepseek", modelID: "deepseek-v4-pro", capabilities: Self.v0215) == "deepseek-v4-pro")
        #expect(svc.validateModel("deepseek-chat", for: "deepseek", capabilities: Self.v0215) == .valid)
    }
}
