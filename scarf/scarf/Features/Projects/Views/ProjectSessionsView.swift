import SwiftUI
import ScarfCore

/// Per-project Sessions tab (v2.3). Lives beside the Dashboard and
/// Site tabs in the project view; populated from the session
/// attribution sidecar maintained by ChatViewModel. A "New Chat"
/// button spawns a fresh ACP session at cwd = project.path and
/// routes the user into the Chat feature via AppCoordinator.
struct ProjectSessionsView: View {
    let project: ProjectEntry

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher
    @Environment(\.serverContext) private var serverContext

    @State private var viewModel: ProjectSessionsViewModel?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        // `idealHeight: 400` caps what this subtree reports as its
        // ideal height. Without it, the inner List's row-materialised
        // intrinsic height bubbles up through NavigationSplitView's
        // detail slot and, under `.windowResizability(.contentMinSize)`,
        // opens the window at a height that exceeds the screen on
        // busy projects — the Sessions tab header + "New Chat" button
        // end up below the visible desktop edge. `maxHeight: .infinity`
        // still lets the List fill any taller offered space, and
        // `minHeight: 0` allows it to shrink. Mirrors the same pattern
        // applied in RichChatView.
        .frame(minHeight: 0, idealHeight: 400, maxHeight: .infinity)
        .task(id: project.id) {
            // Rebuild the VM when the project changes so stale state
            // from a previously-selected project doesn't bleed
            // through.
            viewModel = ProjectSessionsViewModel(
                context: serverContext,
                project: project
            )
            await viewModel?.load()
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel?.load() }
        }
        .onDisappear {
            // Release the SQLite handle so it doesn't dangle once
            // the user leaves this tab. `load()` will re-open next
            // time. Mirrors ActivityView's disappear cleanup.
            Task { await viewModel?.close() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sessions in this project")
                    .font(.headline)
                Text("Chats you start here get attributed automatically. Older CLI-started sessions live in the global Sessions sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                // Route into the Chat feature with a cwd override.
                // ChatView observes this via its onChange and starts
                // a fresh session with projectPath = our project.
                coordinator.pendingProjectChat = project.path
                coordinator.selectedSection = .chat
            } label: {
                Label("New Chat", systemImage: "message.badge.filled.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            if vm.isLoading && vm.sessions.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.sessions.isEmpty {
                emptyState(hint: vm.emptyStateHint)
            } else {
                sessionList(vm.sessions)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyState(hint: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(hint ?? "No sessions yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionList(_ sessions: [HermesSession]) -> some View {
        List(sessions) { session in
            ProjectSessionRow(session: session)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Route into the Chat feature with this session
                    // as a resume target. Existing ChatView logic
                    // handles ACP reconnect.
                    coordinator.selectedSessionId = session.id
                    coordinator.selectedSection = .chat
                }
        }
        .listStyle(.plain)
    }
}

/// Single row in the per-project Sessions list. Intentionally small
/// and self-contained so it can evolve independently of the global
/// Sessions sidebar's row UI — if the two visualisations diverge
/// (e.g. the project tab wants to hide the `source` badge that's
/// useful in the global list), they don't pull each other along.
private struct ProjectSessionRow: View {
    let session: HermesSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconForSource(session.source))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(session.id.prefix(12))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    if let started = formattedStart {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(started)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(session.messageCount)")
                    .font(.caption.monospaced())
                Text("msgs")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var displayTitle: String {
        if let t = session.title, !t.isEmpty { return t }
        return "Untitled session"
    }

    private var formattedStart: String? {
        // `startedAt` is `Date?` — the DB column can be null for
        // sessions in unusual states. Locale-aware short form keeps
        // us consistent with Insights + Activity.
        guard let date = session.startedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func iconForSource(_ source: String) -> String {
        switch source.lowercased() {
        case "cli", "acp": return "terminal"
        case "telegram": return "paperplane"
        case "discord": return "bubble.left.and.bubble.right"
        default: return "message"
        }
    }
}
