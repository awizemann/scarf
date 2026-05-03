import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Exercises the catalog browser's view model. Most coverage is on
/// the filtering / sorting / install-state classification logic — the
/// load lifecycle is exercised by `CatalogServiceTests`. Serialized
/// because the underlying `loadCatalog` walks `SCARF_HERMES_HOME`
/// state.
@MainActor
@Suite(.serialized)
struct CatalogViewModelTests {

    private static let envKey = "SCARF_HERMES_HOME"

    @Test func displayedEntriesAppliesSearchFilter() async throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let vm = CatalogViewModel()
        vm._seedForTesting(entries: Self.fixtureEntries)
        vm.searchText = "digest"

        let visible = vm.displayedEntries
        #expect(visible.count == 1)
        #expect(visible.first?.id == "awizemann/hackernews-digest")
    }

    @Test func displayedEntriesAppliesCategoryFilter() async throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let vm = CatalogViewModel()
        vm._seedForTesting(entries: Self.fixtureEntries)
        vm.selectedCategory = "monitoring"

        let visible = vm.displayedEntries
        #expect(visible.count == 1)
        #expect(visible.first?.id == "awizemann/site-status-checker")
    }

    @Test func sortPutsOfficialAwizemannFirst() async throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let vm = CatalogViewModel()
        // `community/zzzz` is alphabetically first by name; awizemann
        // entries should still rank above it because of the official
        // prefix.
        vm._seedForTesting(entries: [
            Self.makeEntry(id: "community/zebra", name: "AAAA Community"),
            Self.makeEntry(id: "awizemann/hackernews-digest", name: "HackerNews Daily Digest"),
            Self.makeEntry(id: "awizemann/site-status-checker", name: "Site Status Checker")
        ])

        let visible = vm.displayedEntries
        #expect(visible.count == 3)
        #expect(visible[0].id.hasPrefix("awizemann/"))
        #expect(visible[1].id.hasPrefix("awizemann/"))
        #expect(visible[2].id == "community/zebra")
    }

    @Test func availableCategoriesDeduplicatesAndSorts() async throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let vm = CatalogViewModel()
        vm._seedForTesting(entries: [
            Self.makeEntry(id: "x/a", name: "A", category: "news"),
            Self.makeEntry(id: "x/b", name: "B", category: "monitoring"),
            Self.makeEntry(id: "x/c", name: "C", category: "monitoring"),
            Self.makeEntry(id: "x/d", name: "D", category: nil)
        ])

        #expect(vm.availableCategories == ["monitoring", "news"])
    }

    @Test func installStateReportsNotInstalledForUnknown() async throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let vm = CatalogViewModel()
        vm._seedForTesting(entries: Self.fixtureEntries)
        // installedIndex stays empty.
        let state = vm.installState(for: Self.fixtureEntries[0])
        #expect(state == .notInstalled)
    }

    @Test func installURLPassesThroughHTTPS() async throws {
        let fixture = try makeTmpHome()
        defer { teardown(fixture) }

        let vm = CatalogViewModel()
        let url = vm.installURL(for: Self.fixtureEntries[0])
        #expect(url?.scheme == "https")
    }

    // MARK: - Helpers

    /// Cross-suite serialization. See `CatalogServiceTests` for rationale.
    private struct HomeFixture {
        let homeURL: URL
        let registrySnapshot: Data?
    }

    private func makeTmpHome() throws -> HomeFixture {
        let registrySnapshot = TestRegistryLock.acquireAndSnapshot()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let path = base.appendingPathComponent("scarf-vm-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: path.path + "/scarf",
            withIntermediateDirectories: true
        )
        // Sentinel marker — see CatalogServiceTests for rationale.
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

    private static let fixtureEntries: [CatalogEntry] = [
        makeEntry(id: "awizemann/hackernews-digest", name: "HackerNews Daily Digest", category: "news", tags: ["digest", "hackernews"]),
        makeEntry(id: "awizemann/site-status-checker", name: "Site Status Checker", category: "monitoring", tags: ["uptime"])
    ]

    private static func makeEntry(
        id: String,
        name: String,
        category: String? = "test",
        tags: [String] = []
    ) -> CatalogEntry {
        CatalogEntry(
            id: id,
            name: name,
            version: "1.0.0",
            description: "Fixture for CatalogViewModelTests.",
            category: category,
            tags: tags,
            author: .init(name: "Tester", url: nil),
            minScarfVersion: nil,
            minHermesVersion: nil,
            installUrl: "https://example.invalid/\(id).scarftemplate",
            bundleSize: nil,
            bundleSha256: nil,
            detailSlug: id.replacingOccurrences(of: "/", with: "-"),
            contents: nil,
            config: nil
        )
    }
}
