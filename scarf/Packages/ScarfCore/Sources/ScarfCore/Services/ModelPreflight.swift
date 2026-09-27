import Foundation

/// Pre-flight check used before opening an ACP session. Hermes resolves the
/// model+provider from `config.yaml` at session boot; on a fresh install that
/// file is missing or has neither key set, and the chat fails with an opaque
/// "Model parameter is required" 400 from the upstream provider only after the
/// user has typed a prompt and hit send. Catching the missing config here lets
/// the UI surface a real "pick a model" sheet before any ACP work starts.
///
/// `HermesConfig.empty` (returned on read failure) and the YAML parser's
/// missing-key fallback both use the literal string `"unknown"`, so the check
/// has to treat `""` and `"unknown"` as equivalent. Anything else is
/// considered configured — we don't try to validate the model against the
/// provider's catalog here; that happens later in `ModelPickerSheet`.
public enum ModelPreflight: Sendable {
    public enum Result: Equatable, Sendable {
        case configured
        case missingModel
        case missingProvider
        case missingBoth

        public var isConfigured: Bool {
            self == .configured
        }

        /// Short user-facing reason. Long enough to be honest, short enough
        /// for a sheet header — full messaging belongs to the picker UI.
        public var reason: String {
            switch self {
            case .configured:     return ""
            case .missingModel:   return "No primary model is set in this server's config."
            case .missingProvider:return "No primary provider is set in this server's config."
            case .missingBoth:    return "No model is configured on this server yet."
            }
        }
    }

    /// Treat `""` and the YAML parser's `"unknown"` fallback as missing.
    /// Trim whitespace so a stray newline in a hand-edited config.yaml
    /// doesn't read as "configured."
    public static func check(_ config: HermesConfig) -> Result {
        let modelMissing = isUnset(config.model)
        let providerMissing = isUnset(config.provider)
        // Local custom-endpoint auto-detect (T4 audit): the model picker's
        // Local tab legitimately saves `provider: custom` with an EMPTY
        // `model.default` when the base URL is loopback — Hermes then
        // auto-detects the single loaded model at request time
        // (runtime_provider.py:206-213). That config is CONFIGURED, not
        // missing; without this gate the preflight sheet re-prompts on
        // every chat start, including immediately after saving the
        // auto-detect setup from the preflight sheet itself.
        if modelMissing, !providerMissing,
           let descriptor = LocalModelProvider.descriptor(for: config.provider),
           descriptor.allowsEmptyModelWhenLoopback,
           LocalModelProvider.hermesAutoDetectsEmptyModel(baseURL: config.modelBaseURL) {
            return .configured
        }
        switch (modelMissing, providerMissing) {
        case (true, true):   return .missingBoth
        case (true, false):  return .missingModel
        case (false, true):  return .missingProvider
        case (false, false): return .configured
        }
    }

    private static func isUnset(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty || trimmed == "unknown"
    }

    /// Result of a `model.default` ↔ `model.provider` mismatch check.
    /// Captures the case where `model.default` carries a `<provider>/...`
    /// prefix that doesn't match the standalone `model.provider` key —
    /// observed in 2026-05-05 dogfooding when switching OAuth providers
    /// via Credential Pools left the prior provider's model name
    /// stranded in `model.default`. Hermes can't reconcile the two and
    /// chats die with an opaque `-32603 Internal error` at first prompt.
    public struct Mismatch: Sendable, Equatable {
        /// The provider prefix found in `model.default` (e.g. `"anthropic"`).
        public let prefixProvider: String
        /// The standalone `model.provider` value (e.g. `"openai"`).
        public let activeProvider: String
        /// The full `model.default` string as configured.
        public let modelDefault: String
        /// The bare model id (with the prefix stripped) — what the user
        /// would see if Scarf rewrites `model.default` for them.
        public let bareModel: String
        /// False when the caller supplied a known-provider roster and
        /// the prefix (after alias resolution) isn't on it — e.g.
        /// `foo/bar` under provider `openai`. The banner then hides the
        /// "Use foo" button: writing `model.provider = foo` would
        /// swap one broken config for another. True when no roster
        /// was supplied (catalog unavailable) — trust the prefix.
        public let prefixIsKnownProvider: Bool
    }

    /// Providers whose model IDs are natively `org/model` namespaced
    /// (e.g. openrouter's `xiaomi/mimo-v2.5`), so a slash in
    /// `model.default` is part of the model ID — never a stale provider
    /// prefix. Reconcile on every Hermes bump alongside the
    /// ModelCatalogService provider tables (GH issue #121).
    ///
    /// Two Hermes sources, unioned:
    /// - `HERMES_OVERLAYS` entries with `is_aggregator=True`
    ///   (`hermes_cli/providers.py`);
    /// - `_AGGREGATOR_PROVIDERS` in `hermes_cli/model_normalize.py:30-32`
    ///   @ `v2026.9.24` — "Providers whose APIs consume vendor/model slugs":
    ///   `openrouter`, `nous`, `ai-gateway`, `kilocode` (canonically
    ///   `openrouter`, `nous`, `vercel`, `kilo`). That set has named `nous`
    ///   since the file first appeared (≤ v2026.4.8), and `agent_init.py`
    ///   skips model-name normalization for those providers.
    ///
    /// `nous` is only in the second one — `providers.py` gives it an overlay
    /// without `is_aggregator` — and was missing here until S06-F1. Nous's
    /// own catalog ids are vendor-prefixed (`anthropic/claude-opus-5.5`,
    /// `website/static/api/model-catalog.json` providers.nous), so every
    /// Nous user saw a false "Chats will fail" banner whose "Use anthropic"
    /// button moved them off Nous. `scripts/check-hermes-tables.py` lane 2
    /// diffs this set against both sources.
    ///
    /// Entries are **canonical** IDs as `canonicalProviderID(_:)` returns
    /// them, not Hermes's display slugs. That's why OpenCode Zen appears
    /// here as bare `opencode`: `providerAliases` maps `opencode-zen` and
    /// `zen` → `opencode` (mirroring providers.py ALIASES), so `opencode`
    /// is the only spelling this lookup can ever see for Zen. `opencode-go`
    /// is canonical in its own right. `opencode-free` — canonical too, and
    /// also `is_aggregator=True` in `providers.py` while it existed — is
    /// NOT here: it was REMOVED from Hermes at v0.21.4, so it can no longer
    /// be in the table this one is checked against
    /// (`scripts/check-hermes-tables.py` lane 2 diffs this set against
    /// `providers.py` at Scarf's CURRENT target tag). See
    /// `legacyAggregatorProviders` for the pre-0.21.4 fallback.
    static let aggregatorProviders: Set<String> = [
        "openrouter", "opencode", "opencode-go",
        "kilo", "huggingface", "novita", "vercel",
        "nous",
    ]

    /// GitHub Copilot providers (canonical ids — `copilot` canonicalises to
    /// `github-copilot`), for which Hermes strips ANY vendor prefix before
    /// sending: `normalize_model_for_provider` →
    /// `normalize_copilot_model_id` (`hermes_cli/model_normalize.py:232-238`
    /// @ v2026.9.24). Verified: `anthropic/claude-sonnet-4.6` under
    /// `copilot` sends `claude-sonnet-4.6`. Consulted only on hosts with
    /// `hasVendorPrefixStrippingForCopilot`. Not an aggregator (the model
    /// namespace is flat), so it is NOT in `aggregatorProviders` and not in
    /// check-hermes-tables lane 2.
    static let vendorStrippingProviders: Set<String> = ["github-copilot", "copilot-acp"]

    /// Direct providers whose own API serves `vendor/model` ids, so a slash
    /// in `model.default` is the model id, not a stale provider prefix.
    /// NVIDIA NIM (build.nvidia.com) serves `nvidia/nemotron-…`,
    /// `meta/llama-…` and third-party `z-ai/glm-…`; Hermes sends an id that
    /// already has a slash unchanged — `nvidia` is in no prefix-stripping set
    /// and falls to `_repair_prefix_from_catalogue`, which only touches BARE
    /// ids (`hermes_cli/model_normalize.py:72-82,171-175,257-258` @ v2026.9.24). No
    /// tag ever stripped for it (the file first appears at v2026.4.8; before
    /// that every id went out as typed), so this needs no floor.
    /// Kept apart from `aggregatorProviders`, which `check-hermes-tables.py`
    /// lane 2 diffs against Hermes' aggregator tables.
    static let vendorNamespacedProviders: Set<String> = ["nvidia"]

    /// `aggregatorProviders` entries for a provider Hermes removed at a
    /// version floor — added back only below that floor. See
    /// `HermesCapabilities.hasOpenCodeFreeProvider`.
    static let legacyAggregatorProviders: Set<String> = ["opencode-free"]

    /// `aggregatorProviders`, widened with `legacyAggregatorProviders` when
    /// the connected host still runs a since-removed aggregator. Defaults to
    /// `.empty` capabilities, which resolves exactly as the old unconditional
    /// `aggregatorProviders` did (`hasOpenCodeFreeProvider` is true for an
    /// undetected host) — every existing caller that doesn't pass real
    /// capabilities keeps today's behavior.
    static func aggregatorProviders(capabilities: HermesCapabilities) -> Set<String> {
        capabilities.hasOpenCodeFreeProvider
            ? aggregatorProviders.union(legacyAggregatorProviders)
            : aggregatorProviders
    }

    /// True when config.yaml selects `model.provider: llamacpp` (or a
    /// spelling alias) with a `model.base_url` that a v0.21.1+ host will
    /// IGNORE — Hermes resolves that provider to its managed llama.cpp
    /// runtime, which only uses its own server or a probe of
    /// `127.0.0.1:8080` (`hermes_cli/runtime_provider_custom.py:537-540`,
    /// `hermes_cli/local_runtime/detect.py:16,40-43` @ v2026.9.24). So a
    /// base URL on any other host or port makes the first prompt fail with
    /// "The local model server is turned off". The chat banner offers a
    /// one-click switch to `custom`, which honours the URL. Configs saved
    /// by Scarf before R03 look exactly like this (S06-F2).
    ///
    /// `false` below the floor (llamacpp honoured base_url there), for
    /// undetected hosts, with no base_url, and for a base_url that IS the
    /// probed endpoint (`127.0.0.1`/`localhost` port 8080, any path).
    ///
    /// Deliberately approximate: Hermes also probes any extra ports listed in
    /// `local_runtime.detect_ports` (`hermes_cli/local_runtime/endpoint.py:91`)
    /// and prefers a `custom_providers` entry literally named `llamacpp`
    /// (`runtime_provider_custom.py:538-540`); Scarf doesn't model either,
    /// so such a config may see the banner needlessly. The offered switch to
    /// `custom` works in every one of those cases, so a false positive costs
    /// one click, not a broken config.
    public static func llamaCppBaseURLIgnored(
        _ config: HermesConfig,
        capabilities: HermesCapabilities
    ) -> Bool {
        guard capabilities.llamaCppProviderIgnoresBaseURL,
              LocalModelProvider.descriptor(for: config.provider)?.providerID == "llamacpp"
        else { return false }
        let base = config.modelBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return false }
        if let url = URLComponents(string: base),
           let host = url.host?.lowercased(),
           host == "127.0.0.1" || host == "localhost",
           (url.port ?? (url.scheme == "https" ? 443 : 80)) == 8080 {
            return false
        }
        return true
    }

    /// Detect a `model.default` / `model.provider` mismatch. Returns
    /// `nil` when there's no provider prefix on `model.default`, when
    /// either field is unset, when the prefix and provider resolve to
    /// the same canonical Hermes provider (aliases like `claude/...`
    /// vs `anthropic`, `x-ai/...` vs `xai` are equivalent, not
    /// mismatched), or when the provider is an aggregator (whose model
    /// IDs contain slashes natively).
    ///
    /// `knownProviders` is the roster of canonical provider IDs the
    /// caller trusts (models.dev catalog + Hermes overlays, via
    /// `ModelCatalogService.loadProviders()`). When supplied and the
    /// prefix resolves to an ID not on it, the mismatch still fires —
    /// the config is genuinely broken — but is marked
    /// `prefixIsKnownProvider = false` so the UI won't offer to write
    /// a nonexistent provider into config.yaml. Pass nil when the
    /// catalog is unavailable (keeps the pre-roster behavior).
    public static func detectMismatch(
        _ config: HermesConfig,
        knownProviders: Set<String>? = nil,
        capabilities: HermesCapabilities = .empty
    ) -> Mismatch? {
        let modelDefault = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeProvider = config.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isUnset(modelDefault), !isUnset(activeProvider) else { return nil }
        let canonicalActive = ModelCatalogService.canonicalProviderID(
            activeProvider, capabilities: capabilities)
        guard !aggregatorProviders(capabilities: capabilities).contains(canonicalActive) else { return nil }
        // Custom endpoints serve whatever model IDs the user's own server
        // exposes — a slash is never a stale provider prefix. Hermes makes
        // `custom:*` an aggregator outright (providers.py is_aggregator)
        // and refuses to second-guess `custom`/`custom:*` configs (#48305).
        guard canonicalActive != "custom",
              !canonicalActive.hasPrefix("custom:") else { return nil }
        guard !vendorNamespacedProviders.contains(canonicalActive) else { return nil }
        guard let slash = modelDefault.firstIndex(of: "/") else { return nil }
        let prefix = String(modelDefault[..<slash])
        let bare = String(modelDefault[modelDefault.index(after: slash)...])
        guard !prefix.isEmpty, !bare.isEmpty else { return nil }
        // Providers Hermes strips a vendor prefix for before sending — the
        // prefix is harmless there, not a stale provider (see
        // `hasVendorPrefixStrippingForCopilot` / `hasOpenAIPrefixStrippingForCodex`).
        if capabilities.hasVendorPrefixStrippingForCopilot,
           vendorStrippingProviders.contains(canonicalActive) { return nil }
        if capabilities.hasOpenAIPrefixStrippingForCodex,
           canonicalActive == "openai-codex", prefix.lowercased() == "openai" { return nil }
        let canonicalPrefix = ModelCatalogService.canonicalProviderID(
            prefix, capabilities: capabilities)
        guard canonicalPrefix != canonicalActive else { return nil }
        let prefixKnown = knownProviders.map {
            $0.contains(canonicalPrefix) || $0.contains(prefix.lowercased())
        } ?? true
        return Mismatch(
            prefixProvider: prefix,
            activeProvider: activeProvider,
            modelDefault: modelDefault,
            bareModel: bare,
            prefixIsKnownProvider: prefixKnown
        )
    }
}
