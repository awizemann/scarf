import ScarfCore
import ScarfDesign
import SwiftUI

/// The catalog sheet's outer shell. Top: search field + category
/// filter + refresh button + "last refreshed" timestamp. Body: a list
/// of `CatalogRowView`s wrapped in `NavigationLink`s pushing
/// `CatalogDetailView`. The whole sheet is one `NavigationStack` so
/// the row → detail push uses native macOS behaviour.
struct CatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = CatalogViewModel()

    /// Closure the host (ProjectsView) provides — invoked when the
    /// user clicks Install on a detail page. Hands the URL to the
    /// existing `TemplateInstallerViewModel.openRemoteURL(_:)` flow.
    let onInstall: (URL) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                toolbar
                Divider()
                content
            }
            .navigationTitle("Template Catalog")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .task {
            // Initial load on first present. `refresh()` honours the
            // 24h TTL — repeat opens within a day reuse the cache.
            await viewModel.refresh()
        }
    }

    // MARK: - Subviews

    private var toolbar: some View {
        HStack(spacing: ScarfSpace.s2) {
            ScarfTextField("Search templates", text: $viewModel.searchText)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("catalog.searchField")
            CatalogCategoryFilter(
                selected: $viewModel.selectedCategory,
                availableCategories: viewModel.availableCategories
            )
            Spacer()
            refreshButton
        }
        .padding(ScarfSpace.s3)
    }

    private var refreshButton: some View {
        HStack(spacing: ScarfSpace.s2) {
            lastRefreshedLabel
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Button {
                Task { await viewModel.refresh(forceRefresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh catalog")
            .accessibilityIdentifier("catalog.refreshButton")
        }
    }

    @ViewBuilder
    private var lastRefreshedLabel: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            Text("")
        case .loaded(let kind):
            switch kind {
            case .fresh(let fetchedAt):
                Text("Refreshed \(relative(fetchedAt))")
            case .cache(let fetchedAt, let refreshError):
                if refreshError != nil {
                    Text("Cached • refresh failed")
                } else {
                    Text("Cached \(relative(fetchedAt))")
                }
            case .fallback:
                Text("Offline • bundled list")
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(ScarfColor.danger)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            VStack {
                Spacer()
                ProgressView("Loading catalog…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: ScarfSpace.s2) {
                Spacer()
                Text(message)
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.danger)
                Button("Retry") {
                    Task { await viewModel.refresh(forceRefresh: true) }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            entriesList
        }
    }

    private var entriesList: some View {
        let entries = viewModel.displayedEntries
        return Group {
            if entries.isEmpty {
                VStack(spacing: ScarfSpace.s2) {
                    Spacer()
                    Text("No templates match your filters.")
                        .scarfStyle(.body)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    NavigationLink(value: entry) {
                        CatalogRowView(
                            entry: entry,
                            installState: viewModel.installState(for: entry)
                        )
                    }
                }
                .listStyle(.inset)
                .navigationDestination(for: CatalogEntry.self) { entry in
                    CatalogDetailView(
                        entry: entry,
                        installState: viewModel.installState(for: entry),
                        onInstall: {
                            if let url = viewModel.installURL(for: entry) {
                                onInstall(url)
                                dismiss()
                            }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
