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
        reasoningContent: String? = nil
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
    }
    public var isUser: Bool { role == "user" }
    public var isAssistant: Bool { role == "assistant" }
    public var isToolResult: Bool { role == "tool" }
    /// True when ANY reasoning channel has content. UI uses this to
    /// decide whether to render the "Thinking…" disclosure.
    public var hasReasoning: Bool {
        let r = reasoning ?? ""
        let rc = reasoningContent ?? ""
        return !r.isEmpty || !rc.isEmpty
    }
    /// Preferred reasoning text for rendering — `reasoningContent`
    /// (newer, richer) wins over the legacy `reasoning` blob when
    /// both are present.
    public var preferredReasoning: String? {
        if let rc = reasoningContent, !rc.isEmpty { return rc }
        return reasoning
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
