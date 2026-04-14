import SwiftUI

struct LogsView: View {
    @State private var viewModel = LogsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .navigationTitle("Logs")
        .searchable(text: $viewModel.searchText, prompt: "Filter logs...")
        .task { await viewModel.load() }
        .onDisappear { Task { await viewModel.cleanup() } }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Log File", selection: Binding(
                get: { viewModel.selectedLogFile },
                set: { file in Task { await viewModel.switchLogFile(file) } }
            )) {
                ForEach(LogsViewModel.LogFile.allCases) { file in
                    Text(file.rawValue).tag(file)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Picker("Component", selection: $viewModel.selectedComponent) {
                ForEach(LogsViewModel.LogComponent.allCases) { component in
                    Text(component.rawValue).tag(component)
                }
            }
            .frame(maxWidth: 140)

            Spacer()

            Picker("Level", selection: $viewModel.filterLevel) {
                Text("All Levels").tag(LogEntry.LogLevel?.none)
                ForEach(LogEntry.LogLevel.allCases, id: \.rawValue) { level in
                    Text(level.rawValue).tag(LogEntry.LogLevel?.some(level))
                }
            }
            .frame(maxWidth: 150)

            Text("\(viewModel.filteredEntries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(viewModel.filteredEntries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.timestamp)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    Text(entry.level.rawValue)
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(colorForLevel(entry.level))
                        .frame(width: 60, alignment: .leading)
                    if let sessionId = entry.sessionId {
                        Button {
                            viewModel.searchText = sessionId
                        } label: {
                            Text(sessionId)
                                .font(.system(.caption2, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Filter to session \(sessionId)")
                    }
                    Text(entry.logger)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140, alignment: .leading)
                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                .id(entry.id)
            }
            .listStyle(.inset)
            .onChange(of: viewModel.entries.count) {
                if let last = viewModel.filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func colorForLevel(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error, .critical: return .red
        }
    }
}
