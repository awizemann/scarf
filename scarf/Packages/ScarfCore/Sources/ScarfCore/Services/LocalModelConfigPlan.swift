import Foundation

/// The model picker's complete description of a local-provider choice —
/// everything the Local tab collected that must land in `config.yaml`.
/// Carried alongside the classic `(modelID, providerID)` pair so hosts
/// that can't persist the extra keys (model presets, delegation) simply
/// never receive one.
public struct LocalModelSelection: Sendable, Equatable {
    /// A local-table provider ID or one of its runtime spelling aliases
    /// (`lm-studio`, `llama.cpp`, …). The plan canonicalizes via
    /// `LocalModelProvider.descriptor(for:)` before writing.
    public let providerID: String
    /// Value for `model.default`. Empty is legal only for the custom
    /// endpoint on a loopback base URL (Hermes auto-detects the single
    /// loaded model) — the picker gates submit accordingly.
    public let modelID: String
    /// User-entered base URL. Nil/blank falls back to the descriptor's
    /// `defaultBaseURL` (Ollama MUST always end up with one — omitting
    /// `model.base_url` silently routes the chat to OpenRouter).
    public let baseURL: String?
    /// Optional inline API key — custom endpoint only.
    public let apiKey: String?
    /// Optional `model.api_mode` — custom endpoint only; must be one of
    /// `LocalModelProvider.validAPIModes` or blank.
    public let apiMode: String?

    public init(
        providerID: String,
        modelID: String,
        baseURL: String? = nil,
        apiKey: String? = nil,
        apiMode: String? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiMode = apiMode
    }
}

/// Pure planner for the `hermes config set` writes a model-picker save
/// performs. One place owns the wire format; hosts (SettingsViewModel,
/// the chat preflight) just execute the returned operations in order.
///
/// **Clear-on-switch rule** (T1 audit, non-negotiable): on any provider
/// switch the writer first clears every local-managed key
/// (`model.base_url`, `model.api_key`, `model.api_mode`) that the new
/// selection does not itself write. A stale `base_url`/`api_mode` left
/// behind in config.yaml is the GH #27132 failure class — the runtime
/// trust gate honors `model.base_url` for any custom-resolving provider,
/// so yesterday's Ollama URL silently redirects today's provider.
///
/// **How clear works.** Hermes v0.17's config verbs are
/// show/edit/set/path/env-path/check/migrate — there is no `unset`.
/// `hermes config set <key> ""` writes an empty string, and the RUNTIME
/// READER treats empty as unset for all three keys (verified against
/// `~/.hermes/hermes-agent` @ v0.17.0):
/// - `model.base_url`: `cfg_base_url.strip()` gates use — falsy `""`
///   falls through to env/default (runtime_provider.py:961, and the
///   api-key-provider branch's `(model_cfg.get("base_url") or "").strip()`
///   at :1799-1803).
/// - `model.api_key`: only consumed `if isinstance(v, str) and v.strip()`
///   (runtime_provider.py:933-937).
/// - `model.api_mode`: `_parse_api_mode` returns None for anything not in
///   `_VALID_API_MODES` after strip().lower() — `""` → None → URL
///   auto-detect → `chat_completions` (runtime_provider.py:269-276).
public enum LocalModelConfigPlan {
    /// One `hermes config set` invocation. `clear` is `set <key> ""` —
    /// see the type comment for why empty-string is the unset mechanism.
    public enum Operation: Equatable, Sendable {
        case set(key: String, value: String)
        case clear(key: String)

        /// argv for `runHermesCLI` / `context.runHermes`.
        public var cliArguments: [String] {
            switch self {
            case .set(let key, let value): return ["config", "set", key, value]
            case .clear(let key):          return ["config", "set", key, ""]
            }
        }
    }

    /// Union of the keys any local descriptor may manage beyond
    /// model.default/model.provider — the clear-on-switch set. Ordered
    /// (not a Set) so plans are deterministic and testable.
    public static let localManagedKeys: [String] = [
        "model.base_url", "model.api_key", "model.api_mode",
    ]

    // MARK: - Local selection

    /// Ordered write plan for saving a local-provider selection.
    /// Empty when `selection.providerID` isn't a local descriptor (or
    /// spelling alias) — callers should treat that as a programming error
    /// and fall back to the remote path.
    ///
    /// Local saves always clear the unwritten managed keys, even when the
    /// provider didn't change: the Local tab owns these fields outright,
    /// so a blanked API-key field on a custom→custom re-save must clear
    /// `model.api_key`, not leave the old secret behind.
    public static func operations(selecting selection: LocalModelSelection) -> [Operation] {
        guard let descriptor = LocalModelProvider.descriptor(for: selection.providerID) else {
            return []
        }

        var sets: [Operation] = []
        var writtenKeys: Set<String> = []

        // base_url — explicit value wins, descriptor default fills in.
        // For Ollama the default is always written (never reads
        // OLLAMA_HOST; no key → silent OpenRouter fallthrough).
        let explicitBase = trimmed(selection.baseURL)
        let effectiveBase = explicitBase.isEmpty ? (descriptor.defaultBaseURL ?? "") : explicitBase
        if descriptor.configKeysWritten.contains("model.base_url"), !effectiveBase.isEmpty {
            sets.append(.set(key: "model.base_url", value: effectiveBase))
            writtenKeys.insert("model.base_url")
        }

        if descriptor.supportsAPIKey {
            let key = trimmed(selection.apiKey)
            if !key.isEmpty {
                sets.append(.set(key: "model.api_key", value: key))
                writtenKeys.insert("model.api_key")
            }
        }

        if descriptor.supportsAPIMode {
            // Mirror the runtime's own normalization (strip().lower())
            // so what we write is byte-for-byte what the reader honors.
            let mode = trimmed(selection.apiMode).lowercased()
            if !mode.isEmpty, LocalModelProvider.isValidAPIMode(mode) {
                sets.append(.set(key: "model.api_mode", value: mode))
                writtenKeys.insert("model.api_mode")
            }
        }

        // Clears FIRST (per the audit rule), then provider/model, then
        // the managed-key sets.
        var ops: [Operation] = localManagedKeys
            .filter { !writtenKeys.contains($0) }
            .map { .clear(key: $0) }
        ops.append(.set(key: "model.provider", value: descriptor.providerID))
        let model = trimmed(selection.modelID)
        if model.isEmpty {
            // Custom endpoint on loopback: an EMPTY model.default is what
            // enables Hermes's single-loaded-model auto-detect
            // (runtime_provider.py:206-213) — a stale value would pin it.
            ops.append(.clear(key: "model.default"))
        } else {
            ops.append(.set(key: "model.default", value: model))
        }
        ops += sets
        return ops
    }

    // MARK: - Remote selection

    /// Ordered write plan for a remote/catalog selection. Clears the
    /// local-managed keys only when the provider actually changes —
    /// re-picking a model within the same provider must not destroy a
    /// hand-maintained `model.base_url` (e.g. a MiniMax China endpoint,
    /// honored when `model.provider` matches — issue #6039 class).
    ///
    /// Mirrors the empty-value semantics of
    /// `HermesFileService.setModelAndProvider`: an empty provider keeps
    /// the current one (custom entry without a prefix), an empty model
    /// skips the `model.default` write (subscription providers let
    /// Hermes pick its own default).
    public static func operations(
        selectingRemoteModel model: String,
        provider: String,
        currentProvider: String
    ) -> [Operation] {
        let newProvider = trimmed(provider)
        let newModel = trimmed(model)
        var ops: [Operation] = []
        if !newProvider.isEmpty,
           normalizedProvider(newProvider) != normalizedProvider(currentProvider) {
            ops += localManagedKeys.map { .clear(key: $0) }
        }
        if !newProvider.isEmpty {
            ops.append(.set(key: "model.provider", value: newProvider))
        }
        if !newModel.isEmpty {
            ops.append(.set(key: "model.default", value: newModel))
        }
        return ops
    }

    // MARK: - Helpers

    /// Case/whitespace-insensitive provider identity, with the local
    /// table's runtime spelling aliases folded in — `llama.cpp` →
    /// `llamacpp` so a CLI-written alias doesn't read as a "switch".
    private static func normalizedProvider(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return LocalModelProvider.descriptor(for: t)?.providerID ?? t
    }

    private static func trimmed(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
