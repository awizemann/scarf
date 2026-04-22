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

    public init(
        providerID: String,
        providerName: String,
        envVars: [String],
        docURL: String?,
        modelCount: Int
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.envVars = envVars
        self.docURL = docURL
        self.modelCount = modelCount
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

    /// All providers, sorted by display name.
    public func loadProviders() -> [HermesProviderInfo] {
        guard let catalog = loadCatalog() else { return [] }
        return catalog
            .map { (id, p) in
                HermesProviderInfo(
                    providerID: id,
                    providerName: p.name ?? id,
                    envVars: p.env ?? [],
                    docURL: p.doc,
                    modelCount: p.models?.count ?? 0
                )
            }
            .sorted { $0.providerName.localizedCaseInsensitiveCompare($1.providerName) == .orderedAscending }
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
                    modelCount: p.models?.count ?? 0
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
                    modelCount: p.models?.count ?? 0
                )
            }
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
}
