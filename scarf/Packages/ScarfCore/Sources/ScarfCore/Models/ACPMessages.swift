import Foundation

// MARK: - JSON-RPC Transport

// Hand-written `encode(to:)` / `init(from:)` with explicit `nonisolated` so
// Swift 6's default-isolation doesn't synthesize a MainActor-isolated
// conformance — which would prevent these payloads from being encoded or
// decoded inside `ACPClient`'s actor context (the JSON-RPC read/write loop).
// The member list must stay in sync with the stored properties above.

public struct ACPRequest: Encodable, Sendable {
    public nonisolated let jsonrpc = "2.0"
    public nonisolated let id: Int
    public nonisolated let method: String
    public nonisolated let params: [String: AnyCodable]


    public init(
        id: Int,
        method: String,
        params: [String: AnyCodable]
    ) {
        self.id = id
        self.method = method
        self.params = params
    }
    public enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        try c.encode(method, forKey: .method)
        try c.encode(params, forKey: .params)
    }
}

/// An outgoing JSON-RPC NOTIFICATION: no `id` member at all. Not
/// `"id": null` — the acp lib Hermes ships classifies a frame by the id
/// KEY's presence (`has_id = "id" in message`, acp/connection.py:166 in
/// agent-client-protocol 0.9.0; same in 0.8.1), so a null id still routes
/// as a request.
public struct ACPNotification: Encodable, Sendable {
    public nonisolated let jsonrpc = "2.0"
    public nonisolated let method: String
    public nonisolated let params: [String: AnyCodable]

    public init(method: String, params: [String: AnyCodable]) {
        self.method = method
        self.params = params
    }
    public enum CodingKeys: String, CodingKey { case jsonrpc, method, params }

    public nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(method, forKey: .method)
        try c.encode(params, forKey: .params)
    }
}

public struct ACPRawMessage: Decodable, Sendable {
    public nonisolated let jsonrpc: String?
    public nonisolated let id: Int?
    public nonisolated let method: String?
    public nonisolated let result: AnyCodable?
    public nonisolated let error: ACPError?
    public nonisolated let params: AnyCodable?

    public nonisolated var isResponse: Bool { id != nil && method == nil }
    public nonisolated var isNotification: Bool { method != nil && id == nil }
    public nonisolated var isRequest: Bool { method != nil && id != nil }

    public enum CodingKeys: String, CodingKey { case jsonrpc, id, method, result, error, params }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decodeIfPresent(String.self, forKey: .jsonrpc)
        self.id      = try c.decodeIfPresent(Int.self, forKey: .id)
        self.method  = try c.decodeIfPresent(String.self, forKey: .method)
        self.result  = try c.decodeIfPresent(AnyCodable.self, forKey: .result)
        self.error   = try c.decodeIfPresent(ACPError.self, forKey: .error)
        self.params  = try c.decodeIfPresent(AnyCodable.self, forKey: .params)
    }
}

public struct ACPError: Decodable, Sendable {
    public nonisolated let code: Int
    public nonisolated let message: String
    /// The JSON-RPC error's optional `data` member — per spec a
    /// "primitive or structured value that contains additional
    /// information about the error". Hermes's acp lib wraps unexpected
    /// server-side exceptions into `-32603 Internal error` with the
    /// REAL failure text under `data.details` (acp/connection.py:232,
    /// verified against the lib Hermes 0.17/0.18 ships) — without
    /// decoding it, Scarf's banner showed only "Internal error" while
    /// the actionable message (e.g. the context-floor explanation)
    /// rode invisibly in this field.
    public nonisolated let data: AnyCodable?

    public enum CodingKeys: String, CodingKey { case code, message, data }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decode(Int.self, forKey: .code)
        self.message = try c.decode(String.self, forKey: .message)
        self.data = try c.decodeIfPresent(AnyCodable.self, forKey: .data)
    }

    /// Server-side failure text extracted from `data`, when present:
    /// either `data.details` (the shape Hermes's acp lib emits for
    /// wrapped internal errors) or `data` itself when it's a plain
    /// string (the spec allows primitive values). Trimmed; nil when
    /// empty or when `data` is some other structure.
    public nonisolated var details: String? {
        let candidate: String?
        if let dict = data?.dictValue {
            candidate = dict["details"] as? String
        } else {
            candidate = data?.stringValue
        }
        guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }
}

// MARK: - AnyCodable (for dynamic JSON)

public struct AnyCodable: Codable, @unchecked Sendable {
    public nonisolated let value: Any

    public nonisolated init(_ value: Any) { self.value = value }

    // NOT marked `nonisolated`: Swift's default-isolation treats writes to a
    // `let value: Any` stored property as MainActor-isolated even when the
    // property is declared nonisolated (Any can't be strictly Sendable, so
    // the compiler can't prove the write is safe off-main). Leaving the
    // init as default-isolated silences the mutation warnings; the Decodable
    // conformance is still usable from ACPClient's nonisolated read loop
    // because all callers are already @preconcurrency with respect to
    // `AnyCodable` (it's @unchecked Sendable).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    // MARK: - Accessors

    public nonisolated var stringValue: String? { value as? String }
    public nonisolated var intValue: Int? { value as? Int }
    public nonisolated var dictValue: [String: Any]? { value as? [String: Any] }
    public nonisolated var arrayValue: [Any]? { value as? [Any] }
}

// MARK: - ACP Events (parsed from session/update notifications)

/// `@unchecked Sendable` because `.availableCommands` carries `[[String: Any]]`
/// parsed straight from the ACP JSON notification — an immutable value graph
/// (`JSONSerialization` output / string literals), never mutated after the
/// event is constructed. Same rationale + treatment as `AnyCodable` above; we
/// keep the raw `Any` rather than box every consumer in macOS + iOS + tests.
public enum ACPEvent: @unchecked Sendable {
    /// `isCompactionSummary` / `containsCompactionSummary` reflect Hermes
    /// v0.20's `_meta.hermes.compactionSummary` /
    /// `_meta.hermes.containsCompactionSummary` flags, stamped on
    /// `agent_message_chunk` updates during `session/load` /
    /// `session/resume` history replay (see
    /// `_history_summary_meta` in Hermes' `acp_adapter/server.py`).
    /// Both default `false` — absent `_meta`, or `_meta` from an older
    /// host or a live (non-replay) chunk, parses as "not a summary"
    /// with zero behavior change.
    ///
    /// `messageId` is Hermes's per-reply id (`AssistantMessageIdAllocator`,
    /// `acp_adapter/events.py:185-236` @ v2026.9.24): streamed chunks of one
    /// assistant reply share it and the next reply gets a fresh UUID. It is
    /// ABSENT on the out-of-band text Hermes sends for slash commands and
    /// absorbed mid-turn prompts ("Queued for the next turn…", "⏩ Steer
    /// queued…", `server.py:827-843`), and on every chunk from a host that
    /// predates the allocator. `RichChatViewModel` starts a new bubble when
    /// it changes.
    case messageChunk(
        sessionId: String,
        text: String,
        isCompactionSummary: Bool = false,
        containsCompactionSummary: Bool = false,
        messageId: String? = nil
    )
    /// Same compaction-summary semantics as `.messageChunk`, but for
    /// `user_message_chunk` replay updates — the compressor sometimes
    /// persists a standalone handoff summary under `role="user"` to
    /// keep turn alternation valid.
    case userMessageChunk(
        sessionId: String,
        text: String,
        isCompactionSummary: Bool = false,
        containsCompactionSummary: Bool = false
    )
    /// `messageId` shares `.messageChunk`'s allocator: a reply's thoughts
    /// and its text carry the same id.
    case thoughtChunk(sessionId: String, text: String, messageId: String? = nil)
    case toolCallStart(sessionId: String, call: ACPToolCallEvent)
    case toolCallUpdate(sessionId: String, update: ACPToolCallUpdateEvent)
    case permissionRequest(sessionId: String, requestId: Int, request: ACPPermissionRequestEvent)
    case promptComplete(sessionId: String, response: ACPPromptResult)
    case availableCommands(sessionId: String, commands: [[String: Any]])
    case sessionInfoUpdate(sessionId: String, title: String?, updatedAt: String?)
    case connectionLost(reason: String)
    case unknown(sessionId: String, type: String)

    /// Session id the event was emitted against, or `nil` for events
    /// that don't carry one (`.connectionLost`). Used by
    /// `RichChatViewModel.handleACPEvent` to drop straggling events
    /// from a session the VM is no longer attached to.
    public var sessionId: String? {
        switch self {
        case let .messageChunk(sid, _, _, _, _),
             let .userMessageChunk(sid, _, _, _),
             let .thoughtChunk(sid, _, _),
             let .toolCallStart(sid, _),
             let .toolCallUpdate(sid, _),
             let .promptComplete(sid, _),
             let .availableCommands(sid, _),
             let .sessionInfoUpdate(sid, _, _),
             let .unknown(sid, _):
            return sid
        case let .permissionRequest(sid, _, _):
            return sid
        case .connectionLost:
            return nil
        }
    }
}

/// `@unchecked Sendable` because `rawInput` is the tool call's `[String: Any]?`
/// JSON arguments parsed from the ACP notification — an immutable value graph
/// re-serialized verbatim in `argumentsJSON`. Same rationale as `ACPEvent` /
/// `AnyCodable`.
public struct ACPToolCallEvent: @unchecked Sendable {
    public let toolCallId: String
    public let title: String
    public let kind: String
    public let status: String
    public let content: String
    /// Tool arguments. Hermes sends `rawInput` ONLY for unknown/plugin
    /// tools (`acp_adapter/tools.py:797-815` @ v2026.9.24, and every built-in
    /// has had `raw_input=None` since at least v2026.7.7.2); for terminal,
    /// read_file, patch, web_search and the other built-ins the target lives
    /// in `title` and `locations` instead.
    public let rawInput: [String: Any]?
    /// `locations[].path` in wire order (`extract_locations`,
    /// `acp_adapter/tools.py:850-854` — the tool's `path` argument).
    public let locationPaths: [String]

    public init(
        toolCallId: String,
        title: String,
        kind: String,
        status: String,
        content: String,
        rawInput: [String: Any]?,
        locationPaths: [String] = []
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.rawInput = rawInput
        self.locationPaths = locationPaths
    }
    public var functionName: String {
        // title format is "functionName: summary" or just "functionName"
        let parts = title.split(separator: ":", maxSplits: 1)
        return String(parts.first ?? Substring(title)).trimmingCharacters(in: .whitespaces)
    }

    public var argumentsSummary: String {
        let parts = title.split(separator: ":", maxSplits: 1)
        if parts.count > 1 {
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    public var argumentsJSON: String {
        guard let input = rawInput,
              let data = try? JSONSerialization.data(withJSONObject: input),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// A one-line label for a call that arrived without `rawInput`: the
    /// first location path (the tool's full `path` argument — the same
    /// value `HermesToolCall.argumentsSummary` shows once the call is
    /// reloaded from state.db), else the title's preview
    /// (`build_tool_title` → `"<name>: <preview>"`, the per-tool preview
    /// the CLI/TUI render, `acp_adapter/tools.py:193-198` — the command for
    /// `terminal`, the query for `web_search`). The path comes first because
    /// read_file's preview is only the basename. Nil when the start event
    /// carries neither.
    public var livePreview: String? {
        if let path = locationPaths.first(where: { !$0.isEmpty }) { return path }
        let preview = argumentsSummary
        return preview.isEmpty ? nil : preview
    }
}

/// `@unchecked Sendable` for the same reason as `ACPToolCallEvent`:
/// `rawInput` is an immutable `[String: Any]` value graph parsed off the
/// ACP notification and only ever re-serialized verbatim.
public struct ACPToolCallUpdateEvent: @unchecked Sendable {
    public let toolCallId: String
    public let kind: String
    public let status: String
    public let content: String
    public let rawOutput: String?
    /// Tool-call arguments as carried on the `tool_call_update`
    /// notification. No Hermes tag sends this today —
    /// `build_tool_complete` never sets `raw_input`
    /// (`acp_adapter/tools.py:818-835` @ v2026.9.24) — so the live card's
    /// label comes from the start event's title instead
    /// (`ACPToolCallEvent.livePreview`). Kept as a backfill for the
    /// stored call's `"{}"` placeholder should a host ever send it.
    /// Defaulted so existing call sites (and tests) compile unchanged.
    public let rawInput: [String: Any]?

    public init(
        toolCallId: String,
        kind: String,
        status: String,
        content: String,
        rawOutput: String?,
        rawInput: [String: Any]? = nil
    ) {
        self.toolCallId = toolCallId
        self.kind = kind
        self.status = status
        self.content = content
        self.rawOutput = rawOutput
        self.rawInput = rawInput
    }

    /// `rawInput` re-serialized as a JSON string, or nil when the update
    /// carried no arguments (never fabricates a `"{}"` placeholder —
    /// that token is exactly what the backfill exists to replace).
    public var argumentsJSON: String? {
        guard let input = rawInput, !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}

public struct ACPPermissionRequestEvent: Sendable {
    public let toolCallTitle: String
    public let toolCallKind: String
    public let options: [(optionId: String, name: String)]

    public init(
        toolCallTitle: String,
        toolCallKind: String,
        options: [(optionId: String, name: String)]
    ) {
        self.toolCallTitle = toolCallTitle
        self.toolCallKind = toolCallKind
        self.options = options
    }
}

public struct ACPPromptResult: Sendable {
    public let stopReason: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let thoughtTokens: Int
    public let cachedReadTokens: Int
    /// Number of automatic context compactions Hermes has performed on this
    /// session so far. v0.13+ — older Hermes hosts always return 0, which
    /// the chat status bar treats as "hide chip". Optional in the wire
    /// payload; folded into a non-optional `Int` here with a 0 default so
    /// the rest of the pipeline doesn't need to nil-check.
    // TODO(WS-8-Q1): Verify that v0.13 Hermes emits the count on
    // `session/prompt`'s `usage` blob (assumed here). If it lands on a
    // separate `session/update` notification instead, this becomes a new
    // ACPEvent case + a branch in RichChatViewModel.handleACPEvent — wire
    // shape is documented in the WS-8 plan as the bigger fix path.
    public let compressionCount: Int

    public init(
        stopReason: String,
        inputTokens: Int,
        outputTokens: Int,
        thoughtTokens: Int,
        cachedReadTokens: Int,
        compressionCount: Int = 0
    ) {
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cachedReadTokens = cachedReadTokens
        self.compressionCount = compressionCount
    }
}

// MARK: - Event Parsing

public enum ACPEventParser {
    public nonisolated static func parse(notification: ACPRawMessage) -> ACPEvent? {
        guard notification.method == "session/update",
              let params = notification.params?.dictValue,
              let sessionId = params["sessionId"] as? String,
              let update = params["update"] as? [String: Any],
              let updateType = update["sessionUpdate"] as? String else {
            return nil
        }

        switch updateType {
        case "agent_message_chunk":
            let text = extractContentText(from: update)
            let meta = extractCompactionMeta(from: update)
            return .messageChunk(
                sessionId: sessionId,
                text: text,
                isCompactionSummary: meta.isSummary,
                containsCompactionSummary: meta.containsSummary,
                messageId: extractMessageId(from: update)
            )

        case "user_message_chunk":
            let text = extractContentText(from: update)
            let meta = extractCompactionMeta(from: update)
            return .userMessageChunk(
                sessionId: sessionId,
                text: text,
                isCompactionSummary: meta.isSummary,
                containsCompactionSummary: meta.containsSummary
            )

        case "agent_thought_chunk":
            let text = extractContentText(from: update)
            return .thoughtChunk(sessionId: sessionId, text: text, messageId: extractMessageId(from: update))

        case "tool_call":
            let event = ACPToolCallEvent(
                toolCallId: update["toolCallId"] as? String ?? "",
                title: update["title"] as? String ?? "",
                kind: update["kind"] as? String ?? "other",
                status: update["status"] as? String ?? "pending",
                content: extractContentArrayText(from: update),
                rawInput: update["rawInput"] as? [String: Any],
                locationPaths: (update["locations"] as? [[String: Any]] ?? [])
                    .compactMap { $0["path"] as? String }
            )
            return .toolCallStart(sessionId: sessionId, call: event)

        case "tool_call_update":
            let event = ACPToolCallUpdateEvent(
                toolCallId: update["toolCallId"] as? String ?? "",
                kind: update["kind"] as? String ?? "other",
                status: update["status"] as? String ?? "completed",
                content: extractContentArrayText(from: update),
                rawOutput: update["rawOutput"] as? String,
                rawInput: update["rawInput"] as? [String: Any]
            )
            return .toolCallUpdate(sessionId: sessionId, update: event)

        case "available_commands_update":
            let commands = update["availableCommands"] as? [[String: Any]] ?? []
            return .availableCommands(sessionId: sessionId, commands: commands)

        case "session_info_update":
            let title = update["title"] as? String
            let updatedAt = update["updatedAt"] as? String
            return .sessionInfoUpdate(sessionId: sessionId, title: title, updatedAt: updatedAt)

        default:
            return .unknown(sessionId: sessionId, type: updateType)
        }
    }

    public nonisolated static func parsePermissionRequest(_ message: ACPRawMessage) -> ACPEvent? {
        guard message.method == "session/request_permission",
              let params = message.params?.dictValue,
              let sessionId = params["sessionId"] as? String,
              let requestId = message.id else { return nil }

        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let optionsRaw = params["options"] as? [[String: Any]] ?? []
        let options = optionsRaw.compactMap { opt -> (optionId: String, name: String)? in
            guard let id = opt["optionId"] as? String,
                  let name = opt["name"] as? String else { return nil }
            return (optionId: id, name: name)
        }

        let event = ACPPermissionRequestEvent(
            toolCallTitle: toolCall["title"] as? String ?? "",
            toolCallKind: toolCall["kind"] as? String ?? "other",
            options: options
        )
        return .permissionRequest(sessionId: sessionId, requestId: requestId, request: event)
    }

    // MARK: - Content Extraction

    /// `messageId` off a chunk update; nil when absent, not a string, or
    /// empty (an empty id would read as "same reply" for every such chunk).
    nonisolated private static func extractMessageId(from update: [String: Any]) -> String? {
        guard let id = update["messageId"] as? String, !id.isEmpty else { return nil }
        return id
    }

    nonisolated private static func extractContentText(from update: [String: Any]) -> String {
        if let content = update["content"] as? [String: Any],
           let text = content["text"] as? String {
            return text
        }
        return ""
    }

    /// Parse Hermes v0.20's `_meta.hermes.compactionSummary` /
    /// `_meta.hermes.containsCompactionSummary` flags off a message-chunk
    /// update. `_meta` is ACP's reserved extensibility namespace — any
    /// shape (missing, non-dict, extra sibling keys, non-bool flag
    /// values) is tolerated and simply yields `(false, false)` rather
    /// than throwing, since older Hermes hosts and live (non-replay)
    /// chunks never send it at all.
    nonisolated private static func extractCompactionMeta(
        from update: [String: Any]
    ) -> (isSummary: Bool, containsSummary: Bool) {
        guard let meta = update["_meta"] as? [String: Any],
              let hermes = meta["hermes"] as? [String: Any] else {
            return (false, false)
        }
        let isSummary = (hermes["compactionSummary"] as? Bool) ?? false
        let containsSummary = (hermes["containsCompactionSummary"] as? Bool) ?? false
        return (isSummary, containsSummary)
    }

    nonisolated private static func extractContentArrayText(from update: [String: Any]) -> String {
        if let contentArray = update["content"] as? [[String: Any]] {
            return contentArray.compactMap { item -> String? in
                guard let inner = item["content"] as? [String: Any] else { return nil }
                return inner["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }
}
