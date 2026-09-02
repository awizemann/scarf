import SwiftUI
import ScarfCore
import ScarfDesign

#if canImport(SQLite3)

/// iOS Curator surface — read-mostly view of `hermes curator status`
/// with Run Now / Pause / Resume actions and inline pin toggles on
/// the leaderboard rows. Mirrors the Mac surface visually but folds
/// into a single SwiftUI List for thumb-friendly scrolling.
///
/// Capability-gated upstream: only routed when
/// `HermesCapabilities.hasCurator` is true.
struct CuratorView: View {
    @State private var viewModel: CuratorViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    init(context: ServerContext) {
        _viewModel = State(initialValue: CuratorViewModel(context: context))
    }

    /// v0.13 capability gate. Drives both the synchronous `runNow`
    /// blocking-with-spinner behavior AND the read-only Archived
    /// section. Pre-v0.13 hosts skip the archive load entirely so we
    /// don't spam `hermes curator list-archived` against a binary that
    /// would error out.
    private var archiveAvailable: Bool {
        capabilitiesStore?.capabilities.hasCuratorArchive ?? false
    }

    var body: some View {
        List {
            Section {
                statusRow
                LabeledContent("Last run", value: viewModel.status.lastRunISO ?? "Never")
                if let summary = viewModel.status.lastSummary {
                    LabeledContent("Summary", value: summary)
                }
                LabeledContent("Interval", value: viewModel.status.intervalLabel)
                LabeledContent("Stale after", value: viewModel.status.staleAfterLabel)
                LabeledContent("Archive after", value: viewModel.status.archiveAfterLabel)
                LabeledContent("Runs", value: "\(viewModel.status.runCount)")
            } header: {
                Text("Status")
            } footer: {
                actionFooter
            }

            Section("Skills") {
                LabeledContent("Total", value: "\(viewModel.status.totalSkills)")
                LabeledContent("Active", value: "\(viewModel.status.activeSkills)")
                LabeledContent("Stale", value: "\(viewModel.status.staleSkills)")
                LabeledContent("Archived", value: "\(viewModel.status.archivedSkills)")
            }

            if !viewModel.status.pinnedNames.isEmpty {
                Section("Pinned") {
                    ForEach(viewModel.status.pinnedNames, id: \.self) { name in
                        HStack {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(ScarfColor.accent)
                            Text(name)
                            Spacer()
                            Button("Unpin") {
                                Task { await viewModel.unpin(name) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            if !viewModel.status.leastRecentlyActive.isEmpty {
                rowsSection(title: "Least recently active", rows: viewModel.status.leastRecentlyActive)
            }
            if !viewModel.status.mostActive.isEmpty {
                rowsSection(title: "Most active", rows: viewModel.status.mostActive)
            }
            if !viewModel.status.leastActive.isEmpty {
                rowsSection(title: "Least active", rows: viewModel.status.leastActive)
            }

            if let report = viewModel.lastReportMarkdown {
                Section("Last report") {
                    Text(report)
                        .font(ScarfFont.monoSmall)
                        .textSelection(.enabled)
                }
            }

            if archiveAvailable {
                archivedSection
            }
        }
        .navigationTitle("Curator")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            await viewModel.load()
            if archiveAvailable {
                await viewModel.loadArchive()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.transientMessage {
                toastView(toast)
            }
        }
        .task {
            await viewModel.load()
            if archiveAvailable {
                await viewModel.loadArchive()
            }
        }
    }

    /// v0.13 read-only Archived list. iOS doesn't expose Restore /
    /// Prune-this / Prune-all — that's a Mac-only surface in v2.8.0.
    /// The footer signposts the user to the Mac app when there are
    /// rows to act on.
    @ViewBuilder
    private var archivedSection: some View {
        Section {
            if viewModel.archivedSkills.isEmpty {
                Text("No archived skills — Curator will move stale skills here after the next review cycle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.archivedSkills) { skill in
                    archivedRow(skill)
                }
            }
        } header: {
            Text("Archived")
        } footer: {
            if !viewModel.archivedSkills.isEmpty {
                Text("Restore archived skills, or archive idle ones, from the Mac app.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func archivedRow(_ skill: HermesCuratorArchivedSkill) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(skill.name)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                if let category = skill.category, !category.isEmpty {
                    ScarfBadge(verbatim: category, kind: .neutral)
                }
            }
            HStack(spacing: 6) {
                if let reason = skill.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(skill.archivedAtLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let size = skill.sizeBytes, size > 0 {
                Text(skill.sizeLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusRow: some View {
        HStack {
            Text("Curator")
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        let kind: ScarfBadgeKind
        let label: LocalizedStringKey
        switch viewModel.status.state {
        case .enabled:  kind = .success; label = "Enabled"
        case .paused:   kind = .warning; label = "Paused"
        case .disabled: kind = .neutral; label = "Disabled"
        case .unknown:  kind = .neutral; label = "Unknown"
        }
        return ScarfBadge(label, kind: kind)
    }

    private var actionFooter: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.runNow(synchronous: archiveAvailable, timeout: 600) }
            } label: {
                Label("Run now", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.isLoading)

            if viewModel.status.state == .enabled {
                Button {
                    Task { await viewModel.pause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if viewModel.status.state == .paused {
                Button {
                    Task { await viewModel.resume() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private func rowsSection(title: String, rows: [HermesCuratorSkillRow]) -> some View {
        Section(title) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.name)
                            .font(.body)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            Task { await viewModel.pin(row.name) }
                        } label: {
                            Image(systemName: viewModel.status.pinnedNames.contains(row.name) ? "pin.fill" : "pin")
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 6) {
                        Text("use \(row.useCount) · view \(row.viewCount) · patch \(row.patchCount)")
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.lastActivityLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ScarfColor.success)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .padding(.bottom, 12)
        .transition(.opacity)
    }
}

#endif
