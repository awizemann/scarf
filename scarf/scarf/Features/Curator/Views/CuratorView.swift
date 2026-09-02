import SwiftUI
import ScarfCore
import ScarfDesign

/// Mac UI for Hermes's autonomous skill curator (v0.12 base + v0.13
/// archive/prune surface).
///
/// Surfaces the running state (enabled / paused / disabled), last-run
/// metadata, agent-created skill counts, the most/least-active /
/// least-recently-active leaderboards, and on v0.13+ hosts the new
/// archived-skills section + per-row Archive button on each leaderboard
/// entry. Pin / unpin / restore / archive / prune route through
/// CuratorViewModel → CuratorService.
///
/// Capability-gated upstream: AppCoordinator only wires the sidebar
/// item when `HermesCapabilities.hasCurator` is true. Archive surfaces
/// gate independently on `hasCuratorArchive`; pre-v0.13 hosts see the
/// v2.7.x layout unchanged (legacy `CuratorRestoreSheet` reachable from
/// the overflow menu, no Archive section, fire-and-forget Run Now).
struct CuratorView: View {
    @State private var viewModel: CuratorViewModel
    @State private var showRestoreSheet = false
    @State private var showAdoptAllConfirmation = false

    @Environment(\.hermesCapabilities) private var capabilitiesStore

    init(context: ServerContext) {
        _viewModel = State(initialValue: CuratorViewModel(context: context))
    }

    /// Single source of truth for "v0.13 archive surface visible". Read
    /// once in `body` and threaded into sub-views. Defensive default to
    /// `false` so previews / smoke tests behave like a pre-v0.13 host.
    private var archiveAvailable: Bool {
        capabilitiesStore?.capabilities.hasCuratorArchive ?? false
    }

    /// v0.20 adopt surface. Hidden entirely on pre-0.20 hosts so the
    /// legacy layout renders byte-identical.
    private var adoptAvailable: Bool {
        capabilitiesStore?.capabilities.hasCuratorAdopt ?? false
    }

    /// v0.20.4 ledger surface. Hidden entirely on pre-0.20.4 hosts.
    private var ledgerAvailable: Bool {
        capabilitiesStore?.capabilities.hasCuratorLedger ?? false
    }

    /// v0.20.4 purge (permanent delete) surface.
    private var purgeAvailable: Bool {
        capabilitiesStore?.capabilities.hasCuratorPurge ?? false
    }

    /// v0.20.4 per-entry rollback surface. Gates the "roll back this
    /// entry" action on ledger rows independently of `ledgerAvailable` —
    /// a host could in principle have one without the other.
    private var entryRollbackAvailable: Bool {
        capabilitiesStore?.capabilities.hasCuratorEntryRollback ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                ScarfPageHeader(
                    "Curator",
                    subtitle: archiveAvailable
                        ? "Autonomous skill maintenance — archive, prune, restore"
                        : "Autonomous skill maintenance — Hermes v0.12+"
                ) {
                    headerActions
                }

                if let errorMessage = viewModel.errorMessage {
                    errorBanner(errorMessage)
                }

                if let toast = viewModel.transientMessage {
                    transientToast(toast)
                }

                statusSummary
                skillCountsSection
                if adoptAvailable {
                    unmanagedSection
                }
                pinnedSection
                activityTables

                if archiveAvailable {
                    CuratorArchivedSection(
                        archived: viewModel.archivedSkills,
                        isLoading: viewModel.isLoadingArchive,
                        onRestore: { name in
                            Task { await viewModel.restore(name) }
                        }
                    )
                }

                if ledgerAvailable {
                    CuratorLedgerSection(
                        entries: viewModel.ledgerEntries,
                        isLoading: viewModel.isLoadingLedger,
                        rollbackAvailable: entryRollbackAvailable,
                        pendingRollbackEntryID: viewModel.pendingRollbackEntryID,
                        onRollback: { entry in
                            Task { await viewModel.rollbackEntry(entry.id) }
                        }
                    )
                }

                if let report = viewModel.lastReportMarkdown {
                    lastReportSection(markdown: report)
                }
            }
            .padding(ScarfSpace.s4)
        }
        .background(ScarfColor.backgroundPrimary)
        .task {
            await viewModel.load()
            if archiveAvailable {
                await viewModel.loadArchive()
            }
            if adoptAvailable {
                await viewModel.loadUnmanaged()
            }
            if ledgerAvailable {
                await viewModel.loadLedger()
            }
        }
        .sheet(isPresented: $showRestoreSheet) {
            CuratorRestoreSheet(viewModel: viewModel)
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.pruneSummary != nil },
                set: { isShown in
                    if !isShown { viewModel.cancelPrune() }
                }
            )
        ) {
            if let summary = viewModel.pruneSummary {
                CuratorPruneConfirmSheet(
                    summary: summary,
                    isPruning: viewModel.isPruning,
                    onConfirm: {
                        Task { await viewModel.confirmPrune() }
                    },
                    onCancel: {
                        viewModel.cancelPrune()
                    }
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.purgeSummary != nil },
                set: { isShown in
                    if !isShown { viewModel.cancelPurge() }
                }
            )
        ) {
            if let summary = viewModel.purgeSummary {
                CuratorPurgeConfirmSheet(
                    summary: summary,
                    isPurging: viewModel.isPurging,
                    onConfirm: {
                        Task { await viewModel.confirmPurge() }
                    },
                    onCancel: {
                        viewModel.cancelPurge()
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: ScarfSpace.s2) {
            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("Run Now") {
                Task {
                    await viewModel.runNow(
                        synchronous: archiveAvailable,
                        timeout: 600
                    )
                }
            }
            .buttonStyle(ScarfPrimaryButton())
            .disabled(viewModel.isLoading)
            .help(archiveAvailable
                ? "Curator runs synchronously on Hermes v0.13+. Usually 10–90s."
                : "Trigger a curator run. Returns immediately on pre-v0.13 hosts.")

            Menu {
                switch viewModel.status.state {
                case .paused:
                    Button("Resume") { Task { await viewModel.resume() } }
                case .enabled:
                    Button("Pause") { Task { await viewModel.pause() } }
                default:
                    EmptyView()
                }

                if archiveAvailable {
                    Divider()
                    Menu("Archive idle skills…") {
                        Button("Idle ≥ 30 days")  { Task { await viewModel.planPrune(days: 30) } }
                        Button("Idle ≥ 60 days")  { Task { await viewModel.planPrune(days: 60) } }
                        Button("Idle ≥ 90 days")  { Task { await viewModel.planPrune(days: 90) } }
                        Button("Idle ≥ 180 days") { Task { await viewModel.planPrune(days: 180) } }
                    }
                    if purgeAvailable {
                        // Deliberately a separate, plainly-labeled entry —
                        // never folded into the Archive menu above. "Archive"
                        // is reversible; "Permanently Delete" is not.
                        Button("Permanently Delete Archived…") {
                            Task { await viewModel.planPurge() }
                        }
                    }
                } else {
                    Button("Restore Archived…") {
                        showRestoreSheet = true
                    }
                    .disabled(viewModel.status.archivedSkills == 0)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var statusSummary: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                HStack {
                    statusBadge
                    Spacer()
                    Text("\(viewModel.status.runCount) runs")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                ScarfDivider()
                infoRow(label: "Last run", value: viewModel.status.lastRunISO ?? "Never")
                if let summary = viewModel.status.lastSummary {
                    infoRow(label: "Last summary", value: summary)
                }
                infoRow(label: "Interval", value: viewModel.status.intervalLabel)
                infoRow(label: "Stale after", value: viewModel.status.staleAfterLabel)
                infoRow(label: "Archive after", value: viewModel.status.archiveAfterLabel)
            }
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

    private var skillCountsSection: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                ScarfSectionHeader("Agent-created skills")
                HStack(spacing: ScarfSpace.s4) {
                    countCell(value: viewModel.status.totalSkills, label: "Total")
                    countCell(value: viewModel.status.activeSkills, label: "Active")
                    countCell(value: viewModel.status.staleSkills, label: "Stale")
                    countCell(value: viewModel.status.archivedSkills, label: "Archived")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// v0.20 unmanaged-skills card. Surfaces the count from the status
    /// header plus per-row / bulk Adopt actions. Empty state renders
    /// nothing — no unmanaged skills means nothing to adopt.
    @ViewBuilder
    private var unmanagedSection: some View {
        let count = viewModel.status.unmanagedCount ?? viewModel.unmanagedSkills.count
        if count > 0 {
            ScarfCard {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    HStack {
                        ScarfSectionHeader("Unmanaged skills")
                        Spacer()
                        if viewModel.isAdopting {
                            ProgressView().controlSize(.small)
                        }
                        // CuratorService's adopt doc says the UI gates the
                        // real (dryRun: false) call behind a confirm — this
                        // alert is that gate for the bulk path. Per-skill
                        // Adopt stays unconfirmed: one named skill is easy
                        // to reason about and to re-orphan.
                        Button("Adopt All (\(count))") {
                            showAdoptAllConfirmation = true
                        }
                        .disabled(viewModel.isAdopting)
                        .help("Hand every unmanaged skill to the curator (they become prunable/archivable)")
                        .alert("Adopt all unmanaged skills?", isPresented: $showAdoptAllConfirmation) {
                            Button("Adopt All (\(count))") {
                                Task { await viewModel.adoptAll() }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("All \(count) unmanaged skills will be handed to the curator and become eligible for automatic staling, archiving, and pruning.")
                        }
                    }
                    Text("Skills with no provenance marker are never auto-staled or archived. Adopting hands them to the curator.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    ForEach(viewModel.unmanagedSkills) { row in
                        HStack(alignment: .center, spacing: ScarfSpace.s2) {
                            Text(row.name)
                                .scarfStyle(.body)
                                .foregroundStyle(ScarfColor.foregroundPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            counterChip(label: "activity", value: row.activityCount)
                            Text(row.lastActivityLabel)
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.foregroundFaint)
                                .frame(width: 92, alignment: .trailing)
                            Button("Adopt") {
                                Task { await viewModel.adopt(row.name) }
                            }
                            .disabled(viewModel.isAdopting)
                            .help("Hand \(row.name) to the curator")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pinnedSection: some View {
        if !viewModel.status.pinnedNames.isEmpty {
            ScarfCard {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    ScarfSectionHeader("Pinned")
                    Text("Pinned skills are never auto-archived or rewritten by the curator.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    FlowLayout(spacing: ScarfSpace.s2) {
                        ForEach(viewModel.status.pinnedNames, id: \.self) { name in
                            HStack(spacing: 4) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10))
                                Text(name)
                                    .scarfStyle(.caption)
                                Button {
                                    Task { await viewModel.unpin(name) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(ScarfColor.foregroundMuted)
                                }
                                .buttonStyle(.plain)
                                .help("Unpin")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: ScarfRadius.md)
                                    .fill(ScarfColor.accentTint)
                            )
                        }
                    }
                }
            }
        }
    }

    private var activityTables: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s4) {
            if !viewModel.status.leastRecentlyActive.isEmpty {
                skillTable(title: "Least recently active", rows: viewModel.status.leastRecentlyActive)
            }
            if !viewModel.status.mostActive.isEmpty {
                skillTable(title: "Most active", rows: viewModel.status.mostActive)
            }
            if !viewModel.status.leastActive.isEmpty {
                skillTable(title: "Least active", rows: viewModel.status.leastActive)
            }
        }
    }

    private func skillTable(title: LocalizedStringKey, rows: [HermesCuratorSkillRow]) -> some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                ScarfSectionHeader(title)
                ForEach(rows) { row in
                    HStack(alignment: .center, spacing: ScarfSpace.s2) {
                        Text(row.name)
                            .scarfStyle(.body)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        counterChip(label: "use", value: row.useCount)
                        counterChip(label: "view", value: row.viewCount)
                        counterChip(label: "patch", value: row.patchCount)
                        Text(row.lastActivityLabel)
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                            .frame(width: 92, alignment: .trailing)
                        Button {
                            Task { await viewModel.pin(row.name) }
                        } label: {
                            Image(systemName: viewModel.status.pinnedNames.contains(row.name)
                                  ? "pin.fill" : "pin")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.status.pinnedNames.contains(row.name) ? "Pinned" : "Pin skill")

                        if archiveAvailable {
                            archiveButton(for: row.name)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func archiveButton(for name: String) -> some View {
        if viewModel.pendingArchiveName == name {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        } else {
            Button {
                Task { await viewModel.archive(name) }
            } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Archive (move out of active set)")
            .disabled(viewModel.pendingArchiveName != nil)
        }
    }

    private func counterChip(label: String, value: Int) -> some View {
        Text("\(label) \(value)")
            .font(ScarfFont.monoSmall)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.sm)
                    .fill(ScarfColor.backgroundTertiary)
            )
    }

    private func lastReportSection(markdown: String) -> some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                ScarfSectionHeader("Last report")
                Text(markdown)
                    .scarfStyle(.mono)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer(minLength: 0)
        }
    }

    private func countCell(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .scarfStyle(.title2)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Text(label)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
        .frame(minWidth: 64, alignment: .leading)
    }

    private func transientToast(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ScarfColor.success)
            Text(text)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 6)
        .background(ScarfColor.accentTint)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
    }

    /// Inline yellow banner for CLI failures. Non-blocking — sits above
    /// the status summary and dismisses with the "x" so users can keep
    /// interacting with the leaderboard. Mirrors the pattern in
    /// KanbanBoardView.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ScarfColor.warning)
            Text(message)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                viewModel.dismissError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md)
                .fill(ScarfColor.warning.opacity(0.12))
        )
    }
}

/// Simple `FlowLayout` for the pinned-skill chips. Custom layout
/// keeps the chip wrap behaviour predictable across DynamicType
/// scales without resorting to LazyVGrid (which forces fixed columns).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
