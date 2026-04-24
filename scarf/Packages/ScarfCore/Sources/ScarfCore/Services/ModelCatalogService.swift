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
            byID[id] = HermesProviderInfo(
                providerID: id,
                providerName: p.name ?? id,
                envVars: p.env ?? [],
                docURL: p.doc,
                modelCount: p.models?.count ?? 0,
                isOverlay: false,
                subscriptionGated: false
            )
        }
        for (id, overlay) in Self.overlayOnlyProviders where byID[id] == nil {
            byID[id] = HermesProviderInfo(
                providerID: id,
                providerName: overlay.displayName,
                envVars: [],
                docURL: overlay.docURL,
                modelCount: 0,
                isOverlay: true,
                subscriptionGated: overlay.subscriptionGated
            )
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.subscriptionGated != rhs.subscriptionGated {
                return lhs.subscriptionGated
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

    /// Models for one provider, sorted by release date (newest first), then name.
    public func loadModels(for providerID: String) -> [HermesModelInfo] {
        guard let catalog = loadCatalog(), let provider = catalog[providerID] else { return [] }
        let providerName = provider.name ?? providerID
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

    /// Find the provider that ships a given model ID. Useful for auto-syncing
    /// provider when the user picks a model from a flat list or types one in.
    public func provider(for modelID: String) -> HermesProviderInfo? {
        guard let catalog = loadCatalog() else { return nil }
        for (providerID, p) in catalog {
            if p.models?[modelID] != nil {
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
        guard let catalog = loadCatalog(),
              let provider = catalog[providerID],
              let raw = provider.models?[modelID] else { return nil }
        return HermesModelInfo(
            providerID: providerID,
            providerName: provider.name ?? providerID,
            modelID: modelID,
            modelName: raw.name ?? modelID,
            contextWindow: raw.limit?.context,
            maxOutput: raw.limit?.output,
            costInput: raw.cost?.input,
            costOutput: raw.cost?.output,
            reasoning: raw.reasoning ?? false,
            toolCall: raw.tool_call ?? false,
            releaseDate: raw.release_date
        )
    }

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
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid(providerName: providerID, suggestions: [])
        }

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
    }

    private struct CostEntry: Decodable {
        let input: Double?
        let output: Double?
    }

    private struct LimitEntry: Decodable {
        let context: Int?
        let output: Int?
    }

    // MARK: - Hermes overlay providers

    /// The six providers Hermes surfaces via `hermes model` that have no
    /// entry in `models_dev_cache.json` (models.dev doesn't mirror them).
    /// Mirrors the overlay-only subset of `HERMES_OVERLAYS` in
    /// `hermes-agent/hermes_cli/providers.py`. The other ~19 overlay entries
    /// already ship in the cache and only add augmentation (base-URL
    /// override, extra env vars) that Scarf doesn't currently display.
    ///
    /// Keep this in sync with the Python side on Hermes version bumps.
    static let overlayOnlyProviders: [String: HermesProviderOverlay] = [
        "nous": HermesProviderOverlay(
            displayName: "Nous Portal",
            baseURL: "https://inference-api.nousresearch.com/v1",
            authType: .oauthDeviceCode,
            subscriptionGated: true,
            docURL: "https://hermes-agent.nousresearch.com/docs/user-guide/setup/nous-portal"
        ),
        "openai-codex": HermesProviderOverlay(
            displayName: "OpenAI Codex",
            baseURL: "https://chatgpt.com/backend-api/codex",
            authType: .oauthExternal,
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
        "google-gemini-cli": HermesProviderOverlay(
            displayName: "Google Gemini CLI",
            baseURL: "cloudcode-pa://google",
            authType: .oauthExternal,
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
    ]
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
    }
}
