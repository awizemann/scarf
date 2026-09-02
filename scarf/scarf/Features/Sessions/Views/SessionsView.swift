import SwiftUI
import ScarfCore
import ScarfDesign

/// Sessions — full-width table of every conversation, per
/// `design/static-site/ui-kit/Sessions.jsx`. Replaces the previous
/// HSplitView master-detail layout: rows live in a single bordered
/// card with column headers; the detail view is presented as a sheet
/// when a row is selected. The mockup omits an inline detail pane.
///
/// Page chrome (top → bottom):
///  1. ContentHeader-shaped title row with Filter + Export actions.
///  2. Filter chip strip — All/Today/Starred pills + project filter
///     menu + a custom search field flush right.
///  3. Active filter summary (only when a project filter is set).
///  4. Bordered card with column-header row + data rows.
struct SessionsView: View {
    @State private var viewModel: SessionsViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(\.hermesCapabilities) private var capabilitiesStore
    /// Focus binding for the search field so ⌘F can focus it. (t-aud18)
    @FocusState private var searchFocused: Bool

    init(context: ServerContext) {
        _viewModel = State(initialValue: SessionsViewModel(context: context))
    }

    /// `hermes sessions export --format …` (v0.20+). Pre-0.20 hosts keep
    /// the export flow exactly as it was: jsonl only, straight to the save
    /// panel, no picker sheet.
    private var hasExportFormats: Bool {
        capabilitiesStore?.capabilities.hasSessionsExportFormats ?? false
    }

    /// Top-of-list filter pills. `today` filters by `startedAt` falling
    /// within the current calendar day; `starred` filters on
    /// `HermesSession.pinned` — Hermes v0.20's `sessions.pinned` column,
    /// the same flag the Chat sidebar floats pinned sessions with. It was
    /// a hardcoded `return 0` / no-op placeholder: the pill showed a
    /// permanent zero and selecting it changed nothing, which reads as a
    /// broken filter rather than an unwired one. On a pre-v0.20 host the
    /// column is absent, `pinned` is false for every row, and a truthful
    /// zero is exactly what the pill should show.
    /// The pill enum, its counts and the row slice all live on the view
    /// model now — see `SessionsViewModel.QuickFilter`. As view state they
    /// were recomputed from scratch on every body evaluation.
    typealias QuickFilter = SessionsViewModel.QuickFilter

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            filterStrip
            if viewModel.projectFilter != nil {
                activeFilterSummary
            }
            ScrollView {
                sessionsTable
                    .padding(.horizontal, ScarfSpace.s6)
                    .padding(.vertical, ScarfSpace.s3)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Sessions")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading sessions…",
            isEmpty: viewModel.sessions.isEmpty
        )
        .background {
            // ⌘F focuses the sessions search field — standard macOS Find
            // affordance. Hidden control that just owns the shortcut for
            // the active window. (t-aud18)
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task {
            await viewModel.load()
            if let id = coordinator.selectedSessionId {
                await viewModel.selectSessionById(id)
                coordinator.selectedSessionId = nil
            }
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.load() }
        }
        .onDisappear { Task { await viewModel.cleanup() } }
        .sheet(isPresented: detailSheetBinding) { detailSheet }
        .sheet(isPresented: $viewModel.showRenameSheet) { renameSheet }
        .sheet(isPresented: $viewModel.showExportOptionsSheet) { exportOptionsSheet }
        .confirmationDialog("Delete Session?", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Delete", role: .destructive) { viewModel.confirmDelete() }
                .disabled(viewModel.isDeleting)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the session and all its messages.")
        }
    }

    // MARK: - Page header

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sessions")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                if let stats = viewModel.storeStats {
                    Text("\(stats.totalSessions) sessions · \(stats.totalMessages) messages · \(stats.databaseSize)")
                        .scarfStyle(.footnote)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                } else {
                    Text("Every conversation across projects, agents, and models.")
                        .scarfStyle(.footnote)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }
            Spacer()
            if let deleteError = viewModel.deleteError {
                Label(deleteError, systemImage: "exclamationmark.triangle.fill")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .trailing)
                    .textSelection(.enabled)
            }
            if let message = viewModel.exportMessage {
                Label(message, systemImage: "info.circle")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .trailing)
                    .textSelection(.enabled)
            }
            Button {
                viewModel.exportAll(formatsAvailable: hasExportFormats)
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(ScarfSecondaryButton())
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s4)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Filter strip

    private var filterStrip: some View {
        HStack(spacing: ScarfSpace.s2) {
            ForEach(QuickFilter.allCases) { f in
                quickFilterPill(f)
            }
            Rectangle()
                .fill(ScarfColor.border)
                .frame(width: 1, height: 18)
                .padding(.horizontal, 4)

            projectFilterMenu

            Spacer()

            searchField
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s3)
        .padding(.bottom, ScarfSpace.s2)
    }

    private func quickFilterPill(_ filter: QuickFilter) -> some View {
        let isActive = viewModel.quickFilter == filter
        return Button {
            viewModel.quickFilter = filter
        } label: {
            HStack(spacing: 5) {
                Text(filter.label)
                    .scarfStyle(.caption)
                Text("\(viewModel.quickFilterCounts[filter] ?? 0)")
                    .font(ScarfFont.monoSmall)
                    .opacity(0.7)
            }
            .foregroundStyle(isActive ? ScarfColor.onAccent : ScarfColor.foregroundPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isActive ? ScarfColor.accent : ScarfColor.backgroundTertiary)
            )
        }
        .buttonStyle(.plain)
    }

    /// Memoized on the view model — see `recomputeFilteredSessions()`.
    private var visibleSessions: [HermesSession] { viewModel.visibleSessions }

    private var projectFilterMenu: some View {
        Menu {
            Button {
                viewModel.projectFilter = nil
            } label: {
                Label("All projects", systemImage: "tray.full")
            }
            Button {
                viewModel.projectFilter = ""
            } label: {
                Label("Unattributed", systemImage: "questionmark.folder")
            }
            if !viewModel.allProjects.isEmpty {
                Divider()
                ForEach(viewModel.allProjects.sorted { $0.name < $1.name }) { project in
                    Button {
                        viewModel.projectFilter = project.name
                    } label: {
                        Label(project.name, systemImage: "folder.fill")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: projectFilterIcon)
                    .font(.system(size: 11))
                Text(projectFilterLabel)
                    .scarfStyle(.caption)
                if viewModel.projectFilter == nil {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(viewModel.projectFilter != nil ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(viewModel.projectFilter != nil ? ScarfColor.accentTint : ScarfColor.backgroundTertiary)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        viewModel.projectFilter != nil ? ScarfColor.accent : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var projectFilterIcon: String {
        switch viewModel.projectFilter {
        case .none: return "square.stack.3d.up"
        case .some(let s) where s.isEmpty: return "questionmark.folder"
        default: return "folder.fill"
        }
    }

    private var projectFilterLabel: String {
        switch viewModel.projectFilter {
        case .none: return "All projects"
        case .some(let s) where s.isEmpty: return "Unattributed"
        case .some(let s): return s
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(ScarfColor.foregroundFaint)
            TextField("Search sessions…", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .scarfStyle(.caption)
                .focused($searchFocused)
                .onSubmit { Task { await viewModel.search() } }
                .onChange(of: viewModel.searchText) {
                    if viewModel.searchText.isEmpty {
                        viewModel.isSearching = false
                        viewModel.searchResults = []
                    }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
        )
    }

    private var activeFilterSummary: some View {
        HStack(spacing: 4) {
            Text("Showing \(visibleSessions.count) session\(visibleSessions.count == 1 ? "" : "s") from")
            Text(projectFilterLabel)
                .scarfStyle(.bodyEmph)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Text("·")
                .foregroundStyle(ScarfColor.foregroundFaint)
            Button {
                viewModel.projectFilter = nil
            } label: {
                Text("clear filter")
                    .underline(true, pattern: .dot)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ScarfColor.accentActive)
            Spacer()
        }
        .scarfStyle(.caption)
        .foregroundStyle(ScarfColor.foregroundMuted)
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s2)
    }

    // MARK: - Table

    private var sessionsTable: some View {
        // LAZY: the table sits inside a `ScrollView` and renders up to 500
        // rows. An eager `VStack` built and laid out every one of them on
        // first paint, whether or not any were on screen (C10). `LazyVStack`
        // keeps the same appearance — the header pins as the first child, not
        // as a section header — while only materialising visible rows.
        LazyVStack(spacing: 0) {
            tableHeaderRow
            if viewModel.isSearching {
                searchResultRows
            } else if visibleSessions.isEmpty {
                emptyState
            } else {
                ForEach(Array(visibleSessions.enumerated()), id: \.element.id) { idx, session in
                    SessionTableRow(
                        session: session,
                        preview: viewModel.previewFor(session),
                        projectName: viewModel.projectName(for: session),
                        onTap: { Task { await viewModel.selectSession(session) } },
                        onProjectTap: { name in viewModel.projectFilter = name }
                    )
                    .contextMenu {
                        Button("Rename…") { viewModel.beginRename(session) }
                        Button("Export…") { viewModel.exportSession(session, formatsAvailable: hasExportFormats) }
                        Divider()
                        Button("Delete…", role: .destructive) { viewModel.beginDelete(session) }
                    }
                    if idx < visibleSessions.count - 1 {
                        Rectangle()
                            .fill(ScarfColor.border)
                            .frame(height: 1)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 6) {
            Text("Project").frame(width: 120, alignment: .leading)
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            Text("Model").frame(width: 110, alignment: .leading)
            Text("Msgs").frame(width: 60, alignment: .trailing)
            Text("Tokens").frame(width: 90, alignment: .trailing)
            Text("Cost").frame(width: 70, alignment: .trailing)
            Text("Updated").frame(width: 90, alignment: .trailing)
            Spacer().frame(width: 18)
        }
        .scarfStyle(.captionUppercase)
        .foregroundStyle(ScarfColor.foregroundMuted)
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, ScarfSpace.s2)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private var emptyState: some View {
        Text("No sessions match this filter.")
            .scarfStyle(.body)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .frame(maxWidth: .infinity)
            .padding(ScarfSpace.s10)
    }

    @ViewBuilder
    private var searchResultRows: some View {
        if viewModel.searchResults.isEmpty {
            Text("No matches for \"\(viewModel.searchText)\".")
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(maxWidth: .infinity)
                .padding(ScarfSpace.s8)
        } else {
            ForEach(Array(viewModel.searchResults.enumerated()), id: \.element.id) { idx, message in
                Button {
                    Task { await viewModel.selectSessionById(message.sessionId) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.content.prefix(140) + (message.content.count > 140 ? "…" : ""))
                            .scarfStyle(.body)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                            .lineLimit(2)
                        Text("session: \(message.sessionId)")
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ScarfSpace.s4)
                    .padding(.vertical, ScarfSpace.s3 - 2)
                }
                .buttonStyle(.plain)
                if idx < viewModel.searchResults.count - 1 {
                    Rectangle()
                        .fill(ScarfColor.border)
                        .frame(height: 1)
                }
            }
        }
    }

    // MARK: - Detail / rename sheets

    /// Bridge `viewModel.selectedSession` to a Bool sheet binding.
    /// Setting to `false` clears the selection and closes the sheet.
    private var detailSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.selectedSession != nil },
            set: { presented in
                if !presented {
                    viewModel.selectedSession = nil
                    viewModel.messages = []
                }
            }
        )
    }

    @ViewBuilder
    private var detailSheet: some View {
        if let session = viewModel.selectedSession {
            VStack(spacing: 0) {
                HStack {
                    Text("Session detail")
                        .scarfStyle(.bodyEmph)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                    Spacer()
                    Button("Done") {
                        viewModel.selectedSession = nil
                        viewModel.messages = []
                    }
                    .buttonStyle(ScarfGhostButton())
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, ScarfSpace.s4)
                .padding(.vertical, ScarfSpace.s2)
                Divider()
                SessionDetailView(
                    session: session,
                    messages: viewModel.messages,
                    subagentSessions: viewModel.subagentSessions,
                    preview: viewModel.previewFor(session),
                    onRename: { viewModel.beginRename(session) },
                    onExport: { viewModel.exportSession(session, formatsAvailable: hasExportFormats) },
                    onDelete: { viewModel.beginDelete(session) },
                    onSelectSubagent: { sub in
                        Task { await viewModel.selectSession(sub) }
                    },
                    loadReasoningContent: { await viewModel.reasoningContent(for: $0) }
                )
            }
            .frame(minWidth: 720, idealWidth: 880, minHeight: 520, idealHeight: 700)
        }
    }

    private var renameSheet: some View {
        VStack(spacing: ScarfSpace.s4) {
            Text("Rename Session")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            ScarfTextField("Session title", text: $viewModel.renameText)
                .onSubmit { viewModel.confirmRename() }
            if let renameError = viewModel.renameError {
                Label(renameError, systemImage: "exclamationmark.triangle")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { viewModel.showRenameSheet = false }
                    .buttonStyle(ScarfGhostButton())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if viewModel.isRenaming {
                    ProgressView().controlSize(.small)
                }
                Button("Rename") { viewModel.confirmRename() }
                    .buttonStyle(ScarfPrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        viewModel.isRenaming
                        || viewModel.renameText.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 420)
        .confirmationDialog(
            "Rename “Bot Chat”?",
            isPresented: $viewModel.showBotChatRenameWarning,
            titleVisibility: .visible
        ) {
            Button("Rename Anyway", role: .destructive) {
                viewModel.confirmRenameAcknowledgingBotChat()
            }
            Button("Cancel", role: .cancel) { viewModel.showBotChatRenameWarning = false }
        } message: {
            Text(BotChatSession.renameWarning)
        }
    }

    /// v0.20+ export format picker, shown instead of jumping straight to
    /// the save panel. `md`/`qmd` write a whole directory of files and
    /// `html` needs a real output path — `confirmExportOptions()` routes to
    /// the right panel kind once the user picks.
    private var exportOptionsSheet: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s4) {
            Text("Export Sessions")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Format")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                Picker("Format", selection: $viewModel.exportFormat) {
                    ForEach(viewModel.availableExportFormats) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                if viewModel.availableExportFormats.count < SessionExportFormat.allCases.count {
                    Text("Markdown, Quarto, and HTML exports write files on the remote host, so only stream-capable formats are offered here.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
            }

            Toggle("Redact secrets", isOn: $viewModel.exportRedact)
                .toggleStyle(.checkbox)
                .help("Strip API keys, tokens, and credentials from the exported content.")

            HStack {
                Button("Cancel") { viewModel.cancelExportOptions() }
                    .buttonStyle(ScarfGhostButton())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export…") { viewModel.confirmExportOptions() }
                    .buttonStyle(ScarfPrimaryButton())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 360)
    }
}

// MARK: - Table row

private struct SessionTableRow: View {
    let session: HermesSession
    let preview: String?
    let projectName: String?
    let onTap: () -> Void
    let onProjectTap: (String) -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                projectCell
                titleCell
                Text(modelLabel)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .frame(width: 110, alignment: .leading)
                    .lineLimit(1)
                Text("\(session.messageCount)")
                    .font(ScarfFont.monoSmall)
                    .frame(width: 60, alignment: .trailing)
                Text(formatTokens(session.totalTokens))
                    .font(ScarfFont.monoSmall)
                    .frame(width: 90, alignment: .trailing)
                Text(costLabel)
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .frame(width: 70, alignment: .trailing)
                Text(updatedLabel)
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .frame(width: 90, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .frame(width: 18)
            }
            .padding(.horizontal, ScarfSpace.s4)
            .padding(.vertical, ScarfSpace.s2 + 2)
            .background(hover ? ScarfColor.backgroundTertiary.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var projectCell: some View {
        Group {
            if let projectName, !projectName.isEmpty {
                Button {
                    onProjectTap(projectName)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                        Text(projectName)
                            .scarfStyle(.caption)
                    }
                    .foregroundStyle(ScarfColor.accentActive)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(ScarfColor.accentTint))
                }
                .buttonStyle(.plain)
            } else {
                Text("—")
                    .font(ScarfFont.monoSmall)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
        .frame(width: 120, alignment: .leading)
    }

    private var titleCell: some View {
        HStack(spacing: 6) {
            statusDot
            Text(session.displayLabel(preview: preview))
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            // v0.16: rewind indicator. 0 on pre-v0.16 hosts (column absent).
            if session.rewindCount > 0 {
                Label("\(session.rewindCount)", systemImage: "arrow.counterclockwise")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
                    .help("Rewound \(session.rewindCount) time\(session.rewindCount == 1 ? "" : "s")")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusDot: some View {
        if let _ = session.endedAt {
            EmptyView()
        } else if session.startedAt != nil {
            // No reliable "active" signal on HermesSession today —
            // skip the dot until we wire it from the live session
            // probe. Reserved 0 width so columns stay aligned.
            EmptyView()
        }
    }

    /// `sessions.model` — fetched by `sessionColumns` since the first
    /// schema Scarf supported and carried on `HermesSession` all along.
    /// This cell used to read a private `lastModel` extension that was
    /// hardcoded to `nil`, so the Model column rendered blank on every
    /// row while the value sat in the struct being displayed.
    private var modelLabel: String {
        session.model ?? "—"
    }

    private var costLabel: String {
        if let c = session.displayCostUSD, c > 0 {
            return c.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        }
        return "$0.00"
    }

    private static let updatedFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    /// The column is headed "Updated", so it must not show `startedAt` —
    /// a month-old conversation that took a turn this morning was
    /// reporting "1 month ago" under that heading.
    ///
    /// `lastActivityAt` is Hermes v0.20's durable activity heartbeat;
    /// `endedAt` covers a closed session on a host too old to have it; and
    /// `startedAt` remains the floor. This list's query deliberately does
    /// NOT select the correlated `last_active` recency expression (see
    /// `sessionListSnapshot(includeUnreadActivity:)`), so this is the
    /// freshest signal available here without paying a per-row subquery.
    private var updatedLabel: String {
        guard let date = session.lastActivityAt ?? session.endedAt ?? session.startedAt else { return "—" }
        return Self.updatedFormatter.localizedString(for: date, relativeTo: Date())
    }
}
