import SwiftUI
import ScarfCore
import ScarfDesign

/// Updates sub-tab. Mirrors Mac: Check button populates `vm.updates`;
/// Update All button is enabled only when there's at least one
/// available update. Both calls run remote `hermes skills` over SSH;
/// the parse logic is shared with Mac via `HermesSkillsHubParser`.
struct UpdatesView: View {
    @Bindable var vm: SkillsViewModel

    @Environment(\.hermesCapabilities) private var capabilitiesStore
    /// Skill awaiting confirmation for a destructive `--force` update.
    @State private var forceUpdateTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            // Hermes v0.20.4+ skips locally-edited skills. Empty on
            // older hosts, so this section stays invisible there.
            if !vm.skippedLocalEdits.isEmpty {
                keptLocalEditsSection
                Divider()
            }
            content
        }
        .alert(
            "Discard local edits to \(forceUpdateTarget ?? "")?",
            isPresented: Binding(
                get: { forceUpdateTarget != nil },
                set: { if !$0 { forceUpdateTarget = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { forceUpdateTarget = nil }
            Button("Update & Discard", role: .destructive) {
                if let name = forceUpdateTarget { vm.forceUpdateSkill(name) }
                forceUpdateTarget = nil
            }
        } message: {
            Text("The upstream version will replace your edited copy. This can't be undone.")
        }
        .background(ScarfColor.backgroundPrimary)
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                vm.checkForUpdates()
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(ScarfPrimaryButton())
            .controlSize(.small)
            .disabled(vm.isHubLoading)

            if !vm.updates.isEmpty {
                Button {
                    vm.updateAll()
                } label: {
                    Label("Update All", systemImage: "arrow.down.app")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.isHubLoading)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Skills the last "Update All" left alone because they carry local
    /// edits. The override re-runs `skills update <name> --force` for
    /// that one skill — destructive, never applied in bulk, and only
    /// offered on hosts that support it.
    @ViewBuilder
    private var keptLocalEditsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "\(vm.skippedLocalEdits.count) skill(s) kept your local edits",
                systemImage: "pencil.and.outline"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.orange)
            ForEach(vm.skippedLocalEdits, id: \.self) { name in
                HStack {
                    Text(name).font(.callout.monospaced())
                    Spacer()
                    if capabilitiesStore?.capabilities.hasSkillsUpdateForce ?? false {
                        Button("Update anyway…") { forceUpdateTarget = name }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(vm.isHubLoading)
                    }
                }
            }
            Text("Updating these would overwrite your edits, so Hermes skipped them.")
                .font(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if vm.updates.isEmpty {
            ContentUnavailableView {
                Label("No updates", systemImage: "checkmark.circle.fill")
            } description: {
                Text("Tap Check for Updates to query each installed skill against its source registry.")
                    .font(.caption)
            }
        } else {
            List {
                ForEach(vm.updates) { update in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.identifier)
                                .font(.callout.monospaced())
                            HStack(spacing: 6) {
                                Text(update.currentVersion)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(ScarfColor.foregroundMuted)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(update.availableVersion)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.green)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .scarfGoCompactListRow()
                    .listRowBackground(ScarfColor.backgroundSecondary)
                }
            }
            .scarfGoListDensity()
            .scrollContentBackground(.hidden)
            .background(ScarfColor.backgroundPrimary)
        }
    }
}
