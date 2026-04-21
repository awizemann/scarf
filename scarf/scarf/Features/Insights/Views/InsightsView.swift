import SwiftUI

struct InsightsView: View {
    @State private var viewModel: InsightsViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: InsightsViewModel(context: context))
    }


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                periodPicker
                overviewSection
                modelSection
                platformSection
                toolsSection
                activitySection
                notableSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Insights")
        .task { await viewModel.load() }
        .onChange(of: viewModel.period) {
            Task { await viewModel.load() }
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.load() }
        }
    }

    private var periodPicker: some View {
        Picker("Period", selection: $viewModel.period) {
            ForEach(InsightsPeriod.allCases) { period in
                Text(period.displayName).tag(period)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 400)
    }

    // MARK: - Overview

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Overview")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                InsightCard(label: "Sessions", value: "\(viewModel.sessions.count)")
                InsightCard(label: "Messages", value: "\(viewModel.totalMessages)")
                InsightCard(label: "User Messages", value: "\(viewModel.userMessageCount)")
                InsightCard(label: "Tool Calls", value: "\(viewModel.totalToolCalls)")
                InsightCard(label: "Input Tokens", value: formatTokens(viewModel.totalInputTokens))
                InsightCard(label: "Output Tokens", value: formatTokens(viewModel.totalOutputTokens))
                InsightCard(label: "Cache Read", value: formatTokens(viewModel.totalCacheReadTokens))
                InsightCard(label: "Cache Write", value: formatTokens(viewModel.totalCacheWriteTokens))
                InsightCard(label: "Reasoning Tokens", value: formatTokens(viewModel.totalReasoningTokens))
                InsightCard(label: "Total Tokens", value: formatTokens(viewModel.totalTokens))
                InsightCard(label: "Total Cost", value: viewModel.totalCost.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                InsightCard(label: "Active Time", value: formatDuration(viewModel.activeTime))
                InsightCard(label: "Avg Session", value: formatDuration(viewModel.avgSessionDuration))
                InsightCard(label: "Avg Msgs/Session", value: viewModel.sessions.isEmpty ? "0" : (Double(viewModel.totalMessages) / Double(viewModel.sessions.count)).formatted(.number.precision(.fractionLength(1))))
            }
        }
    }

    // MARK: - Models

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models")
                .font(.headline)
            if viewModel.modelUsage.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.modelUsage) { model in
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundStyle(.blue)
                            .frame(width: 20)
                        Text(model.model)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(model.sessions) sessions")
                                .font(.caption)
                            Text("\(formatTokens(model.totalTokens)) tokens")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Platforms

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Platforms")
                .font(.headline)
            if viewModel.platformUsage.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    ForEach(viewModel.platformUsage) { platform in
                        VStack(spacing: 6) {
                            Image(systemName: platformIcon(platform.platform))
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            Text(platform.platform)
                                .font(.caption.bold())
                            Text("\(platform.sessions) sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(platform.messages) msgs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .background(.quaternary.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Tools")
                .font(.headline)
            if viewModel.toolUsage.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
            } else {
                let maxCount = viewModel.toolUsage.first?.count ?? 1
                ForEach(viewModel.toolUsage.prefix(15)) { tool in
                    HStack(spacing: 10) {
                        Text(tool.name)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 140, alignment: .trailing)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor(for: tool.name))
                                .frame(width: max(4, geo.size.width * Double(tool.count) / Double(maxCount)))
                        }
                        .frame(height: 16)
                        Text("\(tool.count)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Text((tool.percentage / 100).formatted(.percent.precision(.fractionLength(1))))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .frame(height: 20)
                }
            }
        }
    }

    // MARK: - Activity Patterns

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity Patterns")
                .font(.headline)
            HStack(alignment: .top, spacing: 24) {
                dayOfWeekChart
                hourlyChart
            }
        }
    }

    private var dayOfWeekChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("By Day")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            let dayNames = Calendar.current.shortWeekdaySymbols
            let maxVal = max(1, viewModel.dailyActivity.values.max() ?? 1)
            ForEach(0..<7, id: \.self) { day in
                let count = viewModel.dailyActivity[day] ?? 0
                HStack(spacing: 6) {
                    Text(verbatim: dayNames[(day + 1) % 7])
                        .font(.caption.monospaced())
                        .frame(width: 30, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: max(0, CGFloat(count) / CGFloat(maxVal) * 120), height: 14)
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var hourlyChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("By Hour")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            let maxVal = max(1, viewModel.hourlyActivity.values.max() ?? 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = viewModel.hourlyActivity[hour] ?? 0
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(count > 0 ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.15))
                            .frame(width: 12, height: max(4, CGFloat(count) / CGFloat(maxVal) * 80))
                        if hour % 6 == 0 {
                            Text("\(hour)")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("")
                                .font(.system(size: 8))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Notable Sessions

    private var notableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notable Sessions")
                .font(.headline)
            if viewModel.notableSessions.isEmpty {
                Text("No data")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.notableSessions) { notable in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notable.label)
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text(notable.preview)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(notable.value)
                            .font(.system(.body, design: .monospaced, weight: .semibold))
                        Button {
                            coordinator.selectedSessionId = notable.session.id
                            coordinator.selectedSection = .sessions
                        } label: {
                            Image(systemName: "arrow.right.circle")
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Open session")
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    // MARK: - Helpers

    private func platformIcon(_ platform: String) -> String {
        KnownPlatforms.icon(for: platform)
    }

    private func barColor(for toolName: String) -> Color {
        switch toolName {
        case "terminal", "execute_code": return .orange
        case "read_file", "search_files": return .green
        case "write_file", "patch": return .blue
        case "web_search", "web_extract": return .purple
        case _ where toolName.hasPrefix("browser"): return .indigo
        case "memory": return .pink
        case "vision", "image_gen": return .mint
        default: return Color.accentColor
        }
    }
}

struct InsightCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .monospaced, weight: .semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
