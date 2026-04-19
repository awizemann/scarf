import SwiftUI

struct SessionsView: View {
    @State private var viewModel: SessionsViewModel
    @Environment(AppCoordinator.self) private var coordinator

    init(context: ServerContext) {
        _viewModel = State(initialValue: SessionsViewModel(context: context))
    }


    var body: some View {
        VStack(spacing: 0) {
            if let stats = viewModel.storeStats {
                statsBar(stats)
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
                ForEach(viewModel.sessions) { session in
                    SessionRow(session: session, preview: viewModel.previewFor(session))
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
