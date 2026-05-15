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
    @State private var deleteTarget: HermesSession?

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
                            isActive: session.id == richChat.sessionId,
                            isLive: session.id == richChat.sessionId && richChat.isAgentWorking,
                            onSelect: { chatViewModel.resumeSession(session.id) }
                        )
                        .contextMenu {
                            Button("Rename…") {
                                renameText = chatViewModel.previewFor(session)
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
            }
            // While a session is mid-boot the SSH tunnel is bottlenecked
            // on the in-flight start/load — letting the user queue up a
            // second session-switch ends with both fights racing for
            // the same backend (we've seen the small fast chat lose to
            // a 30s timeout from the prior big chat). Disable the
            // entire pane (taps + visual) during prep, plus a
            // ProgressView so the cause is obvious. v2.8.
            .disabled(chatViewModel.isPreparingSession)
            .opacity(chatViewModel.isPreparingSession ? 0.55 : 1.0)
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
                    chatViewModel.deleteSession(target.id)
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This permanently deletes the session and all its messages.")
        }
    }

    private func renameSheet(for session: HermesSession) -> some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text("Rename Session")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            ScarfTextField("Session title", text: $renameText)
                .onSubmit { commitRename(session) }
            HStack {
                Button("Cancel") { renameTarget = nil }
                    .buttonStyle(ScarfGhostButton())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { commitRename(session) }
                    .buttonStyle(ScarfPrimaryButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 380)
    }

    private func commitRename(_ session: HermesSession) {
        chatViewModel.renameSession(session.id, to: renameText)
        renameTarget = nil
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
        var base = chatViewModel.recentSessions
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
        guard !trimmed.isEmpty else { return base }
        return base.filter { session in
            chatViewModel.previewFor(session).lowercased().contains(trimmed)
        }
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
        let total = chatViewModel.recentSessions.count
        let visible = visibleSessions.count
        let suffix = total == 1 ? "" : "s"
        if visible == total {
            return "\(total) chat\(suffix)"
        }
        return "\(visible) of \(total) chat\(suffix)"
    }
}

// MARK: - Row

private struct ChatSessionRow: View {
    let session: HermesSession
    let preview: String
    let projectName: String?
    let isActive: Bool
    let isLive: Bool
    let onSelect: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    statusDot
                    Text(preview)
                        .scarfStyle(.bodyEmph)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isActive ? ScarfColor.accentActive : ScarfColor.foregroundPrimary)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    if let activity = session.lastActivityAt {
                        Text(activity, style: .relative)
                            .font(ScarfFont.caption2)
                            .foregroundStyle(ScarfColor.foregroundFaint)
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
                    Spacer(minLength: 0)
                }
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.leading, 14)
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
    }

    private var rowBackground: Color {
        if isActive { return ScarfColor.accentTint }
        if hover { return ScarfColor.border.opacity(0.5) }
        return .clear
    }

    @ViewBuilder
    private var statusDot: some View {
        if isLive {
            Circle()
                .fill(ScarfColor.success)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(ScarfColor.success.opacity(0.20), lineWidth: 2))
        } else {
            Circle()
                .fill(ScarfColor.foregroundFaint.opacity(0.4))
                .frame(width: 6, height: 6)
        }
    }
}
