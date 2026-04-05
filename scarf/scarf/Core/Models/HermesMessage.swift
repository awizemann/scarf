import Foundation

struct HermesMessage: Identifiable, Sendable {
    let id: Int
    let sessionId: String
    let role: String
    let content: String
    let toolCallId: String?
    let toolCalls: [HermesToolCall]
    let toolName: String?
    let timestamp: Date?
    let tokenCount: Int?
    let finishReason: String?
    let reasoning: String?

    var isUser: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }
    var isToolResult: Bool { role == "tool" }
    var hasReasoning: Bool { reasoning != nil && !(reasoning?.isEmpty ?? true) }
}

struct HermesToolCall: Identifiable, Sendable, Codable {
    var id: String { callId }
    let callId: String
    let functionName: String
    let arguments: String

    enum CodingKeys: String, CodingKey {
        case callId = "id"
        case type
        case function
    }

    enum FunctionKeys: String, CodingKey {
        case name
        case arguments
    }

    init(callId: String, functionName: String, arguments: String) {
        self.callId = callId
        self.functionName = functionName
        self.arguments = arguments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callId = try container.decode(String.self, forKey: .callId)
        let funcContainer = try container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        functionName = try funcContainer.decode(String.self, forKey: .name)
        arguments = try funcContainer.decode(String.self, forKey: .arguments)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(callId, forKey: .callId)
        try container.encode("function", forKey: .type)
        var funcContainer = container.nestedContainer(keyedBy: FunctionKeys.self, forKey: .function)
        try funcContainer.encode(functionName, forKey: .name)
        try funcContainer.encode(arguments, forKey: .arguments)
    }

    var toolKind: ToolKind {
        switch functionName {
        case "read_file", "search_files", "vision_analyze": return .read
        case "write_file", "patch": return .edit
        case "terminal", "execute_code": return .execute
        case "web_search", "web_extract": return .fetch
        case "browser_navigate", "browser_click", "browser_screenshot": return .browser
        default: return .other
        }
    }

    var argumentsSummary: String {
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

enum ToolKind: String, Sendable, CaseIterable {
    case read
    case edit
    case execute
    case fetch
    case browser
    case other

    var icon: String {
        switch self {
        case .read: return "doc.text.magnifyingglass"
        case .edit: return "pencil"
        case .execute: return "terminal"
        case .fetch: return "globe"
        case .browser: return "safari"
        case .other: return "gearshape"
        }
    }

    var color: String {
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
