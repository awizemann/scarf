import Testing
import Foundation
@testable import ScarfCore

/// Pure tests for `ModelPreflight` — both the `check(_:)` configured-vs-
/// missing classifier and the v2.8 `detectMismatch(_:)` provider/prefix
/// reconciliation. The mismatch path is what surfaces the orange
/// "Model/provider mismatch in config.yaml" banner in ChatView when the
/// user switches OAuth providers via Credential Pools and `model.default`
/// is left carrying the old provider's prefix.
@Suite struct ModelPreflightTests {

    // MARK: - check(_:) — missing-field classifier

    @Test func bothModelAndProviderEmptyReportsMissingBoth() {
        var cfg = HermesConfig.empty
        cfg.model = ""
        cfg.provider = ""
        #expect(ModelPreflight.check(cfg) == .missingBoth)
    }

    @Test func bothModelAndProviderUnknownReportsMissingBoth() {
        // `HermesConfig.empty` defaults model/provider to the literal
        // "unknown" — the classifier must treat that the same as "".
        let cfg = HermesConfig.empty
        #expect(ModelPreflight.check(cfg) == .missingBoth)
    }

    @Test func providerSetButModelEmptyReportsMissingModel() {
        var cfg = HermesConfig.empty
        cfg.model = ""
        cfg.provider = "anthropic"
        #expect(ModelPreflight.check(cfg) == .missingModel)
    }

    @Test func modelSetButProviderEmptyReportsMissingProvider() {
        var cfg = HermesConfig.empty
        cfg.model = "claude-sonnet-4.6"
        cfg.provider = ""
        #expect(ModelPreflight.check(cfg) == .missingProvider)
    }

    @Test func bothSetReportsConfigured() {
        var cfg = HermesConfig.empty
        cfg.model = "claude-sonnet-4.6"
        cfg.provider = "anthropic"
        #expect(ModelPreflight.check(cfg) == .configured)
    }

    @Test func whitespaceTreatedAsUnsetForBothFields() {
        var cfg = HermesConfig.empty
        cfg.model = "  "
        cfg.provider = "\n"
        #expect(ModelPreflight.check(cfg) == .missingBoth)
    }

    // MARK: - check(_:) — custom-endpoint empty-model auto-detect (T4)

    @Test func customProviderWithEmptyModelOnLoopbackIsConfigured() {
        // The Local tab's auto-detect save: provider=custom, empty
        // model.default, loopback base_url. Hermes resolves the model
        // at request time (runtime_provider.py:206-213) — the preflight
        // must NOT re-prompt on every chat start (it would even loop:
        // save auto-detect from the preflight sheet → sheet reopens).
        var cfg = HermesConfig.empty
        cfg.model = ""
        cfg.provider = "custom"
        cfg.modelBaseURL = "http://127.0.0.1:8000/v1"
        #expect(ModelPreflight.check(cfg) == .configured)
        cfg.modelBaseURL = "http://localhost:1234/v1"
        #expect(ModelPreflight.check(cfg) == .configured)
    }

    @Test func customEmptyModelOnNonAutoDetectURLStillReportsMissingModel() {
        // The reader's auto-detect gate is literally
        // `"localhost" in base_url or "127.0.0.1" in base_url` — a LAN
        // URL, `::1`, or a non-.1 127.x address never auto-detects, so
        // an empty model there IS a broken config worth prompting for.
        var cfg = HermesConfig.empty
        cfg.model = ""
        cfg.provider = "custom"
        for url in ["http://192.168.1.20:8000/v1", "http://[::1]:8000/v1", "http://127.0.0.2:8000/v1", ""] {
            cfg.modelBaseURL = url
            #expect(ModelPreflight.check(cfg) == .missingModel, "url: \(url)")
        }
    }

    @Test func nonCustomLocalProviderWithEmptyModelStillReportsMissingModel() {
        // Only the custom descriptor advertises empty-model auto-detect
        // (allowsEmptyModelWhenLoopback); ollama et al. require a model.
        var cfg = HermesConfig.empty
        cfg.model = ""
        cfg.provider = "ollama"
        cfg.modelBaseURL = "http://127.0.0.1:11434/v1"
        #expect(ModelPreflight.check(cfg) == .missingModel)
    }

    @Test func resultIsConfiguredOnlyForConfiguredCase() {
        #expect(ModelPreflight.Result.configured.isConfigured)
        #expect(!ModelPreflight.Result.missingBoth.isConfigured)
        #expect(!ModelPreflight.Result.missingModel.isConfigured)
        #expect(!ModelPreflight.Result.missingProvider.isConfigured)
    }

    // MARK: - detectMismatch(_:)

    @Test func detectMismatchReturnsNilWhenNoPrefixOnModelDefault() {
        var cfg = HermesConfig.empty
        cfg.model = "claude-sonnet-4.6"
        cfg.provider = "anthropic"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchReturnsNilWhenPrefixMatchesProvider() {
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/claude-sonnet-4.6"
        cfg.provider = "anthropic"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchReturnsNilWhenModelDefaultIsUnset() {
        var cfg = HermesConfig.empty
        cfg.model = ""
        cfg.provider = "nous"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchReturnsNilWhenProviderIsUnset() {
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/claude-sonnet-4.6"
        cfg.provider = ""
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchReturnsNilWhenBothUnknown() {
        // The literal "unknown" sentinel from the YAML parser fallback
        // counts as unset on both sides — no mismatch to report.
        let cfg = HermesConfig.empty // model + provider both "unknown"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchSurfacesPrefixVsActiveProvider() {
        // A stale vendor prefix under a DIRECT provider: Gemini's API
        // takes bare ids, so `anthropic/claude-sonnet-4.6` under
        // `gemini` is genuinely broken. The banner offers a one-click fix
        // in either direction; this test pins the data the banner reads.
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/claude-sonnet-4.6"
        cfg.provider = "gemini"
        let mismatch = ModelPreflight.detectMismatch(cfg)
        #expect(mismatch != nil)
        #expect(mismatch?.prefixProvider == "anthropic")
        #expect(mismatch?.activeProvider == "gemini")
        #expect(mismatch?.modelDefault == "anthropic/claude-sonnet-4.6")
        #expect(mismatch?.bareModel == "claude-sonnet-4.6")
    }

    @Test func detectMismatchReturnsNilForNousVendorPrefixedModels() {
        // S06-F1. This test used to pin the OPPOSITE — `anthropic/…`
        // under `nous` as a mismatch — which was the bug. Nous is in
        // Hermes's `model_normalize._AGGREGATOR_PROVIDERS` ("Providers
        // whose APIs consume vendor/model slugs", model_normalize.py:30-32
        // @ v2026.9.24) and its own catalog ids are vendor-prefixed, so
        // this is a valid, working config. The banner's "Use anthropic"
        // button would have moved the user off Nous.
        for model in ["anthropic/claude-sonnet-4.6", "anthropic/claude-opus-5.5",
                      "openai/gpt-6-astra", "moonshotai/kimi-k2"] {
            var cfg = HermesConfig.empty
            cfg.model = model
            cfg.provider = "nous"
            #expect(ModelPreflight.detectMismatch(cfg) == nil, "false mismatch for nous + \(model)")
            // A detected host resolves the same way.
            let host = HermesHost.caps("Hermes Agent v0.21.5 (2026.9.24)")
            #expect(ModelPreflight.detectMismatch(cfg, capabilities: host) == nil)
        }
    }

    @Test func aggregatorProvidersCoverModelNormalizeAggregators() {
        // Every provider in Hermes's `model_normalize._AGGREGATOR_PROVIDERS`
        // (`openrouter`, `nous`, `ai-gateway`, `kilocode`), under the
        // spelling Hermes uses there, must skip the mismatch check once
        // canonicalised. check-hermes-tables.py lane 2 enforces the same
        // against the tagged source.
        for provider in ["openrouter", "nous", "ai-gateway", "kilocode"] {
            var cfg = HermesConfig.empty
            cfg.model = "anthropic/claude-opus-5.5"
            cfg.provider = provider
            #expect(ModelPreflight.detectMismatch(cfg) == nil, "false mismatch for \(provider)")
        }
    }

    @Test func detectMismatchIsCaseInsensitiveOnPrefixMatch() {
        // Hermes accepts both `Anthropic/...` and `anthropic/...` casings
        // in the wild — case-only differences must NOT surface as a
        // mismatch (would be a false-positive banner).
        var cfg = HermesConfig.empty
        cfg.model = "Anthropic/claude-sonnet-4.6"
        cfg.provider = "anthropic"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchHandlesNonAnthropicProviders() {
        // The mismatch banner needs to work for any provider pair —
        // not just the dogfooding case. Pin the openai+gemini shape.
        var cfg = HermesConfig.empty
        cfg.model = "openai/gpt-5"
        cfg.provider = "gemini"
        let mismatch = ModelPreflight.detectMismatch(cfg)
        #expect(mismatch?.prefixProvider == "openai")
        #expect(mismatch?.activeProvider == "gemini")
        #expect(mismatch?.bareModel == "gpt-5")
    }

    @Test func detectMismatchReturnsNilForEmptyBareModel() {
        // A pathological "anthropic/" with no model name after the
        // slash isn't a valid mismatch — caller has no bare model to
        // write back. The classifier should refuse to surface it
        // rather than emit a useless fix button.
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/"
        cfg.provider = "gemini"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchReturnsNilForEmptyPrefix() {
        // Symmetric pathological case — leading slash, no provider
        // prefix. Don't fire.
        var cfg = HermesConfig.empty
        cfg.model = "/claude-sonnet-4.6"
        cfg.provider = "gemini"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchHandlesModelsWithMultipleSlashes() {
        // Some provider/model strings carry path-style segments after
        // the first slash (e.g. an OpenRouter style path). The first
        // slash separates prefix from bare model; the rest of the
        // string is the bare model verbatim.
        var cfg = HermesConfig.empty
        cfg.model = "openrouter/anthropic/claude-sonnet-4.6"
        cfg.provider = "anthropic"
        let mismatch = ModelPreflight.detectMismatch(cfg)
        #expect(mismatch?.prefixProvider == "openrouter")
        #expect(mismatch?.activeProvider == "anthropic")
        #expect(mismatch?.bareModel == "anthropic/claude-sonnet-4.6")
    }

    @Test func detectMismatchReturnsNilForAggregatorProviders() {
        // GH issue #121: OpenRouter model IDs are natively org/model
        // namespaced — `xiaomi/mimo-v2.5` under provider `openrouter`
        // is a valid, working config. The banner must not fire (both
        // of its fix buttons would corrupt the config).
        var cfg = HermesConfig.empty
        cfg.model = "xiaomi/mimo-v2.5"
        cfg.provider = "openrouter"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchReturnsNilForAllAggregatorProviders() {
        // Every Hermes `is_aggregator = True` provider gets the same
        // treatment — slashes are model namespace, not provider prefix.
        for provider in ModelPreflight.aggregatorProviders {
            var cfg = HermesConfig.empty
            cfg.model = "moonshotai/kimi-k2"
            cfg.provider = provider
            #expect(ModelPreflight.detectMismatch(cfg) == nil, "false mismatch for \(provider)")
        }
    }

    @Test func detectMismatchReturnsNilForEveryOpenCodeTier() {
        // v0.20.5: all three OpenCode tiers are is_aggregator=True in
        // HERMES_OVERLAYS. The set is keyed on CANONICAL ids, so Zen is
        // reachable only as bare `opencode` (opencode-zen/zen alias into
        // it) — that's why the bare entry is correct, not a gap.
        for provider in ["opencode", "opencode-zen", "zen",
                         "opencode-go", "opencode-go-sub", "go",
                         "opencode-free", "opencode_free", "free"] {
            var cfg = HermesConfig.empty
            cfg.model = "moonshotai/kimi-k2"
            cfg.provider = provider
            #expect(ModelPreflight.detectMismatch(cfg) == nil, "false mismatch for \(provider)")
        }
    }

    @Test func detectMismatchTreatsOpenCodeFreeAsUnknownProviderOnV0214Host() {
        // Below the removal floor, `opencode-free` is still a real
        // aggregator — no mismatch banner. `capabilities` defaults to
        // `.empty`, matching every pre-existing call site that doesn't
        // pass one.
        var cfg = HermesConfig.empty
        cfg.model = "moonshotai/kimi-k2"
        cfg.provider = "opencode-free"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)

        // At/above it, Hermes no longer resolves `opencode-free` as an
        // aggregator (removed from providers.py entirely), so the
        // `model.default` prefix IS a live mismatch again on that host.
        let newHost = HermesHost.caps("Hermes Agent v0.21.4 (2026.9.21)")
        #expect(ModelPreflight.detectMismatch(cfg, capabilities: newHost) != nil)
    }

    @Test func aggregatorProvidersAreAllCanonicalIDs() {
        // A non-canonical entry would be dead weight: the lookup happens
        // after canonicalProviderID(), so an alias could never match.
        for provider in ModelPreflight.aggregatorProviders {
            #expect(ModelCatalogService.canonicalProviderID(provider) == provider,
                    "\(provider) is an alias, not a canonical provider id")
        }
        // `opencode-free` was REMOVED from Hermes at v0.21.4 (see
        // `HermesCapabilities.hasOpenCodeFreeProvider`), so it moved out of
        // the unconditional `aggregatorProviders` mirror (which
        // `scripts/check-hermes-tables.py` diffs against the CURRENT
        // target tag) into `legacyAggregatorProviders`, added back by
        // `aggregatorProviders(capabilities:)` only below that floor.
        #expect(!ModelPreflight.aggregatorProviders.contains("opencode-free"))
        #expect(ModelPreflight.legacyAggregatorProviders.contains("opencode-free"))
        #expect(ModelPreflight.aggregatorProviders(capabilities: .empty).contains("opencode-free"))
        let newHost = HermesHost.caps("Hermes Agent v0.21.4 (2026.9.21)")
        #expect(!ModelPreflight.aggregatorProviders(capabilities: newHost).contains("opencode-free"))
    }

    @Test func detectMismatchReturnsNilForBareOpenAIAlias() {
        // Hermes aliases bare `openai` → `openrouter`, so a config
        // carrying provider `openai` is aggregator-routed too.
        var cfg = HermesConfig.empty
        cfg.model = "xiaomi/mimo-v2.5"
        cfg.provider = "openai"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchAggregatorSkipIsCaseInsensitive() {
        var cfg = HermesConfig.empty
        cfg.model = "xiaomi/mimo-v2.5"
        cfg.provider = "OpenRouter"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchReturnsNilForCustomProviders() {
        // Hermes treats every `custom:*` endpoint as an aggregator
        // (providers.py is_aggregator) and never second-guesses
        // `custom`/`custom:*` configs (#48305) — the user's own server
        // defines the model namespace, so a slash is part of the ID.
        for provider in ["custom", "custom:my-vllm", "Custom:LAN"] {
            var cfg = HermesConfig.empty
            cfg.model = "meta-llama/llama-4-maverick"
            cfg.provider = provider
            #expect(ModelPreflight.detectMismatch(cfg) == nil, "false mismatch for \(provider)")
        }
    }

    @Test func detectMismatchStillFiresForNonAggregatorProviders() {
        // The original dogfooding failure mode must keep working: a
        // stale `anthropic/` prefix under a direct provider is a real
        // mismatch that kills chats at first prompt. (Until S06-F1 this
        // used `nous`, which is an aggregator in Hermes — see
        // `detectMismatchReturnsNilForNousVendorPrefixedModels`.)
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/claude-sonnet-4.6"
        cfg.provider = "gemini"
        #expect(ModelPreflight.detectMismatch(cfg) != nil)
    }

    @Test func detectMismatchReturnsNilWhenPrefixIsAliasOfProvider() {
        // Hermes ALIASES makes `claude` ↔ `anthropic` the same provider —
        // a `claude/` prefix under provider `anthropic` (or vice versa)
        // is equivalent, not mismatched.
        var cfg = HermesConfig.empty
        cfg.model = "claude/claude-sonnet-4.6"
        cfg.provider = "anthropic"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)

        cfg.model = "x-ai/grok-4"
        cfg.provider = "xai"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchReturnsNilWhenProviderIsAliasOfPrefix() {
        // Alias resolution applies to both sides: provider `zhipu` is
        // Hermes's alias for `zai`, so a `zai/` prefix matches it.
        var cfg = HermesConfig.empty
        cfg.model = "zai/glm-5"
        cfg.provider = "zhipu"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    // MARK: - detectMismatch(_:knownProviders:) — prefix validation

    @Test func detectMismatchMarksUnknownPrefixWithRoster() {
        // GH issue #121 follow-up: `foo/bar` under a direct provider is
        // genuinely broken (banner fires), but `foo` isn't a provider
        // Hermes has — the UI must not offer "Use foo".
        var cfg = HermesConfig.empty
        cfg.model = "foo/bar-model"
        cfg.provider = "gemini"
        let mismatch = ModelPreflight.detectMismatch(cfg, knownProviders: ["anthropic", "xai", "gemini"])
        #expect(mismatch != nil)
        #expect(mismatch?.prefixIsKnownProvider == false)
    }

    @Test func detectMismatchMarksKnownPrefixWithRoster() {
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/claude-sonnet-4.6"
        cfg.provider = "gemini"
        let mismatch = ModelPreflight.detectMismatch(cfg, knownProviders: ["anthropic", "gemini"])
        #expect(mismatch?.prefixIsKnownProvider == true)
    }

    @Test func detectMismatchResolvesAliasBeforeRosterLookup() {
        // A `grok/` prefix isn't in the roster verbatim, but Hermes
        // aliases it to `xai`, which is — the "Use grok" fix would
        // work, so the prefix counts as known.
        var cfg = HermesConfig.empty
        cfg.model = "grok/grok-4"
        cfg.provider = "gemini"
        let mismatch = ModelPreflight.detectMismatch(cfg, knownProviders: ["xai", "gemini"])
        #expect(mismatch?.prefixIsKnownProvider == true)
    }

    @Test func detectMismatchTrustsPrefixWithoutRoster() {
        // No roster (catalog unavailable) → pre-roster behavior: the
        // prefix is trusted and both fix buttons render.
        var cfg = HermesConfig.empty
        cfg.model = "foo/bar-model"
        cfg.provider = "gemini"
        let mismatch = ModelPreflight.detectMismatch(cfg)
        #expect(mismatch?.prefixIsKnownProvider == true)
    }

    @Test func detectMismatchTrimsWhitespaceBeforeComparing() {
        // A stray newline in a hand-edited config.yaml shouldn't read
        // as a mismatch when the trimmed values agree.
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/claude-sonnet-4.6  "
        cfg.provider = " anthropic\n"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }
}
