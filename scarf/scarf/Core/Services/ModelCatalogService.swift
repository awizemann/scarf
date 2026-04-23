import Foundation
import os

/// A single model from the models.dev catalog shipped with hermes.
struct HermesModelInfo: Sendable, Identifiable, Hashable {
    var id: String { providerID + ":" + modelID }

    let providerID: String
    let providerName: String
    let modelID: String
    let modelName: String
    let contextWindow: Int?
    let maxOutput: Int?
    let costInput: Double?      // USD per 1M input tokens
    let costOutput: Double?     // USD per 1M output tokens
    let reasoning: Bool
    let toolCall: Bool
    let releaseDate: String?

    /// Display-friendly cost string, or nil if cost is unknown.
    var costDisplay: String? {
        guard let input = costInput, let output = costOutput else { return nil }
        let currency = FloatingPointFormatStyle<Double>.Currency.currency(code: "USD").precision(.fractionLength(2))
        return "\(input.formatted(currency)) / \(output.formatted(currency))"
    }

    /// Display-friendly context window ("200K", "1M", etc.).
    var contextDisplay: String? {
        guard let ctx = contextWindow else { return nil }
        if ctx >= 1_000_000 { return "\(ctx / 1_000_000)M" }
        if ctx >= 1_000 { return "\(ctx / 1_000)K" }
        return "\(ctx)"
    }
}

/// Provider summary — one row in the left column of the picker.
struct HermesProviderInfo: Sendable, Identifiable, Hashable {
    var id: String { providerID }

    let providerID: String
    let providerName: String
    let envVars: [String]       // e.g. ["ANTHROPIC_API_KEY"]
    let docURL: String?
    let modelCount: Int
    /// True when this provider is surfaced only by the Hermes overlay list —
    /// i.e. it has no entry in `models_dev_cache.json` and therefore no model
    /// list from models.dev. The picker renders a different right-column
    /// affordance in this case (subscription CTA or free-form model entry).
    let isOverlay: Bool
    /// True for providers whose tool access is gated on an active subscription
    /// rather than a BYO API key. Nous Portal is the only such provider as of
    /// hermes-agent v0.10.0.
    let subscriptionGated: Bool
}

/// Reads the models.dev catalog that hermes caches at
/// `~/.hermes/models_dev_cache.json`. Offline-capable, fast enough to read per
/// call (~1500 models across ~110 providers).
///
/// We decode a trimmed subset so unknown fields don't break loading. Every
/// field we care about is optional on disk — providers may omit cost, context
/// limits, etc.
struct ModelCatalogService: Sendable {
    private let logger = Logger(subsystem: "com.scarf", category: "ModelCatalogService")
    let path: String
    let transport: any ServerTransport

    nonisolated init(context: ServerContext = .local) {
        self.path = context.paths.home + "/models_dev_cache.json"
        self.transport = context.makeTransport()
    }

    /// Escape hatch for tests.
    init(path: String) {
        self.path = path
        self.transport = LocalTransport()
    }

    /// All providers, sorted with subscription-gated providers first (Nous
    /// Portal), then alphabetical by display name.
    ///
    /// Merges two data sources:
    /// 1. `~/.hermes/models_dev_cache.json` — the models.dev mirror.
    /// 2. ``Self/overlayOnlyProviders`` — Hermes-injected providers that
    ///    aren't in the models.dev catalog (e.g. Nous Portal, OpenAI Codex).
    ///    Without this merge, those providers are invisible in Scarf's picker
    ///    even though `hermes model` on the CLI can reach them.
    func loadProviders() -> [HermesProviderInfo] {
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
    func overlayMetadata(for providerID: String) -> HermesProviderOverlay? {
        Self.overlayOnlyProviders[providerID]
    }

    /// Models for one provider, sorted by release date (newest first), then name.
    func loadModels(for providerID: String) -> [HermesModelInfo] {
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
    func provider(for modelID: String) -> HermesProviderInfo? {
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
    func providerByID(_ providerID: String) -> HermesProviderInfo? {
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
    func model(providerID: String, modelID: String) -> HermesModelInfo? {
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

    // MARK: - Decoding

    private func loadCatalog() -> [String: ProviderEntry]? {
        guard let data = try? transport.readFile(path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode([String: ProviderEntry].self, from: data)
        } catch {
            logger.error("Failed to decode models_dev_cache.json: \(error.localizedDescription)")
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
struct HermesProviderOverlay: Sendable {
    let displayName: String
    let baseURL: String?
    let authType: AuthType
    /// True for providers whose tool access is subscription-gated rather than
    /// BYO-API-key. Nous Portal is the only `true` entry today.
    let subscriptionGated: Bool
    let docURL: String?

    enum AuthType: String, Sendable {
        case apiKey
        case oauthDeviceCode
        case oauthExternal
        case externalProcess
    }
}
