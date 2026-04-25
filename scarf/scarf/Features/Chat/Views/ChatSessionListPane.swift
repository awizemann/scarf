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
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.bottom, ScarfSpace.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if projectFilter != nil {
            return "No chats in this project (showing the most recent 50)."
        }
        return "No matches for that search."
    }

    private var footer: some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: "bubble.left")
                .font(.system(size: 10))
            Text("\(chatViewModel.recentSessions.count) chat\(chatViewModel.recentSessions.count == 1 ? "" : "s")")
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
                    if let started = session.startedAt {
                        Text(started, style: .relative)
                            .font(ScarfFont.caption2)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                    }
                }
                HStack(spacing: 6) {
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
