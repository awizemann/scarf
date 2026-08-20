import Foundation

public enum MCPTransport: String, Sendable, Equatable, CaseIterable, Identifiable {
    case stdio
    case http
    /// Server-Sent Events transport. Hermes v0.13+ only.
    case sse

    public var id: String { rawValue }

    #if canImport(Darwin)
    public var displayName: LocalizedStringResource {
        switch self {
        case .stdio: return "Local (stdio)"
        case .http: return "Remote (HTTP)"
        case .sse: return "Remote (SSE)"
        }
    }
    #endif
}

/// Hermes v0.20.4+ — optional per-user identity header attached to this
/// server's HTTP/SSE requests (`identity_header:` nested block; see
/// `mcp_tool.py._resolve_identity_header`). `valueFrom == .static` requires
/// `value`; `.profile` resolves the value to the active Hermes profile name
/// at connect time and `value` is ignored (kept for round-trip fidelity).
public struct MCPIdentityHeader: Sendable, Equatable {
    public enum ValueSource: String, Sendable, Equatable, CaseIterable, Identifiable {
        case `static`
        case profile

        public var id: String { rawValue }
    }

    public var name: String
    public var valueFrom: ValueSource
    public var value: String

    public init(name: String, valueFrom: ValueSource = .static, value: String = "") {
        self.name = name
        self.valueFrom = valueFrom
        self.value = value
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
    /// Hermes-side keepalive interval (seconds) for SSE transport. `nil`
    /// when the YAML doesn't specify `sse_read_timeout` (Hermes default
    /// applies). Pre-v0.13 hosts always have this as `nil`.
    public let sseReadTimeout: Int?
    /// Hermes v0.14+ — when `true`, the agent batches concurrent tool
    /// calls to this MCP server instead of serializing them. `nil`
    /// means "use Hermes's default" (currently false). The setting
    /// surfaces in MCPServerEditorView as an optional toggle when
    /// `HermesCapabilities.hasMCPParallelToolCalls` is on.
    public let supportsParallelToolCalls: Bool?
    /// Hermes v0.15+ — mTLS / TLS client-certificate config for HTTP + SSE
    /// transports. `clientCert` is the path to a combined-PEM file (Hermes
    /// also accepts `[cert, key]` / `[cert, key, password]` list forms on
    /// disk; Scarf reads/writes only the common string-path form, taking the
    /// first element if a list is present). `nil` means the key is absent.
    public let clientCert: String?
    /// Hermes v0.15+ — path to a private-key file paired with a string
    /// `clientCert`. `nil` when absent.
    public let clientKey: String?
    /// Hermes v0.15+ — TLS peer verification. Held as `String?` so it can
    /// represent the bool form (`"true"` / `"false"`) OR a CA-bundle file
    /// path. `nil` = key absent = Hermes default (`true`). Surfaced in
    /// MCPServerEditorView when `HermesCapabilities.hasMCPClientCerts` is on.
    public let sslVerify: String?
    /// Hermes v0.20.4+ — optional per-user identity header for HTTP/SSE
    /// transports (`identity_header:` nested block). `nil` when the key is
    /// absent from the YAML. Surfaced in MCPServerEditorView when
    /// `HermesCapabilities.hasMCPIdentityHeader` is on. This is a nested
    /// block, not a single scalar, so it is NOT a candidate for the flat
    /// single-line `patchMCPServerField` scalar helpers — HermesFileService
    /// writes it with a dedicated sub-block writer that must not disturb
    /// sibling unknown blocks.
    public let identityHeader: MCPIdentityHeader?
    /// Hermes v0.20.4+ — `strict_redirect_headers` bool for HTTP/SSE
    /// transports (Portable Agent Plugins v1 §7.2.1: configured headers must
    /// not follow a cross-origin redirect). `nil` = key absent = Hermes
    /// default (`false`).
    public let strictRedirectHeaders: Bool?
    /// Hermes v0.20.4+ — working directory for stdio-transport servers
    /// (`cwd:` scalar, `StdioServerParameters.cwd`). `nil` = key absent =
    /// Hermes's own process cwd.
    public let cwd: String?


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
        hasOAuthToken: Bool,
        sseReadTimeout: Int? = nil,
        supportsParallelToolCalls: Bool? = nil,
        clientCert: String? = nil,
        clientKey: String? = nil,
        sslVerify: String? = nil,
        identityHeader: MCPIdentityHeader? = nil,
        strictRedirectHeaders: Bool? = nil,
        cwd: String? = nil
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
        self.sseReadTimeout = sseReadTimeout
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.clientCert = clientCert
        self.clientKey = clientKey
        self.sslVerify = sslVerify
        self.identityHeader = identityHeader
        self.strictRedirectHeaders = strictRedirectHeaders
        self.cwd = cwd
    }
    public var id: String { name }

    public var summary: String {
        switch transport {
        case .stdio:
            let argString = args.isEmpty ? "" : " " + args.joined(separator: " ")
            return (command ?? "") + argString
        case .http:
            return url ?? ""
        case .sse:
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
