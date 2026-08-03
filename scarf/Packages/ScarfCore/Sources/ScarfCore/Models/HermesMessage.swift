import Foundation

public struct HermesMessage: Identifiable, Sendable {
    public let id: Int
    public let sessionId: String
    public let role: String
    public let content: String
    public let toolCallId: String?
    public let toolCalls: [HermesToolCall]
    public let toolName: String?
    public let timestamp: Date?
    public let tokenCount: Int?
    public let finishReason: String?
    public let reasoning: String?
    /// Hermes v2026.4.23+ richer reasoning column. Some providers
    /// emit a structured "thinking" payload separate from the
    /// classic `reasoning` blob; both can be present on the same
    /// message during the v0.10 → v0.11 transition. UI prefers
    /// `reasoningContent` when set, falls back to `reasoning`.
    public let reasoningContent: String?
    /// True when this message has v0.11 `reasoning_content` on disk that the
    /// lightweight / skeleton fetch deliberately did NOT load (the blob can be
    /// 20+ KB per message). Lets the REASONING disclosure render on resume for
    /// thinking-model messages that populate ONLY `reasoning_content` — Hermes
    /// v0.16 leaves the legacy `reasoning` column NULL for them, so without
    /// this flag `hasReasoning` is false and the disclosure (plus t-aud21's
    /// on-open lazy fetch) never appears. Derived from a cheap boolean column
    /// (`reasoning_content IS NOT NULL …`), never the blob itself. (t-aud27)
    public let reasoningContentAvailable: Bool

    /// Hermes v0.20 `_meta.hermes.compactionSummary` — the ENTIRE message
    /// is a replayed compaction handoff summary, not real conversation
    /// content. Set only on `session/load`/`session/resume` replay
    /// chunks; always `false` for live turns and older Hermes hosts. UI
    /// collapses these behind a disclosure row by default.
    public let isCompactionSummary: Bool
    /// Hermes v0.20 `_meta.hermes.containsCompactionSummary` — a
    /// merged-tail replay message: real preserved content followed by a
    /// compaction summary. UI keeps the message fully visible (never
    /// collapsed — that would hide the preserved content) and shows only
    /// a subtle badge.
    public let containsCompactionSummary: Bool


    public init(
        id: Int,
        sessionId: String,
        role: String,
        content: String,
        toolCallId: String?,
        toolCalls: [HermesToolCall],
        toolName: String?,
        timestamp: Date?,
        tokenCount: Int?,
        finishReason: String?,
        reasoning: String?,
        reasoningContent: String? = nil,
        reasoningContentAvailable: Bool = false,
        isCompactionSummary: Bool = false,
        containsCompactionSummary: Bool = false
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
        self.toolName = toolName
        self.timestamp = timestamp
        self.tokenCount = tokenCount
        self.finishReason = finishReason
        self.reasoning = reasoning
        self.reasoningContent = reasoningContent
        self.reasoningContentAvailable = reasoningContentAvailable
        self.isCompactionSummary = isCompactionSummary
        self.containsCompactionSummary = containsCompactionSummary
    }
    public var isUser: Bool { role == "user" }
    public var isAssistant: Bool { role == "assistant" }
    public var isToolResult: Bool { role == "tool" }
    /// True when ANY reasoning channel has content. UI uses this to
    /// decide whether to render the "Thinking…" disclosure.
    public var hasReasoning: Bool {
        let r = reasoning ?? ""
        let rc = reasoningContent ?? ""
        // `reasoningContentAvailable` covers the light/skeleton fetch: the
        // blob isn't loaded (so `rc` is empty) but it exists on disk, and on
        // v0.16 thinking models the legacy `reasoning` column is NULL too — so
        // without this the disclosure would never show on resume (t-aud27).
        return !r.isEmpty || !rc.isEmpty || reasoningContentAvailable
    }
    /// Preferred reasoning text for rendering — `reasoningContent`
    /// (newer, richer) wins over the legacy `reasoning` blob when
    /// both are present.
    public var preferredReasoning: String? {
        if let rc = reasoningContent, !rc.isEmpty { return rc }
        return reasoning
    }

    /// Stable chronological order across mixed local+DB message arrays.
    ///
    /// Sort by `timestamp` ascending; on ties, by `id` ascending. The
    /// id tie-break is what stops the "user prompt jumps below the
    /// agent reply" bug — `Date()` collisions are rare but real for
    /// fast turns (slash commands, cached responses), and Swift's
    /// `sort` is unstable for arrays past the small-array threshold.
    ///
    /// The id tie-break also yields the right user-before-assistant
    /// ordering on ties because:
    ///  - User local optimistic msg → negative id (`nextLocalId -= 1`).
    ///  - Streaming assistant → `id == 0`.
    ///  - Persisted DB rows → positive monotonic SQLite ROWIDs (the
    ///    user msg is always inserted before its assistant within a
    ///    turn, so the user always has the lower id).
    ///
    /// Ascending: negatives → 0 → positives. Within the same turn this
    /// places (local user) → (streaming assistant) → (persisted) in
    /// the correct visual order even when timestamps tie.
    public static func chronologicalOrder(_ a: HermesMessage, _ b: HermesMessage) -> Bool {
        let lt = a.timestamp ?? .distantPast
        let rt = b.timestamp ?? .distantPast
        if lt != rt { return lt < rt }
        return a.id < b.id
    }

    /// Return a copy of this message with `toolCalls` replaced. Used
    /// by the v2.8 two-phase chat loader: skeleton fetch returns
    /// messages with empty `toolCalls`; the background hydrate splices
    /// the parsed values in without re-fetching the conversational
    /// columns.
    public func withToolCalls(_ newCalls: [HermesToolCall]) -> HermesMessage {
        HermesMessage(
            id: id,
            sessionId: sessionId,
            role: role,
            content: content,
            toolCallId: toolCallId,
            toolCalls: newCalls,
            toolName: toolName,
            timestamp: timestamp,
            tokenCount: tokenCount,
            finishReason: finishReason,
            reasoning: reasoning,
            reasoningContent: reasoningContent,
            reasoningContentAvailable: reasoningContentAvailable,
            isCompactionSummary: isCompactionSummary,
            containsCompactionSummary: containsCompactionSummary
        )
    }
}

public struct HermesToolCall: Identifiable, Sendable, Codable {
    public var id: String { callId }
    public let callId: String
    public let functionName: String
    public let arguments: String

    /// Wall-clock duration of the tool call. Set on ACP `toolCallComplete`
    /// (or equivalent) by `RichChatViewModel`. Nil for sessions loaded
    /// from `state.db` (no live timing) and for in-flight calls.
    public var duration: TimeInterval?

    /// Process exit code, when the tool kind is `.execute` and the
    /// tool-result message exposes one. Best-effort parse of the result
    /// content; nil when not applicable / not parseable.
    public var exitCode: Int?

    /// Wall-clock timestamp the call was emitted by Hermes. Set on ACP
    /// `toolCallStart`. Nil for sessions loaded from `state.db`.
    public var startedAt: Date?

    public enum CodingKeys: String, CodingKey {
        case callId = "id"
        case type
        case function
    }

    public enum FunctionKeys: String, CodingKey {
        case name
        case arguments
    }

    public init(
        callId: String,
        functionName: String,
        arguments: String,
        duration: TimeInterval? = nil,
        exitCode: Int? = nil,
        startedAt: Date? = nil
    ) {
        self.callId = callId
        self.functionName = functionName
        self.arguments = arguments
        self.duration = duration
        self.exitCode = exitCode
        self.startedAt = startedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callId = try container.decode(String.self, forKey: .callId)
        let funcContainer = try container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        functionName = try funcContainer.decode(String.self, forKey: .name)
        arguments = try funcContainer.decode(String.self, forKey: .arguments)
        // Telemetry fields are populated locally from ACP events, never
        // persisted via Codable, so they decode as nil.
        duration = nil
        exitCode = nil
        startedAt = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callId, forKey: .callId)
        try container.encode("function", forKey: .type)
        var funcContainer = container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        try funcContainer.encode(functionName, forKey: .name)
        try funcContainer.encode(arguments, forKey: .arguments)
    }

    public var toolKind: ToolKind {
        switch functionName {
        case "read_file", "search_files", "vision_analyze": return .read
        case "write_file", "patch": return .edit
        case "terminal", "execute_code": return .execute
        case "web_search", "web_extract": return .fetch
        case "browser_navigate", "browser_click", "browser_screenshot": return .browser
        default: return .other
        }
    }

    public var argumentsSummary: String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return arguments
        }
        if let command = json["command"] as? String {
            return command
        }
        if let path = json["path"] as? String {
            return path
        }
        if let query = json["query"] as? String {
            return query
        }
        if let url = json["url"] as? String {
            return url
        }
        return arguments.prefix(120) + (arguments.count > 120 ? "..." : "")
    }
}

public enum ToolKind: String, Sendable, CaseIterable {
    case read
    case edit
    case execute
    case fetch
    case browser
    case other

    #if canImport(Darwin)
    public var displayName: LocalizedStringResource {
        switch self {
        case .read: return "Read"
        case .edit: return "Edit"
        case .execute: return "Execute"
        case .fetch: return "Fetch"
        case .browser: return "Browser"
        case .other: return "Other"
        }
    }
    #endif

    public var icon: String {
        switch self {
        case .read: return "doc.text.magnifyingglass"
        case .edit: return "pencil"
        case .execute: return "terminal"
        case .fetch: return "globe"
        case .browser: return "safari"
        case .other: return "gearshape"
        }
    }

    public var color: String {
        switch self {
        case .read: return "green"
        case .edit: return "blue"
        case .execute: return "orange"
        case .fetch: return "purple"
        case .browser: return "indigo"
        case .other: return "gray"
        }
    }
}

/// Outcome of a `fetchMessagesOutcome` call. `transportError` is non-nil
/// only when the underlying SSH/SQLite call hit a transport-layer
/// failure (timeout, ControlMaster drop) — distinguishes a genuine
/// empty session from a silent partial-load. The chat resume path uses
/// it to surface a "couldn't load full history" banner.
public struct MessageFetchOutcome: Sendable {
    public let messages: [HermesMessage]
    public let transportError: String?

    public init(messages: [HermesMessage], transportError: String?) {
        self.messages = messages
        self.transportError = transportError
    }

    /// True when the fetch tripped a transport failure. Distinct from
    /// `messages.isEmpty` — an empty session is a successful zero-row
    /// result, while a transport error is "we don't know what's there."
    public var didTimeOut: Bool { transportError != nil }
}
