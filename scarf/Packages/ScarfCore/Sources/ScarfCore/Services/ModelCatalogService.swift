import Foundation
#if canImport(os)
import os
#endif

/// A single model from the models.dev catalog shipped with hermes.
public struct HermesModelInfo: Sendable, Identifiable, Hashable {
    public var id: String { providerID + ":" + modelID }

    public let providerID: String
    public let providerName: String
    public let modelID: String
    public let modelName: String
    public let contextWindow: Int?
    public let maxOutput: Int?
    public let costInput: Double?      // USD per 1M input tokens
    public let costOutput: Double?     // USD per 1M output tokens
    public let reasoning: Bool
    public let toolCall: Bool
    public let releaseDate: String?

    /// Display-friendly cost string, or nil if cost is unknown.

    public init(
        providerID: String,
        providerName: String,
        modelID: String,
        modelName: String,
        contextWindow: Int?,
        maxOutput: Int?,
        costInput: Double?,
        costOutput: Double?,
        reasoning: Bool,
        toolCall: Bool,
        releaseDate: String?
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.modelName = modelName
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
        self.costInput = costInput
        self.costOutput = costOutput
        self.reasoning = reasoning
        self.toolCall = toolCall
        self.releaseDate = releaseDate
    }
    public var costDisplay: String? {
        guard let input = costInput, let output = costOutput else { return nil }
        let currency = FloatingPointFormatStyle<Double>.Currency.currency(code: "USD").precision(.fractionLength(2))
        return "\(input.formatted(currency)) / \(output.formatted(currency))"
    }

    /// Display-friendly context window ("200K", "1M", etc.).
    public var contextDisplay: String? {
        guard let ctx = contextWindow else { return nil }
        if ctx >= 1_000_000 { return "\(ctx / 1_000_000)M" }
        if ctx >= 1_000 { return "\(ctx / 1_000)K" }
        return "\(ctx)"
    }
}

/// Provider summary — one row in the left column of the picker.
public struct HermesProviderInfo: Sendable, Identifiable, Hashable {
    public var id: String { providerID }

    public let providerID: String
    public let providerName: String
    public let envVars: [String]       // e.g. ["ANTHROPIC_API_KEY"]
    public let docURL: String?
    public let modelCount: Int
    /// True when this provider is surfaced only by the Hermes overlay list —
    /// i.e. no entry in `models_dev_cache.json`. The picker renders a
    /// different right-column affordance (subscription CTA or free-form
    /// model entry).
    public let isOverlay: Bool
    /// True for providers whose tool access is subscription-gated rather
    /// than BYO API key. Nous Portal is the only such provider as of
    /// hermes-agent v0.10.0.
    public let subscriptionGated: Bool

    public init(
        providerID: String,
        providerName: String,
        envVars: [String],
        docURL: String?,
        modelCount: Int,
        isOverlay: Bool = false,
        subscriptionGated: Bool = false
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.envVars = envVars
        self.docURL = docURL
        self.modelCount = modelCount
        self.isOverlay = isOverlay
        self.subscriptionGated = subscriptionGated
    }
}

/// Reads the models.dev catalog that hermes caches at
/// `~/.hermes/models_dev_cache.json`. Offline-capable, fast enough to read per
/// call (~1500 models across ~110 providers).
///
/// We decode a trimmed subset so unknown fields don't break loading. Every
/// field we care about is optional on disk — providers may omit cost, context
/// limits, etc.
public struct ModelCatalogService: Sendable {
    #if canImport(os)
    private let logger = Logger(subsystem: "com.scarf", category: "ModelCatalogService")
    #endif
    public let path: String
    public let transport: any ServerTransport

    public nonisolated init(context: ServerContext = .local) {
        self.path = context.paths.home + "/models_dev_cache.json"
        self.transport = context.makeTransport()
    }

    /// Escape hatch for tests.
    public init(path: String) {
        self.path = path
        self.transport = LocalTransport()
    }

    /// All providers, sorted with subscription-gated providers first (Nous
    /// Portal), then alphabetical by display name. Merges the models.dev
    /// cache with `Self.overlayOnlyProviders` so Hermes-injected providers
    /// (Nous Portal, OpenAI Codex, …) appear in the picker even when
    /// they're absent from `models_dev_cache.json`.
    public func loadProviders() -> [HermesProviderInfo] {
        let catalog = loadCatalog() ?? [:]
        var byID: [String: HermesProviderInfo] = [:]
        for (id, p) in catalog {
            let resolvedName = Self.providerDisplayNameOverrides[id] ?? p.name ?? id
            byID[id] = HermesProviderInfo(
                providerID: id,
                providerName: resolvedName,
                envVars: p.env ?? [],
                docURL: p.doc,
                modelCount: p.models?.count ?? 0,
                isOverlay: false,
                subscriptionGated: false
            )
        }
        for (id, overlay) in Self.overlayOnlyProviders where byID[id] == nil {
            let resolvedName = Self.providerDisplayNameOverrides[id] ?? overlay.displayName
            byID[id] = HermesProviderInfo(
                providerID: id,
                providerName: resolvedName,
                envVars: [],
                docURL: overlay.docURL,
                modelCount: 0,
                isOverlay: true,
                subscriptionGated: overlay.subscriptionGated
            )
        }
        return byID.values.sorted { lhs, rhs in
            // Subscription-gated first (Nous Portal).
            if lhs.subscriptionGated != rhs.subscriptionGated {
                return lhs.subscriptionGated
            }
            // Demoted last (Vercel AI Gateway, per Hermes v0.13). The
            // axis is unconditional — we don't gate on the Hermes
            // version because "Vercel mid-alphabet on v0.12, bottom on
            // v0.13" would be more confusing than the consistent
            // "Vercel last" treatment for everyone.
            let lDemoted = Self.demotedProviders.contains(lhs.providerID)
            let rDemoted = Self.demotedProviders.contains(rhs.providerID)
            if lDemoted != rDemoted {
                return !lDemoted
            }
            return lhs.providerName.localizedCaseInsensitiveCompare(rhs.providerName) == .orderedAscending
        }
    }

    /// Overlay metadata for a provider that isn't in the models.dev catalog —
    /// Scarf needs to surface these so the picker matches `hermes model` on
    /// the CLI.
    public func overlayMetadata(for providerID: String) -> HermesProviderOverlay? {
        Self.overlayOnlyProviders[providerID]
    }

    /// Async wrapper around `loadProviders()` for use from MainActor view
    /// code. The sync method does a transport-backed file read that on a
    /// remote SSH context can take 1–2 minutes (ControlMaster setup +
    /// pulling the multi-megabyte models.dev JSON), and on local contexts
    /// still parses ~1500 models — both unsuitable for the main thread.
    /// Issue #59. Existing call sites (tests, any non-View consumers)
    /// can keep using the sync method.
    public nonisolated func loadProvidersAsync() async -> [HermesProviderInfo] {
        await Task.detached { [self] in
            let providers = ScarfMon.measure(.diskIO, "modelCatalog.loadProviders") {
                self.loadProviders()
            }
            ScarfMon.event(.diskIO, "modelCatalog.providers.count", count: providers.count)
            return providers
        }.value
    }

    /// Models for one provider, sorted by release date (newest first), then name.
    public func loadModels(for providerID: String) -> [HermesModelInfo] {
        guard let catalog = loadCatalog(), let provider = catalog[providerID] else { return [] }
        let providerName = Self.providerDisplayNameOverrides[providerID]
            ?? provider.name
            ?? providerID
        let models = (provider.models ?? [:]).map { (id, m) in
            HermesModelInfo(
                providerID: providerID,
                providerName: providerName,
                modelID: id,
                modelName: m.name ?? id,
                contextWindow: m.limit?.context,
                maxOutput: m.limit?.output,
                costInput: m.cost?.input,
                costOutput: m.cost?.output,
                reasoning: m.reasoning ?? false,
                toolCall: m.tool_call ?? false,
                releaseDate: m.release_date
            )
        }
        return models.sorted { lhs, rhs in
            // Newest-first by release date if both are known; otherwise fall
            // back to alphabetical on display name.
            if let lDate = lhs.releaseDate, let rDate = rhs.releaseDate, lDate != rDate {
                return lDate > rDate
            }
            return lhs.modelName.localizedCaseInsensitiveCompare(rhs.modelName) == .orderedAscending
        }
    }

    /// Async wrapper around `loadModels(for:)`. Same rationale as
    /// `loadProvidersAsync()` — the View call site that fires on every
    /// provider-switch click in the picker sheet was reading the catalog
    /// synchronously on the MainActor, freezing the UI on remote contexts.
    /// Issue #59.
    public nonisolated func loadModelsAsync(for providerID: String) async -> [HermesModelInfo] {
        await Task.detached { [self] in
            let models = ScarfMon.measure(.diskIO, "modelCatalog.loadModels") {
                self.loadModels(for: providerID)
            }
            ScarfMon.event(.diskIO, "modelCatalog.models.count", count: models.count)
            return models
        }.value
    }

    /// Find the provider that ships a given model ID. Useful for auto-syncing
    /// provider when the user picks a model from a flat list or types one in.
    public func provider(for modelID: String) -> HermesProviderInfo? {
        guard let catalog = loadCatalog() else { return nil }
        for (providerID, p) in catalog {
            // Resolve any model-rename alias for this provider before
            // checking the catalog — see `modelAliases` for rationale.
            let resolved = resolveModelAlias(providerID: providerID, modelID: modelID)
            if p.models?[resolved] != nil {
                return HermesProviderInfo(
                    providerID: providerID,
                    providerName: p.name ?? providerID,
                    envVars: p.env ?? [],
                    docURL: p.doc,
                    modelCount: p.models?.count ?? 0,
                    isOverlay: false,
                    subscriptionGated: false
                )
            }
        }
        // Handle provider-prefixed IDs like "openai/gpt-4o" — look up the
        // prefix before the slash.
        if let slash = modelID.firstIndex(of: "/") {
            let prefix = String(modelID[modelID.startIndex..<slash])
            if let p = catalog[prefix] {
                return HermesProviderInfo(
                    providerID: prefix,
                    providerName: p.name ?? prefix,
                    envVars: p.env ?? [],
                    docURL: p.doc,
                    modelCount: p.models?.count ?? 0,
                    isOverlay: false,
                    subscriptionGated: false
                )
            }
        }
        return nil
    }

    /// Look up a provider by ID, falling back to overlays when the cache has
    /// no entry. Use this when resolving a stored `model.provider` to display
    /// metadata — `nous` and other overlay-only IDs never appear in the
    /// cache, so a plain catalog lookup returns nil for them.
    public func providerByID(_ providerID: String) -> HermesProviderInfo? {
        if let catalog = loadCatalog(), let p = catalog[providerID] {
            return HermesProviderInfo(
                providerID: providerID,
                providerName: p.name ?? providerID,
                envVars: p.env ?? [],
                docURL: p.doc,
                modelCount: p.models?.count ?? 0,
                isOverlay: false,
                subscriptionGated: false
            )
        }
        if let overlay = Self.overlayOnlyProviders[providerID] {
            return HermesProviderInfo(
                providerID: providerID,
                providerName: overlay.displayName,
                envVars: [],
                docURL: overlay.docURL,
                modelCount: 0,
                isOverlay: true,
                subscriptionGated: overlay.subscriptionGated
            )
        }
        return nil
    }

    /// Look up a specific model by provider + ID. Returns nil if not in the
    /// catalog (e.g., free-typed custom model).
    public func model(providerID: String, modelID: String) -> HermesModelInfo? {
        // Resolve any model-rename alias for this provider before
        // checking the catalog — see `modelAliases` for rationale.
        let resolved = resolveModelAlias(providerID: providerID, modelID: modelID)
        guard let catalog = loadCatalog(),
              let provider = catalog[providerID],
              let raw = provider.models?[resolved] else { return nil }
        return HermesModelInfo(
            providerID: providerID,
            providerName: provider.name ?? providerID,
            modelID: resolved,
            modelName: raw.name ?? resolved,
            contextWindow: raw.limit?.context,
            maxOutput: raw.limit?.output,
            costInput: raw.cost?.input,
            costOutput: raw.cost?.output,
            reasoning: raw.reasoning ?? false,
            toolCall: raw.tool_call ?? false,
            releaseDate: raw.release_date
        )
    }

    // MARK: - Vision capability (t-31img)

    /// Whether a model can natively see image content. Three-state on
    /// purpose: local models (Ollama tags, custom endpoints) and
    /// overlay-only providers never appear in `models_dev_cache.json`,
    /// and "we don't know" must NOT render as "can't see images" —
    /// `llama3.2-vision` exists. The composer heads-up only fires on a
    /// confident `.no`.
    public enum VisionCapability: String, Sendable, Equatable {
        case yes
        case no
        case unknown
    }

    /// Answer "can (provider, model) see images natively?" from the
    /// models.dev cache.
    ///
    /// Semantics pin Hermes's own `agent/models_dev.py` parse (which
    /// `agent/image_routing.py::decide_image_input_mode` consumes):
    /// prefer `modalities.input` containing `"image"` when the array is
    /// present; fall back to the older `attachment` bool only when
    /// modalities are absent. A cache entry with neither field is a
    /// confident `.no` — Hermes coerces the missing `attachment` to
    /// False and routes to the lossy text pipeline. A model or provider
    /// absent from the cache entirely is `.unknown`.
    ///
    /// Results are memoized per (path, provider, model) so composer
    /// state changes never re-parse the multi-megabyte catalog. The
    /// memo intentionally ignores later rewrites of the cache file —
    /// vision capability for a fixed (provider, model) doesn't flip
    /// within an app run.
    public func visionCapability(providerID: String, modelID: String) -> VisionCapability {
        let canonical = Self.modelsDevProviderKey(for: providerID)
        let trimmedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty, !trimmedModel.isEmpty else { return .unknown }

        let cacheKey = "\(path)|\(canonical)|\(trimmedModel)"
        Self.visionCacheLock.lock()
        let cached = Self.visionCache[cacheKey]
        Self.visionCacheLock.unlock()
        if let cached { return cached }

        let result = ScarfMon.measure(.diskIO, "modelCatalog.visionCapability") {
            uncachedVisionCapability(canonicalProviderID: canonical, modelID: trimmedModel)
        }
        Self.visionCacheLock.lock()
        Self.visionCache[cacheKey] = result
        Self.visionCacheLock.unlock()
        return result
    }

    private func uncachedVisionCapability(
        canonicalProviderID canonical: String, modelID: String
    ) -> VisionCapability {
        guard let catalog = loadCatalog(), let provider = catalog[canonical] else {
            // Provider not mirrored to models.dev (local endpoints,
            // overlay-only providers, missing cache file) — no signal.
            return .unknown
        }
        let resolved = resolveModelAlias(providerID: canonical, modelID: modelID)
        if let entry = provider.models?[resolved] {
            return Self.visionCapability(of: entry)
        }
        // Stored model IDs sometimes carry a redundant provider prefix
        // (`anthropic/claude-…` under provider `anthropic`, or a preset's
        // `openrouter/anthropic/claude-…`). If the prefix canonicalizes
        // to this same provider, retry with it stripped.
        if let slash = resolved.firstIndex(of: "/") {
            let prefix = String(resolved[..<slash])
            let bare = String(resolved[resolved.index(after: slash)...])
            if !bare.isEmpty, Self.modelsDevProviderKey(for: prefix) == canonical,
               let entry = provider.models?[resolveModelAlias(providerID: canonical, modelID: bare)] {
                return Self.visionCapability(of: entry)
            }
        }
        // In the catalog's provider list but not its model list — a
        // free-typed or newer-than-cache model. Not confident either way.
        return .unknown
    }

    private static func visionCapability(of entry: ModelEntry) -> VisionCapability {
        if let input = entry.modalities?.input {
            return input.contains("image") ? .yes : .no
        }
        if let attachment = entry.attachment {
            return attachment ? .yes : .no
        }
        // Neither field: Hermes's parser coerces this to
        // supports_vision=False, so the text pipeline WILL fire.
        return .no
    }

    /// Memoized lookups. `nonisolated(unsafe)` + lock matches the
    /// `ScarfMon` static-state pattern under the package's Swift 5
    /// language mode.
    private static let visionCacheLock = NSLock()
    nonisolated(unsafe) private static var visionCache: [String: VisionCapability] = [:]

    /// Map a Hermes provider ID onto its models.dev cache key for
    /// capability lookups — a Scarf mirror of the entries in Hermes's
    /// `agent/models_dev.py` `PROVIDER_TO_MODELS_DEV` that diverge from
    /// `canonicalProviderID(_:)`. Three divergence classes matter:
    ///
    /// - Bare `openai` aliases to `openrouter` for *inference routing*
    ///   (providers.py ALIASES), but Hermes resolves its *capability
    ///   metadata* against the models.dev `openai` entry — where
    ///   `gpt-4o` etc. actually live.
    /// - OAuth/transport variants (`xai-oauth`, `qwen-oauth`,
    ///   `minimax-oauth`, `openai-codex`) serve the same catalogs as
    ///   their base providers.
    /// - Providers whose models.dev cache key differs from the Hermes
    ///   wire ID: `novita` → `novita-ai`, `fireworks` → `fireworks-ai`
    ///   (both verified against the live cache, 2026-07).
    ///
    /// `openai-api` is a deliberate Scarf EXTENSION, not a mirror:
    /// Hermes's map has no `openai-api` entry, so on that provider
    /// Hermes resolves no capability metadata at all and auto-mode
    /// always routes images through the text pipeline. Resolving it
    /// against the models.dev `openai` catalog keeps the composer
    /// heads-up truthful for text-only models (the image WILL go
    /// through the lossy fallback); the cost is a suppressed heads-up
    /// for vision models, never a false one.
    ///
    /// Providers absent from both this map and the catalog resolve to
    /// `.unknown` downstream, which is the safe default. Reconcile on
    /// Hermes bumps alongside the other provider tables here.
    static func modelsDevProviderKey(for providerID: String) -> String {
        let key = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = capabilityProviderOverrides[key] { return mapped }
        // Hermes normalizes aliases (providers.py ALIASES) BEFORE its
        // PROVIDER_TO_MODELS_DEV lookup, so alias spellings must land
        // on the same models.dev key their canonical form does — e.g.
        // `grok-oauth` → `xai-oauth` → `xai`, and `novita-ai` →
        // `novita` → `novita-ai`.
        let canonical = canonicalProviderID(key)
        return capabilityProviderOverrides[canonical] ?? canonical
    }

    private static let capabilityProviderOverrides: [String: String] = [
        "openai": "openai",
        "openai-api": "openai",  // Scarf extension — see doc comment above.
        "openai-codex": "openai",
        "xai-oauth": "xai",
        "qwen-oauth": "alibaba",
        "minimax-oauth": "minimax",
        "gemini": "google",
        // models.dev cache keys that differ from the Hermes wire ID
        // (PROVIDER_TO_MODELS_DEV: novita → novita-ai, fireworks →
        // fireworks-ai).
        "novita": "novita-ai",
        "fireworks": "fireworks-ai",
    ]

    /// Result of validating a user-entered model ID against the
    /// selected provider. See `validateModel(_:for:)`.
    public enum ModelValidation: Equatable, Sendable {
        /// Accept the save — the model is in the provider's catalog
        /// (or the provider is overlay-only, where a free-form model
        /// name is the normal path).
        case valid
        /// Accept with a warning — we don't have a catalog entry for
        /// the provider at all, so can't check. Usually means the
        /// user is offline or the local cache is missing. Save but
        /// surface an advisory.
        case unknownProvider(providerID: String)
        /// Block the save — the provider exists but doesn't serve
        /// that model. Includes a handful of close-by suggestions
        /// for the UI to render as "did you mean…".
        case invalid(providerName: String, suggestions: [String])
    }

    /// Validate `modelID` against `providerID` before persisting it as
    /// `model.default` in `config.yaml`. Centralises the logic so both
    /// Mac's ModelPickerSheet and ScarfGo's scoped settings editor
    /// (Phase 4.3) use the same check. Pass-1 found that you could
    /// save `claude-haiku-4-5-20251001` under provider `nous` —
    /// Nous's catalog has no such model and Hermes later failed with
    /// HTTP 404 at runtime. Catch that at save time, not 6 hours later.
    public func validateModel(_ modelID: String, for providerID: String) -> ModelValidation {
        ScarfMon.measure(.diskIO, "modelCatalog.validateModel") {
            let raw = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                return .invalid(providerName: providerID, suggestions: [])
            }
            // Resolve any model-rename alias before lookup so configs
            // referencing a deprecated ID (e.g. `x-ai/grok-4.20-beta`)
            // validate against the canonical successor.
            let trimmed = resolveModelAlias(providerID: providerID, modelID: raw)

            // Overlay-only providers (Nous Portal, OpenAI Codex, Qwen
            // OAuth, …) serve their own catalogs that aren't mirrored to
            // models.dev, so we don't have a reliable way to check model
            // IDs locally. Treat any non-empty value as provisionally
            // valid — the worst case is the runtime 404 we hit in pass-1,
            // but the UI has the error banner now (M7 #2) to surface that
            // cleanly.
            //
            // Exception: if an overlay-only provider DOES appear in the
            // models.dev cache (unlikely but possible as catalogs evolve),
            // we fall through to the real check below.
            let models = loadModels(for: providerID)
            if models.isEmpty {
                if Self.overlayOnlyProviders[providerID] != nil {
                    return .valid
                }
                return .unknownProvider(providerID: providerID)
            }

            if models.contains(where: { $0.modelID == trimmed }) {
                return .valid
            }

            // No exact match — offer the closest names (by prefix) as
            // suggestions. Up to 5, ordered by release date (newest
            // first — already the sort order of loadModels).
            let lowerTrimmed = trimmed.lowercased()
            let byPrefix = models
                .filter { $0.modelID.lowercased().hasPrefix(String(lowerTrimmed.prefix(3))) }
                .prefix(5)
                .map(\.modelID)
            let suggestions = byPrefix.isEmpty
                ? Array(models.prefix(5).map(\.modelID))
                : Array(byPrefix)
            let providerName = providerByID(providerID)?.providerName ?? providerID
            return .invalid(providerName: providerName, suggestions: suggestions)
        }
    }

    // MARK: - Decoding

    private func loadCatalog() -> [String: ProviderEntry]? {
        guard let data = try? transport.readFile(path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode([String: ProviderEntry].self, from: data)
        } catch {
            #if canImport(os)
            logger.error("Failed to decode models_dev_cache.json: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // Trimmed representations — we decode a subset of fields and tolerate
    // anything new hermes adds later. `snake_case` field names match the file.
    private struct ProviderEntry: Decodable {
        let id: String?
        let name: String?
        let env: [String]?
        let doc: String?
        let models: [String: ModelEntry]?
    }

    private struct ModelEntry: Decodable {
        let name: String?
        let reasoning: Bool?
        let tool_call: Bool?
        let release_date: String?
        let cost: CostEntry?
        let limit: LimitEntry?
        /// Legacy vision flag ("supports image/file attachments"). The
        /// 2026-07 cache carries `modalities` on every entry, but Hermes
        /// still honors this as the fallback — mirror that.
        let attachment: Bool?
        let modalities: ModalitiesEntry?
    }

    private struct ModalitiesEntry: Decodable {
        let input: [String]?
        let output: [String]?
    }

    private struct CostEntry: Decodable {
        let input: Double?
        let output: Double?
    }

    private struct LimitEntry: Decodable {
        let context: Int?
        let output: Int?
    }

    // MARK: - Model aliases (model rename resolution)

    /// Hermes deprecates model IDs across releases. When a stored config
    /// `model.default` references a deprecated ID, resolve to its
    /// canonical successor. Lossless — we never rewrite the user's
    /// `config.yaml`; the alias just lets `validateModel` /
    /// `model(providerID:modelID:)` / `provider(for:)` succeed against
    /// the new ID.
    ///
    /// Keys are slash-joined `providerID/modelID` to disambiguate
    /// across providers — even if `vercel` later adds a `grok-4.20-beta`
    /// alias on its own, the openrouter resolution shouldn't fire.
    /// Values are the bare resolved model ID (no provider prefix).
    ///
    /// **Schema is Swift-primary.** Mirror new entries into Hermes's
    /// upstream deprecation map in `hermes_cli/providers.py` if/when
    /// upstream tracks renames in code (today they're release-notes
    /// only).
    public static let modelAliases: [String: String] = [
        // v0.13: x-ai dropped the `-beta` suffix once Grok 4.20 GA'd.
        // The model is the same one served at the same OpenRouter slot;
        // only the marketing identifier changed.
        "openrouter/x-ai/grok-4.20-beta": "x-ai/grok-4.20",
        "xai/grok-4.20-beta": "grok-4.20",

        // v0.20: DeepSeek retired `deepseek-chat`/`deepseek-reasoner` on
        // 2026-07-24; Hermes's model_normalize.py wire-remaps both to
        // `deepseek-v4-flash` (chat = non-thinking, reasoner = thinking —
        // thinking mode is controlled separately via extra_body.thinking).
        "deepseek/deepseek-chat": "deepseek-v4-flash",
        "deepseek/deepseek-reasoner": "deepseek-v4-flash",

        // v0.15: xAI retired a swath of Grok models on May 15. Mirrors
        // `hermes_cli/xai_retirement.py` `_RETIRED_MODELS` — all roll to
        // `grok-4.3` except the image model. Hermes pairs some with a
        // `reasoning_effort="none"` adjustment; that nuance is Hermes-side,
        // the id→id alias is all Scarf needs so a stored retired id still
        // resolves in the picker. Registered under both `xai` and
        // `xai-oauth` provider prefixes since users may have either.
        "xai/grok-4-0709": "grok-4.3",
        "xai/grok-4-fast-reasoning": "grok-4.3",
        "xai/grok-4-fast-non-reasoning": "grok-4.3",
        "xai/grok-4-1-fast-reasoning": "grok-4.3",
        "xai/grok-4-1-fast-non-reasoning": "grok-4.3",
        "xai/grok-code-fast-1": "grok-4.3",
        "xai/grok-3": "grok-4.3",
        "xai/grok-imagine-image-pro": "grok-imagine-image-quality",
        "xai-oauth/grok-4-0709": "grok-4.3",
        "xai-oauth/grok-4-fast-reasoning": "grok-4.3",
        "xai-oauth/grok-4-fast-non-reasoning": "grok-4.3",
        "xai-oauth/grok-4-1-fast-reasoning": "grok-4.3",
        "xai-oauth/grok-4-1-fast-non-reasoning": "grok-4.3",
        "xai-oauth/grok-code-fast-1": "grok-4.3",
        "xai-oauth/grok-3": "grok-4.3",
    ]

    /// Resolve a stored model identifier through the alias map. Returns
    /// the input unchanged when no alias exists. Pure function — used at
    /// read time everywhere a config'd model ID is rendered, validated,
    /// or sent to Hermes.
    public func resolveModelAlias(providerID: String, modelID: String) -> String {
        let composite = "\(providerID)/\(modelID)"
        return Self.modelAliases[composite] ?? modelID
    }

    // MARK: - Demoted providers (sort tail)

    /// Provider IDs that Hermes explicitly deprioritizes in the picker.
    /// `loadProviders()` sorts these to the tail of the list, after the
    /// alphabetical group. Mirrors Hermes's deprioritized-provider list
    /// in `hermes-agent/hermes_cli/providers.py`.
    ///
    /// Empty as of v0.15 — Vercel AI Gateway (the only prior entry) was
    /// removed from Hermes entirely, then reintroduced in v0.20 as the
    /// aggregator `vercel` (see `ModelPreflight.aggregatorProviders`)
    /// without being re-added here. Kept as a hook for future demotions.
    public static let demotedProviders: Set<String> = []

    // MARK: - Image-generation model allowlist (curated)

    /// Known image-generation models, used to pre-populate the
    /// `image_gen.model` picker on the Auxiliary tab. The list is
    /// curated — `models_dev_cache.json` doesn't tag image-capable
    /// models, so we maintain this by hand on Hermes version bumps.
    /// Always free-form-typeable on the picker too, so missing entries
    /// don't block users with non-listed image providers.
    ///
    /// Order: most-likely-to-be-chosen first.
    public static let imageGenModels: [HermesImageGenModel] = [
        .init(modelID: "openai/gpt-image-1", display: "OpenAI · gpt-image-1", providerHint: "openai"),
        .init(modelID: "google/imagen-4", display: "Google · Imagen 4", providerHint: "google-vertex"),
        .init(modelID: "google/imagen-3", display: "Google · Imagen 3", providerHint: "google-vertex"),
        .init(modelID: "stability/stable-image-ultra", display: "Stability · Stable Image Ultra", providerHint: "stability"),
        // v0.15: Krea joins image_gen as a built-in plugin (env KREA_API_KEY).
        .init(modelID: "krea-2-medium", display: "Krea · Krea 2 Medium", providerHint: "krea"),
        .init(modelID: "krea-2-large", display: "Krea · Krea 2 Large", providerHint: "krea"),
        .init(modelID: "fal-ai/flux-pro-1.1", display: "fal · FLUX 1.1 Pro", providerHint: "fal"),
        .init(modelID: "black-forest-labs/flux-1.1-pro", display: "Black Forest Labs · FLUX 1.1 Pro", providerHint: "openrouter"),
        .init(modelID: "openai/dall-e-3", display: "OpenAI · DALL·E 3", providerHint: "openai"),
    ]

    // MARK: - Hermes overlay providers

    /// The providers Hermes surfaces via `hermes model` that have no
    /// entry in `models_dev_cache.json` (models.dev doesn't mirror them).
    /// Mirrors the overlay-only subset of `HERMES_OVERLAYS` in
    /// `hermes-agent/hermes_cli/providers.py`. The other overlay entries
    /// already ship in the cache and only add augmentation (base-URL
    /// override, extra env vars) that Scarf doesn't currently display.
    ///
    /// Keep this in sync with the Python side on Hermes version bumps —
    /// see `ToolGatewayTests.v012OverlayProvidersCarryCorrectAuthTypes`
    /// for the auth-type lock-in.
    public static let overlayOnlyProviders: [String: HermesProviderOverlay] = [
        "nous": HermesProviderOverlay(
            displayName: "Nous Portal",
            baseURL: "https://inference-api.nousresearch.com/v1",
            authType: .oauthDeviceCode,
            subscriptionGated: true,
            docURL: "https://hermes-agent.nousresearch.com/docs/user-guide/setup/nous-portal"
        ),
        "openai-codex": HermesProviderOverlay(
            displayName: "ChatGPT or Codex Subscription",
            baseURL: "https://chatgpt.com/backend-api/codex",
            authType: .oauthExternal,
            subscriptionGated: false,
            docURL: nil
        ),
        // v0.15: OpenAI API as a first-class provider, distinct from the
        // Codex runtime above. Wire ID `openai-api` (HERMES_OVERLAYS) —
        // NOT bare `openai`, which Hermes aliases to `openrouter`.
        "openai-api": HermesProviderOverlay(
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            authType: .apiKey,
            subscriptionGated: false,
            docURL: nil
        ),
        "qwen-oauth": HermesProviderOverlay(
            displayName: "Qwen (OAuth)",
            baseURL: "https://portal.qwen.ai/v1",
            authType: .oauthExternal,
            subscriptionGated: false,
            docURL: nil
        ),
        // v0.18: MoA (Mixture of Agents) — a virtual local provider that
        // fans a prompt out to multiple advisor models and aggregates.
        // No credentials (auth_type "virtual"); model IDs are preset
        // names, not catalog slugs. Replaced `google-gemini-cli`, which
        // v0.18 removed in favor of `vertex` (Google Vertex AI,
        // OAuth2 SA/ADC) — an overlay-only provider, not models.dev-
        // backed (see the `vertex` entry below).
        "moa": HermesProviderOverlay(
            displayName: "Mixture of Agents",
            baseURL: "moa://local",
            authType: .virtual,
            subscriptionGated: false,
            docURL: nil
        ),
        "copilot-acp": HermesProviderOverlay(
            displayName: "GitHub Copilot ACP",
            baseURL: "acp://copilot",
            authType: .externalProcess,
            subscriptionGated: false,
            docURL: nil
        ),
        "arcee": HermesProviderOverlay(
            displayName: "Arcee",
            baseURL: "https://api.arcee.ai/api/v1",
            authType: .apiKey,
            subscriptionGated: false,
            docURL: nil
        ),
        // -- v0.12 additions ---------------------------------------------
        // Hermes v2026.4.30 added five overlay-only providers that
        // models.dev doesn't mirror. Provider IDs match HERMES_OVERLAYS
        // verbatim — drift here means the picker can't reach them.
        "gmi": HermesProviderOverlay(
            displayName: "GMI Cloud",
            baseURL: "https://api.gmi-serving.com/v1",
            authType: .apiKey,
            subscriptionGated: false,
            docURL: nil
        ),
        "azure-foundry": HermesProviderOverlay(
            displayName: "Azure AI Foundry",
            // Base URL is per-tenant — Hermes resolves it from the
            // AZURE_FOUNDRY_BASE_URL env var at runtime. Leave nil so the
            // settings UI shows "Tenant URL — set via env" instead of a
            // misleading default.
            baseURL: nil,
            authType: .apiKey,
            subscriptionGated: false,
            docURL: nil
        ),
        // Intentionally dormant on current caches: models.dev has since
        // absorbed lmstudio, so loadProviders() prefers the catalog entry
        // and this one only merges on hosts whose cache predates it
        // (Scarf supports Hermes back to v0.6). Hermes v0.16 still ships
        // it in HERMES_OVERLAYS; keep parity. check-hermes-tables.py
        // WARNs on it by design.
        "lmstudio": HermesProviderOverlay(
            displayName: "LM Studio",
            // v0.12 promotes LM Studio from custom-endpoint alias to a
            // first-class provider. 1234 is the LM Studio default port;
            // users with a non-default port set LM_BASE_URL.
            baseURL: "http://127.0.0.1:1234/v1",
            authType: .apiKey,
            subscriptionGated: false,
            docURL: nil
        ),
        "minimax-oauth": HermesProviderOverlay(
            displayName: "MiniMax (OAuth)",
            baseURL: "https://api.minimax.io/anthropic",
            authType: .oauthExternal,
            subscriptionGated: false,
            docURL: nil
        ),
        // Intentionally dormant on current caches — same story as
        // lmstudio above: models.dev absorbed it; kept for stale-cache
        // hosts and HERMES_OVERLAYS parity.
        "tencent-tokenhub": HermesProviderOverlay(
            displayName: "Tencent TokenHub",
            // Resolved from TOKENHUB_BASE_URL at runtime.
            baseURL: nil,
            authType: .apiKey,
            subscriptionGated: false,
            docURL: nil
        ),
        // -- v0.14 additions ---------------------------------------------
        // Hermes v2026.5.16 added two overlay-only providers:
        // xAI Grok OAuth (SuperGrok subscription) and NovitaAI. Wire IDs
        // match HERMES_OVERLAYS verbatim — `xai-oauth` is canonical
        // (`x-ai-oauth` / `grok-oauth` / `xai-grok-oauth` are accepted
        // aliases server-side, but Scarf only registers the canonical so
        // the picker shows one row).
        "xai-oauth": HermesProviderOverlay(
            displayName: "xAI (SuperGrok)",
            baseURL: "https://api.x.ai/v1",
            authType: .oauthExternal,
            subscriptionGated: true,
            docURL: nil
        ),
        "novita": HermesProviderOverlay(
            displayName: "NovitaAI",
            baseURL: nil, // Resolved at runtime from NOVITA_BASE_URL.
            authType: .apiKey,
            subscriptionGated: false,
            docURL: nil
        ),
        // -- v0.16 additions ---------------------------------------------
        // Hermes v0.16 added AWS Bedrock as overlay-only provider (not in
        // models.dev). Wire ID `bedrock` matches HERMES_OVERLAYS verbatim.
        // Uses AWS SDK for auth; no baseURL needed at Scarf level.
        "bedrock": HermesProviderOverlay(
            displayName: "AWS Bedrock",
            baseURL: nil,
            authType: .apiKey,
            subscriptionGated: false,
            docURL: nil
        ),
        // -- v0.20 additions ---------------------------------------------
        // Hermes v2026.8.3 added Fireworks AI as overlay-only (not in
        // models.dev). Wire ID `fireworks` matches HERMES_OVERLAYS
        // verbatim; env var FIREWORKS_API_KEY.
        "fireworks": HermesProviderOverlay(
            displayName: "Fireworks AI",
            baseURL: "https://api.fireworks.ai/inference/v1",
            authType: .apiKey,
            subscriptionGated: false,
            docURL: nil
        ),
        // Vertex authenticates via OAuth2 (service-account JSON / ADC),
        // not a static API key — resolved specially by Hermes's
        // agent/vertex_adapter.py (auth_type "vertex" in providers.py),
        // like bedrock's aws_sdk. Closest Scarf authType is
        // .oauthExternal. No base URL; no API key.
        "vertex": HermesProviderOverlay(
            displayName: "Google Vertex AI",
            baseURL: nil,
            authType: .oauthExternal,
            subscriptionGated: false,
            docURL: nil
        ),
        // Hermes v2026.8.18 added Actual Computer as overlay-only (not in
        // models.dev). Wire ID `actual` matches HERMES_OVERLAYS verbatim;
        // codex_responses transport; env var ACTUAL_API_KEY.
        "actual": HermesProviderOverlay(
            displayName: "Actual Computer",
            baseURL: "https://api.actual.inc/v1",
            authType: .apiKey,
            subscriptionGated: false,
            docURL: nil
        ),
    ]

    /// Provider-ID aliases — verbatim mirror of `ALIASES` in
    /// hermes_cli/providers.py (minus identity entries). Maps
    /// human-friendly / legacy names to canonical provider IDs, using
    /// models.dev IDs where possible. Used by `canonicalProviderID(_:)`
    /// so preflight checks compare what Hermes would actually resolve.
    /// Reconcile on every Hermes bump alongside the other tables here.
    public static let providerAliases: [String: String] = [
        // openrouter
        "openai": "openrouter",     // bare "openai" → route through aggregator
        // zai
        "glm": "zai",
        "z-ai": "zai",
        "z.ai": "zai",
        "zhipu": "zai",
        // xai
        "x-ai": "xai",
        "x.ai": "xai",
        "grok": "xai",
        "grok-oauth": "xai-oauth",
        "x-ai-oauth": "xai-oauth",
        "xai-grok-oauth": "xai-oauth",
        // nvidia
        "nim": "nvidia",
        "nvidia-nim": "nvidia",
        "build-nvidia": "nvidia",
        "nemotron": "nvidia",
        // kimi-for-coding (models.dev ID)
        "kimi": "kimi-for-coding",
        "kimi-coding": "kimi-for-coding",
        "kimi-coding-cn": "kimi-for-coding",
        "moonshot": "kimi-for-coding",
        // stepfun
        "step": "stepfun",
        "stepfun-coding-plan": "stepfun",
        // minimax-cn
        "minimax-china": "minimax-cn",
        "minimax_cn": "minimax-cn",
        // anthropic
        "claude": "anthropic",
        "claude-code": "anthropic",
        // github-copilot (models.dev ID)
        "copilot": "github-copilot",
        "github": "github-copilot",
        "github-copilot-acp": "copilot-acp",
        // opencode (models.dev ID for OpenCode Zen)
        "opencode-zen": "opencode",
        "zen": "opencode",
        // opencode-go
        "go": "opencode-go",
        "opencode-go-sub": "opencode-go",
        // kilo (models.dev ID for KiloCode)
        "kilocode": "kilo",
        "kilo-code": "kilo",
        "kilo-gateway": "kilo",
        // deepseek
        "deep-seek": "deepseek",
        // alibaba
        "dashscope": "alibaba",
        "aliyun": "alibaba",
        "qwen": "alibaba",
        "alibaba-cloud": "alibaba",
        "alibaba_coding": "alibaba-coding-plan",
        "alibaba-coding": "alibaba-coding-plan",
        "alibaba_coding_plan": "alibaba-coding-plan",
        // v0.18 removed google-gemini-cli (and its gemini-cli /
        // gemini-oauth aliases) in favor of the models.dev-backed
        // `vertex` provider (Google Vertex AI, OAuth2 SA/ADC). Vertex
        // needs no entry here: its aliases live in models.py's picker
        // table, not providers.py ALIASES, which this dict mirrors.
        // vercel (models.dev ID for AI Gateway)
        "ai-gateway": "vercel",
        "aigateway": "vercel",
        "vercel-ai-gateway": "vercel",
        // huggingface
        "hf": "huggingface",
        "hugging-face": "huggingface",
        "huggingface-hub": "huggingface",
        // novita
        "novita-ai": "novita",
        "novitaai": "novita",
        // xiaomi
        "mimo": "xiaomi",
        "xiaomi-mimo": "xiaomi",
        // tencent
        "tencent": "tencent-tokenhub",
        "tokenhub": "tencent-tokenhub",
        "tencent-cloud": "tencent-tokenhub",
        "tencentmaas": "tencent-tokenhub",
        // bedrock
        "aws": "bedrock",
        "aws-bedrock": "bedrock",
        "amazon-bedrock": "bedrock",
        "amazon": "bedrock",
        // arcee
        "arcee-ai": "arcee",
        "arceeai": "arcee",
        // gmi
        "gmi-cloud": "gmi",
        "gmicloud": "gmi",
        // fireworks
        "fireworks-ai": "fireworks",
        "fw": "fireworks",
        // upstage
        "solar": "upstage",
        // Actual Computer
        "actual-computer": "actual",
        "actualcomputer": "actual",
        "aci": "actual",
        // Local server aliases → virtual "local" concept (resolved via user config)
        "lm-studio": "lmstudio",
        "lm_studio": "lmstudio",
        "ollama": "custom",  // bare "ollama" = local; use "ollama-cloud" for cloud
        "vllm": "local",
        "llamacpp": "local",
        "llama.cpp": "local",
        "llama-cpp": "local",
    ]

    /// Resolve aliases and normalize casing to a canonical provider ID —
    /// mirrors `normalize_provider` in hermes_cli/providers.py. Does not
    /// validate that the result names a known provider.
    public static func canonicalProviderID(_ name: String) -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return providerAliases[key] ?? key
    }

    /// Display-name overrides applied at `loadProviders()` time. Used
    /// when Hermes renames a provider's display string without changing
    /// the wire ID — `alibaba` → "Qwen Cloud" in v0.14 is the only
    /// entry today. Keys are the provider's wire ID; values are the
    /// preferred display name.
    ///
    /// **Why unconditional (no capability gate):** pre-v0.14 Hermes
    /// hosts still accept the `alibaba` provider ID, so showing
    /// "Qwen Cloud" cosmetically across all hosts matches what the
    /// world calls it (per the v0.14 release notes) and avoids the
    /// jarring "name changes when Hermes upgrades" UX. Mirror new
    /// entries to `hermes_cli/models.py`'s `ProviderEntry` table on
    /// Hermes version bumps so display drift stays minimal.
    public static let providerDisplayNameOverrides: [String: String] = [
        "alibaba": "Qwen Cloud",
        "upstage": "Upstage Solar",
    ]
}

/// Curated entry for the `image_gen.model` picker on the Auxiliary
/// tab. Hermes v0.13 honors a top-level `image_gen.model` key but the
/// models.dev catalog has no `image: true` tag, so we maintain a
/// short hand-curated allowlist keyed by display order. The picker
/// always allows free-form-typing too, so any provider's model ID
/// works regardless of whether it appears here.
public struct HermesImageGenModel: Sendable, Identifiable, Hashable {
    public let modelID: String
    public let display: String
    /// Hint at which provider serves this model — surfaced as a
    /// "Configure provider X first" advisory but never enforced.
    public let providerHint: String?
    public var id: String { modelID }

    public init(modelID: String, display: String, providerHint: String?) {
        self.modelID = modelID
        self.display = display
        self.providerHint = providerHint
    }
}

/// Scarf-side mirror of `HermesOverlay` from hermes-agent's
/// `hermes_cli/providers.py`. Describes a provider that isn't in the
/// models.dev catalog.
public struct HermesProviderOverlay: Sendable {
    public let displayName: String
    public let baseURL: String?
    public let authType: AuthType
    /// True for providers whose tool access is subscription-gated rather than
    /// BYO-API-key. Nous Portal is the only `true` entry today.
    public let subscriptionGated: Bool
    public let docURL: String?

    public init(
        displayName: String,
        baseURL: String?,
        authType: AuthType,
        subscriptionGated: Bool,
        docURL: String?
    ) {
        self.displayName = displayName
        self.baseURL = baseURL
        self.authType = authType
        self.subscriptionGated = subscriptionGated
        self.docURL = docURL
    }

    public enum AuthType: String, Sendable {
        case apiKey
        case oauthDeviceCode
        case oauthExternal
        case externalProcess
        /// No credentials at all — the provider is a local virtual
        /// construct (e.g. `moa`, whose "models" are preset names).
        case virtual
    }
}
