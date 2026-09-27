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

    /// Hard-coded fallback for offline-with-no-cache. Short on purpose —
    /// the API is the source of truth, this just keeps the picker
    /// non-empty with ids Nous actually serves.
    ///
    /// A subset of Hermes's own offline list, `_PROVIDER_MODELS["nous"]`
    /// (`hermes_cli/models_catalog_static.py:164` @ v2026.9.24, built from
    /// `OPENROUTER_MODELS` minus `_OPENROUTER_ONLY` and `:free` SKUs), in
    /// that order, ending with `z-ai/glm-5.2` — the entry
    /// `website/static/api/model-catalog.json` marks `"default": true`.
    /// Until S06-F5 this held four `Hermes-3-…` ids, which Hermes itself
    /// filters out of the Nous list (see ``agenticModels(_:)``). Update
    /// alongside the Hermes release audit; not a checked table.
    public static let fallbackModels: [NousModel] = [
        NousModel(id: "anthropic/claude-fable-5.1"),
        NousModel(id: "anthropic/claude-opus-5.5"),
        NousModel(id: "anthropic/claude-sonnet-5"),
        NousModel(id: "openai/gpt-6-astra"),
        NousModel(id: "openai/gpt-5.5"),
        NousModel(id: "google/gemini-3.1-pro-preview"),
        NousModel(id: "x-ai/grok-4.7"),
        NousModel(id: "deepseek/deepseek-v4-pro"),
        NousModel(id: "moonshotai/kimi-k3"),
        NousModel(id: "z-ai/glm-5.2"),
    ]

    /// The models Hermes offers from a Nous `/models` response: any id
    /// containing "hermes" (any case) is dropped — "Hermes models aren't
    /// reliable for agentic tool-calling" (`fetch_nous_models`,
    /// `hermes_cli/auth_nous.py:724-727` @ v2026.9.24; the same filter is
    /// in `auth.py` back to v2026.4.30, from hermes-agent 69d3d3c15a) —
    /// ids are trimmed, empties dropped, and duplicates collapsed keeping
    /// the first. Applied to fresh fetches AND cached lists, so a cache
    /// written before this filter existed doesn't bring them back.
    public static func agenticModels(_ models: [NousModel]) -> [NousModel] {
        var seen: Set<String> = []
        var out: [NousModel] = []
        for model in models {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !id.lowercased().contains("hermes"), seen.insert(id).inserted else { continue }
            out.append(id == model.id
                ? model
                : NousModel(id: id, owned_by: model.owned_by, created: model.created, description: model.description))
        }
        return out
    }

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

    /// What `auth.json` says about calling Nous's `/models`.
    public enum BearerLookup: Equatable, Sendable {
        /// No Nous sign-in (or no token) in the record.
        case missing
        /// The key's recorded expiry has passed. Hermes renews it on its
        /// next run; Scarf does not refresh it (that rotates the refresh
        /// token under Hermes's feet).
        case expired
        /// Send `token` to `url`.
        case usable(token: String, url: URL)
    }

    /// Seconds of life a key needs left to be worth sending.
    static let expirySkew: TimeInterval = 60

    /// The key and URL Hermes itself would use for `/models`, from the raw
    /// `auth.json` bytes (T3-F3).
    ///
    /// - Key: `providers.nous.agent_key`, the inference key Hermes sends
    ///   (`resolve_nous_runtime_credentials` returns it as `api_key`,
    ///   `hermes_cli/auth_nous.py:1085-1090` @ v2026.9.24), falling back to
    ///   `access_token`. Since v2026.5.28 the two are the same JWT
    ///   (`_set_nous_agent_key_from_invoke_jwt`, `auth_nous.py:285-302`);
    ///   before that `agent_key` was a separate opaque key, so reading only
    ///   `access_token` sent the wrong credential on those hosts.
    /// - Expiry: `agent_key_expires_at` for the agent key, `expires_at` for
    ///   the access token, else the JWT's own `exp`. Hermes treats both as
    ///   short-lived (about an hour) and renews them before each run
    ///   (`ensure_usable_access_token`, `auth_nous.py:1060-1080`); Scarf
    ///   reads a file Hermes may not have touched for a day. An expired key
    ///   is not sent. An unknown expiry is sent as before.
    /// - URL: `providers.nous.inference_base_url` + `/models`, as
    ///   `fetch_nous_models` builds it (`auth_nous.py:702-712`), when it is
    ///   an https URL; else the default inference host.
    public static func bearerLookup(authJSON data: Data, now: Date = Date()) -> BearerLookup {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nous = (root["providers"] as? [String: Any])?["nous"] as? [String: Any]
        else { return .missing }
        func text(_ key: String) -> String? {
            guard let value = nous[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let token: String
        let recordedExpiry: String?
        if let agentKey = text("agent_key") {
            token = agentKey
            recordedExpiry = text("agent_key_expires_at") ?? (agentKey == text("access_token") ? text("expires_at") : nil)
        } else if let accessToken = text("access_token") {
            token = accessToken
            recordedExpiry = text("expires_at")
        } else {
            return .missing
        }
        let expiry = recordedExpiry.flatMap(parseISODate) ?? jwtExpiry(token)
        if let expiry, expiry.timeIntervalSince(now) <= expirySkew {
            return .expired
        }
        var url = baseURL
        if let base = text("inference_base_url"),
           let parsed = URL(string: base), parsed.scheme?.lowercased() == "https",
           let host = parsed.host, !host.isEmpty {
            var trimmed = base
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            url = URL(string: trimmed + "/models") ?? baseURL
        }
        return .usable(token: token, url: url)
    }

    /// An ISO-8601 timestamp as Hermes writes it (`datetime.isoformat()`,
    /// with or without fractional seconds, `Z` or an offset, or naive UTC).
    static func parseISODate(_ raw: String) -> Date? {
        var text = raw
        if text.hasSuffix("Z") { text = String(text.dropLast()) + "+00:00" }
        let hasZone = text.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil
        if !hasZone { text += "+00:00" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// The `exp` claim of a JWT, or nil when `token` is not one.
    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    /// Read the bearer key from `auth.json` on the active server (see
    /// ``bearerLookup(authJSON:now:)``). `.missing` when the user isn't
    /// signed in to Nous, in which case `loadModels` skips the network
    /// call and falls through to cache or fallback.
    private func bearer() -> BearerLookup {
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
            // Named profile: Hermes falls back to the ROOT auth.json's
            // `providers.nous` when the profile has none (S06-F3).
            let merged = HermesAuthFallback.load(
                authJSONPath: context.paths.authJSON,
                home: context.paths.home,
                capabilities: HermesVersionCache.shared.capabilitiesSync(for: context),
                transport: transport
            )
            guard let data = merged.data else { return .missing }
            return Self.bearerLookup(authJSON: data)
        }
    }

    /// Make the API call. Times out after `requestTimeout` so a hung
    /// network doesn't block the picker indefinitely. Returns the raw
    /// `[NousModel]` on success, throws on any HTTP / decode error so
    /// the caller can log + fall back.
    public func fetchModels() async throws -> [NousModel] {
        try await ScarfMon.measureAsync(.transport, "nous.fetchModels") {
            // `bearer()` reads auth.json over the transport and may
            // probe the host version — a thread of its own, not the pool.
            let service = self
            let token: String
            let url: URL
            switch await OffPool.run({ service.bearer() }) {
            case .missing: throw NousModelCatalogError.notAuthenticated
            case .expired: throw NousModelCatalogError.tokenExpired
            case .usable(let key, let endpoint):
                token = key
                url = endpoint
            }
            var request = URLRequest(url: url)
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
            return Self.agenticModels(envelope.data)
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
        let rawCached = await readCacheWithTimeout(seconds: 5)

        // Same filter as a fresh fetch — a cache written by an older Scarf
        // may still carry the Hermes-* ids Hermes drops (S06-F5).
        let cached = rawCached.map {
            NousModelsCache(version: $0.version, fetchedAt: $0.fetchedAt, models: Self.agenticModels($0.models))
        }

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
    /// The saved key has expired; Hermes renews it on its next run.
    case tokenExpired
    case http(status: Int)
    case transport(String)

    public var userMessage: String {
        switch self {
        case .notAuthenticated:
            return "Sign in to Nous Portal to fetch the latest model list."
        case .tokenExpired:
            return "The saved Nous token has expired. Hermes renews it the next time it runs, and the list refreshes after that."
        case .http(let status) where status == 401:
            // Usually a token that expired after Hermes last wrote its
            // expiry; Hermes renews it on its own (T3-F3).
            return "Nous didn't accept the saved token (401). Hermes renews it the next time it runs; if this keeps happening, sign in to Nous Portal again."
        case .http(let status):
            return "Nous returned HTTP \(status)."
        case .transport(let detail):
            return "Couldn't reach Nous: \(detail)."
        }
    }
}
