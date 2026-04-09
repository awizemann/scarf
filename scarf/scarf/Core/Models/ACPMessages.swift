import Foundation

// MARK: - JSON-RPC Transport

struct ACPRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [String: AnyCodable]
}

struct ACPRawMessage: Decodable {
    let jsonrpc: String?
    let id: Int?
    let method: String?
    let result: AnyCodable?
    let error: ACPError?
    let params: AnyCodable?

    var isResponse: Bool { id != nil && method == nil }
    var isNotification: Bool { method != nil && id == nil }
    var isRequest: Bool { method != nil && id != nil }
}

struct ACPError: Decodable, Sendable {
    let code: Int
    let message: String
}

// MARK: - AnyCodable (for dynamic JSON)

struct AnyCodable: Codable, Sendable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }
    var dictValue: [String: Any]? { value as? [String: Any] }
    var arrayValue: [Any]? { value as? [Any] }
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
    static func parse(notification: ACPRawMessage) -> ACPEvent? {
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

    static func parsePermissionRequest(_ message: ACPRawMessage) -> ACPEvent? {
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

    private static func extractContentText(from update: [String: Any]) -> String {
        if let content = update["content"] as? [String: Any],
           let text = content["text"] as? String {
            return text
        }
        return ""
    }

    private static func extractContentArrayText(from update: [String: Any]) -> String {
        if let contentArray = update["content"] as? [[String: Any]] {
            return contentArray.compactMap { item -> String? in
                guard let inner = item["content"] as? [String: Any] else { return nil }
                return inner["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }
}
