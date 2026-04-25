import SwiftUI
import ScarfCore

/// Installed skills sub-tab. Category-grouped list; tapping a row
/// pushes `SkillDetailView` for that skill. Filtering uses the VM's
/// `filteredCategories` derivation so the search field works against
/// the same model the Mac uses.
struct InstalledSkillsListView: View {
    @Bindable var vm: SkillsViewModel

    var body: some View {
        Group {
            if vm.isLoading && vm.categories.isEmpty {
                ProgressView("Scanning skills…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.categories.isEmpty {
                ContentUnavailableView {
                    Label("No skills installed", systemImage: "lightbulb")
                } description: {
                    Text("Browse the Hub tab to install one, or run `hermes skills install <name>` on the remote.")
                        .font(.caption)
                }
            } else {
                listContent
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        List {
            ForEach(vm.filteredCategories) { category in
                Section(category.name) {
                    ForEach(category.skills) { skill in
                        NavigationLink {
                            SkillDetailView(skill: skill, vm: vm)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                    .font(.body)
                                Text("\(skill.files.count) file\(skill.files.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .scarfGoCompactListRow()
                    }
                }
            }
        }
        .scarfGoListDensity()
        .searchable(text: $vm.searchText, placement: .navigationBarDrawer(displayMode: .always))
    }
}
