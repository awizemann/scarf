import SwiftUI

struct ActivityView: View {
    @State private var viewModel: ActivityViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: ActivityViewModel(context: context))
    }


    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            HSplitView {
                activityList
                    .frame(minWidth: 350, idealWidth: 450)
                activityDetail
                    .frame(minWidth: 300)
            }
        }
        .navigationTitle("Activity")
        .task { await viewModel.load() }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.load() }
        }
        .onDisappear { Task { await viewModel.cleanup() } }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(label: "All", isSelected: viewModel.filterKind == nil) {
                        viewModel.filterKind = nil
                    }
                    ForEach(ToolKind.allCases, id: \.rawValue) { kind in
                        FilterChip(label: kind.rawValue.capitalized, isSelected: viewModel.filterKind == kind) {
                            viewModel.filterKind = kind
                        }
                    }
                }
            }
            Divider()
                .frame(height: 16)
            Picker(selection: $viewModel.filterSessionId) {
                Text("All Sessions").tag(String?.none)
                Divider()
                ForEach(viewModel.availableSessions, id: \.id) { session in
                    Text(session.label)
                        .lineLimit(1)
                        .tag(String?.some(session.id))
                }
            } label: {
                EmptyView()
            }
            .frame(maxWidth: 250)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var activityList: some View {
        List(selection: Binding(
            get: { viewModel.selectedEntry?.id },
            set: { id in
                let entry = id.flatMap { id in viewModel.filteredActivity.first(where: { $0.id == id }) }
                Task { await viewModel.selectEntry(entry) }
            }
        )) {
            ForEach(viewModel.filteredActivity) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.kind.icon)
                        .foregroundStyle(colorForKind(entry.kind))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.toolName)
                            .font(.system(.body, design: .monospaced, weight: .medium))
                        Text(entry.summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if let time = entry.timestamp {
                        Text(time, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(entry.id)
                .padding(.vertical, 2)
            }
        }
        .listStyle(.inset)
        .overlay {
            if viewModel.filteredActivity.isEmpty && !viewModel.isLoading {
                ContentUnavailableView("No Activity", systemImage: "bolt.horizontal", description: Text("No tool calls found"))
            }
        }
    }

    @ViewBuilder
    private var activityDetail: some View {
        if let entry = viewModel.selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: entry.kind.icon)
                            .font(.title2)
                            .foregroundStyle(colorForKind(entry.kind))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.toolName)
                                .font(.title3.bold().monospaced())
                            Text(entry.kind.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 16) {
                        if let time = entry.timestamp {
                            Label(time.formatted(.dateTime.month().day().hour().minute().second()), systemImage: "clock")
                        }
                        Button {
                            coordinator.selectedSessionId = entry.sessionId
                            coordinator.selectedSection = .sessions
                        } label: {
                            Label(String(entry.sessionId.prefix(20)), systemImage: "bubble.left.and.bubble.right")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Open session")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Arguments")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(entry.prettyArguments)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if let result = viewModel.toolResult, !result.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Output")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(result)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(50)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(.quaternary, lineWidth: 1)
                                )
                        }
                    }

                    if !entry.messageContent.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Assistant Message")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            MarkdownContentView(content: entry.messageContent)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ContentUnavailableView("Select a Tool Call", systemImage: "bolt.horizontal", description: Text("Choose an entry from the list"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func colorForKind(_ kind: ToolKind) -> Color {
        switch kind {
        case .read: return .green
        case .edit: return .blue
        case .execute: return .orange
        case .fetch: return .purple
        case .browser: return .indigo
        case .other: return .secondary
        }
    }
}

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
