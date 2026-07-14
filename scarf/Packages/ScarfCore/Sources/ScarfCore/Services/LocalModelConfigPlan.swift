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
/// - `model.context_length` (the fourth managed key — dogfood round 2's
///   stale-override trap; the picker never WRITES it, only clears it) is
///   the one key whose unset value is `"0"`, not `""`: the reader does
///   `int(value)` on any present value (agent_init.py:1469-1490), so a
///   cleared-to-`""` key WARNS on every startup ("Invalid
///   model.context_length: ''"), while `0` parses silently and every
///   consumer treats non-positive as unset — `config_context_length > 0`
///   gates the override in `get_model_context_length` (model_metadata.py
///   step 0, pinned upstream by test_config_context_length_zero_is_
///   ignored) and the LM Studio preloader does `max(value or 0,
///   MINIMUM_CONTEXT_LENGTH)` (run_agent.py:682). Verified against
///   `~/.hermes/hermes-agent` @ v0.17.0.
///
/// **Crash-safe ordering** (T4 audit). Each operation is its own
/// `hermes config set` process, and the executor aborts on the first
/// failure — so every PREFIX of the plan is a config state some chat
/// may actually run against. The one state that must never exist is
/// `model.provider = <local alias>` with no/empty `model.base_url`:
/// the runtime then falls through to OpenRouter SILENTLY
/// (runtime_provider.py:970-976), sending a local-intent prompt to a
/// cloud endpoint. Hence:
/// - Local saves write `model.provider` LAST — base_url/key/mode and
///   model.default are all in place before the provider commits. The
///   pre-commit writes are inert under the old provider (every reader
///   path gates `model.base_url`/`model.api_mode` on the configured
///   provider matching the one being resolved — the anthropic branch,
///   the api-key branch at :1799-1803, and
///   `_config_base_url_trustworthy_for_bare_custom`).
/// - Remote saves write `model.provider` + `model.default` FIRST and
///   clear the stale local keys after. The worst mid-sequence state is
///   the new cloud provider briefly honoring a stale local base_url —
///   a loud connection failure against the user's own old endpoint,
///   never a silent reroute.
public enum LocalModelConfigPlan {
    /// One `hermes config set` invocation. `clear` is `set <key>
    /// <unset-value>` — `""` for the string keys, `"0"` for
    /// `model.context_length` (see the type comment for the reader
    /// verification of both).
    public enum Operation: Equatable, Sendable {
        case set(key: String, value: String)
        case clear(key: String)

        /// argv for `runHermesCLI` / `context.runHermes`.
        public var cliArguments: [String] {
            switch self {
            case .set(let key, let value): return ["config", "set", key, value]
            case .clear(let key):          return ["config", "set", key, LocalModelConfigPlan.unsetValue(for: key)]
            }
        }
    }

    /// The value that reads as "unset" for a managed key. `""` for the
    /// string keys (reader-verified silent); `"0"` for
    /// model.context_length, where `""` would warn on every Hermes
    /// startup but a non-positive int is silently ignored by every
    /// consumer (type comment has the line-level receipts).
    static func unsetValue(for key: String) -> String {
        key == "model.context_length" ? "0" : ""
    }

    /// Union of the keys any local descriptor may manage beyond
    /// model.default/model.provider — the clear-on-switch set. Ordered
    /// (not a Set) so plans are deterministic and testable.
    /// `model.context_length` is the clear-ONLY member: no descriptor
    /// ever writes it (the picker has no context-override UI — the
    /// override is a runtime trap for sub-64K models anyway), but a
    /// CLI-set stale value must not survive a provider switch, where it
    /// would mask Hermes's context preflight for the next model.
    public static let localManagedKeys: [String] = [
        "model.base_url", "model.api_key", "model.api_mode", "model.context_length",
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

        // Clears first (the T1 audit rule: a switch must scrub every
        // unwritten managed key), then the managed-key sets and
        // model.default, and `model.provider` LAST as the commit point —
        // see the type comment's crash-safe-ordering rationale. No
        // prefix of this plan ever reads as `provider: <local alias>`
        // without its base_url (the silent-OpenRouter state).
        var ops: [Operation] = localManagedKeys
            .filter { !writtenKeys.contains($0) }
            .map { .clear(key: $0) }
        ops += sets
        let model = trimmed(selection.modelID)
        if model.isEmpty {
            // Custom endpoint on loopback: an EMPTY model.default is what
            // enables Hermes's single-loaded-model auto-detect
            // (runtime_provider.py:206-213) — a stale value would pin it.
            ops.append(.clear(key: "model.default"))
        } else {
            ops.append(.set(key: "model.default", value: model))
        }
        ops.append(.set(key: "model.provider", value: descriptor.providerID))
        return ops
    }

    // MARK: - Remote selection

    /// Ordered write plan for a remote/catalog selection. Clears the
    /// local-managed keys only when the provider actually changes —
    /// re-picking a model within the same provider must not destroy a
    /// hand-maintained `model.base_url` (e.g. a MiniMax China endpoint,
    /// honored when `model.provider` matches — issue #6039 class).
    ///
    /// The clears trail the provider/model writes (crash-safe ordering,
    /// see the type comment): clearing `model.base_url` while
    /// `model.provider` is still a local alias would leave the
    /// silent-OpenRouter-fallthrough state if the sequence aborts
    /// between the two.
    ///
    /// Empty-value semantics: an empty provider keeps the current one
    /// (custom catalog entry without a prefix) and never clears — no
    /// switch happened. An empty model CLEARS `model.default`
    /// (subscription providers — Nous — advertise "leave blank for the
    /// provider default"; skipping the write would leave the previous
    /// provider's model pinned, exactly the staleness this plan exists
    /// to prevent). Empty is reader-verified unset:
    /// `(cfg.get("default") or "").strip()` (runtime_provider.py:206).
    ///
    /// `currentBaseURL` / `currentAPIKey` / `currentAPIMode` /
    /// `currentContextLength` are the config's current values of the
    /// local-managed keys, when the caller knows them: a key that is
    /// already empty/absent is skipped rather than re-cleared, so a user
    /// who never touched a local provider gets exactly the classic
    /// two-op `[set provider, set default]` write — no junk empty keys,
    /// no extra SSH round-trips. Pass nil when unknown → conservative
    /// unconditional clears. For `model.context_length`, "already unset"
    /// additionally means any non-positive integer — `"0"` is this
    /// plan's own unset value and the reader ignores it, so re-clearing
    /// would churn forever.
    public static func operations(
        selectingRemoteModel model: String,
        provider: String,
        currentProvider: String,
        currentBaseURL: String? = nil,
        currentAPIKey: String? = nil,
        currentAPIMode: String? = nil,
        currentContextLength: String? = nil
    ) -> [Operation] {
        let newProvider = trimmed(provider)
        let newModel = trimmed(model)
        guard !newProvider.isEmpty || !newModel.isEmpty else { return [] }
        var ops: [Operation] = []
        if !newProvider.isEmpty {
            ops.append(.set(key: "model.provider", value: newProvider))
        }
        if !newModel.isEmpty {
            ops.append(.set(key: "model.default", value: newModel))
        } else if !newProvider.isEmpty {
            ops.append(.clear(key: "model.default"))
        }
        if !newProvider.isEmpty,
           normalizedProvider(newProvider) != normalizedProvider(currentProvider) {
            let current: [String: String?] = [
                "model.base_url": currentBaseURL,
                "model.api_key": currentAPIKey,
                "model.api_mode": currentAPIMode,
                "model.context_length": currentContextLength,
            ]
            ops += localManagedKeys
                .filter { key in
                    // nil = unknown → clear; known-unset → skip.
                    guard let value = current[key] ?? nil else { return true }
                    return !readsAsUnset(trimmed(value), for: key)
                }
                .map { .clear(key: $0) }
        }
        return ops
    }

    /// Whether a KNOWN current value already reads as unset to the
    /// Hermes runtime, so re-clearing it is pure churn. Empty string for
    /// every key; for model.context_length also any integer <= 0 (the
    /// reader's own `> 0` gate — and `"0"` is what our clear writes).
    /// Note the asymmetry with garbage: a non-integer like `"256K"` is
    /// NOT unset here even though the reader ignores it, because it
    /// warns on every startup — clearing it to `0` silences that.
    private static func readsAsUnset(_ value: String, for key: String) -> Bool {
        if value.isEmpty { return true }
        if key == "model.context_length", let n = Int(value), n <= 0 { return true }
        return false
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
