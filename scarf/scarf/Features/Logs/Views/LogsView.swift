import SwiftUI
import ScarfCore
import ScarfDesign

/// Logs — visual layer follows `design/static-site/ui-kit/Logs.jsx`:
/// page header (title + subtitle + Export action), filter toolbar
/// with file picker + component picker + level picker + search +
/// counter, and a dark monospaced tail. Each row carries timestamp +
/// uppercase level + logger + message in a tahoe-rust palette.
struct LogsView: View {
    @State private var viewModel: LogsViewModel

    init(context: ServerContext) {
        _viewModel = State(initialValue: LogsViewModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            toolbar
            logList
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Logs")
        .searchable(text: $viewModel.searchText, prompt: "Filter logs…")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading logs…",
            isEmpty: viewModel.filteredEntries.isEmpty
        )
        .task { await viewModel.load() }
        .onDisappear { Task { await viewModel.cleanup() } }
    }

    // MARK: - Header

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Logs")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("Live tail across the gateway, agent, tools, MCP servers, and cron.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
            // The retention cap must be visible: a tab left open long enough
            // to drop its oldest entries otherwise just looks like a log that
            // starts in the middle.
            if viewModel.didDropOldEntries {
                Label(
                    "Showing the most recent \(LogsViewModel.maxRetainedEntries) entries",
                    systemImage: "scissors"
                )
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Text("\(viewModel.filteredEntries.count) entries")
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundFaint)
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s4)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private var toolbar: some View {
        HStack(spacing: ScarfSpace.s3) {
            Picker("Log File", selection: Binding(
                get: { viewModel.selectedLogFile },
                set: { file in Task { await viewModel.switchLogFile(file) } }
            )) {
                ForEach(LogsViewModel.LogFile.allCases) { file in
                    Text(file.displayName).tag(file)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Picker("Component", selection: $viewModel.selectedComponent) {
                ForEach(LogsViewModel.LogComponent.allCases) { component in
                    Text(component.displayName).tag(component)
                }
            }
            .frame(maxWidth: 140)

            Picker("Level", selection: $viewModel.filterLevel) {
                Text("All Levels").tag(LogEntry.LogLevel?.none)
                ForEach(LogEntry.LogLevel.allCases, id: \.rawValue) { level in
                    Text(verbatim: level.rawValue).tag(LogEntry.LogLevel?.some(level))
                }
            }
            .frame(maxWidth: 150)

            Spacer()
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.vertical, ScarfSpace.s2 + 2)
        .background(ScarfColor.backgroundSecondary)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(viewModel.filteredEntries) { entry in
                        logRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, ScarfSpace.s2)
            }
            .background(Color(red: 0.07, green: 0.06, blue: 0.05))
            .onChange(of: viewModel.entries.count) {
                if let last = viewModel.filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(entry.timestamp)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(Color(red: 0.49, green: 0.45, blue: 0.39))
                .frame(width: 100, alignment: .leading)
            Text(verbatim: entry.level.rawValue.uppercased())
                .font(ScarfFont.caption2)
                .fontWeight(.bold)
                .tracking(0.4)
                .foregroundStyle(colorForLevel(entry.level))
                .frame(width: 50, alignment: .leading)
            if let sessionId = entry.sessionId {
                Button {
                    viewModel.searchText = sessionId
                } label: {
                    Text(sessionId)
                        .font(ScarfFont.caption2.monospaced())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(ScarfColor.accentTint)
                        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.sm))
                        .foregroundStyle(ScarfColor.accent)
                }
                .buttonStyle(.plain)
                .help("Filter to session \(sessionId)")
            }
            Text(entry.logger)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(Color(red: 0.66, green: 0.61, blue: 0.51))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
            Text(entry.message)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(Color(red: 0.91, green: 0.88, blue: 0.82))
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.vertical, 1)
        // One element per line instead of five, so VoiceOver walks the log
        // a line at a time. Deliberately `.combine` with NO explicit label:
        // an `.accessibilityLabel` here would build a String on every body
        // evaluation of every one of up to 5,000 rows (F6's cap), whereas
        // `.combine` costs nothing until accessibility actually asks.
        // Combining absorbs the session-id button, so its action comes back
        // as a custom action rather than being lost.
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let sessionId = entry.sessionId {
                Button("Filter to this session") {
                    viewModel.searchText = sessionId
                }
            }
        }
    }

    private func colorForLevel(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .debug:    return Color(red: 0.49, green: 0.45, blue: 0.39)
        case .info:     return ScarfColor.info
        case .warning:  return ScarfColor.warning
        case .error,
             .critical: return ScarfColor.danger
        }
    }
}
