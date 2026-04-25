import SwiftUI
import ScarfCore

/// Updates sub-tab. Mirrors Mac: Check button populates `vm.updates`;
/// Update All button is enabled only when there's at least one
/// available update. Both calls run remote `hermes skills` over SSH;
/// the parse logic is shared with Mac via `HermesSkillsHubParser`.
struct UpdatesView: View {
    @Bindable var vm: SkillsViewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                vm.checkForUpdates()
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
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
                                    .foregroundStyle(.secondary)
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
                }
            }
            .scarfGoListDensity()
        }
    }
}
