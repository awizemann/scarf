import Foundation

// MARK: - JSON-RPC Transport

// Hand-written `encode(to:)` / `init(from:)` with explicit `nonisolated` so
// Swift 6's default-isolation doesn't synthesize a MainActor-isolated
// conformance — which would prevent these payloads from being encoded or
// decoded inside `ACPClient`'s actor context (the JSON-RPC read/write loop).
// The member list must stay in sync with the stored properties above.

struct ACPRequest: Encodable, Sendable {
    nonisolated let jsonrpc = "2.0"
    nonisolated let id: Int
    nonisolated let method: String
    nonisolated let params: [String: AnyCodable]

    enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        try c.encode(method, forKey: .method)
        try c.encode(params, forKey: .params)
    }
}

struct ACPRawMessage: Decodable, Sendable {
    nonisolated let jsonrpc: String?
    nonisolated let id: Int?
    nonisolated let method: String?
    nonisolated let result: AnyCodable?
    nonisolated let error: ACPError?
    nonisolated let params: AnyCodable?

    nonisolated var isResponse: Bool { id != nil && method == nil }
    nonisolated var isNotification: Bool { method != nil && id == nil }
    nonisolated var isRequest: Bool { method != nil && id != nil }

    enum CodingKeys: String, CodingKey { case jsonrpc, id, method, result, error, params }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try c.decodeIfPresent(String.self, forKey: .jsonrpc)
        self.id      = try c.decodeIfPresent(Int.self, forKey: .id)
        self.method  = try c.decodeIfPresent(String.self, forKey: .method)
        self.result  = try c.decodeIfPresent(AnyCodable.self, forKey: .result)
        self.error   = try c.decodeIfPresent(ACPError.self, forKey: .error)
        self.params  = try c.decodeIfPresent(AnyCodable.self, forKey: .params)
    }
}

struct ACPError: Decodable, Sendable {
    nonisolated let code: Int
    nonisolated let message: String

    enum CodingKeys: String, CodingKey { case code, message }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decode(Int.self, forKey: .code)
        self.message = try c.decode(String.self, forKey: .message)
    }
}

// MARK: - AnyCodable (for dynamic JSON)

struct AnyCodable: Codable, @unchecked Sendable {
    nonisolated let value: Any

    nonisolated init(_ value: Any) { self.value = value }

    // NOT marked `nonisolated`: Swift's default-isolation treats writes to a
    // `let value: Any` stored property as MainActor-isolated even when the
    // property is declared nonisolated (Any can't be strictly Sendable, so
    // the compiler can't prove the write is safe off-main). Leaving the
    // init as default-isolated silences the mutation warnings; the Decodable
    // conformance is still usable from ACPClient's nonisolated read loop
    // because all callers are already @preconcurrency with respect to
    // `AnyCodable` (it's @unchecked Sendable).
    init(from decoder: any Decoder) throws {
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

    func encode(to encoder: any Encoder) throws {
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

    nonisolated var stringValue: String? { value as? String }
    nonisolated var intValue: Int? { value as? Int }
    nonisolated var dictValue: [String: Any]? { value as? [String: Any] }
    nonisolated var arrayValue: [Any]? { value as? [Any] }
}

// MARK: - ACP Events (parsed from session/update notifications)

enum ACPEvent: Sendable {
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

struct ACPToolCallEvent: Sendable {
    let toolCallId: String
    let title: String
    let kind: String
    let status: String
    let content: String
    let rawInput: [String: Any]?

    var functionName: String {
        // title format is "functionName: summary" or just "functionName"
        let parts = title.split(separator: ":", maxSplits: 1)
        return String(parts.first ?? Substring(title)).trimmingCharacters(in: .whitespaces)
    }

    var argumentsSummary: String {
        let parts = title.split(separator: ":", maxSplits: 1)
        if parts.count > 1 {
            return String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    var argumentsJSON: String {
        guard let input = rawInput,
              let data = try? JSONSerialization.data(withJSONObject: input),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

struct ACPToolCallUpdateEvent: Sendable {
    let toolCallId: String
    let kind: String
    let status: String
    let content: String
    let rawOutput: String?
}

struct ACPPermissionRequestEvent: Sendable {
    let toolCallTitle: String
    let toolCallKind: String
    let options: [(optionId: String, name: String)]
}

struct ACPPromptResult: Sendable {
    let stopReason: String
    let inputTokens: Int
    let outputTokens: Int
    let thoughtTokens: Int
    let cachedReadTokens: Int
}

// MARK: - Event Parsing

enum ACPEventParser {
    nonisolated static func parse(notification: ACPRawMessage) -> ACPEvent? {
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

    nonisolated static func parsePermissionRequest(_ message: ACPRawMessage) -> ACPEvent? {
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
