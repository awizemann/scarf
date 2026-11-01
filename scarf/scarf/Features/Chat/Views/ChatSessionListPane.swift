import SwiftUI
import ScarfCore
import ScarfDesign

/// Left pane of the 3-pane chat layout — mirrors the sessions list in
/// `design/static-site/ui-kit/Chat.jsx` + `ScarfChatView.swift`. Reads
/// `chatViewModel.recentSessions` (loaded on the parent view's `.task`),
/// surfaces filter pills + a search field, and renders rows that resume
/// the session on tap. Active row matches `richChat.sessionId`.
struct ChatSessionListPane: View {
    @Bindable var chatViewModel: ChatViewModel
    @Bindable var richChat: RichChatViewModel

    @State private var searchText: String = ""
    /// Project filter — same semantics as the Sessions feature:
    /// nil = all projects (no filter), "" = unattributed, any other
    /// string matches against `chatViewModel.sessionProjectNames`.
    @State private var projectFilter: String?

    /// Hide sessions whose `source` is `"cron"` — these are
    /// scheduled-job runs that clutter the chat list. Persisted via
    /// `@AppStorage` so the preference survives across launches.
    /// Default `true` because the noise-to-signal ratio for cron
    /// rows in the chat surface is poor: they're more useful inside
    /// the Cron / Activity feature than as resumable conversations.
    @AppStorage("scarf.chat.hideCronSessions") private var hideCronSessions: Bool = true

    @State private var renameTarget: HermesSession?
    @State private var renameText: String = ""
    /// Raised by `commitRename` when the rename would detach a bot's
    /// conversation history (see `BotChatSession.renameNeedsConfirmation`).
    @State private var showBotChatRenameWarning = false
    @State private var deleteTarget: HermesSession?
    /// The list scroll view's own width, which a scroller doesn't change.
    @State private var listViewportWidth: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            header
            projectFilterRow
            searchField
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleSessions) { session in
                        ChatSessionRow(
                            session: session,
                            preview: chatViewModel.previewFor(session),
                            projectName: chatViewModel.projectName(for: session),
                            // By lineage (R14-2): after a mid-chat
                            // compression rotation the row is listed under
                            // the new tip while the chat keeps its ACP id.
                            isActive: chatViewModel.isAttached(to: session),
                            isLive: chatViewModel.isAttached(to: session) && richChat.isAgentWorking,
                            // The window's live chat on this conversation,
                            // focused or not, or the shown chat when it is
                            // this one (its error stays visible after its
                            // client is gone): the row reads its state
                            // (parallel chats P1).
                            liveChat: chatViewModel.rowChat(for: session),
                            onSelect: { chatViewModel.resumeSession(session.id) }
                        )
                        .contextMenu {
                            // UNGATED, deliberately. `sessions rename` exists
                            // at every tagged Hermes — `add_parser("rename", …)`
                            // at `hermes_cli/main.py:2373`, tag v2026.3.12
                            // (0.2.0), below Scarf's v0.6.0 minimum — so the
                            // `hasSessionsRename` flag that used to guard this
                            // (floored at v0.16) only hid the item from
                            // 0.12–0.15 hosts that have the verb.
                            Button("Rename…") {
                                renameText = chatViewModel.previewFor(session)
                                chatViewModel.renameError = nil
                                renameTarget = session
                            }
                            Divider()
                            Button("Delete…", role: .destructive) {
                                deleteTarget = session
                            }
                        }
                    }
                    if visibleSessions.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, ScarfSpace.s2)
                .modifier(ScrollerStableContentWidth(viewportWidth: listViewportWidth))
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listViewportWidth = $0 }
            // Rows stay CLICKABLE while a session is mid-boot
            // (t-5451bd1b). The v2.8 behavior disabled the whole pane
            // during prep to stop two starts racing over one SSH
            // backend — but a wedged start then left the pane locked
            // forever (S3's self-locking spinner: no watchdog bounded
            // the pipeline, so restart was the only way out). Racing is
            // now prevented at the source instead: a new row click
            // bumps `sessionStartGeneration`, and the superseded
            // start's pipeline abandons itself at its next await and
            // stops its client (see ChatViewModel.startStillCurrent).
            // The ProgressView capsule below still shows boot progress.
            .overlay {
                if chatViewModel.isPreparingSession {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(chatViewModel.acpStatus.isEmpty ? "Loading…" : chatViewModel.acpStatus)
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    .padding(.horizontal, ScarfSpace.s3)
                    .padding(.vertical, ScarfSpace.s2)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, ScarfSpace.s5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
                }
            }
            footer
        }
        .background(ScarfColor.backgroundTertiary)
        .sheet(item: $renameTarget) { session in
            renameSheet(for: session)
        }
        .confirmationDialog(
            deleteTarget.map { "Delete \(chatViewModel.previewFor($0))?" } ?? "",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    Task { await chatViewModel.deleteConversation(target) }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            // A rotated compression chain is one row but several session
            // rows; the delete removes every one (R14-3).
            if let target = deleteTarget, target.lineageIds.count > 1 {
                Text("This conversation was compressed into \(target.lineageIds.count) linked segments. Deleting it permanently deletes all \(target.lineageIds.count) segments and their messages.")
            } else {
                Text("This permanently deletes the session and all its messages.")
            }
        }
    }

    private func renameSheet(for session: HermesSession) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text("Rename Session")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            ScarfTextField("Session title", text: $renameText)
                .onSubmit { commitRename(session) }
            if let renameError = chatViewModel.renameError(for: session.id) {
                Label(renameError, systemImage: "exclamationmark.triangle")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { renameTarget = nil }
                    .buttonStyle(ScarfGhostButton())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { commitRename(session) }
                    .buttonStyle(ScarfPrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty
                              || chatViewModel.isRenamingSession)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 380)
        .confirmationDialog(
            "Rename \u{201C}Bot Chat\u{201D}?",
            isPresented: $showBotChatRenameWarning,
            titleVisibility: .visible
        ) {
            Button("Rename Anyway", role: .destructive) {
                showBotChatRenameWarning = false
                performRename(session)
            }
            Button("Cancel", role: .cancel) { showBotChatRenameWarning = false }
        } message: {
            Text(BotChatSession.renameWarning)
        }
    }

    private func commitRename(_ session: HermesSession) {
        // Ask before detaching a bot's history. Hermes only refuses the
        // rename server-side for a HIDDEN "Bot Chat"; a Scarf-created one
        // is never hidden, so this rename would succeed and orphan the
        // transcript (go/no-go blocking condition 3).
        if BotChatSession.renameNeedsConfirmation(currentTitle: session.title, newTitle: renameText),
           !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showBotChatRenameWarning = true
            return
        }
        performRename(session)
    }

    private func performRename(_ session: HermesSession) {
        // Keep the sheet open on failure so the reason is visible next
        // to the field — a rename Hermes refuses (a hidden canonical Bot
        // Chat) would otherwise just appear to do nothing.
        let title = renameText
        Task {
            // Close only the sheet this rename came from: the user may have
            // cancelled and opened another one while the CLI ran.
            if await chatViewModel.renameSession(session.id, to: title),
               renameTarget?.id == session.id {
                renameTarget = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: ScarfSpace.s2) {
            Text("Chats")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer()
            Button {
                chatViewModel.startNewSession()
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(ScarfPrimaryButton())
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.top, ScarfSpace.s3)
        .padding(.bottom, ScarfSpace.s2)
    }

    private var projectFilterRow: some View {
        HStack(spacing: ScarfSpace.s2) {
            projectFilterMenu
            Spacer(minLength: 0)
            cronVisibilityToggle
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.bottom, ScarfSpace.s2)
    }

    private var projectFilterMenu: some View {
        Menu {
            Button {
                projectFilter = nil
            } label: {
                Label("All projects", systemImage: "tray.full")
            }
            Button {
                projectFilter = ""
            } label: {
                Label("Unattributed", systemImage: "questionmark.folder")
            }
            if !chatViewModel.allProjects.isEmpty {
                Divider()
                ForEach(chatViewModel.allProjects.sorted { $0.name < $1.name }) { project in
                    Button {
                        projectFilter = project.name
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
                    .lineLimit(1)
                if projectFilter == nil {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(projectFilter != nil ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(projectFilter != nil ? ScarfColor.accentTint : ScarfColor.backgroundSecondary)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        projectFilter != nil ? ScarfColor.accent : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Right-side chip that toggles visibility of cron-originated
    /// sessions. Filled when cron is HIDDEN (the active-filter look,
    /// matching the project pill). The hidden-count is read from
    /// `cronSessionCount` so the user knows how many rows the toggle
    /// is suppressing.
    private var cronVisibilityToggle: some View {
        Button {
            hideCronSessions.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: hideCronSessions ? "clock.badge.xmark" : "clock")
                    .font(.system(size: 10))
                Text(hideCronSessions ? "Cron hidden" : "Cron shown")
                    .scarfStyle(.caption)
                    .lineLimit(1)
                if hideCronSessions, cronSessionCount > 0 {
                    Text("\(cronSessionCount)")
                        .font(ScarfFont.caption2)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                }
            }
            .foregroundStyle(hideCronSessions ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(hideCronSessions ? ScarfColor.accentTint : ScarfColor.backgroundSecondary)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        hideCronSessions ? ScarfColor.accent : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .help(hideCronSessions
              ? "Showing user chats only. Click to include cron-originated sessions."
              : "Showing all chats. Click to hide cron-originated sessions.")
        .fixedSize()
    }

    /// How many of the currently-loaded sessions are cron-originated.
    /// Surfaced as a count badge on the toggle so the hidden volume
    /// is visible.
    private var cronSessionCount: Int {
        chatViewModel.recentSessions.lazy.filter { $0.source == "cron" }.count
    }

    private var projectFilterIcon: String {
        switch projectFilter {
        case .none: return "square.stack.3d.up"
        case .some(let s) where s.isEmpty: return "questionmark.folder"
        default: return "folder.fill"
        }
    }

    private var projectFilterLabel: String {
        switch projectFilter {
        case .none: return "All projects"
        case .some(let s) where s.isEmpty: return "Unattributed"
        case .some(let s): return s
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(ScarfColor.foregroundFaint)
            TextField("Search…", text: $searchText)
                .textFieldStyle(.plain)
                .scarfStyle(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.md, style: .continuous)
                .strokeBorder(ScarfColor.borderStrong, lineWidth: 1)
        )
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.bottom, ScarfSpace.s2)
    }

    // MARK: - Filtering

    private var visibleSessions: [HermesSession] {
        var base = chatViewModel.sessionsForList
        // Cron-source filter — applied first so subsequent filters
        // operate on the smaller set. Authoritative signal: Hermes
        // tags every session row with `source` (`"cron"` for
        // scheduled jobs, `"acp"` for interactive chat, `"cli"` for
        // one-off CLI runs). Skips a brittle prompt-prefix match.
        if hideCronSessions {
            base = base.filter { $0.source != "cron" }
        }
        // Project filter — same semantics as the Sessions feature.
        if let filter = projectFilter {
            if filter.isEmpty {
                base = base.filter { chatViewModel.projectName(for: $0) == nil }
            } else {
                base = base.filter { chatViewModel.projectName(for: $0) == filter }
            }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmed.isEmpty {
            base = base.filter { session in
                chatViewModel.previewFor(session).lowercased().contains(trimmed)
            }
        }
        // v0.20: pinned sessions float to the top of the single flat list
        // (no separate section header — just a stable reorder), each group
        // keeping its existing recency order. On pre-0.20 hosts `pinned`
        // is always false (column absent) and this is an order-preserving
        // no-op.
        return base.filter(\.pinned) + base.filter { !$0.pinned }
    }

    // MARK: - Empty state + footer

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22))
                .foregroundStyle(ScarfColor.foregroundFaint)
            Text(emptyMessage)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(ScarfSpace.s5)
    }

    private var emptyMessage: String {
        if chatViewModel.recentSessions.isEmpty {
            return "No sessions yet — tap New to start one."
        }
        // The cron toggle hides every visible row when the loaded
        // window is exclusively cron — surface that as the cause
        // rather than implying a search miss.
        if hideCronSessions, cronSessionCount == chatViewModel.recentSessions.count {
            return "All loaded chats are cron-originated. Click 'Cron hidden' above to include them."
        }
        if projectFilter != nil {
            return "No chats in this project (showing the most recent 50)."
        }
        return "No matches for that search."
    }

    private var footer: some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: "bubble.left")
                .font(.system(size: 10))
            // Show "X of Y" when filtering hides rows so the user
            // knows the chip is doing something.
            Text(footerCountText)
            Spacer()
        }
        .scarfStyle(.caption)
        .foregroundStyle(ScarfColor.foregroundMuted)
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, ScarfSpace.s2)
        .overlay(
            Rectangle()
                .fill(ScarfColor.border)
                .frame(height: 1),
            alignment: .top
        )
    }

    private var footerCountText: String {
        let total = chatViewModel.sessionsForList.count
        let visible = visibleSessions.count
        let suffix = total == 1 ? "" : "s"
        if visible == total {
            return "\(total) chat\(suffix)"
        }
        return "\(visible) of \(total) chat\(suffix)"
    }
}

// MARK: - Scroller-stable width

/// Lays a scroll view's content out at one width whether its scroller shows or
/// not. With always-visible ("legacy") scrollers, showing the scroller narrows
/// the clip view. If the content is then short enough to fit, the scroller
/// hides, the clip widens, the content is too tall again, and so on: AppKit and
/// SwiftUI flip it forever on the main thread and the app hangs (seen on the
/// chat list at doc 554x1094 / 537x1066 against a 1067pt viewport). With the
/// width fixed the content's height can't follow the scroller, so the first
/// answer stands. Overlay scrollers take no width and need nothing.
struct ScrollerStableContentWidth: ViewModifier {
    let viewportWidth: CGFloat?
    @State private var style = NSScroller.preferredScrollerStyle

    func body(content: Content) -> some View {
        content
            .frame(width: Self.contentWidth(viewportWidth: viewportWidth, style: style))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                style = NSScroller.preferredScrollerStyle
            }
    }

    static func contentWidth(viewportWidth: CGFloat?, style: NSScroller.Style) -> CGFloat? {
        guard let viewportWidth, viewportWidth > 0, style == .legacy else { return nil }
        return max(0, viewportWidth - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
    }
}

// MARK: - Row

private struct ChatSessionRow: View {
    let session: HermesSession
    let preview: String
    let projectName: String?
    let isActive: Bool
    /// The shown chat is working (terminal mode has no live chat to read).
    let isLive: Bool
    /// This conversation's live chat in the window, if any. Its row state
    /// is read HERE, in the row's own body, so a state change re-renders
    /// this row only (and nothing reads the transcript).
    let liveChat: ChatSession?
    let onSelect: () -> Void

    @State private var hover = false

    private var state: ChatSession.RowState {
        if let liveChat { return liveChat.rowState }
        return isLive ? .replying : .idle
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    statusDot
                    // v0.20: pin indicator — only rendered for pinned
                    // sessions, so pre-0.20 hosts (column absent,
                    // `pinned` always false) see the exact same row.
                    if session.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(ScarfColor.accentActive)
                            .help("Pinned")
                    }
                    Text(preview)
                        .scarfStyle(.bodyEmph)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isActive ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
                    // #145: branch mark — false without lineage data.
                    if session.isBranch {
                        SessionBranchBadge(session: session)
                    }
                    Spacer(minLength: 0)
                    // v0.20.4: unread indicator — activity postdating
                    // Hermes's `last_read_at` watermark. Only rendered
                    // when Hermes actually tracked a read for this
                    // conversation, so pre-0.20.4 hosts (column absent
                    // → `lastReadAt` nil → `isUnread` false) and
                    // never-tracked rows see the exact same row.
                    if session.isUnread {
                        Circle()
                            .fill(ScarfColor.accentActive)
                            .frame(width: 6, height: 6)
                            .help("Unread")
                    }
                    // v0.20: prefer the activity heartbeat when present
                    // — "what happened last" beats "when it started".
                    // Pre-0.20 hosts fall back to startedAt as before.
                    if let stamp = session.lastActivityAt ?? session.startedAt {
                        Text(stamp, style: .relative)
                            .font(ScarfFont.caption2)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                    }
                }
                HStack(spacing: 6) {
                    // An approval or question waits in this chat, maybe in
                    // the background: its sheet opens when the chat is
                    // focused.
                    if state == .needsAnswer {
                        ScarfBadge("Needs answer", kind: .warning)
                            .help("Hermes is waiting for your answer in this chat")
                    }
                    if let projectName, !projectName.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 8))
                            Text(projectName)
                                .font(ScarfFont.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(ScarfColor.accentActive)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(ScarfColor.accentTint))
                    }
                    Label("\(session.messageCount)", systemImage: "bubble.left")
                        .scarfStyle(.caption)
                    if session.toolCallCount > 0 {
                        Label("\(session.toolCallCount)", systemImage: "wrench")
                            .scarfStyle(.caption)
                    }
                    // v0.16: rewind indicator — how many times the session
                    // was rewound. 0 on pre-v0.16 hosts (column absent).
                    if session.rewindCount > 0 {
                        Label("\(session.rewindCount)", systemImage: "arrow.counterclockwise")
                            .scarfStyle(.caption)
                            .help("Rewound ^[\(session.rewindCount) time](inflect: true)")
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.leading, 14)
                // v0.20: last-activity line — dimmed secondary text
                // describing what the agent last did. Absent on
                // pre-0.20 hosts (columns missing → nil) so the row
                // renders exactly as before.
                if let activity = session.lastActivityDescription, !activity.isEmpty {
                    Text(activity)
                        .font(ScarfFont.caption2)
                        .foregroundStyle(ScarfColor.foregroundFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 14)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, ScarfSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        // Addressable by SESSION ID so a journey can open one specific
        // chat (the Live badge journey clicks two seeded ACP chats in
        // turn) rather than matching a preview string the accessibility
        // layer truncates.
        .accessibilityIdentifier("chat.session.\(session.id)")
        // `isActive` is `session.id == richChat.sessionId` — i.e. the
        // chat pane really is BOUND to this session, which is what the
        // Kanban badge scopes its poll by. Publishing it is what lets a
        // test wait for the bind instead of guessing that a click landed
        // (a resume whose ACP `session/load` fails falls back to a NEW
        // session with a different id, and the badge would then be
        // correct about a session the test did not mean).
        // Empty when inactive rather than "inactive", matching the
        // sidebar section headers' `value == "collapsed"` precedent: a
        // list of twenty chats should not have VoiceOver say "inactive"
        // nineteen times.
        .accessibilityValue(Text(isActive ? "active" : ""))
    }

    /// What the status glyph says, for VoiceOver (nil: nothing to say).
    private var stateLabel: Text? {
        switch state {
        case .needsAnswer: return Text("Needs your answer")
        case .error: return Text("Error")
        case .replying: return Text("Replying")
        case .finishedUnread: return Text("Finished, unread")
        case .idle: return nil
        }
    }

    private var rowBackground: Color {
        if isActive { return ScarfColor.accentTint }
        if hover { return ScarfColor.border.opacity(0.5) }
        return .clear
    }

    /// The leading status mark. Replying keeps the green live dot; the
    /// other live states are small glyphs in the same slot. Finished-unread
    /// is a check here, never a second dot beside Hermes's own unread dot
    /// (trailing, v0.20.4).
    @ViewBuilder
    private var statusDot: some View {
        Group {
            switch state {
            case .replying:
                Circle()
                    .fill(ScarfColor.success)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(ScarfColor.successHue.opacity(0.20), lineWidth: 2))
            case .needsAnswer:
                statusGlyph("questionmark.circle.fill", ScarfColor.warning)
            case .error:
                statusGlyph("exclamationmark.circle.fill", ScarfColor.danger)
            case .finishedUnread:
                statusGlyph("checkmark.circle.fill", ScarfColor.success)
            case .idle:
                Circle()
                    .fill(ScarfColor.foregroundFaint.opacity(0.4))
                    .frame(width: 6, height: 6)
            }
        }
        // Fixed slot (the live dot's width, which the second line's
        // leading padding lines up with), so the title doesn't shift as
        // the state changes; a glyph may overhang it by a point.
        .frame(width: 7, height: 7)
        .accessibilityElement()
        .accessibilityLabel(stateLabel ?? Text(""))
        .accessibilityHidden(stateLabel == nil)
    }

    private func statusGlyph(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
    }
}
