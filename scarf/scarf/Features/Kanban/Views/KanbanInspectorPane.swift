import SwiftUI
import ScarfCore
import ScarfDesign

/// Side-pane inspector for one Kanban task. Rendered alongside the board
/// (not modally) so the user can drag another card immediately after
/// closing this one. 420pt wide; slides in from the trailing edge.
struct KanbanInspectorPane: View {
    @State private var viewModel: KanbanTaskDetailViewModel
    let availableAssignees: [HermesKanbanAssignee]
    /// True when the connected Hermes is on v0.13+ — gates the
    /// hallucination banner, max_retries chip, diagnostics block,
    /// and auto-blocked reason banner. Pre-v0.13 hosts see the v2.7.5
    /// inspector unchanged.
    let supportsKanbanDiagnostics: Bool
    /// True when the connected Hermes is on v0.15+ — gates the read-only
    /// model-override + branch chips. Pre-v0.15 hosts never populate
    /// those fields, so this is belt-and-suspenders.
    let supportsKanbanV015: Bool
    /// Resolves an effective hallucination gate — the board VM owns the
    /// optimistic-override merge so the banner disappears immediately on
    /// Verify before the polled state confirms the new gate. Falls back
    /// to the wire-level value when no override is in flight.
    let effectiveHallucinationGate: (HermesKanbanTask) -> KanbanHallucinationGate?
    let onClose: () -> Void
    let onClaim: () -> Void
    let onComplete: () -> Void
    let onBlock: () -> Void
    let onUnblock: () -> Void
    let onArchive: () -> Void
    let onReassign: (String?) -> Void
    let onRejectHallucination: () -> Void

    @State private var selectedTab: DetailTab = .comments
    @Environment(\.scenePhase) private var scenePhase

    enum DetailTab: String, CaseIterable, Identifiable {
        case comments = "Comments"
        case events = "Events"
        case runs = "Runs"
        case log = "Log"
        var id: String { rawValue }
    }

    init(
        service: KanbanService,
        taskId: String,
        availableAssignees: [HermesKanbanAssignee] = [],
        supportsKanbanDiagnostics: Bool = false,
        supportsKanbanV015: Bool = false,
        effectiveHallucinationGate: @escaping (HermesKanbanTask) -> KanbanHallucinationGate? = { _ in nil },
        onClose: @escaping () -> Void,
        onClaim: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onBlock: @escaping () -> Void,
        onUnblock: @escaping () -> Void,
        onArchive: @escaping () -> Void,
        onReassign: @escaping (String?) -> Void = { _ in },
        onRejectHallucination: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: KanbanTaskDetailViewModel(service: service, taskId: taskId))
        self.availableAssignees = availableAssignees
        self.supportsKanbanDiagnostics = supportsKanbanDiagnostics
        self.supportsKanbanV015 = supportsKanbanV015
        self.effectiveHallucinationGate = effectiveHallucinationGate
        self.onClose = onClose
        self.onClaim = onClaim
        self.onComplete = onComplete
        self.onBlock = onBlock
        self.onUnblock = onUnblock
        self.onArchive = onArchive
        self.onReassign = onReassign
        self.onRejectHallucination = onRejectHallucination
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScarfDivider()
            if let detail = viewModel.detail {
                ScrollView {
                    VStack(alignment: .leading, spacing: ScarfSpace.s3) {
                        healthBanner(for: detail.task)
                        bodySection(detail.task)
                        Picker("", selection: $selectedTab) {
                            ForEach(DetailTab.allCases) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        switch selectedTab {
                        case .comments: commentsSection(detail.comments)
                        case .events:   eventsSection(detail.events)
                        case .runs:     runsSection
                        case .log:      logSection(for: detail.task)
                        }
                    }
                    .padding(ScarfSpace.s4)
                }
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = viewModel.lastError {
                errorState(err)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ScarfDivider()
            actionBar
        }
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .background(ScarfColor.backgroundPrimary)
        .task {
            // Start the 5s detail-poll loop. First iteration runs the
            // initial fetch so the user sees the same load latency as
            // the previous one-shot `viewModel.load()` did.
            viewModel.startDetailPolling()
        }
        .onChange(of: viewModel.taskId) { _, _ in
            viewModel.stopLogPolling()
            viewModel.stopDetailPolling()
            viewModel.startDetailPolling()
        }
        .onChange(of: selectedTab) { _, newTab in
            handleTabChange(newTab)
        }
        .onChange(of: viewModel.detail?.task.status ?? "") { _, _ in
            // If the task transitions to running while the log tab is
            // open, start polling. If it transitions out, the polling
            // loop self-cancels.
            if selectedTab == .log {
                handleTabChange(.log)
            }
        }
        .onDisappear {
            viewModel.stopLogPolling()
            viewModel.stopDetailPolling()
        }
        // The inspector's two loops (detail every 5s, log every 2s) are the
        // other half of the board's polling cost. Pause both when the window
        // is not the active scene, and resume whichever the open tab wants.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.startDetailPolling()
                handleTabChange(selectedTab)
            } else {
                viewModel.stopLogPolling()
                viewModel.stopDetailPolling()
            }
        }
    }

    private func handleTabChange(_ tab: DetailTab) {
        guard tab == .log else {
            viewModel.stopLogPolling()
            return
        }
        let isRunning = (viewModel.detail?.task.status).flatMap {
            KanbanStatus.from($0)
        } == .running
        if isRunning {
            viewModel.startLogPolling()
        } else {
            // Static fetch for terminal-state tasks (done/blocked/etc).
            viewModel.stopLogPolling()
            Task { await viewModel.refreshLogOnce() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            VStack(alignment: .leading, spacing: 4) {
                if let task = viewModel.detail?.task {
                    Text(task.title)
                        .scarfStyle(.title3)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                        .lineLimit(2)
                    // Horizontal scroll lets the chip row degrade
                    // gracefully on narrow inspectors (or with long
                    // profile / tenant names) instead of wrapping
                    // chips onto a second visual line, which looked
                    // broken when a single name pushed past the
                    // available width.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ScarfBadge(verbatim: task.status.lowercased(), kind: badgeKind(for: task.status))
                                .fixedSize()
                            assigneeMenu(for: task)
                                .fixedSize()
                            if let workspace = task.workspaceKind {
                                ScarfBadge(verbatim: workspace, kind: .neutral)
                                    .fixedSize()
                            }
                            // v0.13: max_retries chip. Read-only — Hermes
                            // has no `update --max-retries` verb. The
                            // `if let` guards pre-v0.13 hosts (always nil)
                            // and the explicit capability gate adds
                            // belt-and-suspenders.
                            if supportsKanbanDiagnostics, let maxRetries = task.maxRetries {
                                ScarfBadge("retries: \(maxRetries)", kind: .neutral)
                                    .fixedSize()
                                    .help("Max retries set at create time. Hermes has no update verb — re-create the task to change this.")
                            }
                            // v0.15: read-only model override + branch chips.
                            // Hermes has no update verb for either — set at
                            // create time (model) or by the worker (branch).
                            if supportsKanbanV015, let model = task.modelOverride, !model.isEmpty {
                                ScarfBadge("Model: \(model)", kind: .neutral)
                                    .fixedSize()
                                    .help("Per-task model override set at create time. Read-only — Hermes has no update verb.")
                            }
                            if supportsKanbanV015, let branch = task.branchName, !branch.isEmpty {
                                ScarfBadge("Branch: \(branch)", kind: .neutral)
                                    .fixedSize()
                                    .help("Git branch the worker is operating on.")
                            }
                            if let tenant = task.tenant, !tenant.isEmpty {
                                ScarfBadge(verbatim: tenant, kind: .brand)
                                    .fixedSize()
                            }
                        }
                    }
                } else {
                    Text("Loading…")
                        .scarfStyle(.title3)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(ScarfGhostButton())
            .keyboardShortcut(.cancelAction)
        }
        .padding(ScarfSpace.s4)
    }

    /// Inline assignee picker. Renders as a clickable badge styled to
    /// match neighboring chips: `.brand` when set, `.warning` when
    /// unassigned (so the user immediately sees the signal). Menu
    /// items list every known profile + "Unassigned"; selection
    /// routes through `onReassign`, which on the board side calls
    /// `kanban assign <id> <profile>` and then `kanban dispatch`.
    private func assigneeMenu(for task: HermesKanbanTask) -> some View {
        let current = task.assignee?.isEmpty == false ? task.assignee : nil
        let options = mergedAssigneeOptions(currentAssignee: current)
        let kind: ScarfBadgeKind = (current == nil) ? .warning : .brand
        return Menu {
            Button("Unassigned") { onReassign(nil) }
            if !options.isEmpty {
                Divider()
                ForEach(options, id: \.self) { profile in
                    Button(profile) { onReassign(profile) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let current {
                    ScarfBadge(verbatim: current, kind: kind)
                } else {
                    ScarfBadge("Unassigned", kind: kind)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            .fixedSize() // prevent chevron + badge from wrapping
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(current == nil
              ? "Assign a profile so the dispatcher can spawn a worker."
              : "Reassign this task. Hermes's dispatcher only runs assigned tasks.")
    }

    /// Build the assignee dropdown list. Sources, in order:
    /// 1. The board's known-assignees list (passed in via init —
    ///    union of `~/.hermes/profiles/` and current task assignees).
    /// 2. The active local Hermes profile.
    /// 3. The task's current assignee (so reassigning back is one tap).
    /// Deduped, sorted for stability.
    private func mergedAssigneeOptions(currentAssignee: String?) -> [String] {
        var set = Set<String>()
        for entry in availableAssignees {
            set.insert(entry.profile)
        }
        let active = HermesProfileResolver.activeProfileName()
        if !active.isEmpty {
            set.insert(active)
        }
        if let currentAssignee {
            set.insert(currentAssignee)
        }
        return set.sorted()
    }

    private func badgeKind(for status: String) -> ScarfBadgeKind {
        switch KanbanStatus.from(status) {
        case .running, .ready: return .info
        case .done:            return .success
        case .blocked:         return .warning
        case .archived:        return .neutral
        default:               return .neutral
        }
    }

    // MARK: - Body

    /// Inline health banner shown above the task body when something
    /// requires user attention. Stack vertically (multiple can apply at
    /// once on a v0.13 task — e.g. unassigned + hallucination pending +
    /// last-run-blocked).
    /// Order top-to-bottom:
    /// 1. **Hallucination gate (v0.13+)** — pending worker-created card.
    ///    User must verify or reject before any other action makes sense.
    /// 2. **Auto-blocked reason (v0.13+)** — server-supplied reason
    ///    overrides the generic "Last run: blocked" banner.
    /// 3. Task is in `ready`/`todo` with no assignee — explains that the
    ///    dispatcher silently skips unassigned tasks.
    /// 4. The most recent run ended in a non-success outcome — surfaces
    ///    the error so the user doesn't have to dig into the Runs tab.
    @ViewBuilder
    private func healthBanner(for task: HermesKanbanTask) -> some View {
        let status = KanbanStatus.from(task.status)
        let column = status.boardColumn
        let isUnassigned = (task.assignee?.isEmpty ?? true)
        let needsAssignee = (column == .upNext || column == .triage) && isUnassigned

        // Pick the most recent **completed** run by id descending —
        // skipping any in-flight run so a fresh worker doesn't show
        // up here. The previous reclaimed/crashed run is only
        // user-relevant *until* the next attempt actually starts;
        // the moment status flips to running, the Log tab's live
        // stream is the right signal and a stale banner just adds
        // noise.
        let lastEndedRun = viewModel.runs
            .filter { $0.endedAt != nil }
            .max(by: { $0.id < $1.id })

        let failureOutcomes: Set<String> = [
            "stale_lock", "reclaimed", "crashed",
            "timed_out", "spawn_failed", "gave_up", "failed"
        ]
        let hadFailedEndedRun = lastEndedRun
            .flatMap { (run: HermesKanbanRun) -> String? in
                run.outcome ?? run.status
            }
            .map { failureOutcomes.contains($0.lowercased()) }
            ?? false

        // Suppress the failure banner during an active attempt — once
        // status is `running` again, the previous outcome is stale.
        // Also suppress for `done` (terminal success).
        let suppressFailureBanner = (status == .running) || (status == .done)

        // v0.13: hallucination-gate state. Read through the VM's
        // optimistic-aware accessor so a Verify click takes effect
        // before the polled state confirms. Belt-and-suspenders gate
        // on capability flag.
        let hallucination: KanbanHallucinationGate? = supportsKanbanDiagnostics
            ? effectiveHallucinationGate(task)
            : nil
        // v0.13: structured auto-blocked reason. Renders the server's
        // string verbatim; takes precedence over the generic "Last run:
        // blocked" banner.
        let autoBlockedReason: String? = (supportsKanbanDiagnostics
                                          && status == .blocked
                                          && (task.autoBlockedReason?.isEmpty == false))
            ? task.autoBlockedReason
            : nil
        // Suppress the generic last-run banner when the more specific
        // server-side reason supersedes it.
        let suppressGenericFailure = autoBlockedReason != nil

        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            if hallucination == .pending {
                hallucinationBanner
            }
            if let reason = autoBlockedReason {
                bannerRow(
                    icon: "exclamationmark.octagon.fill",
                    tint: ScarfColor.danger,
                    title: "Auto-blocked",
                    // Verbatim — Hermes-side message is the source of truth.
                    message: reason
                )
            }
            if needsAssignee {
                bannerRow(
                    icon: "exclamationmark.triangle.fill",
                    tint: ScarfColor.warning,
                    title: "Won't run automatically",
                    message: "Unassigned tasks are silently skipped by Hermes's dispatcher. Add an assignee to get this scheduled."
                )
            }
            if hadFailedEndedRun, let lastEndedRun,
               !suppressFailureBanner, !suppressGenericFailure {
                let label = (lastEndedRun.outcome ?? lastEndedRun.status).lowercased()
                let detail = lastEndedRun.error ?? lastEndedRun.summary ?? "no details"
                bannerRow(
                    icon: "exclamationmark.octagon.fill",
                    tint: ScarfColor.danger,
                    title: "Last run: \(label)",
                    message: detail
                )
            }
            // v0.13: cross-run diagnostics on the task header.
            if supportsKanbanDiagnostics, !task.diagnostics.isEmpty {
                diagnosticsBlock(task.diagnostics)
            }
        }
    }

    /// v0.13 hallucination-gate banner — Reject affordance for
    /// worker-created cards waiting on user review. (Hermes has no
    /// `kanban verify` verb, so there is no Verify action; Reject
    /// archives the card with an audit comment.)
    private var hallucinationBanner: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Image(systemName: "questionmark.diamond.fill")
                .foregroundStyle(ScarfColor.warning)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Created by a worker — review before running")
                    .scarfStyle(.captionStrong)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("A worker claimed it created this card; Hermes hasn't confirmed the underlying work exists. Reject it if it's a hallucinated reference.")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                HStack(spacing: ScarfSpace.s2) {
                    Button("Reject", action: onRejectHallucination)
                        .buttonStyle(ScarfDestructiveButton())
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(ScarfSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .strokeBorder(ScarfColor.warning.opacity(0.4), lineWidth: 1)
        )
    }

    /// v0.13 diagnostics block — renders a list of distress signals.
    /// Used both at the task-header level (cross-run signals) and per
    /// run on the Runs tab (in-flight signals). Wraps in a horizontal
    /// scroll so a long diag list doesn't blow out inspector width.
    private func diagnosticsBlock(_ diags: [HermesKanbanDiagnostic]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Diagnostics")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundFaint)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(diags) { diag in
                        diagnosticBadge(diag)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func diagnosticBadge(_ diag: HermesKanbanDiagnostic) -> some View {
        let kind = KanbanDiagnosticKind.from(diag.kind)
        let badgeKind: ScarfBadgeKind = {
            switch kind.severity {
            case .danger:  return .danger
            case .warning: return .warning
            case .neutral: return .neutral
            }
        }()
        // Render the raw kind string — view code stays in sync with
        // whatever future kinds Hermes ships. The typed mirror picks
        // the badge tint and tooltip glyph; the verbatim wire string
        // is the user-facing label.
        ScarfBadge(verbatim: diag.kind, kind: badgeKind)
            .help(diag.message ?? diag.kind)
    }

    private func bannerRow(
        icon: String,
        tint: Color,
        title: String,
        message: String
    ) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .scarfStyle(.captionStrong)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(message)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(ScarfSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .strokeBorder(tint.opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func bodySection(_ task: HermesKanbanTask) -> some View {
        if let body = task.body, !body.isEmpty {
            // PLAIN text, deliberately. A card body is written by whatever
            // worker touched the card, and `AttributedString(markdown:)`
            // renders links with no scheme allowlist — a worker could plant
            // `[Approve](javascript:…)`-shaped bait in the inspector. Comment
            // bodies right below render as plain `Text` for the same reason;
            // the two must not diverge. Rendered markdown in this app goes
            // through `MarkdownContentView`, which carries the allowlist.
            Text(body)
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            Text("No description.")
                .scarfStyle(.footnote)
                .foregroundStyle(ScarfColor.foregroundFaint)
        }
    }

    private func commentsSection(_ comments: [HermesKanbanComment]) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            if comments.isEmpty {
                Text("No comments yet.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            } else {
                ForEach(comments) { comment in
                    commentRow(comment)
                }
            }
            commentComposer
        }
    }

    private func commentRow(_ comment: HermesKanbanComment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: ScarfSpace.s2) {
                Text(comment.author)
                    .scarfStyle(.captionStrong)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(comment.createdAt)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            Text(comment.body)
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ScarfSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.backgroundSecondary.opacity(0.5))
        )
    }

    private var commentComposer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScarfTextField("Add a comment…", text: Binding(
                get: { viewModel.commentDraft },
                set: { viewModel.commentDraft = $0 }
            ))
            HStack {
                Spacer()
                Button("Comment") {
                    Task { await viewModel.submitComment() }
                }
                .buttonStyle(ScarfPrimaryButton())
                .disabled(viewModel.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, ScarfSpace.s2)
    }

    private func eventsSection(_ events: [HermesKanbanEvent]) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            if events.isEmpty {
                Text("No events yet.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            } else {
                ForEach(events) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: HermesKanbanEvent) -> some View {
        HStack(alignment: .top, spacing: ScarfSpace.s2) {
            Image(systemName: glyphForEventKind(event.kindEnum))
                .foregroundStyle(colorForEventKind(event.kindEnum))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.kind)
                    .scarfStyle(.captionStrong)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text(event.createdAt)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            Spacer(minLength: 0)
        }
    }

    private func glyphForEventKind(_ kind: KanbanEventKind) -> String {
        switch kind {
        case .created:   return "plus.circle"
        case .claimed:   return "hand.raised"
        case .started:   return "play.circle"
        case .completed: return "checkmark.circle.fill"
        case .blocked:   return "exclamationmark.triangle.fill"
        case .unblocked: return "arrow.uturn.backward"
        case .commented: return "text.bubble"
        case .archived:  return "archivebox"
        case .heartbeat: return "waveform.path"
        case .crashed, .timedOut, .spawnFailed, .error: return "xmark.octagon.fill"
        case .statusChange, .released, .unknown: return "arrow.right"
        }
    }

    private func colorForEventKind(_ kind: KanbanEventKind) -> Color {
        switch kind {
        case .completed:                                       return ScarfColor.success
        case .blocked, .crashed, .timedOut, .spawnFailed, .error: return ScarfColor.warning
        case .claimed, .started, .unblocked:                   return ScarfColor.info
        default:                                                return ScarfColor.foregroundMuted
        }
    }

    @ViewBuilder
    private func logSection(for task: HermesKanbanTask) -> some View {
        let isRunning = KanbanStatus.from(task.status) == .running
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            HStack(spacing: 6) {
                if isRunning && viewModel.isLogStreaming {
                    Circle()
                        .fill(ScarfColor.success)
                        .frame(width: 6, height: 6)
                    Text("streaming")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                } else if isRunning {
                    Text("waiting for first poll…")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                } else {
                    Text("snapshot from `hermes kanban log \(task.id)`")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
                Spacer()
                Button {
                    Task { await viewModel.refreshLogOnce() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(ScarfGhostButton())
                .help("Refresh worker log")
            }
            if viewModel.log.isEmpty {
                Text(isRunning
                    ? "No output yet. The worker may not have written anything to stdout / stderr."
                    : "No log captured for this task.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .padding(.vertical, ScarfSpace.s2)
            } else {
                if viewModel.logWasTruncated {
                    Label(
                        "Showing the last 256 KB of this log — earlier output isn't loaded.",
                        systemImage: "scissors"
                    )
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .padding(.horizontal, ScarfSpace.s2)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(viewModel.log)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(ScarfSpace.s2)
                        // Invisible anchor pinned to the bottom so we
                        // can `scrollTo(.bottom)` whenever the log
                        // grows during a poll tick.
                        Color.clear.frame(height: 1).id("log-bottom-anchor")
                    }
                    .onChange(of: viewModel.log) { _, _ in
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo("log-bottom-anchor", anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: 280)
                .background(
                    RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                        .fill(ScarfColor.backgroundSecondary.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                        .strokeBorder(ScarfColor.border, lineWidth: 1)
                )
            }
        }
    }

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            if viewModel.runs.isEmpty {
                Text("No runs yet.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            } else {
                ForEach(viewModel.runs) { run in
                    runRow(run)
                }
            }
        }
    }

    private func runRow(_ run: HermesKanbanRun) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: ScarfSpace.s2) {
                // Render the wire-side outcome / status string verbatim so
                // v0.13's richer outcome strings ("zombied — reclaimed by
                // reaper", etc.) surface unchanged.
                ScarfBadge(verbatim: run.outcome ?? run.status, kind: outcomeKind(run.outcome ?? run.status))
                if let profile = run.profile {
                    Text(profile)
                        .scarfStyle(.captionStrong)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                }
                Spacer()
                Text(run.startedAt)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
            if let summary = run.summary, !summary.isEmpty {
                Text(summary)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = run.error, !error.isEmpty {
                Text(error)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // v0.13: per-run diagnostics. Gated on capability so a future
            // server-side change can't accidentally surface partial UX
            // on a pre-v0.13 host.
            if supportsKanbanDiagnostics, !run.diagnostics.isEmpty {
                diagnosticsBlock(run.diagnostics)
            }
        }
        .padding(ScarfSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.backgroundSecondary.opacity(0.4))
        )
    }

    private func outcomeKind(_ outcome: String) -> ScarfBadgeKind {
        switch outcome.lowercased() {
        case "completed", "done":                      return .success
        case "blocked":                                return .warning
        case "crashed", "timed_out", "spawn_failed", "failed": return .danger
        case "running":                                return .info
        default:                                        return .neutral
        }
    }

    // MARK: - Action bar

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: ScarfSpace.s2) {
            primaryAction
            secondaryActions
            Spacer()
            archiveAction
        }
        .padding(ScarfSpace.s3)
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let task = viewModel.detail?.task {
            // v0.13: when the hallucination gate is pending, suppress the
            // primary action — the banner provides Verify / Reject as the
            // gate. Showing "Start" alongside the banner would let the
            // user dispatch a card Hermes hasn't confirmed exists.
            if supportsKanbanDiagnostics,
               effectiveHallucinationGate(task) == .pending {
                EmptyView()
            } else {
                switch KanbanStatus.from(task.status) {
                case .ready, .todo:
                    Button("Start", action: onClaim)
                        .buttonStyle(ScarfPrimaryButton())
                        .help("Atomically claim this task and start the worker. Moves it to Running.")
                case .running:
                    Button("Complete", action: onComplete)
                        .buttonStyle(ScarfPrimaryButton())
                        .help("Mark this task as Done. You'll be prompted for an optional result summary.")
                case .blocked:
                    Button("Unblock", action: onUnblock)
                        .buttonStyle(ScarfPrimaryButton())
                        .help("Return this task to the Up Next queue so the dispatcher can pick it up again.")
                case .triage:
                    EmptyView()
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if let task = viewModel.detail?.task {
            switch KanbanStatus.from(task.status) {
            case .ready, .todo, .running:
                Button("Block", action: onBlock)
                    .buttonStyle(ScarfSecondaryButton())
                    .help("Mark this task blocked with a reason. The reason is appended as a comment.")
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var archiveAction: some View {
        if let task = viewModel.detail?.task,
           KanbanStatus.from(task.status) != .archived {
            Button("Archive", action: onArchive)
                .buttonStyle(ScarfDestructiveButton())
                .help("Hide this task from the active board. Hermes has no hard-delete; archived tasks remain in `~/.hermes/kanban.db` and are recoverable via the \"Show archived\" toggle until `hermes kanban gc` runs.")
        }
    }

    // MARK: - Error

    private func errorState(_ message: String) -> some View {
        VStack(spacing: ScarfSpace.s2) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(ScarfColor.warning)
            Text(message)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.load() }
            }
            .buttonStyle(ScarfSecondaryButton())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(ScarfSpace.s4)
    }
}
