import SwiftUI
import ScarfCore
import ScarfDesign

/// Insights — usage charts and breakdowns. Visual layer follows
/// `design/static-site/ui-kit/Insights.jsx`: page header (title +
/// subtitle + period picker + Export action), stat-card row, model /
/// tool / activity breakdown cards. The current Scarf data surface is
/// richer than the mockup (we report cache + reasoning tokens, active
/// time, day-of-week / hour-of-day breakdowns); we keep all of it and
/// only adopt the visual chrome.
struct InsightsView: View {
    @State private var viewModel: InsightsViewModel
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(HermesFileWatcher.self) private var fileWatcher

    init(context: ServerContext) {
        _viewModel = State(initialValue: InsightsViewModel(context: context))
    }

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s5) {
                    overviewSection
                    modelSection
                    platformSection
                    toolsSection
                    activitySection
                    notableSection
                }
                .padding(.horizontal, ScarfSpace.s6)
                .padding(.vertical, ScarfSpace.s5)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(ScarfColor.backgroundPrimary)
        .navigationTitle("Insights")
        .loadingOverlay(
            viewModel.isLoading,
            label: "Loading insights…",
            isEmpty: viewModel.sessions.isEmpty
        )
        .task { await viewModel.load() }
        .onChange(of: viewModel.period) {
            Task { await viewModel.load() }
        }
        .onChange(of: fileWatcher.lastChangeDate) {
            Task { await viewModel.load() }
        }
    }

    // MARK: - Page header

    private var pageHeader: some View {
        HStack(alignment: .top, spacing: ScarfSpace.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Insights")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Text("Patterns across sessions, models, and tools.")
                    .scarfStyle(.footnote)
                    .foregroundStyle(ScarfColor.foregroundMuted)
            }
            Spacer()
            Picker("Period", selection: $viewModel.period) {
                ForEach(InsightsPeriod.allCases) { period in
                    Text(period.displayName).tag(period)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
        }
        .padding(.horizontal, ScarfSpace.s6)
        .padding(.top, ScarfSpace.s5)
        .padding(.bottom, ScarfSpace.s4)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Overview

    private var overviewSection: some View {
        sectionHeader("Overview", spacing: ScarfSpace.s3) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ScarfSpace.s3), count: 4), spacing: ScarfSpace.s3) {
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
                InsightCard(
                    label: "Total Cost",
                    value: viewModel.totalCost.formatted(.currency(code: "USD").precision(.fractionLength(2))),
                    accent: true
                )
                InsightCard(label: "Active Time", value: formatDuration(viewModel.activeTime))
                InsightCard(label: "Avg Session", value: formatDuration(viewModel.avgSessionDuration))
                InsightCard(
                    label: "Avg Msgs/Session",
                    value: viewModel.sessions.isEmpty
                        ? "0"
                        : (Double(viewModel.totalMessages) / Double(viewModel.sessions.count))
                            .formatted(.number.precision(.fractionLength(1)))
                )
            }
        }
    }

    // MARK: - Models

    private var modelSection: some View {
        sectionHeader("By Model") {
            cardWrapper {
                if viewModel.modelUsage.isEmpty {
                    emptyRow("No model data yet")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.modelUsage.enumerated()), id: \.element.id) { idx, model in
                            HStack(spacing: ScarfSpace.s2) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ScarfColor.accent)
                                    .frame(width: 18)
                                Text(model.model)
                                    .font(ScarfFont.monoSmall)
                                    .foregroundStyle(ScarfColor.foregroundPrimary)
                                Spacer()
                                Text("\(model.sessions) sessions")
                                    .scarfStyle(.caption)
                                    .foregroundStyle(ScarfColor.foregroundMuted)
                                Text("·")
                                    .foregroundStyle(ScarfColor.foregroundFaint)
                                Text("\(formatTokens(model.totalTokens)) tokens")
                                    .font(ScarfFont.monoSmall)
                                    .foregroundStyle(ScarfColor.foregroundMuted)
                            }
                            .padding(.horizontal, ScarfSpace.s3)
                            .padding(.vertical, 10)
                            if idx < viewModel.modelUsage.count - 1 {
                                Rectangle().fill(ScarfColor.border).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Platforms

    private var platformSection: some View {
        sectionHeader("By Platform") {
            if viewModel.platformUsage.isEmpty {
                cardWrapper { emptyRow("No platform data yet") }
            } else {
                HStack(spacing: ScarfSpace.s3) {
                    ForEach(viewModel.platformUsage) { platform in
                        VStack(spacing: 6) {
                            Image(systemName: platformIcon(platform.platform))
                                .font(.system(size: 18))
                                .foregroundStyle(ScarfColor.accent)
                            Text(platform.platform)
                                .scarfStyle(.captionStrong)
                                .foregroundStyle(ScarfColor.foregroundPrimary)
                            Text("\(platform.sessions) sessions")
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                            Text("\(platform.messages) msgs")
                                .scarfStyle(.caption)
                                .foregroundStyle(ScarfColor.foregroundMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(ScarfSpace.s3)
                        .background(
                            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                                .fill(ScarfColor.backgroundSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                                .strokeBorder(ScarfColor.border, lineWidth: 1)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        sectionHeader("Top Tools") {
            cardWrapper {
                if viewModel.toolUsage.isEmpty {
                    emptyRow("No tool calls yet")
                } else {
                    let maxCount = viewModel.toolUsage.first?.count ?? 1
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.toolUsage.prefix(15).enumerated()), id: \.element.id) { idx, tool in
                            toolBarRow(tool, maxCount: maxCount)
                            if idx < min(viewModel.toolUsage.count, 15) - 1 {
                                Rectangle().fill(ScarfColor.border).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toolBarRow(_ tool: ToolUsage, maxCount: Int) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Text(tool.name)
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundPrimary)
                .frame(width: 140, alignment: .trailing)
                .lineLimit(1)
                .truncationMode(.middle)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ScarfColor.backgroundTertiary)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(for: tool.name))
                        .frame(width: max(4, geo.size.width * Double(tool.count) / Double(maxCount)), height: 6)
                }
            }
            .frame(height: 6)
            Text("\(tool.count)")
                .font(ScarfFont.monoSmall)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 50, alignment: .trailing)
            Text((tool.percentage / 100).formatted(.percent.precision(.fractionLength(1))))
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 8)
    }

    // MARK: - Activity Patterns

    private var activitySection: some View {
        sectionHeader("Activity Patterns") {
            HStack(alignment: .top, spacing: ScarfSpace.s5) {
                cardWrapper { dayOfWeekChart.padding(ScarfSpace.s3) }
                cardWrapper { hourlyChart.padding(ScarfSpace.s3) }
            }
        }
    }

    private var dayOfWeekChart: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Text("By Day")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            let dayNames = Calendar.current.shortWeekdaySymbols
            let maxVal = max(1, viewModel.dailyActivity.values.max() ?? 1)
            ForEach(0..<7, id: \.self) { day in
                let count = viewModel.dailyActivity[day] ?? 0
                HStack(spacing: 6) {
                    Text(verbatim: dayNames[(day + 1) % 7])
                        .font(ScarfFont.monoSmall)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .frame(width: 30, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ScarfColor.accent.opacity(0.85))
                        .frame(width: max(0, CGFloat(count) / CGFloat(maxVal) * 120), height: 14)
                    if count > 0 {
                        Text("\(count)")
                            .font(ScarfFont.caption2)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                    }
                    Spacer(minLength: 0)
                }
                // The bar's LENGTH is the only rendering of the value (and
                // the numeral is omitted entirely at zero), so the row is
                // collapsed into one element that speaks day and count.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: dayNames[(day + 1) % 7]))
                .accessibilityValue(Text("^[\(count) session](inflect: true)"))
            }
        }
        // `.contain` keeps each bar reachable while giving the group a name;
        // a bare `.accessibilityLabel` here would overwrite every child's.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sessions by day of week"))
    }

    private var hourlyChart: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s2) {
            Text("By Hour")
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            let maxVal = max(1, viewModel.hourlyActivity.values.max() ?? 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = viewModel.hourlyActivity[hour] ?? 0
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(count > 0 ? ScarfColor.accent.opacity(0.85) : ScarfColor.backgroundTertiary)
                            .frame(width: 12, height: max(4, CGFloat(count) / CGFloat(maxVal) * 80))
                        if hour % 6 == 0 {
                            Text("\(hour)")
                                .font(.system(size: 8))
                                .foregroundStyle(ScarfColor.foregroundFaint)
                        } else {
                            Text(" ").font(.system(size: 8))
                        }
                    }
                    // Bar height is the only value rendering, and only every
                    // sixth hour is even labelled on screen.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("\(hour):00"))
                    .accessibilityValue(Text("^[\(count) session](inflect: true)"))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sessions by hour of day"))
    }

    // MARK: - Notable Sessions

    private var notableSection: some View {
        sectionHeader("Notable Sessions") {
            cardWrapper {
                if viewModel.notableSessions.isEmpty {
                    emptyRow("No notable sessions yet")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.notableSessions.enumerated()), id: \.element.id) { idx, notable in
                            HStack(spacing: ScarfSpace.s3) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(notable.label)
                                        .scarfStyle(.captionUppercase)
                                        .foregroundStyle(ScarfColor.foregroundMuted)
                                    Text(notable.preview)
                                        .scarfStyle(.body)
                                        .foregroundStyle(ScarfColor.foregroundPrimary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(notable.value)
                                    .font(ScarfFont.body.monospacedDigit())
                                    .foregroundStyle(ScarfColor.foregroundPrimary)
                                Button {
                                    coordinator.selectedSessionId = notable.session.id
                                    coordinator.selectedSection = .sessions
                                } label: {
                                    Image(systemName: "arrow.right.circle")
                                        .font(.system(size: 16))
                                        .foregroundStyle(ScarfColor.accent)
                                }
                                .buttonStyle(.plain)
                                .help("Open session")
                                // Every row's glyph is identical, so the
                                // bare "Open session" would be ambiguous to
                                // Voice Control and VoiceOver alike.
                                .accessibilityLabel(Text("Open session \(notable.preview)"))
                            }
                            .padding(.horizontal, ScarfSpace.s3)
                            .padding(.vertical, 10)
                            if idx < viewModel.notableSessions.count - 1 {
                                Rectangle().fill(ScarfColor.border).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section primitives

    @ViewBuilder
    private func sectionHeader<Content: View>(
        _ title: LocalizedStringKey,
        spacing: CGFloat = ScarfSpace.s2,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title)
                .scarfStyle(.bodyEmph)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            content()
        }
    }

    @ViewBuilder
    private func cardWrapper<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                    .fill(ScarfColor.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                    .strokeBorder(ScarfColor.border, lineWidth: 1)
            )
    }

    private func emptyRow(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .scarfStyle(.body)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .frame(maxWidth: .infinity)
            .padding(ScarfSpace.s5)
    }

    // MARK: - Helpers

    private func platformIcon(_ platform: String) -> String {
        KnownPlatforms.icon(for: platform)
    }

    private func barColor(for toolName: String) -> Color {
        switch toolName {
        case "terminal", "execute_code": return ScarfColor.warning
        case "read_file", "search_files": return ScarfColor.success
        case "write_file", "patch": return ScarfColor.info
        case "web_search", "web_extract": return ScarfColor.Tool.web
        case _ where toolName.hasPrefix("browser"): return ScarfColor.Tool.search
        case "memory": return ScarfColor.Tool.think
        default: return ScarfColor.accent
        }
    }
}

struct InsightCard: View {
    let label: LocalizedStringKey
    let value: String
    let accent: Bool

    init(label: LocalizedStringKey, value: String, accent: Bool = false) {
        self.label = label
        self.value = value
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
            Text(verbatim: value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent ? ScarfColor.accent : ScarfColor.foregroundPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ScarfSpace.s3)
        .background(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .fill(ScarfColor.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ScarfRadius.lg, style: .continuous)
                .strokeBorder(ScarfColor.border, lineWidth: 1)
        )
    }
}
