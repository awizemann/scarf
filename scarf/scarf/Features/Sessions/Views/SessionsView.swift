import SwiftUI
import ScarfCore

struct SessionsView: View {
    @State private var viewModel: SessionsViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: SessionsViewModel(context: context))
    }


    var body: some View {
        VStack(spacing: 0) {
            if let stats = viewModel.storeStats {
                statsBar(stats)
                Divider()
            }
            if !viewModel.allProjects.isEmpty {
                filterBar
                Divider()
            }
            HSplitView {
                sessionList
                    .frame(minWidth: 280, idealWidth: 320)
                sessionDetail
                    .frame(minWidth: 400)
            }
        }
        .navigationTitle("Sessions")
        .searchable(text: $viewModel.searchText, prompt: "Search messages...")
        .onSubmit(of: .search) { Task { await viewModel.search() } }
        .onChange(of: viewModel.searchText) {
            if viewModel.searchText.isEmpty {
                viewModel.isSearching = false
                viewModel.searchResults = []
            }
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
        .sheet(isPresented: $viewModel.showRenameSheet) {
            renameSheet
        }
        .confirmationDialog("Delete Session?", isPresented: $viewModel.showDeleteConfirmation) {
            Button("Delete", role: .destructive) { viewModel.confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the session and all its messages.")
        }
    }

    private func statsBar(_ stats: SessionStoreStats) -> some View {
        HStack(spacing: 16) {
            Label("\(stats.totalSessions) sessions", systemImage: "bubble.left.and.bubble.right")
            Label("\(stats.totalMessages) messages", systemImage: "text.bubble")
            Label(stats.databaseSize, systemImage: "internaldrive")
            ForEach(stats.platformCounts, id: \.platform) { item in
                Label("\(item.count) \(item.platform)", systemImage: platformIcon(item.platform))
            }
            Spacer()
            Button("Export All") { viewModel.exportAll() }
                .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var sessionList: some View {
        List(selection: Binding(
            get: { viewModel.selectedSession?.id },
            set: { id in
                if let id, let session = viewModel.sessions.first(where: { $0.id == id }) {
                    Task { await viewModel.selectSession(session) }
                } else {
                    viewModel.selectedSession = nil
                    viewModel.messages = []
                }
            }
        )) {
            if viewModel.isSearching {
                Section("Search Results (\(viewModel.searchResults.count))") {
                    ForEach(viewModel.searchResults) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.content.prefix(100))
                                .lineLimit(2)
                                .font(.caption)
                            Text(message.sessionId)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .tag(message.sessionId)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Task { await viewModel.selectSessionById(message.sessionId) }
                        }
                    }
                }
            } else {
                ForEach(viewModel.filteredSessions) { session in
                    SessionRow(
                        session: session,
                        preview: viewModel.previewFor(session),
                        projectName: viewModel.projectName(for: session)
                    )
                    .tag(session.id)
                    .contextMenu {
                        Button("Rename...") { viewModel.beginRename(session) }
                        Button("Export...") { viewModel.exportSession(session) }
                        Divider()
                        Button("Delete...", role: .destructive) { viewModel.beginDelete(session) }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// Project filter Menu shown above the list when at least one
    /// project is registered. Mirrors the Dashboard's Sessions tab on
    /// iOS, with an "Unattributed" entry for quick-chat / pre-v2.3
    /// sessions that have no project mapping.
    private var filterBar: some View {
        HStack(spacing: 8) {
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
                Divider()
                ForEach(viewModel.allProjects.sorted { $0.name < $1.name }) { project in
                    Button {
                        viewModel.projectFilter = project.name
                    } label: {
                        Label(project.name, systemImage: "folder.fill")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: filterIconName)
                    Text(filterLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.tint.opacity(0.1), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if viewModel.projectFilter != nil {
                Button {
                    viewModel.projectFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }

            Spacer()

            Text("\(viewModel.filteredSessions.count) of \(viewModel.sessions.count) shown")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var filterIconName: String {
        viewModel.projectFilter == nil
            ? "line.3.horizontal.decrease.circle"
            : "line.3.horizontal.decrease.circle.fill"
    }

    private var filterLabel: String {
        switch viewModel.projectFilter {
        case .none:                 return "All projects"
        case .some(let s) where s.isEmpty: return "Unattributed"
        case .some(let s):          return s
        }
    }

    @ViewBuilder
    private var sessionDetail: some View {
        if let session = viewModel.selectedSession {
            SessionDetailView(
                session: session,
                messages: viewModel.messages,
                subagentSessions: viewModel.subagentSessions,
                preview: viewModel.previewFor(session),
                onRename: { viewModel.beginRename(session) },
                onExport: { viewModel.exportSession(session) },
                onDelete: { viewModel.beginDelete(session) },
                onSelectSubagent: { sub in
                    Task { await viewModel.selectSession(sub) }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("Select a Session", systemImage: "bubble.left.and.bubble.right", description: Text("Choose a session from the list"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var renameSheet: some View {
        VStack(spacing: 16) {
            Text("Rename Session")
                .font(.headline)
            TextField("Session title", text: $viewModel.renameText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.confirmRename() }
            HStack {
                Button("Cancel") { viewModel.showRenameSheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { viewModel.confirmRename() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func platformIcon(_ platform: String) -> String {
        KnownPlatforms.icon(for: platform)
    }
}
