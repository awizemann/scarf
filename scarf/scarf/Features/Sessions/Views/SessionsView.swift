import SwiftUI

struct SessionsView: View {
    @State private var viewModel = SessionsViewModel()
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 280, idealWidth: 320)
            sessionDetail
                .frame(minWidth: 400)
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
                    SessionRow(session: session)
                        .tag(session.id)
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var sessionDetail: some View {
        if let session = viewModel.selectedSession {
            SessionDetailView(session: session, messages: viewModel.messages)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView("Select a Session", systemImage: "bubble.left.and.bubble.right", description: Text("Choose a session from the list"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
