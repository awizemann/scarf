import Foundation
import ScarfCore
import os

/// VM for the in-app catalog browser. Owns the load lifecycle (fresh /
/// cache / fallback), the install-state index, and the search +
/// category filter. Hands off to the existing
/// `TemplateInstallerViewModel` for actual install — there is no
/// alternate install path here, which is the whole point: the catalog
/// is just a discovery surface that feeds the existing flow.
///
/// Single observable for the whole sheet. Views read filtered entries
/// via `displayedEntries`, refresh via `refresh()`, and install via
/// `installAction(for:)`.
@MainActor
@Observable
final class CatalogViewModel {

    private static let logger = Logger(subsystem: "com.scarf", category: "CatalogViewModel")

    // MARK: - State

    enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case loaded(LoadKind)
        case failed(message: String)

        enum LoadKind: Sendable, Equatable {
            case fresh(fetchedAt: Date)
            case cache(fetchedAt: Date, refreshError: String?)
            case fallback(reason: String)
        }
    }

    /// Catalog entries the loader returned. UI filters/sorts off this
    /// — never mutated except by `refresh()`.
    private(set) var entries: [CatalogEntry] = []

    /// `[templateId: installedVersion]`. Drives "Installed" /
    /// "Update available" badges. Rebuilt on every `refresh()`.
    private(set) var installedIndex: [String: String] = [:]

    private(set) var loadState: LoadState = .idle

    /// User-typed search string. Matches against name + description +
    /// tags case-insensitively. Empty = no filter.
    var searchText: String = ""

    /// `nil` = "All categories." Otherwise the picker constrains to
    /// entries whose `category` matches.
    var selectedCategory: String?

    // MARK: - Dependencies

    private let catalogService: CatalogService
    private let indexService: InstalledTemplatesIndex

    /// Defaults are nil-coalesced inside the body rather than declared
    /// as `= CatalogService()` / `= InstalledTemplatesIndex()` defaults
    /// on the parameter list. Both backing types are `@MainActor`-isolated
    /// (project default), so evaluating their initializers as default
    /// parameter values runs in a synchronous nonisolated context and
    /// the Swift 6 compiler rejects it. Constructing inside the
    /// `@MainActor` init body sidesteps the diagnostic without changing
    /// behavior.
    init(
        catalogService: CatalogService? = nil,
        indexService: InstalledTemplatesIndex? = nil
    ) {
        self.catalogService = catalogService ?? CatalogService()
        self.indexService = indexService ?? InstalledTemplatesIndex()
    }

    /// Test-only seam. Production constructs via `init(catalogService:indexService:)`
    /// then calls `refresh()` to populate. Tests can short-circuit the
    /// load lifecycle by handing fixture entries directly. Marked
    /// `internal` (default) so it's invisible to other modules; the
    /// test target's `@testable import scarf` is what unlocks it.
    func _seedForTesting(entries: [CatalogEntry], installedIndex: [String: String] = [:]) {
        self.entries = entries
        self.installedIndex = installedIndex
    }

    // MARK: - Public surface

    /// All categories present in the loaded entries, sorted. Used to
    /// populate the category picker chrome.
    var availableCategories: [String] {
        let cats = entries.compactMap(\.category).filter { !$0.isEmpty }
        return Array(Set(cats)).sorted()
    }

    /// Apply search + category filters to `entries`. Sort: shipped
    /// awizemann templates first (so the official ones don't get
    /// buried), then alphabetical by name.
    var displayedEntries: [CatalogEntry] {
        let filtered = entries.filter { entry in
            if let selectedCategory, entry.category != selectedCategory {
                return false
            }
            return matchesSearch(entry)
        }
        return filtered.sorted(by: Self.sortRule)
    }

    /// Trigger a load. `forceRefresh: true` skips the fresh-cache
    /// short-circuit and always tries the network. Always rebuilds
    /// the installed index, since the user may have installed/uninstalled
    /// since the last load.
    ///
    /// `indexService.build()` walks the projects registry + every
    /// project's lock file synchronously, so we run it on a detached
    /// task — sync file I/O on `@MainActor` would jank the catalog
    /// sheet during refresh on hosts with many projects.
    func refresh(forceRefresh: Bool = false) async {
        loadState = .loading
        let result = await catalogService.loadCatalog(forceRefresh: forceRefresh)
        let indexService = self.indexService
        let index = await Task.detached { indexService.build() }.value
        await applyLoad(result: result, index: index)
    }

    /// Classify a row's install state from the current index. Used by
    /// `CatalogRowView` to render the badge.
    func installState(for entry: CatalogEntry) -> InstalledTemplatesIndex.InstallState {
        InstalledTemplatesIndex.classify(
            catalogVersion: entry.version,
            installedVersion: installedIndex[entry.id]
        )
    }

    /// Build the URL for the install flow. The catalog ships HTTPS
    /// install URLs; we hand the URL straight to the existing installer
    /// VM via `TemplateInstallerViewModel.openRemoteURL(_:)`.
    func installURL(for entry: CatalogEntry) -> URL? {
        URL(string: entry.installUrl)
    }

    // MARK: - Internals

    private func applyLoad(result: CatalogLoadResult, index: [String: String]) {
        installedIndex = index
        switch result {
        case .fresh(let catalog, let fetchedAt):
            entries = catalog.templates
            loadState = .loaded(.fresh(fetchedAt: fetchedAt))
        case .cache(let catalog, let fetchedAt, let refreshError):
            entries = catalog.templates
            loadState = .loaded(.cache(fetchedAt: fetchedAt, refreshError: refreshError))
        case .fallback(let catalog, let reason):
            entries = catalog.templates
            loadState = .loaded(.fallback(reason: reason))
        }
    }

    private func matchesSearch(_ entry: CatalogEntry) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let needle = q.lowercased()
        if entry.name.lowercased().contains(needle) { return true }
        if (entry.description ?? "").lowercased().contains(needle) { return true }
        if entry.tags.contains(where: { $0.lowercased().contains(needle) }) { return true }
        return false
    }

    /// Sort: official `awizemann/...` templates first, then alphabetical
    /// by name. Keeps the curated subset visible at the top while a
    /// growing community catalog stays browsable.
    private static func sortRule(_ a: CatalogEntry, _ b: CatalogEntry) -> Bool {
        let aOfficial = a.id.hasPrefix("awizemann/")
        let bOfficial = b.id.hasPrefix("awizemann/")
        if aOfficial != bOfficial { return aOfficial && !bOfficial }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
