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
    /// Whether the host's `sessions` table HAS a `cost_status` column —
    /// Scarf's probed `hasV07Schema` (charter C4), stamped by the decoder
    /// that built this row.
    ///
    /// Load-bearing for the cost rule and nothing else. `costStatus` decodes
    /// to nil both on a host too old to have the column AND on a current
    /// host that never priced the session, and those two mean opposite
    /// things: the first must keep rendering as it always did (C1), the
    /// second must say "unknown" rather than `$0.00`. Only the decoder knows
    /// which it is, so it records that here instead of the surfaces guessing.
    ///
    /// Defaults to `false` — the conservative reading — so every fixture and
    /// hand-built session behaves exactly as it did before this flag existed.
    public let hasCostStatusColumn: Bool
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

    /// Hermes's session-recency expression, computed by the session-LIST
    /// query only (`_sql_session_last_active`,
    /// hermes_state_common.py:169-191): `MAX(last_activity_at,
    /// MAX(messages.timestamp))`, falling back to `started_at`. `nil` on
    /// queries that don't select it (single-session fetch, subagent
    /// fetch) — `isUnread` then falls back to the reduced subset.
    ///
    /// It costs a correlated subquery per row, which is why it rides only
    /// on the list queries whose rows feed the unread badge. Hermes pays
    /// exactly the same per-row cost in `list_sessions_rich`.
    public let lastActive: Date?

    /// Every session id of a rotated compression chain this row stands
    /// for, root first and live tip last. Empty for an ordinary row.
    ///
    /// Hermes lists a rotated chain (`end_reason = 'compression'` on the
    /// root, continuation rows hanging off it) as ONE row carrying the
    /// tip's id and live fields, with the root's `started_at` kept for
    /// ordering (`_project_compression_tips`,
    /// hermes_state_sessions.py:1028-1065 @ v2026.9.24). Scarf does the
    /// same in `HermesDataService`, and keeps the whole chain here so the
    /// transcript can span every segment and a search hit or project
    /// attribution recorded against the root still finds this row.
    public let lineageIds: [String]

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
        hasCostStatusColumn: Bool = false,
        apiCallCount: Int = 0,
        rewindCount: Int = 0,
        pinned: Bool = false,
        lastActivityAt: Date? = nil,
        lastActivityDescription: String? = nil,
        lastReadAt: Date? = nil,
        lastActive: Date? = nil,
        lineageIds: [String] = []
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
        self.hasCostStatusColumn = hasCostStatusColumn
        self.apiCallCount = apiCallCount
        self.rewindCount = rewindCount
        self.pinned = pinned
        self.lastActivityAt = lastActivityAt
        self.lastActivityDescription = lastActivityDescription
        self.lastReadAt = lastReadAt
        self.lastActive = lastActive
        self.lineageIds = lineageIds
    }

    /// The ids this row answers to: the whole compression chain when it
    /// stands for one, otherwise just `id`.
    public var allSessionIds: [String] { lineageIds.isEmpty ? [id] : lineageIds }

    /// True when `sessionId` is this row or any segment of its chain.
    public func covers(_ sessionId: String) -> Bool {
        sessionId == id || lineageIds.contains(sessionId)
    }

    /// `labels` (session id → label: a project name, a preview) with each
    /// compression-chain row also answering under its own `id` when only an
    /// earlier segment of the chain has a label. Attribution is recorded
    /// against the id a chat started with — usually the chain's root — so
    /// without this a chain listed under its tip id loses its project.
    public static func carryingLineageLabels(
        _ labels: [String: String],
        onto sessions: [HermesSession]
    ) -> [String: String] {
        var result = labels
        for session in sessions where result[session.id] == nil {
            if let label = session.lineageIds.lazy.compactMap({ labels[$0] }).first {
                result[session.id] = label
            }
        }
        return result
    }

    /// This root row projected onto the live tip of its compression chain,
    /// mirroring Hermes's `_project_compression_tips`: the tip's id and
    /// live fields (ended_at, end_reason, message and tool counts, title,
    /// model, recency, read watermark) with the root's `started_at`,
    /// source, pin and token/cost counters kept. A tip with no title
    /// inherits the root's, as Hermes does for a rotation cut off before
    /// the title was carried over.
    public func projectedOntoCompressionTip(_ tip: HermesSession, lineage: [String]) -> HermesSession {
        HermesSession(
            id: tip.id,
            source: source,
            userId: userId,
            model: tip.model,
            title: tip.title ?? title,
            parentSessionId: parentSessionId,
            startedAt: startedAt,
            endedAt: tip.endedAt,
            endReason: tip.endReason,
            messageCount: tip.messageCount,
            toolCallCount: tip.toolCallCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            estimatedCostUSD: estimatedCostUSD,
            reasoningTokens: reasoningTokens,
            actualCostUSD: actualCostUSD,
            costStatus: costStatus,
            billingProvider: billingProvider,
            hasCostStatusColumn: hasCostStatusColumn,
            apiCallCount: apiCallCount,
            rewindCount: rewindCount,
            pinned: pinned,
            lastActivityAt: tip.lastActivityAt,
            lastActivityDescription: tip.lastActivityDescription,
            lastReadAt: tip.lastReadAt,
            lastActive: tip.lastActive,
            lineageIds: lineage
        )
    }

    /// This row with the token and cost counters of `others` added — the
    /// continuation rows of a rotating compression, which carry every call
    /// booked after the split. A cost adds only where a row has one; the
    /// rest of the row (id, title, model, times) is this row's.
    public func addingUsage(of others: [HermesSession]) -> HermesSession {
        func sum(_ key: KeyPath<HermesSession, Double?>) -> Double? {
            let values = ([self] + others).compactMap { $0[keyPath: key] }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        func sum(_ key: KeyPath<HermesSession, Int>) -> Int {
            ([self] + others).reduce(0) { $0 + $1[keyPath: key] }
        }
        return HermesSession(
            id: id,
            source: source,
            userId: userId,
            model: model,
            title: title,
            parentSessionId: parentSessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            endReason: endReason,
            messageCount: messageCount,
            toolCallCount: toolCallCount,
            inputTokens: sum(\.inputTokens),
            outputTokens: sum(\.outputTokens),
            cacheReadTokens: sum(\.cacheReadTokens),
            cacheWriteTokens: sum(\.cacheWriteTokens),
            estimatedCostUSD: sum(\.estimatedCostUSD),
            reasoningTokens: sum(\.reasoningTokens),
            actualCostUSD: sum(\.actualCostUSD),
            costStatus: others.last?.costStatus ?? costStatus,
            billingProvider: billingProvider,
            hasCostStatusColumn: hasCostStatusColumn,
            apiCallCount: sum(\.apiCallCount),
            rewindCount: rewindCount,
            pinned: pinned,
            lastActivityAt: lastActivityAt,
            lastActivityDescription: lastActivityDescription,
            lastReadAt: lastReadAt,
            lastActive: lastActive,
            lineageIds: lineageIds
        )
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
    /// Last-activity is Hermes's `_sql_session_last_active`
    /// (hermes_state_common.py:169-191): the freshest of
    /// `last_activity_at` and `MAX(messages.timestamp)`, falling back to
    /// `started_at`. The message max is the DOMINANT term — the durable
    /// heartbeat is rate-limited (~60 s) and best-effort, so
    /// `last_activity_at` routinely lags the messages a turn just wrote.
    /// The session-list query computes the whole expression as
    /// `lastActive`; when it's absent (a query that doesn't select it, or
    /// a pre-v0.20 host) this degrades to the old `lastActivityAt ??
    /// startedAt` subset, which can only under-report unread.
    public var isUnread: Bool {
        guard let lastReadAt else { return false }
        guard let activity = lastActive ?? lastActivityAt ?? startedAt else { return false }
        return activity > lastReadAt
    }

    public var totalTokens: Int { inputTokens + outputTokens + reasoningTokens }

    public var displayCostUSD: Double? { actualCostUSD ?? estimatedCostUSD }

    public var costIsActual: Bool { actualCostUSD != nil }

    /// How this session's cost must be presented — the ONE rule, shared by
    /// every cost surface. Reads `cost_status` so a cost Hermes recorded as
    /// unknown is never rendered as a confident `$0.00`; see
    /// ``SessionCostDisplay`` for the Hermes-side citations.
    ///
    /// Prefer this over `displayCostUSD` at any surface that renders a
    /// figure. `displayCostUSD` remains the raw preference order for callers
    /// that only need a number (sums, sorting).
    public var costDisplay: SessionCostDisplay {
        SessionCostDisplay(
            actualCostUSD: actualCostUSD,
            estimatedCostUSD: estimatedCostUSD,
            costStatus: costStatus,
            hasCostStatusColumn: hasCostStatusColumn
        )
    }

    public var duration: TimeInterval? {
        guard let start = startedAt, let end = endedAt else { return nil }
        return end.timeIntervalSince(start)
    }

    public var displayTitle: String {
        title ?? id
    }

    /// The one name a session is shown under, anywhere in Scarf.
    ///
    /// Precedence: the Hermes-side **title** (what the user or the agent
    /// deliberately named the conversation), then the first-user-message
    /// **preview**, then the id. Chat, Sessions and Insights all spelled
    /// this out separately and agreed; the Dashboard did `preview ??
    /// displayTitle` and so preferred the preview — which meant renaming a
    /// session in Sessions left the Dashboard still calling it by its
    /// opening line. Every surface now calls this instead of re-deriving it.
    ///
    /// An empty title or empty preview counts as absent — Hermes writes
    /// `''`, not NULL, for a cleared title.
    public func displayLabel(preview: String?) -> String {
        if let title, !title.isEmpty { return title }
        if let preview, !preview.isEmpty { return preview }
        return id
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
            billingProvider: billingProvider,
            hasCostStatusColumn: hasCostStatusColumn,
            apiCallCount: apiCallCount,
            rewindCount: rewindCount, pinned: pinned,
            lastActivityAt: lastActivityAt,
            lastActivityDescription: lastActivityDescription,
            lastReadAt: lastReadAt,
            lastActive: lastActive,
            lineageIds: lineageIds
        )
    }
}
