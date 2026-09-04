import Testing
import Foundation
@testable import ScarfProjectsMCPKit
@testable import ScarfCore

/// The JSON-RPC / MCP envelope, exercised without a subprocess. The
/// end-to-end smoke test proves the framing; these prove the semantics.
@Suite struct ProjectMCPProtocolTests {

    static func server() -> ProjectMCPServer {
        ProjectMCPServer(context: .local(home: FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-mcp-protocol-\(UUID().uuidString)", isDirectory: true)))
    }

    static func request(_ json: String) -> JSONRPCRequest {
        guard let request = JSONRPCRequest.decode(Data(json.utf8)) else {
            Issue.record("could not decode: \(json)")
            return JSONRPCRequest(id: .int(0), method: "", params: nil)
        }
        return request
    }

    static func result(_ response: JSONRPCResponse?) -> [String: JSONValue] {
        guard case .object(let fields)? = response?.result else {
            Issue.record("response carried no object result")
            return [:]
        }
        return fields
    }

    @Test("initialize announces the protocol version, tool capability and server identity")
    func initialize() {
        let response = Self.server().handle(Self.request("""
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
            """))
        let result = Self.result(response)
        #expect(result["protocolVersion"] == .string("2025-06-18"))
        #expect(result["capabilities"] == .object(["tools": .object([:])]))
        guard case .object(let info)? = result["serverInfo"] else {
            Issue.record("no serverInfo")
            return
        }
        #expect(info["name"] == .string("scarf-projects"))
    }

    @Test("a notification is never answered")
    func notificationsAreSilent() {
        #expect(Self.server().handle(Self.request("""
            {"jsonrpc":"2.0","method":"notifications/initialized"}
            """)) == nil)
        // An explicit null id is a notification too, not id 0.
        #expect(Self.server().handle(Self.request("""
            {"jsonrpc":"2.0","id":null,"method":"notifications/cancelled"}
            """)) == nil)
    }

    @Test("tools/list returns every tool with an object schema")
    func toolsList() {
        let result = Self.result(Self.server().handle(Self.request("""
            {"jsonrpc":"2.0","id":2,"method":"tools/list"}
            """)))
        guard case .array(let tools)? = result["tools"] else {
            Issue.record("no tools array")
            return
        }
        #expect(tools.count == 7)

        var names: [String] = []
        for tool in tools {
            guard case .object(let fields) = tool,
                  case .string(let name)? = fields["name"],
                  case .object(let schema)? = fields["inputSchema"]
            else {
                Issue.record("malformed tool entry")
                continue
            }
            names.append(name)
            #expect(schema["type"] == .string("object"))
            #expect(schema["properties"] != nil)
            if case .string(let description)? = fields["description"] {
                #expect(!description.isEmpty)
            } else {
                Issue.record("\(name) has no description")
            }
        }
        #expect(names.sorted() == [
            "project_add_slash_command", "project_get", "project_list",
            "project_register", "project_set_config", "project_update_dashboard",
            "project_validate",
        ])
    }

    @Test("an unsupported method is a JSON-RPC error naming what is supported")
    func methodNotFound() {
        let response = Self.server().handle(Self.request("""
            {"jsonrpc":"2.0","id":3,"method":"resources/list"}
            """))
        guard case .object(let error)? = response?.error else {
            Issue.record("expected an error")
            return
        }
        #expect(error["code"] == .int(-32601))
        if case .string(let message)? = error["message"] {
            #expect(message.contains("tools/call"))
        }
    }

    @Test("a malformed tools/call envelope is a protocol error, but a tool refusal is not")
    func toolCallEnvelope() {
        let noName = Self.server().handle(Self.request("""
            {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{}}
            """))
        guard case .object(let error)? = noName?.error else {
            Issue.record("expected invalidParams")
            return
        }
        #expect(error["code"] == .int(-32602))

        // A tool that refuses still SUCCEEDS at protocol level, carrying
        // isError so the model reads the reason and retries correctly.
        let refused = Self.result(Self.server().handle(Self.request("""
            {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"project_get","arguments":{}}}
            """)))
        #expect(refused["isError"] == .bool(true))
        guard case .array(let content)? = refused["content"],
              case .object(let first)? = content.first
        else {
            Issue.record("no content array")
            return
        }
        #expect(first["type"] == .string("text"))
    }

    @Test("a line that isn't a JSON-RPC request decodes to nothing")
    func undecodableLines() {
        #expect(JSONRPCRequest.decode(Data("{ not json".utf8)) == nil)
        #expect(JSONRPCRequest.decode(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)) == nil)
        #expect(JSONRPCRequest.decode(Data("[1,2,3]".utf8)) == nil)
    }

    @Test("responses are single-line, so one frame is never split in two")
    func responsesAreSingleLine() {
        let encoded = JSONRPCResponse
            .success(id: .int(1), result: .object(["text": .string("a\nb")]))
            .encoded()
        #expect(encoded.last == 0x0A)
        #expect(encoded.dropLast().firstIndex(of: 0x0A) == nil)
    }
}
