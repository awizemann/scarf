// Gated on `canImport(SQLite3)` because every non-trivial code path calls
// into `HermesDataService`, which itself is only compiled on Apple
// platforms (SQLite3 is not a system module on Linux swift-corelibs).
// iOS + macOS compile this unchanged; Linux CI skips it.
#if canImport(SQLite3)

import Foundation
import Observation

public enum InsightsPeriod: String, CaseIterable, Identifiable {
    case week = "7 Days"
    case month = "30 Days"
    case quarter = "90 Days"
    case all = "All Time"

    public var id: String { rawValue }

    public var displayName: LocalizedStringResource {
        switch self {
        case .week: return "7 Days"
        case .month: return "30 Days"
        case .quarter: return "90 Days"
        case .all: return "All Time"
        }
    }

    public var sinceDate: Date {
        let calendar = Calendar.current
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        case .month: return calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        case .quarter: return calendar.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        case .all: return Date(timeIntervalSince1970: 0)
        }
    }
}

public struct ModelUsage: Identifiable {
    public var id: String { model }
    public let model: String
    public let sessions: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let reasoningTokens: Int
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens }
}

public struct PlatformUsage: Identifiable {
    public var id: String { platform }
    public let platform: String
    public let sessions: Int
    public let messages: Int
    public let tokens: Int
}

public struct ToolUsage: Identifiable {
    public var id: String { name }
    public let name: String
    public let count: Int
    public let percentage: Double
}

public struct NotableSession: Identifiable {
    public var id: String { "\(session.id)-\(label)" }
    public let label: String
    public let value: String
    public let session: HermesSession
    public let preview: String
}

@Observable
public final class InsightsViewModel {
    public let context: ServerContext
    private let dataService: HermesDataService

    public init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
    }


    public var period: InsightsPeriod = .month
    public var isLoading = true

    public var sessions: [HermesSession] = []
    public var sessionPreviews: [String: String] = [:]
    public var userMessageCount = 0
    public var totalMessages = 0
    public var totalToolCalls = 0
    public var totalInputTokens = 0
    public var totalOutputTokens = 0
    public var totalCacheReadTokens = 0
    public var totalCacheWriteTokens = 0
    public var totalReasoningTokens = 0
    public var totalTokens = 0
    public var totalCost: Double = 0
    public var activeTime: TimeInterval = 0
    public var avgSessionDuration: TimeInterval = 0

    public var modelUsage: [ModelUsage] = []
    public var platformUsage: [PlatformUsage] = []
    public var toolUsage: [ToolUsage] = []
    public var hourlyActivity: [Int: Int] = [:]
    public var dailyActivity: [Int: Int] = [:]
    public var notableSessions: [NotableSession] = []

    public func load() async {
        isLoading = true
        // refresh() forces a fresh remote snapshot each load. On local it's
        // a cheap reopen of the live DB.
        let opened = await dataService.refresh()
        guard opened else {
            isLoading = false
            return
        }

        let since = period.sinceDate
        sessions = await dataService.fetchSessionsInPeriod(since: since)
        sessionPreviews = await dataService.fetchSessionPreviews(limit: 500)
        userMessageCount = await dataService.fetchUserMessageCount(since: since)
        let tools = await dataService.fetchToolUsage(since: since)
        hourlyActivity = await dataService.fetchSessionStartHours(since: since)
        dailyActivity = await dataService.fetchSessionDaysOfWeek(since: since)

        await dataService.close()

        computeAggregates()
        computeModelBreakdown()
        computePlatformBreakdown()
        computeToolBreakdown(tools)
        computeNotableSessions()
        isLoading = false
    }

    public func previewFor(_ session: HermesSession) -> String {
        if let title = session.title, !title.isEmpty { return title }
        if let preview = sessionPreviews[session.id], !preview.isEmpty { return preview }
        return session.id
    }

    private func computeAggregates() {
        totalMessages = sessions.reduce(0) { $0 + $1.messageCount }
        totalToolCalls = sessions.reduce(0) { $0 + $1.toolCallCount }
        totalInputTokens = sessions.reduce(0) { $0 + $1.inputTokens }
        totalOutputTokens = sessions.reduce(0) { $0 + $1.outputTokens }
        totalCacheReadTokens = sessions.reduce(0) { $0 + $1.cacheReadTokens }
        totalCacheWriteTokens = sessions.reduce(0) { $0 + $1.cacheWriteTokens }
        totalReasoningTokens = sessions.reduce(0) { $0 + $1.reasoningTokens }
        totalTokens = totalInputTokens + totalOutputTokens + totalCacheReadTokens + totalCacheWriteTokens + totalReasoningTokens
        totalCost = sessions.reduce(0.0) { $0 + ($1.displayCostUSD ?? 0) }

        var total: TimeInterval = 0
        var count = 0
        for session in sessions {
            if let dur = session.duration, dur > 0 {
                total += dur
                count += 1
            }
        }
        activeTime = total
        avgSessionDuration = count > 0 ? total / Double(count) : 0
    }

    private func computeModelBreakdown() {
        var grouped: [String: (sessions: Int, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int)] = [:]
        for s in sessions {
            let model = s.model ?? "unknown"
            var entry = grouped[model, default: (0, 0, 0, 0, 0, 0)]
            entry.sessions += 1
            entry.input += s.inputTokens
            entry.output += s.outputTokens
            entry.cacheRead += s.cacheReadTokens
            entry.cacheWrite += s.cacheWriteTokens
            entry.reasoning += s.reasoningTokens
            grouped[model] = entry
        }
        modelUsage = grouped.map { key, val in
            ModelUsage(model: key, sessions: val.sessions, inputTokens: val.input,
                       outputTokens: val.output, cacheReadTokens: val.cacheRead,
                       cacheWriteTokens: val.cacheWrite, reasoningTokens: val.reasoning)
        }.sorted { $0.totalTokens > $1.totalTokens }
    }

    private func computePlatformBreakdown() {
        var grouped: [String: (sessions: Int, messages: Int, tokens: Int)] = [:]
        for s in sessions {
            var entry = grouped[s.source, default: (0, 0, 0)]
            entry.sessions += 1
            entry.messages += s.messageCount
            entry.tokens += s.inputTokens + s.outputTokens + s.cacheReadTokens + s.cacheWriteTokens + s.reasoningTokens
            grouped[s.source] = entry
        }
        platformUsage = grouped.map { key, val in
            PlatformUsage(platform: key, sessions: val.sessions, messages: val.messages, tokens: val.tokens)
        }.sorted { $0.sessions > $1.sessions }
    }

    private func computeToolBreakdown(_ tools: [(name: String, count: Int)]) {
        let total = tools.reduce(0) { $0 + $1.count }
        toolUsage = tools.map { tool in
            ToolUsage(name: tool.name, count: tool.count,
                      percentage: total > 0 ? Double(tool.count) / Double(total) * 100 : 0)
        }
    }

    private func computeNotableSessions() {
        notableSessions = []

        if let longest = sessions.filter({ $0.duration != nil }).max(by: { ($0.duration ?? 0) < ($1.duration ?? 0) }) {
            notableSessions.append(NotableSession(
                label: "Longest Session",
                value: formatDuration(longest.duration ?? 0),
                session: longest,
                preview: previewFor(longest)
            ))
        }

        if let mostMsgs = sessions.max(by: { $0.messageCount < $1.messageCount }), mostMsgs.messageCount > 0 {
            notableSessions.append(NotableSession(
                label: "Most Messages",
                value: "\(mostMsgs.messageCount) msgs",
                session: mostMsgs,
                preview: previewFor(mostMsgs)
            ))
        }

        if let mostTokens = sessions.max(by: { $0.totalTokens < $1.totalTokens }), mostTokens.totalTokens > 0 {
            notableSessions.append(NotableSession(
                label: "Most Tokens",
                value: formatTokens(mostTokens.totalTokens),
                session: mostTokens,
                preview: previewFor(mostTokens)
            ))
        }

        if let mostTools = sessions.max(by: { $0.toolCallCount < $1.toolCallCount }), mostTools.toolCallCount > 0 {
            notableSessions.append(NotableSession(
                label: "Most Tool Calls",
                value: "\(mostTools.toolCallCount) calls",
                session: mostTools,
                preview: previewFor(mostTools)
            ))
        }
    }
}

public func formatDuration(_ interval: TimeInterval) -> String {
    let hours = Int(interval) / 3600
    let minutes = (Int(interval) % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

public func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    }
    return "\(count)"
}

#endif // canImport(SQLite3)
