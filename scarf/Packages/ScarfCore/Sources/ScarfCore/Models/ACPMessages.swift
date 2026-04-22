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

    public enum CodingKeys: String, CodingKey { case code, message }

    public nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decode(Int.self, forKey: .code)
        self.message = try c.decode(String.self, forKey: .message)
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

public enum ACPEvent: Sendable {
    case messageChunk(sessionId: String, text: String)
    case thoughtChunk(sessionId: String, text: String)
    case toolCallStart(sessionId: String, call: ACPToolCallEvent)
    case toolCallUpdate(sessionId: String, update: ACPToolCallUpdateEvent)
    case permissionRequest(sessionId: String, requestId: Int, request: ACPPermissionRequestEvent)
    case promptComplete(sessionId: String, response: ACPPromptResult)
    case availableCommands(sessionId: String, commands: [[String: Any]])
    case connectionLost(reason: String)
    case unknown(sessionId: String, type: String)
}

public struct ACPToolCallEvent: Sendable {
    public let toolCallId: String
    public let title: String
    public let kind: String
    public let status: String
    public let content: String
    public let rawInput: [String: Any]?


    public init(
        toolCallId: String,
        title: String,
        kind: String,
        status: String,
        content: String,
        rawInput: [String: Any]?
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.rawInput = rawInput
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
}

public struct ACPToolCallUpdateEvent: Sendable {
    public let toolCallId: String
    public let kind: String
    public let status: String
    public let content: String
    public let rawOutput: String?

    public init(
        toolCallId: String,
        kind: String,
        status: String,
        content: String,
        rawOutput: String?
    ) {
        self.toolCallId = toolCallId
        self.kind = kind
        self.status = status
        self.content = content
        self.rawOutput = rawOutput
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

    public init(
        stopReason: String,
        inputTokens: Int,
        outputTokens: Int,
        thoughtTokens: Int,
        cachedReadTokens: Int
    ) {
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cachedReadTokens = cachedReadTokens
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
            return .messageChunk(sessionId: sessionId, text: text)

        case "agent_thought_chunk":
            let text = extractContentText(from: update)
            return .thoughtChunk(sessionId: sessionId, text: text)

        case "tool_call":
            let event = ACPToolCallEvent(
                toolCallId: update["toolCallId"] as? String ?? "",
                title: update["title"] as? String ?? "",
                kind: update["kind"] as? String ?? "other",
                status: update["status"] as? String ?? "pending",
                content: extractContentArrayText(from: update),
                rawInput: update["rawInput"] as? [String: Any]
            )
            return .toolCallStart(sessionId: sessionId, call: event)

        case "tool_call_update":
            let event = ACPToolCallUpdateEvent(
                toolCallId: update["toolCallId"] as? String ?? "",
                kind: update["kind"] as? String ?? "other",
                status: update["status"] as? String ?? "completed",
                content: extractContentArrayText(from: update),
                rawOutput: update["rawOutput"] as? String
            )
            return .toolCallUpdate(sessionId: sessionId, update: event)

        case "available_commands_update":
            let commands = update["availableCommands"] as? [[String: Any]] ?? []
            return .availableCommands(sessionId: sessionId, commands: commands)

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

    nonisolated private static func extractContentText(from update: [String: Any]) -> String {
        if let content = update["content"] as? [String: Any],
           let text = content["text"] as? String {
            return text
        }
        return ""
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
