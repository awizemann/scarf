import SwiftUI
import ScarfCore
import ScarfDesign

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
///   `hermes skills check / update`. There is no `--yes` on either verb:
///   `skills update` takes an optional `name` and `--force` only
///   (`hermes_cli/subcommands/skills.py:79-83` @ `v2026.9.7`), and passing an
///   unknown flag would fail the whole command at argparse time. What the
///   code shells is `SkillsViewModel.updateAllArgs` /
///   `["skills", "update", "--force", "--", name]`.
struct SkillsView: View {
    let config: IOSServerConfig

    @State private var vm: SkillsViewModel
    @State private var currentTab: Tab = .installed
    /// v2.5 SkillSnapshotService diff against the per-(server, profile)
    /// last-seen snapshot. Drives the "What's New" pill at the top of the
    /// tab. Nil before first compute or when there's nothing changed.
    @State private var snapshotDiff: SkillSnapshotDiff?

    /// The real, profile-scoped context injected by `ScarfGoTabRoot`
    /// (`cfg.toServerContext(id: serverID)` — the actual `serverID` plus a
    /// `remoteHome` already re-pointed at the selected profile). The
    /// snapshot baseline keys off THIS so it stays per-(server, profile);
    /// the view-model below deliberately uses `sharedContextID` instead, so
    /// don't conflate the two.
    @Environment(\.serverContext) private var serverContext

    /// Fixed context id for the Skills view-model ONLY — it keys the pooled
    /// SSH connection + home cache so the tab reuses one connection instead
    /// of opening a fresh channel per appearance. Profile scoping rides on
    /// `config.remoteHome` (which `ScarfGoTabRoot` re-points), NOT on this
    /// id, so the skills LIST is already correct per profile. The snapshot
    /// baseline must NOT use this id — it's shared across servers/profiles
    /// and would bleed the diff; it uses `serverContext` above instead.
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
            // v2.5 "What's New" pill — surfaced above the sub-tab
            // picker when the per-server snapshot diff has changes.
            // First-load with no prior snapshot silently primes (no
            // pill, the snapshot just records what's there).
            //
            // Issue #78: scope the pill to the Installed tab. It
            // describes local file deltas; rendering it on Updates
            // contradicts the upstream-version-check pane below.
            if currentTab == .installed,
               let diff = snapshotDiff,
               diff.hasChanges,
               !diff.previousSnapshotEmpty {
                whatsNewPill(diff: diff)
            }
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
        .task {
            await vm.load()
            recomputeSnapshotDiff()
        }
        .refreshable {
            await vm.load()
            recomputeSnapshotDiff()
        }
    }

    /// Snapshot service scoped to the real server AND its selected Hermes
    /// profile (#120), derived from the injected context's `paths.home`
    /// (which `ScarfGoTabRoot` has already re-pointed at the profile). A
    /// default/root home yields a nil profile → the bare per-server key.
    /// This is what stops the pill bleeding across profiles and servers.
    private var snapshotService: SkillSnapshotService {
        SkillSnapshotService(
            serverID: serverContext.id,
            profile: HermesProfileScope.profileName(forHome: serverContext.paths.home)
        )
    }

    /// Compute the snapshot diff against the per-(server, profile)
    /// last-seen state. First load with no prior snapshot silently primes
    /// — the pill never renders for users on day one. (After this fix the
    /// key moved off the fixed `sharedContextID`, so the first post-upgrade
    /// load re-primes silently rather than flashing a bogus pill.)
    private func recomputeSnapshotDiff() {
        let allSkills = vm.categories.flatMap(\.skills)
        let svc = snapshotService
        let diff = svc.diff(against: allSkills)
        if diff.previousSnapshotEmpty {
            svc.markSeen(allSkills)
            snapshotDiff = nil
        } else {
            snapshotDiff = diff
        }
    }

    /// "2 new, 4 updated since you last looked" pill at the top of
    /// the tab. Tapping "Seen" persists the current set as the new
    /// baseline + dismisses the pill.
    @ViewBuilder
    private func whatsNewPill(diff: SkillSnapshotDiff) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text(diff.label)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            Button("Seen") {
                snapshotService.markSeen(vm.categories.flatMap(\.skills))
                snapshotDiff = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.1))
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
                    .foregroundStyle(ScarfColor.foregroundMuted)
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
                    .foregroundStyle(ScarfColor.foregroundMuted)
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
