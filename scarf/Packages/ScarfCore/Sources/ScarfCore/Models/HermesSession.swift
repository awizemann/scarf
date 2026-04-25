import Foundation

public struct HermesSession: Identifiable, Sendable {
    public let id: String
    public let source: String
    public let userId: String?
    public let model: String?
    public let title: String?
    public let parentSessionId: String?
    public let startedAt: Date?
    public let endedAt: Date?
    public let endReason: String?
    public let messageCount: Int
    public let toolCallCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let estimatedCostUSD: Double?
    public let reasoningTokens: Int
    public let actualCostUSD: Double?
    public let costStatus: String?
    public let billingProvider: String?
    /// Number of API calls Hermes made for this session (Hermes
    /// v2026.4.23+; populated from `sessions.api_call_count`). Distinct
    /// from `toolCallCount` — every tool round-trip is a tool call,
    /// but each agent reasoning step also costs an API call. `0` on
    /// older Hermes hosts that don't have the column.
    public let apiCallCount: Int


    public init(
        id: String,
        source: String,
        userId: String?,
        model: String?,
        title: String?,
        parentSessionId: String?,
        startedAt: Date?,
        endedAt: Date?,
        endReason: String?,
        messageCount: Int,
        toolCallCount: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        estimatedCostUSD: Double?,
        reasoningTokens: Int,
        actualCostUSD: Double?,
        costStatus: String?,
        billingProvider: String?,
        apiCallCount: Int = 0
    ) {
        self.id = id
        self.source = source
        self.userId = userId
        self.model = model
        self.title = title
        self.parentSessionId = parentSessionId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.reasoningTokens = reasoningTokens
        self.actualCostUSD = actualCostUSD
        self.costStatus = costStatus
        self.billingProvider = billingProvider
        self.apiCallCount = apiCallCount
    }
    public var isSubagent: Bool { parentSessionId != nil }

    public var totalTokens: Int { inputTokens + outputTokens + reasoningTokens }

    public var displayCostUSD: Double? { actualCostUSD ?? estimatedCostUSD }

    public var costIsActual: Bool { actualCostUSD != nil }

    public var duration: TimeInterval? {
        guard let start = startedAt, let end = endedAt else { return nil }
        return end.timeIntervalSince(start)
    }

    public var displayTitle: String {
        title ?? id
    }

    public var sourceIcon: String {
        KnownPlatforms.icon(for: source)
    }

    public func withTitle(_ newTitle: String) -> HermesSession {
        HermesSession(
            id: id, source: source, userId: userId, model: model,
            title: newTitle, parentSessionId: parentSessionId,
            startedAt: startedAt, endedAt: endedAt, endReason: endReason,
            messageCount: messageCount, toolCallCount: toolCallCount,
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens,
            estimatedCostUSD: estimatedCostUSD, reasoningTokens: reasoningTokens,
            actualCostUSD: actualCostUSD, costStatus: costStatus,
            billingProvider: billingProvider
        )
    }
}
