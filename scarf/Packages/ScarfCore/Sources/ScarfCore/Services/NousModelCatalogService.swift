import Foundation
import os

/// One Nous Portal model as exposed by `GET /v1/models`. The shape
/// mirrors the OpenAI-compatible response schema — Nous's inference
/// API uses the same envelope. Optional fields stay optional because
/// not every entry includes them; `id` is the only field we strictly
/// need (it's what Hermes passes through to the provider).
public struct NousModel: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let owned_by: String?
    public let created: Int?
    /// Free-text description if the API ships one. Nous's current
    /// catalog doesn't include this, but the field is here so future
    /// shape changes don't drop user-visible context on the floor.
    public let description: String?

    public init(id: String, owned_by: String? = nil, created: Int? = nil, description: String? = nil) {
        self.id = id
        self.owned_by = owned_by
        self.created = created
        self.description = description
    }
}

/// On-disk cache shape. Versioned so a future schema change can lift
/// stale caches gracefully — bump `version` and the loader rejects
/// anything older without trying to migrate. Stored as JSON next to
/// the projects registry so a Hermes wipe takes it with the rest of
/// the Scarf-owned state.
public struct NousModelsCache: Codable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let fetchedAt: Date
    public let models: [NousModel]

    public init(version: Int = NousModelsCache.currentVersion, fetchedAt: Date, models: [NousModel]) {
        self.version = version
        self.fetchedAt = fetchedAt
        self.models = models
    }
}

/// Result of a `loadModels` call. Distinguishes "fetched fresh from
/// the API" from "cache served, network failed" so the picker UI can
/// surface a "could not refresh" hint without hiding the cached list.
public enum NousModelsLoadResult: Sendable {
    case fresh(models: [NousModel], fetchedAt: Date)
    case cache(models: [NousModel], fetchedAt: Date, refreshError: String?)
    case fallback(models: [NousModel], reason: String)
}

/// Fetches + caches the list of available Nous Portal models. Runs in
/// the Scarf process (not on the remote), authenticated with the
/// bearer token from `~/.hermes/auth.json` on the active server —
/// `NousSubscriptionService` reads that file via the active transport,
/// so a remote droplet's token comes back over SSH and the network
/// call to Nous still happens from the user's Mac. That's correct:
/// we want the model list visible whenever the user has subscription
/// credentials, regardless of where Hermes will eventually run the
/// chat from.
public struct NousModelCatalogService: Sendable {
    public static let baseURL = URL(string: "https://inference-api.nousresearch.com/v1/models")!
    public static let cacheTTL: TimeInterval = 24 * 60 * 60   // 24h
    public static let requestTimeout: TimeInterval = 10        // seconds

    /// Hard-coded fallback for offline-with-no-cache. Short on purpose
    /// — only the canonical Hermes models (the family the user is most
    /// likely to want) plus a reminder that fresh data is one
    /// successful refresh away. Update when Nous releases a new
    /// flagship; deliberately not exhaustive — the API is the source
    /// of truth, this just keeps the picker non-empty.
    public static let fallbackModels: [NousModel] = [
        NousModel(id: "Hermes-3-Llama-3.1-405B"),
        NousModel(id: "Hermes-3-Llama-3.1-70B"),
        NousModel(id: "Hermes-3-Llama-3.1-8B"),
        NousModel(id: "DeepHermes-3-Llama-3-8B-Preview")
    ]

    private static let logger = Logger(subsystem: "com.scarf", category: "NousModelCatalogService")

    public let context: ServerContext
    private let session: URLSession
    private let cachePath: String

    public init(context: ServerContext, session: URLSession = .shared) {
        self.context = context
        self.session = session
        self.cachePath = context.paths.nousModelsCache
    }

    // MARK: - Cache I/O

    /// Read the cache via the active transport (so a remote droplet's
    /// cache lands on the droplet, not the user's Mac). Missing or
    /// malformed cache → nil; the loader treats that as "no cache" and
    /// kicks off a fresh fetch.
    /// Race readCache against a sleep so a hung remote `cat` doesn't
    /// stall the picker for the full transport-level timeout (60 s).
    /// On timeout returns nil — the caller treats that as "no usable
    /// cache" and falls through to the network fetch.
    public func readCacheWithTimeout(seconds: TimeInterval) async -> NousModelsCache? {
        await withTaskGroup(of: NousModelsCache?.self) { group in
            group.addTask { [self] in
                // Detached because readCache is sync + does blocking
                // SSH I/O; running on the cooperative pool is fine
                // for one task but we don't want to fight executor
                // scheduling with the timer task below.
                await Task.detached { [self] in
                    readCache()
                }.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                ScarfMon.event(.diskIO, "nous.readCache.timeoutFired", count: 1)
                return nil
            }
            // First completion wins; cancel the other.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    public func readCache() -> NousModelsCache? {
        ScarfMon.measure(.diskIO, "nous.readCache") {
            let transport = context.makeTransport()
            // Split into separate measure points so the next perf
            // capture localizes the 60-second observed beach ball
            // — was it the fileExists probe, the read itself, or
            // the JSON decode? Each on its own ScarfMon row.
            let exists = ScarfMon.measure(.diskIO, "nous.readCache.fileExists") {
                transport.fileExists(cachePath)
            }
            guard exists else { return nil }
            do {
                let data = try ScarfMon.measure(.diskIO, "nous.readCache.readFile") {
                    try transport.readFile(cachePath)
                }
                ScarfMon.event(.diskIO, "nous.readCache.bytes", count: 1, bytes: data.count)
                return ScarfMon.measure(.diskIO, "nous.readCache.decode") {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    do {
                        let cache = try decoder.decode(NousModelsCache.self, from: data)
                        guard cache.version == NousModelsCache.currentVersion else {
                            Self.logger.info("nous models cache schema mismatch (got v\(cache.version), expected v\(NousModelsCache.currentVersion)); ignoring")
                            return Optional<NousModelsCache>.none
                        }
                        return cache
                    } catch {
                        Self.logger.warning("couldn't decode nous models cache: \(error.localizedDescription, privacy: .public)")
                        return Optional<NousModelsCache>.none
                    }
                }
            } catch {
                Self.logger.warning("couldn't read nous models cache: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    private func writeCache(_ cache: NousModelsCache) {
        let transport = context.makeTransport()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cache)
            // Make sure the parent dir exists — fresh remote installs
            // may not yet have `~/.hermes/scarf/`. mkdir -p is cheap
            // and idempotent on both transports.
            let parent = (cachePath as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                try? transport.createDirectory(parent)
            }
            // UNGUARDED-WRITE(O): models cache published from a fresh network fetch; nothing read from this file feeds the bytes.
            try transport.unguardedWriteFile(cachePath, data: data)
        } catch {
            Self.logger.warning("couldn't write nous models cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func isCacheStale(_ cache: NousModelsCache) -> Bool {
        Date().timeIntervalSince(cache.fetchedAt) > Self.cacheTTL
    }

    // MARK: - Network fetch

    /// Read the bearer token from `auth.json` on the active server.
    /// Returns nil when the user isn't signed in to Nous, in which
    /// case `loadModels` skips the network call and falls through to
    /// cache or fallback.
    private func bearerToken() -> String? {
        // The subscription service already checks for `present`; we
        // re-read the raw token here because we need the actual string,
        // not just a Bool. Mirrors the SubscriptionService parse path.
        // ScarfMon: separate `nous.bearerToken` measure point because
        // this is the second auth.json read of the picker's open
        // sequence (subscriptionService.loadState() did the first).
        // Together with `nous.subscription.loadState`, total two SSH
        // round-trips of the same file — candidate for caching.
        ScarfMon.measure(.diskIO, "nous.bearerToken") {
            let transport = context.makeTransport()
            guard transport.fileExists(context.paths.authJSON) else { return nil }
            guard let data = try? transport.readFile(context.paths.authJSON) else { return nil }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let providers = root["providers"] as? [String: Any] ?? [:]
            let nous = providers["nous"] as? [String: Any]
            let token = nous?["access_token"] as? String
            guard let token, !token.isEmpty else { return nil }
            return token
        }
    }

    /// Make the API call. Times out after `requestTimeout` so a hung
    /// network doesn't block the picker indefinitely. Returns the raw
    /// `[NousModel]` on success, throws on any HTTP / decode error so
    /// the caller can log + fall back.
    public func fetchModels() async throws -> [NousModel] {
        try await ScarfMon.measureAsync(.transport, "nous.fetchModels") {
            guard let token = bearerToken() else {
                throw NousModelCatalogError.notAuthenticated
            }
            var request = URLRequest(url: Self.baseURL)
            request.httpMethod = "GET"
            request.timeoutInterval = Self.requestTimeout
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NousModelCatalogError.transport("non-HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw NousModelCatalogError.http(status: http.statusCode)
            }
            struct Envelope: Decodable { let data: [NousModel] }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            ScarfMon.event(.transport, "nous.fetchModels.bytes", count: envelope.data.count, bytes: data.count)
            return envelope.data
        }
    }

    // MARK: - Public entry

    /// Top-level "give me models" entry point. Cache-first: serve from
    /// cache if fresh, fetch + write through if stale or empty, fall
    /// back to the hard-coded list when both fail. The caller renders
    /// based on the case so it can show a "could not refresh" hint
    /// next to a stale-but-still-useful list.
    public func loadModels(forceRefresh: Bool = false) async -> NousModelsLoadResult {
        // Cache-read with a short timeout. The underlying SSH `cat`
        // can hang on a corrupted or oversized cache file (a
        // 120-second picker stall observed in the wild — two 60 s
        // timeouts stacked from a duplicated read; perf capture
        // localized to `nous.readCache.readFile`). Cache is a
        // performance hint, not a correctness requirement; if it
        // doesn't return in 5 s, fall through to the network fetch
        // and let writeCache rebuild it. The runaway `cat` keeps
        // running on its own 60 s transport timeout but no longer
        // blocks the picker.
        let cached = await readCacheWithTimeout(seconds: 5)

        if let cached, !forceRefresh, !isCacheStale(cached) {
            return .cache(models: cached.models, fetchedAt: cached.fetchedAt, refreshError: nil)
        }

        do {
            let models = try await fetchModels()
            let now = Date()
            writeCache(NousModelsCache(fetchedAt: now, models: models))
            return .fresh(models: models, fetchedAt: now)
        } catch let error as NousModelCatalogError {
            // Fetch failed but we may still have *something* useful.
            if let cached {
                return .cache(
                    models: cached.models,
                    fetchedAt: cached.fetchedAt,
                    refreshError: error.userMessage
                )
            }
            return .fallback(models: Self.fallbackModels, reason: error.userMessage)
        } catch {
            if let cached {
                return .cache(
                    models: cached.models,
                    fetchedAt: cached.fetchedAt,
                    refreshError: error.localizedDescription
                )
            }
            return .fallback(models: Self.fallbackModels, reason: error.localizedDescription)
        }
    }
}

public enum NousModelCatalogError: Error, Sendable {
    case notAuthenticated
    case http(status: Int)
    case transport(String)

    public var userMessage: String {
        switch self {
        case .notAuthenticated:
            return "Sign in to Nous Portal to fetch the latest model list."
        case .http(let status) where status == 401:
            return "Nous rejected the saved token (401). Sign in again."
        case .http(let status):
            return "Nous returned HTTP \(status)."
        case .transport(let detail):
            return "Couldn't reach Nous: \(detail)."
        }
    }
}
