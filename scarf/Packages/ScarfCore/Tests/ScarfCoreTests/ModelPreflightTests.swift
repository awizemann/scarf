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
        // The dogfooding scenario: Anthropic-prefixed model still sitting
        // in config.yaml after the user OAuth'd into Nous via Credential
        // Pools. Hermes can't reconcile and chats die with -32603 at
        // first prompt. The banner offers a one-click fix in either
        // direction; this test pins the data the banner reads.
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/claude-sonnet-4.6"
        cfg.provider = "nous"
        let mismatch = ModelPreflight.detectMismatch(cfg)
        #expect(mismatch != nil)
        #expect(mismatch?.prefixProvider == "anthropic")
        #expect(mismatch?.activeProvider == "nous")
        #expect(mismatch?.modelDefault == "anthropic/claude-sonnet-4.6")
        #expect(mismatch?.bareModel == "claude-sonnet-4.6")
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
        // not just the dogfooding case. Pin the openai+nous shape.
        var cfg = HermesConfig.empty
        cfg.model = "openai/gpt-5"
        cfg.provider = "nous"
        let mismatch = ModelPreflight.detectMismatch(cfg)
        #expect(mismatch?.prefixProvider == "openai")
        #expect(mismatch?.activeProvider == "nous")
        #expect(mismatch?.bareModel == "gpt-5")
    }

    @Test func detectMismatchReturnsNilForEmptyBareModel() {
        // A pathological "anthropic/" with no model name after the
        // slash isn't a valid mismatch — caller has no bare model to
        // write back. The classifier should refuse to surface it
        // rather than emit a useless fix button.
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/"
        cfg.provider = "nous"
        #expect(ModelPreflight.detectMismatch(cfg) == nil)
    }

    @Test func detectMismatchReturnsNilForEmptyPrefix() {
        // Symmetric pathological case — leading slash, no provider
        // prefix. Don't fire.
        var cfg = HermesConfig.empty
        cfg.model = "/claude-sonnet-4.6"
        cfg.provider = "nous"
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
        // stale `anthropic/` prefix under direct provider `nous` is a
        // real mismatch that kills chats at first prompt.
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/claude-sonnet-4.6"
        cfg.provider = "nous"
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
        cfg.provider = "nous"
        let mismatch = ModelPreflight.detectMismatch(cfg, knownProviders: ["anthropic", "xai", "nous"])
        #expect(mismatch != nil)
        #expect(mismatch?.prefixIsKnownProvider == false)
    }

    @Test func detectMismatchMarksKnownPrefixWithRoster() {
        var cfg = HermesConfig.empty
        cfg.model = "anthropic/claude-sonnet-4.6"
        cfg.provider = "nous"
        let mismatch = ModelPreflight.detectMismatch(cfg, knownProviders: ["anthropic", "nous"])
        #expect(mismatch?.prefixIsKnownProvider == true)
    }

    @Test func detectMismatchResolvesAliasBeforeRosterLookup() {
        // A `grok/` prefix isn't in the roster verbatim, but Hermes
        // aliases it to `xai`, which is — the "Use grok" fix would
        // work, so the prefix counts as known.
        var cfg = HermesConfig.empty
        cfg.model = "grok/grok-4"
        cfg.provider = "nous"
        let mismatch = ModelPreflight.detectMismatch(cfg, knownProviders: ["xai", "nous"])
        #expect(mismatch?.prefixIsKnownProvider == true)
    }

    @Test func detectMismatchTrustsPrefixWithoutRoster() {
        // No roster (catalog unavailable) → pre-roster behavior: the
        // prefix is trusted and both fix buttons render.
        var cfg = HermesConfig.empty
        cfg.model = "foo/bar-model"
        cfg.provider = "nous"
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
