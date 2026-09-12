import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Exercises the catalog browser's view model. Most coverage is on
/// the filtering / sorting / install-state classification logic — the
/// load lifecycle is exercised by `CatalogServiceTests`.
///
/// These tests seed the VM directly via `_seedForTesting` and never load
/// from disk, so each needs only an isolated `ServerContext.local(home:)`
/// to sandbox the VM's construction-time path resolution away from the
/// real `~/.hermes`. No global `SCARF_HERMES_HOME` env, no cross-suite
/// lock, no shared mutable state — so the suite runs in parallel safely.
@MainActor
struct CatalogViewModelTests {

    @Test func displayedEntriesAppliesSearchFilter() async throws {
        let (vm, home) = try makeViewModel()
        defer { home.cleanup() }

        vm._seedForTesting(entries: Self.fixtureEntries)
        vm.searchText = "digest"

        let visible = vm.displayedEntries
        #expect(visible.count == 1)
        #expect(visible.first?.id == "awizemann/hackernews-digest")
    }

    @Test func displayedEntriesAppliesCategoryFilter() async throws {
        let (vm, home) = try makeViewModel()
        defer { home.cleanup() }

        vm._seedForTesting(entries: Self.fixtureEntries)
        vm.selectedCategory = "monitoring"

        let visible = vm.displayedEntries
        #expect(visible.count == 1)
        #expect(visible.first?.id == "awizemann/site-status-checker")
    }

    @Test func sortPutsOfficialAwizemannFirst() async throws {
        let (vm, home) = try makeViewModel()
        defer { home.cleanup() }

        // `community/zzzz` is alphabetically first by name; awizemann
        // entries should still rank above it because of the official
        // prefix.
        vm._seedForTesting(entries: [
            Self.makeEntry(id: "community/zebra", name: "AAAA Community"),
            Self.makeEntry(id: "awizemann/hackernews-digest", name: "HackerNews Daily Digest"),
            Self.makeEntry(id: "awizemann/site-status-checker", name: "Site Status Checker")
        ])

        let visible = vm.displayedEntries
        try #require(visible.count == 3)
        #expect(visible[0].id.hasPrefix("awizemann/"))
        #expect(visible[1].id.hasPrefix("awizemann/"))
        #expect(visible[2].id == "community/zebra")
    }

    @Test func availableCategoriesDeduplicatesAndSorts() async throws {
        let (vm, home) = try makeViewModel()
        defer { home.cleanup() }

        vm._seedForTesting(entries: [
            Self.makeEntry(id: "x/a", name: "A", category: "news"),
            Self.makeEntry(id: "x/b", name: "B", category: "monitoring"),
            Self.makeEntry(id: "x/c", name: "C", category: "monitoring"),
            Self.makeEntry(id: "x/d", name: "D", category: nil)
        ])

        #expect(vm.availableCategories == ["monitoring", "news"])
    }

    @Test func installStateReportsNotInstalledForUnknown() async throws {
        let (vm, home) = try makeViewModel()
        defer { home.cleanup() }

        vm._seedForTesting(entries: Self.fixtureEntries)
        // installedIndex stays empty.
        let state = vm.installState(for: Self.fixtureEntries[0])
        #expect(state == .notInstalled)
    }

    @Test func installURLPassesThroughHTTPS() async throws {
        let (vm, home) = try makeViewModel()
        defer { home.cleanup() }

        let url = vm.installURL(for: Self.fixtureEntries[0])
        #expect(url?.scheme == "https")
    }

    // MARK: - Helpers

    /// Build a `CatalogViewModel` whose catalog + install-index services
    /// are pinned to an isolated temp home, so nothing it does on init
    /// touches the developer's real `~/.hermes`. Caller owns the returned
    /// `TempHermesHome` and must `defer { home.cleanup() }`.
    private func makeViewModel() throws -> (vm: CatalogViewModel, home: TempHermesHome) {
        let home = try TempHermesHome()
        let vm = CatalogViewModel(
            catalogService: CatalogService(context: home.context),
            indexService: InstalledTemplatesIndex(context: home.context)
        )
        return (vm, home)
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
