import Foundation

public enum MCPTransport: String, Sendable, Equatable, CaseIterable, Identifiable {
    case stdio
    case http

    public var id: String { rawValue }

    public var displayName: LocalizedStringResource {
        switch self {
        case .stdio: return "Local (stdio)"
        case .http: return "Remote (HTTP)"
        }
    }
}

public struct HermesMCPServer: Identifiable, Sendable, Equatable {
    public let name: String
    public let transport: MCPTransport
    public let command: String?
    public let args: [String]
    public let url: String?
    public let auth: String?
    public let env: [String: String]
    public let headers: [String: String]
    public let timeout: Int?
    public let connectTimeout: Int?
    public let enabled: Bool
    public let toolsInclude: [String]
    public let toolsExclude: [String]
    public let resourcesEnabled: Bool
    public let promptsEnabled: Bool
    public let hasOAuthToken: Bool


    public init(
        name: String,
        transport: MCPTransport,
        command: String?,
        args: [String],
        url: String?,
        auth: String?,
        env: [String: String],
        headers: [String: String],
        timeout: Int?,
        connectTimeout: Int?,
        enabled: Bool,
        toolsInclude: [String],
        toolsExclude: [String],
        resourcesEnabled: Bool,
        promptsEnabled: Bool,
        hasOAuthToken: Bool
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.auth = auth
        self.env = env
        self.headers = headers
        self.timeout = timeout
        self.connectTimeout = connectTimeout
        self.enabled = enabled
        self.toolsInclude = toolsInclude
        self.toolsExclude = toolsExclude
        self.resourcesEnabled = resourcesEnabled
        self.promptsEnabled = promptsEnabled
        self.hasOAuthToken = hasOAuthToken
    }
    public var id: String { name }

    public var summary: String {
        switch transport {
        case .stdio:
            let argString = args.isEmpty ? "" : " " + args.joined(separator: " ")
            return (command ?? "") + argString
        case .http:
            return url ?? ""
        }
    }
}

public struct MCPTestResult: Sendable, Equatable {
    public let serverName: String
    public let succeeded: Bool
    public let output: String
    public let tools: [String]
    public let elapsed: TimeInterval

    public init(
        serverName: String,
        succeeded: Bool,
        output: String,
        tools: [String],
        elapsed: TimeInterval
    ) {
        self.serverName = serverName
        self.succeeded = succeeded
        self.output = output
        self.tools = tools
        self.elapsed = elapsed
    }
}
