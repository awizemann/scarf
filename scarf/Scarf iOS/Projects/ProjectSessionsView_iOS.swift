import SwiftUI
import ScarfCore
import ScarfDesign

/// iOS twin of the Mac per-project Sessions tab. Reuses the
/// ScarfCore-side `ProjectSessionsViewModel` (promoted from the Mac
/// target in v2.5) so attribution + filtering semantics stay
/// identical. The "New Chat" button routes into the Chat tab via
/// `ScarfGoCoordinator.startChatInProject(path:)`; row taps route via
/// `coordinator.resumeSession(_:)`, the same primitive
/// `DashboardView` already uses.
struct ProjectSessionsView_iOS: View {
    let project: ProjectEntry

    @Environment(\.scarfGoCoordinator) private var coordinator
    @Environment(\.serverContext) private var serverContext

    @State private var viewModel: ProjectSessionsViewModel?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(ScarfColor.backgroundPrimary)
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
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Chats you start here are attributed automatically.")
                    .font(.caption2)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                coordinator?.startChatInProject(path: project.path)
            } label: {
                Label("New Chat", systemImage: "message.badge.filled.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(ScarfPrimaryButton())
            .controlSize(.small)
            .accessibilityLabel("Start new chat in \(project.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let vm = viewModel {
            if vm.isLoading && vm.sessions.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else if vm.sessions.isEmpty {
                emptyState(hint: vm.emptyStateHint)
            } else {
                sessionList(vm.sessions)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        }
    }

    private func emptyState(hint: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(hint ?? "No sessions yet.")
                .font(.callout)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private func sessionList(_ sessions: [HermesSession]) -> some View {
        List {
            ForEach(sessions) { session in
                Button {
                    coordinator?.resumeSession(session.id)
                } label: {
                    ProjectSessionRow_iOS(session: session)
                }
                .buttonStyle(.plain)
                .scarfGoCompactListRow()
                .listRowBackground(ScarfColor.backgroundSecondary)
            }
        }
        .scarfGoListDensity()
        .scrollContentBackground(.hidden)
        .background(ScarfColor.backgroundPrimary)
    }
}

/// Single row in the per-project Sessions list. Mirrors the Mac
/// `ProjectSessionRow` content but uses iOS-friendly text sizing.
private struct ProjectSessionRow_iOS: View {
    let session: HermesSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconForSource(session.source))
                .foregroundStyle(ScarfColor.foregroundMuted)
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
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(session.messageCount)")
                    .font(.caption.monospaced())
                Text("msgs")
                    .font(.caption2)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var displayTitle: String {
        if let t = session.title, !t.isEmpty { return t }
        return "Untitled session"
    }

    private var formattedStart: String? {
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
