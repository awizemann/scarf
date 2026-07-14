import Foundation

/// Client-side descriptor for one entry in the model picker's "Local"
/// section — Ollama, LM Studio, vLLM, llama.cpp, and the free-form custom
/// endpoint. Each descriptor encodes exactly what the UI must write into
/// `config.yaml` for a working local chat, per the runtime reader contract
/// (what `resolve_runtime_provider()` actually executes at request time,
/// NOT what `hermes config set` accepts).
///
/// **Verified against the Hermes v0.17.0 reader** (hermes_cli/
/// runtime_provider.py + hermes_cli/auth.py) — see memory note
/// "Local provider config keys — Hermes reader-verified (v0.17.0)".
///
/// **Deliberately NOT one of the check-hermes-tables.py-synced tables.**
/// This is a UI-level grouping, not a mirror of Hermes source:
/// `overlayOnlyProviders` must stay a verbatim subset of HERMES_OVERLAYS
/// (lane 3 fails on any extra key), and none of these local IDs are
/// overlays — they're runtime aliases (`ollama`/`vllm`/`llamacpp` →
/// `custom`) plus the two real registry entries `lmstudio` and `custom`.
/// Surfacing them is Scarf's own affordance, so the table lives here,
/// outside the synced blocks.
///
/// Hard runtime constraints this table encodes:
/// - Provider ID `local` is NEVER written. It exists only as a
///   catalog-side alias target (providers.py); the runtime alias table
///   (auth.py:1560-1564) maps vllm/llamacpp to `custom`, and
///   `resolve_provider("local")` raises "Unknown provider" at request
///   time.
/// - Bare ollama/vllm/llamacpp have NO built-in endpoint and never read
///   OLLAMA_HOST. Without `model.base_url` the chat **silently falls
///   through to OpenRouter** (runtime_provider.py:970-976) — hence
///   `baseURLRequired` and, for Ollama, a default the UI always writes.
/// - No API key is ever needed: the runtime substitutes the placeholder
///   "no-key-required" itself (LM Studio auto-supplies
///   "dummy-lm-api-key"). Only the custom endpoint accepts an optional
///   inline `model.api_key`.
public struct LocalModelProvider: Sendable, Identifiable, Hashable {
    public var id: String { providerID }

    /// How T2 can enumerate the models a running server actually serves.
    public enum EnumerationHint: String, Sendable {
        /// GET `<host>/api/tags` — Ollama's native tag listing. The
        /// `/v1` suffix of the configured base URL is not part of this
        /// endpoint.
        case ollamaTags
        /// GET `<base_url>/v1/models` — the OpenAI-compatible listing
        /// every other local server exposes (and the same endpoint
        /// Hermes probes for its own loopback auto-detect).
        case openAIModels
        /// No live enumeration — free-form model entry only.
        case none
    }

    /// The exact value the UI writes to `model.provider`. Never `local`.
    public let providerID: String
    public let displayName: String
    /// One-line picker blurb.
    public let blurb: String
    /// Base URL the UI pre-fills — and, when `baseURLRequired`, writes to
    /// `model.base_url` even if the user leaves it untouched. `nil` means
    /// the runtime has no default: the user must supply one.
    public let defaultBaseURL: String?
    /// Ghost text for the base-URL field. For servers with no runtime
    /// default this shows the tool's own conventional port — never
    /// auto-written, purely a typing aid.
    public let baseURLPlaceholder: String
    /// True when `model.base_url` MUST be written to config.yaml. For
    /// Ollama this is true even though a default exists — omitting the
    /// key is the silent-OpenRouter-fallthrough failure mode.
    public let baseURLRequired: Bool
    public let enumerationHint: EnumerationHint
    /// "No API key needed — …" style line for the credentials slot
    /// (see ModelPickerSheet.overlayInstruction for the precedent).
    public let credentialInstruction: String
    /// True only for the custom endpoint, which accepts an optional
    /// inline `model.api_key`. All others must NOT write a key — the
    /// runtime supplies its own placeholder.
    public let supportsAPIKey: Bool
    /// True only for the custom endpoint, which accepts an optional
    /// `model.api_mode`. Values must pass `Self.isValidAPIMode` —
    /// Hermes silently ignores invalid modes, so the UI is the only
    /// validation gate.
    public let supportsAPIMode: Bool
    /// True only for the custom endpoint: `model.default` may be left
    /// empty when the base URL is a loopback host — Hermes auto-detects
    /// a single loaded model via GET `<base_url>/v1/models`.
    public let allowsEmptyModelWhenLoopback: Bool

    public init(
        providerID: String,
        displayName: String,
        blurb: String,
        defaultBaseURL: String?,
        baseURLPlaceholder: String,
        baseURLRequired: Bool,
        enumerationHint: EnumerationHint,
        credentialInstruction: String,
        supportsAPIKey: Bool = false,
        supportsAPIMode: Bool = false,
        allowsEmptyModelWhenLoopback: Bool = false
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.blurb = blurb
        self.defaultBaseURL = defaultBaseURL
        self.baseURLPlaceholder = baseURLPlaceholder
        self.baseURLRequired = baseURLRequired
        self.enumerationHint = enumerationHint
        self.credentialInstruction = credentialInstruction
        self.supportsAPIKey = supportsAPIKey
        self.supportsAPIMode = supportsAPIMode
        self.allowsEmptyModelWhenLoopback = allowsEmptyModelWhenLoopback
    }

    // MARK: - Managed config keys

    /// The exact set of `config.yaml` keys a picker Save of this provider
    /// may write — the explicit write contract T3's picker (and its
    /// clear-on-switch rule) builds on. `model.default` + `model.provider`
    /// always; `model.base_url` whenever the runtime either requires the
    /// key or ships a default the UI pre-fills (today: every descriptor);
    /// `model.api_key` / `model.api_mode` only where the descriptor
    /// supports them (custom endpoint). Any local-managed key NOT written
    /// by a given save must be cleared on provider switch — stale
    /// base_url/api_mode in config.yaml causes real Hermes bugs (the
    /// GH #27132 class). See `LocalModelConfigPlan`.
    ///
    /// `model.context_length` is deliberately in NO descriptor's written
    /// set: the picker offers no context override (for sub-64K models
    /// it's a runtime trap — preflight passes, the turn halts), so the
    /// key is clear-only. It still sits in
    /// `LocalModelConfigPlan.localManagedKeys` so a CLI-set stale
    /// override is scrubbed on every switch.
    public var configKeysWritten: Set<String> {
        var keys: Set<String> = ["model.default", "model.provider"]
        if baseURLRequired || defaultBaseURL != nil { keys.insert("model.base_url") }
        if supportsAPIKey { keys.insert("model.api_key") }
        if supportsAPIMode { keys.insert("model.api_mode") }
        return keys
    }

    // MARK: - api_mode validation

    /// The runtime's `_VALID_API_MODES` (runtime_provider.py:255-268),
    /// verbatim. Anything else is *silently ignored* by Hermes
    /// (`_parse_api_mode`) — the config saves fine and the request quietly
    /// runs with URL auto-detect instead — so the UI must reject invalid
    /// values at save time.
    ///
    /// `codex_app_server` is runtime-valid but esoteric: Hermes only
    /// *auto-applies* it (via `model.openai_runtime`) for openai /
    /// openai-codex, and as an explicit `model.api_mode` it hands the turn
    /// to a `codex app-server` subprocess. The validator must accept it —
    /// the runtime honors it, so the silently-ignored trap doesn't apply —
    /// but T3's picker should surface only the four transport modes in
    /// `pickerAPIModes`.
    public static let validAPIModes: [String] = [
        "chat_completions",
        "codex_responses",
        "anthropic_messages",
        "bedrock_converse",
        "codex_app_server",
    ]

    /// The subset of `validAPIModes` T3 offers as picker choices — the
    /// plain transport modes, without the codex_app_server runtime opt-in
    /// (meaningless for a local endpoint; still accepted if hand-typed).
    public static let pickerAPIModes: [String] = [
        "chat_completions",
        "codex_responses",
        "anthropic_messages",
        "bedrock_converse",
    ]

    /// Membership check for a user-entered `model.api_mode`, mirroring the
    /// runtime's own normalization: `_parse_api_mode` does
    /// `raw.strip().lower()` before the set lookup, so whitespace is
    /// trimmed and case IS folded ("Chat_Completions" is honored).
    /// An empty/blank value means "unset" and is valid — the runtime then
    /// falls back to URL auto-detect, then `chat_completions`.
    public static func isValidAPIMode(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return true }
        return validAPIModes.contains(normalized)
    }

    // MARK: - Auto-detect loopback gate

    /// True when Hermes's empty-`model.default` auto-detect will actually
    /// fire for this base URL. Deliberately NARROWER than "any loopback
    /// address": the reader's gate is a literal substring check —
    /// `"localhost" in base_url or "127.0.0.1" in base_url`
    /// (runtime_provider.py:209, `_get_model_config`) — so `::1`,
    /// `0.0.0.0`, and non-.1 127.x addresses do NOT auto-detect even
    /// though `_loopback_hostname` (the base_url TRUST gate) accepts
    /// them. A UI that allowed saving an empty model against `::1`
    /// would produce a config Hermes runs with no model at all.
    /// The check is a strict SUBSET of the reader's: the reader's
    /// substring test must pass verbatim (it is case-sensitive — an
    /// uppercase `LOCALHOST` does NOT auto-detect), and the substring
    /// must actually be the URL's host (so `http://evil.com/localhost`
    /// doesn't sneak through). Anything we allow, the reader
    /// auto-detects.
    public static func hermesAutoDetectsEmptyModel(baseURL raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("localhost") || trimmed.contains("127.0.0.1") else { return false }
        guard let host = URLComponents(string: trimmed)?.host else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }

    // MARK: - Lookup

    /// The runtime's spelling aliases for the local IDs (the auth.py
    /// :1560-1564 alias table, local subset) — a config.yaml written by
    /// the Hermes CLI can legitimately carry any of these, and the UI must
    /// recognize them as the same local provider. Maps alias → table ID.
    private static let runtimeSpellingAliases: [String: String] = [
        "lm-studio": "lmstudio",
        "lm_studio": "lmstudio",
        "llama.cpp": "llamacpp",
        "llama-cpp": "llamacpp",
    ]

    /// Descriptor for a stored `model.provider`, or nil when the value
    /// isn't one of the local table's IDs or a runtime spelling alias of
    /// one (`lm-studio`, `lm_studio`, `llama.cpp`, `llama-cpp`).
    public static func descriptor(for providerID: String) -> LocalModelProvider? {
        var key = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        key = runtimeSpellingAliases[key] ?? key
        return all.first { $0.providerID == key }
    }

    // MARK: - The table

    /// Picker order is fixed — most-common-first, custom last. Tests pin
    /// this ordering; reordering is a deliberate UX decision, not churn.
    public static let all: [LocalModelProvider] = [
        LocalModelProvider(
            providerID: "ollama",
            displayName: "Ollama",
            blurb: "Local Ollama server — pick from the tags you've pulled.",
            // The runtime has NO built-in Ollama URL (OLLAMA_HOST is never
            // read); this is Ollama's own default port with the /v1
            // OpenAI-compat suffix the reader expects. Always written.
            defaultBaseURL: "http://127.0.0.1:11434/v1",
            baseURLPlaceholder: "http://127.0.0.1:11434/v1",
            baseURLRequired: true,
            enumerationHint: .ollamaTags,
            credentialInstruction: "No API key needed — Hermes talks to your Ollama server directly and supplies a placeholder key on its own."
        ),
        LocalModelProvider(
            providerID: "lmstudio",
            displayName: "LM Studio",
            blurb: "LM Studio's local server — models load on demand.",
            // Real registry default (PROVIDER_REGISTRY["lmstudio"]); the
            // runtime falls back to it, so writing base_url is optional.
            // LM_BASE_URL env overrides; model.base_url is honored only
            // when model.provider == lmstudio.
            defaultBaseURL: "http://127.0.0.1:1234/v1",
            baseURLPlaceholder: "http://127.0.0.1:1234/v1",
            baseURLRequired: false,
            enumerationHint: .openAIModels,
            credentialInstruction: "No API key needed — Hermes auto-supplies LM Studio's placeholder key. Set LM_API_KEY only if your server requires one."
        ),
        LocalModelProvider(
            providerID: "vllm",
            displayName: "vLLM",
            blurb: "A vLLM server's OpenAI-compatible endpoint.",
            // No runtime default of any kind — the user supplies the URL.
            // The placeholder is vLLM's conventional serve port only.
            defaultBaseURL: nil,
            baseURLPlaceholder: "http://127.0.0.1:8000/v1",
            baseURLRequired: true,
            enumerationHint: .openAIModels,
            credentialInstruction: "No API key needed — Hermes supplies a placeholder key for local endpoints automatically."
        ),
        LocalModelProvider(
            providerID: "llamacpp",
            displayName: "llama.cpp",
            blurb: "A llama.cpp server (llama-server) endpoint.",
            // Same story as vLLM: runtime-aliased to custom, no default
            // endpoint. Placeholder is llama-server's conventional port.
            defaultBaseURL: nil,
            baseURLPlaceholder: "http://127.0.0.1:8080/v1",
            baseURLRequired: true,
            enumerationHint: .openAIModels,
            credentialInstruction: "No API key needed — Hermes supplies a placeholder key for local endpoints automatically."
        ),
        LocalModelProvider(
            providerID: "custom",
            displayName: "Custom endpoint",
            blurb: "Any OpenAI-compatible server, local or remote.",
            defaultBaseURL: nil,
            baseURLPlaceholder: "http://127.0.0.1:8000/v1",
            baseURLRequired: true,
            enumerationHint: .openAIModels,
            credentialInstruction: "API key optional — leave blank for local servers; Hermes substitutes a placeholder when the endpoint doesn't need one.",
            supportsAPIKey: true,
            supportsAPIMode: true,
            allowsEmptyModelWhenLoopback: true
        ),
    ]
}
