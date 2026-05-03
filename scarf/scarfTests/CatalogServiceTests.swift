import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Exercises the catalog browser's fetch + cache path. Six suites
/// covering the result-enum surface plus a snapshot test that catches
/// catalog-schema drift between the Python validator
/// (`tools/build-catalog.py`) and the Swift `Catalog` decoder.
///
/// All tests run against an isolated `SCARF_HERMES_HOME` tmpdir so the
/// user's real `~/.hermes/scarf/catalog_cache.json` is never touched.
/// Serialized because we mutate process-wide env.
@Suite(.serialized)
struct CatalogServiceTests {

    private static let envKey = "SCARF_HERMES_HOME"

    // MARK: - Snapshot

    /// Decode the live `templates/catalog.json` shipped in the repo
    /// against the Swift `Catalog` decoder. If this fails, the validator
    /// emitted a field shape the Swift side doesn't accept — fix
    /// whichever side is wrong (usually the Swift side: catch up on a
    /// field the Python validator added).
    @Test func liveCatalogJSONDecodesAgainstSwiftModel() throws {
        let catalogURL = try Self.locateRepoCatalog()
        let data = try Data(contentsOf: catalogURL)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        #expect(catalog.templates.count >= 1)
        let hn = try #require(catalog.templates.first(where: { $0.id == "awizemann/hackernews-digest" }))
        #expect(hn.name == "HackerNews Daily Digest")
        #expect(hn.installUrl.hasPrefix("https://"))
        #expect(hn.config?.fields.count == 3)
    }

    // MARK: - Cache lifecycle

    @Test func freshCacheIsServedWithoutNetwork() async throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let context = ServerContext.local
        let service = CatalogService(context: context)
        let now = Date()
        // Seed a fresh cache.
        try writeCacheFixture(at: context.paths.catalogCache, fetchedAt: now)

        let result = await service.loadCatalog(forceRefresh: false)
        switch result {
        case .cache(let catalog, let fetchedAt, let refreshError):
            #expect(catalog.templates.count == 1)
            #expect(catalog.templates.first?.id == "test/cached")
            #expect(refreshError == nil)
            #expect(abs(fetchedAt.timeIntervalSince(now)) < 1)
        case .fresh, .fallback:
            Issue.record("expected cache result, got \(result)")
        }
    }

    @Test func corruptCacheIsIgnored() throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let context = ServerContext.local
        let cachePath = context.paths.catalogCache
        let parent = (cachePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        // Write garbage where we expect a valid cache.
        try "not-json-at-all".data(using: .utf8)!
            .write(to: URL(fileURLWithPath: cachePath))

        let service = CatalogService(context: context)
        // Cache is unreadable → readCache returns nil; loadCatalog will
        // attempt a network fetch which fails (no internet stub here)
        // and falls through to the bundled fallback. We don't assert
        // *which* of fresh/cache/fallback we get because that depends
        // on the dev Mac's network state — only that the corrupt
        // cache didn't crash the process.
        #expect(service.readCache() == nil)
    }

    @Test func cacheSchemaVersionMismatchIsIgnored() throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let context = ServerContext.local
        let cachePath = context.paths.catalogCache
        let parent = (cachePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        // v999 cache — far ahead of currentVersion. Loader rejects.
        let payload = #"{"version":999,"fetchedAt":"2026-05-03T00:00:00Z","catalog":{"templates":[]}}"#
        try payload.data(using: .utf8)!.write(to: URL(fileURLWithPath: cachePath))

        let service = CatalogService(context: context)
        #expect(service.readCache() == nil)
    }

    // MARK: - Staleness

    @Test func isCacheStaleHonorsTTL() throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let service = CatalogService(context: .local)
        let twentyThreeHoursAgo = Date().addingTimeInterval(-23 * 60 * 60)
        let twentyFiveHoursAgo = Date().addingTimeInterval(-25 * 60 * 60)
        let fresh = CatalogCache(fetchedAt: twentyThreeHoursAgo, catalog: Self.minimalCatalog)
        let stale = CatalogCache(fetchedAt: twentyFiveHoursAgo, catalog: Self.minimalCatalog)
        #expect(!service.isCacheStale(fresh))
        #expect(service.isCacheStale(stale))
    }

    // MARK: - Fallback

    /// One malformed catalog entry must NOT fail the whole list — the
    /// per-entry doc-comment promises this so a single typo on the live
    /// catalog doesn't leave every Scarf user with an empty picker.
    /// Decoder drops the bad entry with a logged warning and keeps the
    /// rest.
    @Test func malformedEntryIsDroppedRestSurvive() throws {
        // First entry has every required field; second is missing
        // `tags` (required by `CatalogEntry`); third is well-formed.
        let json = """
        {
          "schemaVersion": 1,
          "templates": [
            {
              "id": "good/one",
              "name": "Good One",
              "version": "1.0.0",
              "tags": ["a"],
              "author": {"name": "T"},
              "installUrl": "https://example.invalid/one.scarftemplate"
            },
            {
              "id": "bad/missing-tags",
              "name": "Missing Tags",
              "version": "1.0.0",
              "author": {"name": "T"},
              "installUrl": "https://example.invalid/bad.scarftemplate"
            },
            {
              "id": "good/three",
              "name": "Good Three",
              "version": "1.0.0",
              "tags": ["b"],
              "author": {"name": "T"},
              "installUrl": "https://example.invalid/three.scarftemplate"
            }
          ]
        }
        """
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(json.utf8))
        let ids = catalog.templates.map(\.id)
        #expect(ids == ["good/one", "good/three"])
    }

    @Test func bundledFallbackIsNonEmpty() {
        // The fallback ships with the catalog as a hardcoded list so
        // a fresh-install / offline user still sees something on first
        // open. Drift between this list and the live catalog is a
        // separate concern (TODO: tools/check-catalog-fallback-sync.py).
        #expect(!CatalogService.fallbackCatalog.templates.isEmpty)
        let ids = CatalogService.fallbackCatalog.templates.map(\.id)
        #expect(ids.contains("awizemann/site-status-checker"))
        #expect(ids.contains("awizemann/hackernews-digest"))
    }

    // MARK: - Helpers

    /// Bundle returned by `makeTmpHome()` so each `@Test` func can
    /// capture both the tmpdir and the registry-lock snapshot in a
    /// `let` without `mutating` (Swift Testing's `@Test` macros
    /// disallow mutating instance methods on `@Suite struct`s).
    /// `TestRegistryLock` serializes us against
    /// `SessionAttributionServiceTests`, `ProjectsViewModelTests`, and
    /// every other suite that mutates `ServerContext.local.paths` —
    /// without it, Swift Testing's parallel-suite scheduler lets one
    /// suite's `setenv("SCARF_HERMES_HOME", ...)` leak into another
    /// suite's reads and cause non-deterministic failures.
    private struct HomeFixture {
        let homeURL: URL
        let registrySnapshot: Data?
    }

    private func makeTmpHome() throws -> HomeFixture {
        let registrySnapshot = TestRegistryLock.acquireAndSnapshot()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let path = base.appendingPathComponent("scarf-catalog-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        // Drop the sentinel marker BEFORE setenv. Without the marker,
        // `HermesProfileResolver.scarfHermesHomeOverride()` ignores
        // the env var and falls through to the real `~/.hermes/` —
        // protecting the user's real home from any test that crashes
        // mid-teardown or leaks the env var to another process.
        try Data().write(to: path.appendingPathComponent(HermesProfileResolver.testHomeMarkerFilename))
        setenv(Self.envKey, path.path, 1)
        HermesProfileResolver.invalidateCache()
        return HomeFixture(homeURL: path, registrySnapshot: registrySnapshot)
    }

    private func teardown(_ fixture: HomeFixture) {
        unsetenv(Self.envKey)
        HermesProfileResolver.invalidateCache()
        try? FileManager.default.removeItem(at: fixture.homeURL)
        TestRegistryLock.restore(fixture.registrySnapshot)
    }

    private func writeCacheFixture(at path: String, fetchedAt: Date) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let cache = CatalogCache(fetchedAt: fetchedAt, catalog: Self.minimalCatalog)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cache)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private static let minimalCatalog = Catalog(
        schemaVersion: 1,
        templates: [
            CatalogEntry(
                id: "test/cached",
                name: "Cached Test Template",
                version: "1.0.0",
                description: "Fixture entry used in CatalogServiceTests.",
                category: "test",
                tags: ["fixture"],
                author: .init(name: "Tester", url: nil),
                minScarfVersion: nil,
                minHermesVersion: nil,
                installUrl: "https://example.invalid/cached.scarftemplate",
                bundleSize: nil,
                bundleSha256: nil,
                detailSlug: "test-cached",
                contents: nil,
                config: nil
            )
        ]
    )

    /// Walk up from the test source file until we find the repo's
    /// `templates/catalog.json`. Working dirs differ between
    /// `xcodebuild test` and an Xcode IDE run, so the fixed
    /// "../templates/catalog.json" relative path doesn't survive both.
    private static func locateRepoCatalog() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("templates/catalog.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
}
