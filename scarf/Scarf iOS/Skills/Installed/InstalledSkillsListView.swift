import SwiftUI
import ScarfCore
import ScarfDesign

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
                // Flat skills (`skills/<name>/`, the hub default) have no
                // category folder; give their group a heading anyway.
                Section(category.name.isEmpty ? String(localized: "Uncategorized") : category.name) {
                    ForEach(category.skills) { skill in
                        NavigationLink {
                            SkillDetailView(skill: skill, vm: vm)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(skill.name)
                                        .font(.body)
                                        .foregroundStyle(skill.enabled ? .primary : .secondary)
                                        .strikethrough(!skill.enabled, color: .secondary)
                                    Text("\(skill.files.count) file\(skill.files.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(ScarfColor.foregroundMuted)
                                }
                                Spacer(minLength: 0)
                                if skill.pinned {
                                    Image(systemName: "pin.fill")
                                        .font(.caption2)
                                        .foregroundStyle(ScarfColor.accent)
                                        .accessibilityLabel("Pinned by curator")
                                }
                                if !skill.enabled {
                                    Text("OFF")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(ScarfColor.backgroundTertiary)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                        .foregroundStyle(ScarfColor.foregroundMuted)
                                        .accessibilityLabel("Disabled — Hermes won't load this skill")
                                }
                            }
                        }
                        .scarfGoCompactListRow()
                        .listRowBackground(ScarfColor.backgroundSecondary)
                    }
                }
            }
        }
        .scarfGoListDensity()
        .scrollContentBackground(.hidden)
        .background(ScarfColor.backgroundPrimary)
        .searchable(text: $vm.searchText, placement: .navigationBarDrawer(displayMode: .always))
    }
}
