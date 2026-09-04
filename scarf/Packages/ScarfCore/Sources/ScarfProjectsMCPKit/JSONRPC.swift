import Foundation
import ScarfCore

/// Minimal JSON-RPC 2.0 over newline-delimited JSON — the framing the MCP
/// stdio transport specifies (one JSON object per line, no `Content-Length`
/// headers, no embedded newlines).
///
/// Hand-rolled deliberately: the whole protocol surface this server needs is
/// `initialize`, `tools/list`, `tools/call` and `ping`, and Scarf has no MCP
/// SDK dependency to reuse. A third-party package would be more code in the
/// app bundle than the thing it implements.
public enum JSONRPC {
    public static let version = "2.0"

    /// Standard JSON-RPC error codes. MCP adds no codes of its own — a
    /// TOOL failure is a successful `tools/call` result carrying
    /// `isError: true`, not a protocol error, so agents can read it.
    public enum ErrorCode: Int, Sendable {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
    }
}

/// One decoded incoming message. `id` absent ⇒ a notification, which must
/// never be answered (answering `notifications/initialized` makes strict
/// clients drop the connection).
public struct JSONRPCRequest: Sendable {
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?

    public var isNotification: Bool { id == nil }

    public init(id: JSONValue?, method: String, params: JSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Decode one line. Returns `nil` when the line is not a JSON object
    /// or carries no `method` — the caller answers with an
    /// `invalidRequest`, since we cannot know an id to answer under.
    public static func decode(_ data: Data) -> JSONRPCRequest? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = value,
              case .string(let method)? = fields["method"]
        else { return nil }
        var id = fields["id"]
        if case .null? = id { id = nil }
        return JSONRPCRequest(id: id, method: method, params: fields["params"])
    }
}

/// One outgoing response. Exactly one of `result` / `error` is present.
public struct JSONRPCResponse: Sendable {
    public let id: JSONValue
    public let result: JSONValue?
    public let error: JSONValue?

    public static func success(id: JSONValue, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(id: id, result: result, error: nil)
    }

    public static func failure(
        id: JSONValue,
        code: JSONRPC.ErrorCode,
        message: String
    ) -> JSONRPCResponse {
        JSONRPCResponse(
            id: id,
            result: nil,
            error: .object(["code": .int(code.rawValue), "message": .string(message)])
        )
    }

    /// Serialize to one line of UTF-8 JSON, newline included.
    ///
    /// Keys are sorted so the wire output is byte-stable across runs —
    /// what makes the smoke test assertable. No pretty-printing: a
    /// newline inside a frame would split one message into two.
    public func encoded() -> Data {
        var fields: [String: JSONValue] = [
            "jsonrpc": .string(JSONRPC.version),
            "id": id,
        ]
        if let result { fields["result"] = result }
        if let error { fields["error"] = error }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(JSONValue.object(fields))) ?? Data()
        data.append(0x0A)
        return data
    }
}
