import ScarfCore
import ScarfDesign
import SwiftUI

/// Compact category picker for the catalog sheet. Renders the
/// available categories the loaded catalog actually carries (NOT a
/// hard-coded list — keeps the picker honest as the catalog grows or
/// shrinks). `nil` selection means "All categories."
struct CatalogCategoryFilter: View {
    @Binding var selected: String?
    let availableCategories: [String]

    var body: some View {
        Menu {
            Button {
                selected = nil
            } label: {
                Label("All", systemImage: selected == nil ? "checkmark" : "")
            }
            if !availableCategories.isEmpty {
                Divider()
            }
            ForEach(availableCategories, id: \.self) { category in
                Button {
                    selected = category
                } label: {
                    Label(category.capitalized, systemImage: selected == category ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: ScarfSpace.s1) {
                Image(systemName: "line.horizontal.3.decrease.circle")
                Text(selected.map { $0.capitalized } ?? "All")
                    .scarfStyle(.body)
            }
            .padding(.horizontal, ScarfSpace.s2)
            .padding(.vertical, 4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("catalog.categoryFilter")
    }
}
