import SwiftUI
import ScarfCore

/// iOS Skills tab — 3-tab segmented surface mirroring the Mac
/// `SkillsView`. Owns one `SkillsViewModel` (ScarfCore-side, unified
/// in v2.5) shared across the three sub-tabs so installed-list state +
/// hub query/results + update results all live in one place.
///
/// Sub-tabs:
/// - **Installed**: category-grouped list. Tap a skill to view its
///   files, edit content, or uninstall.
/// - **Browse Hub**: search + source picker. Tap to install. Calls
///   remote `hermes skills search/browse` over SSH.
/// - **Updates**: check + update-all buttons. Calls remote
///   `hermes skills check / update --yes`.
struct SkillsView: View {
    let config: IOSServerConfig

    @State private var vm: SkillsViewModel
    @State private var currentTab: Tab = .installed

    private static let sharedContextID: ServerID = ServerID(
        uuidString: "00000000-0000-0000-0000-0000000000A1"
    )!

    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case hub = "Browse Hub"
        case updates = "Updates"
        var id: String { rawValue }
        var displayName: String { rawValue }
    }

    init(config: IOSServerConfig) {
        self.config = config
        let ctx = config.toServerContext(id: Self.sharedContextID)
        _vm = State(initialValue: SkillsViewModel(context: ctx))
    }

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 6)
            statusBanner
            Divider()
            content
        }
        .navigationTitle(titleString)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .refreshable { await vm.load() }
    }

    private var titleString: String {
        vm.totalSkillCount > 0 ? "Skills (\(vm.totalSkillCount))" : "Skills"
    }

    @ViewBuilder
    private var tabPicker: some View {
        Picker("Section", selection: $currentTab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.displayName).tag(tab)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let msg = vm.hubMessage {
            HStack(spacing: 6) {
                if vm.isHubLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08))
        } else if vm.isHubLoading {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Working…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch currentTab {
        case .installed:
            InstalledSkillsListView(vm: vm)
        case .hub:
            HubBrowseView(vm: vm)
        case .updates:
            UpdatesView(vm: vm)
        }
    }
}
