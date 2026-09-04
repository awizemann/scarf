import Foundation
import ScarfCore

/// The `scarf-projects` MCP server: request in, response out, no I/O of
/// its own.
///
/// Keeping the stdio loop outside this type is what makes the protocol
/// testable — `handle(_:)` is a pure function of the request plus the
/// Hermes home on disk, so the unit tests drive the real protocol without
/// spawning anything, and the smoke test spawns the binary to prove the
/// framing.
public struct ProjectMCPServer: Sendable {

    /// The MCP revision this server implements. Announced in
    /// `initialize`; a client asking for a different one is answered with
    /// ours, per the spec's version-negotiation rule (the client then
    /// decides whether it can proceed).
    public static let protocolVersion = "2025-06-18"
    public static let serverName = "scarf-projects"
    public static let serverVersion = "1.0.0"

    public let tools: ProjectMCPTools

    public init(context: ServerContext) {
        self.tools = ProjectMCPTools(context: context)
    }

    /// Handle one request. `nil` for a notification — the spec forbids
    /// answering those, and `notifications/initialized` arrives on every
    /// single connection.
    public func handle(_ request: JSONRPCRequest) -> JSONRPCResponse? {
        guard let id = request.id else { return nil }

        switch request.method {
        case "initialize":
            return .success(id: id, result: .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string(Self.serverName),
                    "version": .string(Self.serverVersion),
                ]),
                "instructions": .string(
                    "Structured CRUD for Scarf projects. Prefer these tools over hand-editing "
                        + "~/.hermes/scarf/projects.json, .scarf/project.json or "
                        + ".scarf/dashboard.json: they validate before writing and refuse writes "
                        + "that would lose data."
                ),
            ]))

        case "ping":
            return .success(id: id, result: .object([:]))

        case "tools/list":
            return .success(id: id, result: ProjectMCPToolCatalog.listResult())

        case "tools/call":
            return callTool(id: id, params: request.params)

        default:
            return .failure(
                id: id,
                code: .methodNotFound,
                message: "Unsupported method \"\(request.method)\". This server implements "
                    + "initialize, ping, tools/list and tools/call."
            )
        }
    }

    private func callTool(id: JSONValue, params: JSONValue?) -> JSONRPCResponse {
        guard case .object(let fields)? = params,
              case .string(let name)? = fields["name"]
        else {
            return .failure(
                id: id,
                code: .invalidParams,
                message: "tools/call requires params.name (the tool to run)."
            )
        }

        var arguments: [String: JSONValue] = [:]
        switch fields["arguments"] {
        case .object(let given)?: arguments = given
        case nil, .null?: break
        default:
            return .failure(
                id: id,
                code: .invalidParams,
                message: "tools/call params.arguments must be an object."
            )
        }

        // A tool that refuses is a SUCCESSFUL call carrying isError — the
        // model is meant to read the reason and fix its input. Only a
        // malformed envelope is a protocol error.
        let outcome = tools.call(name: name, arguments: arguments)
        return .success(id: id, result: .object([
            "content": .array([.object([
                "type": .string("text"),
                "text": .string(outcome.text),
            ])]),
            "isError": .bool(outcome.isError),
        ]))
    }
}
