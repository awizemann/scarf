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
    /// Number of times this session was rewound (Hermes v0.16+; populated
    /// from `sessions.rewind_count`). `0` on older Hermes hosts that don't
    /// have the column.
    public let rewindCount: Int
    /// Whether the user pinned this session (Hermes v0.20+; populated
    /// from `sessions.pinned`). `false` on older hosts that don't have
    /// the column. Pinned sessions sort first in the chat sidebar.
    public let pinned: Bool
    /// Timestamp of the most recent agent activity heartbeat (Hermes
    /// v0.20+; `sessions.last_activity_at`). `nil` on older hosts.
    public let lastActivityAt: Date?
    /// Short human-readable description of the most recent agent
    /// activity (Hermes v0.20+; `sessions.last_activity_description`).
    /// `nil` on older hosts or when Hermes hasn't recorded one.
    public let lastActivityDescription: String?
    /// Read watermark for this conversation (Hermes v0.20.4+;
    /// `sessions.last_read_at`). `nil` on older hosts AND on rows
    /// Hermes never stamped — both mean "never tracked", which
    /// `isUnread` treats as read so shipping the column doesn't badge
    /// a user's entire history at once. `0` is Hermes's explicit
    /// "mark unread" value.
    ///
    /// READ ONLY: Scarf opens state.db read-only and never writes this
    /// — Hermes owns the watermark (`set_session_read`).
    public let lastReadAt: Date?


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
        apiCallCount: Int = 0,
        rewindCount: Int = 0,
        pinned: Bool = false,
        lastActivityAt: Date? = nil,
        lastActivityDescription: String? = nil,
        lastReadAt: Date? = nil
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
        self.rewindCount = rewindCount
        self.pinned = pinned
        self.lastActivityAt = lastActivityAt
        self.lastActivityDescription = lastActivityDescription
        self.lastReadAt = lastReadAt
    }
    public var isSubagent: Bool { parentSessionId != nil }

    /// Whether this conversation has activity the user hasn't seen.
    ///
    /// Mirrors Hermes's `HermesState.session_unread`
    /// (hermes_state.py:8455-8466): a NULL watermark means "never
    /// tracked" and reads as READ; otherwise the conversation is
    /// unread when its last activity postdates the watermark. Hermes's
    /// explicit "mark unread" writes `0`, which any activity postdates.
    ///
    /// Hermes computes last-activity as the freshest of
    /// `last_activity_at` and `MAX(messages.timestamp)`, falling back
    /// to `started_at`. Scarf's session list doesn't carry the message
    /// max (it would cost a correlated subquery per row on every
    /// sidebar load, remote included), so this uses the conservative
    /// subset — `lastActivityAt ?? startedAt`. Conservative in the
    /// right direction: it can only ever under-report unread, never
    /// badge a conversation the user has actually read.
    public var isUnread: Bool {
        guard let lastReadAt else { return false }
        guard let activity = lastActivityAt ?? startedAt else { return false }
        return activity > lastReadAt
    }

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
            billingProvider: billingProvider, apiCallCount: apiCallCount,
            rewindCount: rewindCount, pinned: pinned,
            lastActivityAt: lastActivityAt,
            lastActivityDescription: lastActivityDescription,
            lastReadAt: lastReadAt
        )
    }
}
