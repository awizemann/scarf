import Foundation
import ScarfCore
import os

/// On-disk cache shape. Versioned so a future schema change can lift
/// stale caches gracefully — bump `version` and the loader rejects
/// anything older without trying to migrate. Stored next to the
/// projects registry so a Hermes wipe takes it with the rest of the
/// Scarf-owned state.
struct CatalogCache: Codable, Sendable {
    static let currentVersion = 1
    let version: Int
    let fetchedAt: Date
    let catalog: Catalog

    init(version: Int = CatalogCache.currentVersion, fetchedAt: Date, catalog: Catalog) {
        self.version = version
        self.fetchedAt = fetchedAt
        self.catalog = catalog
    }
}

/// Result of a `loadCatalog` call. Distinguishes "fetched fresh" from
/// "cache served, network failed" so the catalog UI can surface a
/// "could not refresh" hint next to a stale-but-useful list.
enum CatalogLoadResult: Sendable {
    case fresh(catalog: Catalog, fetchedAt: Date)
    case cache(catalog: Catalog, fetchedAt: Date, refreshError: String?)
    case fallback(catalog: Catalog, reason: String)
}

enum CatalogServiceError: LocalizedError, Sendable {
    case transport(String)
    case http(status: Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .transport(let m): return "Catalog transport: \(m)"
        case .http(let status): return "Catalog HTTP \(status)"
        case .decode(let m):    return "Catalog decode: \(m)"
        }
    }
}

/// Fetches + caches the public template catalog from
/// awizemann.github.io. Mirrors `NousModelCatalogService` 1:1 in
/// shape: cache-first, 24h TTL, fallback when both cache and fetch
/// fail. The catalog is unauthenticated (a public static file on
/// GitHub Pages), so no bearer-token plumbing.
struct CatalogService: Sendable {

    /// Where the catalog lives in production. The static-site builder
    /// publishes here on `./scripts/catalog.sh publish`. **Versioned
    /// constant**: if we ever move this URL, every old Scarf install
    /// pegs at its bundled fallback until the user updates Scarf — so
    /// keep it stable. Settings-configurable in v2.9 only if anyone
    /// asks.
    static let baseURL = URL(string: "https://awizemann.github.io/scarf/templates/catalog.json")!
    static let cacheTTL: TimeInterval = 24 * 60 * 60   // 24h
    static let requestTimeout: TimeInterval = 10        // seconds

    /// Hard-coded fallback for offline-with-no-cache. Keeps the picker
    /// non-empty on a fresh install so the user sees *something* even
    /// before the first network call. **Update on every release that
    /// adds a template** — the validator's `tools/check-catalog-fallback-sync.py`
    /// (TODO) catches drift between this list and `templates/`.
    static let fallbackCatalog: Catalog = Catalog(
        schemaVersion: 1,
        templates: [
            CatalogEntry(
                id: "awizemann/site-status-checker",
                name: "Site Status Checker",
                version: "1.1.0",
                description: "Daily uptime check for a list of URLs you configure on install.",
                category: "monitoring",
                tags: ["monitoring", "uptime", "cron", "starter"],
                author: .init(name: "Alan Wizemann", url: "https://github.com/awizemann"),
                minScarfVersion: "2.3.0",
                minHermesVersion: "0.9.0",
                installUrl: "https://raw.githubusercontent.com/awizemann/scarf/main/templates/awizemann/site-status-checker/site-status-checker.scarftemplate",
                bundleSize: nil,
                bundleSha256: nil,
                detailSlug: "awizemann-site-status-checker",
                contents: .init(dashboard: true, agentsMd: true, cron: 1, config: 2, memory: nil, skills: nil),
                config: nil
            ),
            CatalogEntry(
                id: "awizemann/hackernews-digest",
                name: "HackerNews Daily Digest",
                version: "1.0.0",
                description: "A daily digest of HackerNews top stories. No API keys required.",
                category: "news",
                tags: ["news", "digest", "hackernews", "cron", "starter"],
                author: .init(name: "Alan Wizemann", url: "https://github.com/awizemann"),
                minScarfVersion: "2.3.0",
                minHermesVersion: "0.9.0",
                installUrl: "https://raw.githubusercontent.com/awizemann/scarf/main/templates/awizemann/hackernews-digest/hackernews-digest.scarftemplate",
                bundleSize: nil,
                bundleSha256: nil,
                detailSlug: "awizemann-hackernews-digest",
                contents: .init(dashboard: true, agentsMd: true, cron: 1, config: 3, memory: nil, skills: nil),
                config: nil
            )
        ]
    )

    private static let logger = Logger(subsystem: "com.scarf", category: "CatalogService")

    let context: ServerContext
    private let session: URLSession
    private let cachePath: String

    init(context: ServerContext = .local, session: URLSession = .shared) {
        self.context = context
        self.session = session
        self.cachePath = context.paths.catalogCache
    }

    // MARK: - Cache I/O

    /// Read the cache via the active transport so a remote droplet's
    /// cache lands on the droplet, not the user's Mac. Missing or
    /// malformed cache → nil; the loader treats that as "no cache" and
    /// kicks off a fresh fetch.
    func readCache() -> CatalogCache? {
        let transport = context.makeTransport()
        guard transport.fileExists(cachePath) else { return nil }
        do {
            let data = try transport.readFile(cachePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cache = try decoder.decode(CatalogCache.self, from: data)
            guard cache.version == CatalogCache.currentVersion else {
                Self.logger.info("catalog cache schema mismatch (got v\(cache.version), expected v\(CatalogCache.currentVersion)); ignoring")
                return nil
            }
            return cache
        } catch {
            Self.logger.warning("couldn't decode catalog cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func writeCache(_ cache: CatalogCache) {
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
            try transport.writeFile(cachePath, data: data)
        } catch {
            Self.logger.warning("couldn't write catalog cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    func isCacheStale(_ cache: CatalogCache) -> Bool {
        Date().timeIntervalSince(cache.fetchedAt) > Self.cacheTTL
    }

    // MARK: - Network fetch

    /// Make the catalog GET. Times out after `requestTimeout` so a
    /// hung network doesn't block the picker indefinitely. Returns the
    /// parsed catalog on success, throws on any HTTP / decode error.
    func fetchCatalog() async throws -> Catalog {
        var request = URLRequest(url: Self.baseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CatalogServiceError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CatalogServiceError.http(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Catalog.self, from: data)
        } catch {
            throw CatalogServiceError.decode(error.localizedDescription)
        }
    }

    // MARK: - Public entry

    /// Top-level "give me the catalog" entry point. Cache-first: serve
    /// from cache if fresh, fetch + write through if stale or empty,
    /// fall back to the hard-coded list when both fail. The caller
    /// renders based on the case so it can show a "could not refresh"
    /// hint next to a stale-but-still-useful list.
    func loadCatalog(forceRefresh: Bool = false) async -> CatalogLoadResult {
        let cached = readCache()

        if let cached, !forceRefresh, !isCacheStale(cached) {
            return .cache(catalog: cached.catalog, fetchedAt: cached.fetchedAt, refreshError: nil)
        }

        do {
            let catalog = try await fetchCatalog()
            let now = Date()
            writeCache(CatalogCache(fetchedAt: now, catalog: catalog))
            return .fresh(catalog: catalog, fetchedAt: now)
        } catch let error as CatalogServiceError {
            if let cached {
                Self.logger.warning("catalog refresh failed (\(error.localizedDescription, privacy: .public)); serving stale cache")
                return .cache(catalog: cached.catalog, fetchedAt: cached.fetchedAt, refreshError: error.localizedDescription)
            }
            Self.logger.warning("catalog refresh failed and no cache; serving fallback (\(error.localizedDescription, privacy: .public))")
            return .fallback(catalog: Self.fallbackCatalog, reason: error.localizedDescription)
        } catch {
            if let cached {
                return .cache(catalog: cached.catalog, fetchedAt: cached.fetchedAt, refreshError: error.localizedDescription)
            }
            return .fallback(catalog: Self.fallbackCatalog, reason: error.localizedDescription)
        }
    }
}
