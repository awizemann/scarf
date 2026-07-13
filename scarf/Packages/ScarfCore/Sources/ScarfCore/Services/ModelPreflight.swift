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
        /// The standalone `model.provider` value (e.g. `"nous"`).
        public let activeProvider: String
        /// The full `model.default` string as configured.
        public let modelDefault: String
        /// The bare model id (with the prefix stripped) — what the user
        /// would see if Scarf rewrites `model.default` for them.
        public let bareModel: String
        /// False when the caller supplied a known-provider roster and
        /// the prefix (after alias resolution) isn't on it — e.g.
        /// `foo/bar` under provider `nous`. The banner then hides the
        /// "Use foo" button: writing `model.provider = foo` would
        /// swap one broken config for another. True when no roster
        /// was supplied (catalog unavailable) — trust the prefix.
        public let prefixIsKnownProvider: Bool
    }

    /// Providers Hermes defines with `is_aggregator = True`
    /// (hermes_cli/providers.py). Their model IDs are natively
    /// `org/model` namespaced (e.g. openrouter's `xiaomi/mimo-v2.5`),
    /// so a slash in `model.default` is part of the model ID — never a
    /// stale provider prefix. Reconcile on every Hermes bump alongside
    /// the ModelCatalogService provider tables (GH issue #121).
    static let aggregatorProviders: Set<String> = [
        "openrouter", "opencode", "opencode-go", "kilo", "huggingface", "novita",
    ]

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
        knownProviders: Set<String>? = nil
    ) -> Mismatch? {
        let modelDefault = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeProvider = config.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isUnset(modelDefault), !isUnset(activeProvider) else { return nil }
        let canonicalActive = ModelCatalogService.canonicalProviderID(activeProvider)
        guard !aggregatorProviders.contains(canonicalActive) else { return nil }
        // Custom endpoints serve whatever model IDs the user's own server
        // exposes — a slash is never a stale provider prefix. Hermes makes
        // `custom:*` an aggregator outright (providers.py is_aggregator)
        // and refuses to second-guess `custom`/`custom:*` configs (#48305).
        guard canonicalActive != "custom",
              !canonicalActive.hasPrefix("custom:") else { return nil }
        guard let slash = modelDefault.firstIndex(of: "/") else { return nil }
        let prefix = String(modelDefault[..<slash])
        let bare = String(modelDefault[modelDefault.index(after: slash)...])
        guard !prefix.isEmpty, !bare.isEmpty else { return nil }
        let canonicalPrefix = ModelCatalogService.canonicalProviderID(prefix)
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
