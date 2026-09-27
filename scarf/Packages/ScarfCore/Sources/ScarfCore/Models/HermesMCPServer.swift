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
    /// Seconds. `Double` because Hermes stores both keys as floats:
    /// `mcp add --connect-timeout` is `type=float`
    /// (`hermes_cli/subcommands/mcp.py:38-40` @ v2026.9.24) and lands in the
    /// file as `connect_timeout: 45.0`, and the runtime reads both through
    /// `float(...)` (`tools/mcp_tool_transport.py:359,547`). Reading them as
    /// `Int` turned `45.0` into "absent", and the editor then deleted the key
    /// on its next save. Render with ``formatSeconds(_:)``.
    public let timeout: Double?
    public let connectTimeout: Double?
    public let enabled: Bool
    public let toolsInclude: [String]
    public let toolsExclude: [String]
    /// True when `tools.include` holds a list or a string, which makes it a
    /// WHITELIST even when it is empty: Hermes registers nothing for
    /// `include: []` (`tools/mcp_tool_registration.py:209-225` @ v2026.9.24,
    /// the install checklist's "uncheck everything" path writes it). A bare
    /// `include:` (null) or an absent key is false, and then the exclude
    /// list applies. `toolsInclude` alone cannot tell `[]` from absent.
    public let toolsIncludeIsExplicit: Bool
    public let resourcesEnabled: Bool
    public let promptsEnabled: Bool
    public let hasOAuthToken: Bool
    // `sseReadTimeout` used to be parsed and threaded through here "for
    // round-trip fidelity". It never protected anything: both writers are
    // line-level patchers over the user's own YAML, so an `sse_read_timeout`
    // line survives whether or not the model carries it — and no Hermes in
    // Scarf's supported range READS the key (`_sse_transport` hard-codes
    // `"sse_read_timeout": 300.0`, `tools/mcp_tool_transport.py:351-352` @
    // v2026.9.7; a literal at all 32 `v2026.*` tags, first appearing at
    // v2026.5.7 `tools/mcp_tool.py:1323`). P24 removed the editor field; P35
    // removes the residue.
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
    /// Hermes v0.21.1+ — `oauth.flow` inside the server's `oauth:` block:
    /// `"browser"` (PKCE redirect, Hermes's default) or `"device"` (RFC 8628
    /// device code). `nil` = key absent = browser. Held as a String so an
    /// unknown future spelling round-trips instead of collapsing to a default;
    /// `mcp_config.py:639-641` rejects anything outside the two, so Scarf's
    /// picker only ever writes those.
    ///
    /// The `oauth:` block also carries `client_id` / `client_secret` / `scope`
    /// / `timeout`, which Scarf does not model — so this key is written by a
    /// nested-scalar patcher that touches the one line, NOT by a block writer
    /// like `identity_header`'s, which would delete the user's credentials.
    public let oauthFlow: String?


    public init(
        name: String,
        transport: MCPTransport,
        command: String?,
        args: [String],
        url: String?,
        auth: String?,
        env: [String: String],
        headers: [String: String],
        timeout: Double?,
        connectTimeout: Double?,
        enabled: Bool,
        toolsInclude: [String],
        toolsExclude: [String],
        resourcesEnabled: Bool,
        promptsEnabled: Bool,
        hasOAuthToken: Bool,
        supportsParallelToolCalls: Bool? = nil,
        clientCert: String? = nil,
        clientKey: String? = nil,
        sslVerify: String? = nil,
        identityHeader: MCPIdentityHeader? = nil,
        strictRedirectHeaders: Bool? = nil,
        cwd: String? = nil,
        oauthFlow: String? = nil,
        toolsIncludeIsExplicit: Bool? = nil
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
        // Default: a non-empty include list is a whitelist by definition.
        self.toolsIncludeIsExplicit = toolsIncludeIsExplicit ?? !toolsInclude.isEmpty
        self.resourcesEnabled = resourcesEnabled
        self.promptsEnabled = promptsEnabled
        self.hasOAuthToken = hasOAuthToken
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.clientCert = clientCert
        self.clientKey = clientKey
        self.sslVerify = sslVerify
        self.identityHeader = identityHeader
        self.strictRedirectHeaders = strictRedirectHeaders
        self.cwd = cwd
        self.oauthFlow = oauthFlow
    }
    public var id: String { name }

    /// A timeout as the user should see it and as Scarf writes it: `45` for
    /// a whole number (so an Int-valued key round-trips as the same text),
    /// otherwise Swift's shortest decimal form (`45.5`).
    public static func formatSeconds(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// Parses a timeout the way Hermes's `float(...)` would accept it from
    /// the editor, or `nil` for anything that is not a positive finite
    /// number. `Double("inf")` succeeds in Swift, but PyYAML reads a bare
    /// `inf` as a string, so it is refused here rather than written.
    public static func parseSeconds(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return value
    }

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

    /// What the verdict actually KNOWS, carried alongside ``succeeded``
    /// rather than collapsed into it (P54, round-6).
    ///
    /// ``HermesMCPTestVerdict/judge(output:exitCode:)`` returns three states
    /// and `HermesFileService.testMCPServer` used to keep only `.succeeded`,
    /// so `.unconfirmed` — exit 0 with neither a success nor a failure
    /// marker, which is what an unknown-verb fallthrough or a wedged probe
    /// looks like — arrived at the two views as a hard red "Test failed".
    /// That is the mirror of the bug the verdict exists to prevent: a claim
    /// the run PROVED something when it proved nothing. Both consumers had a
    /// two-way `if` on `succeeded` (round-6 lesson 12).
    ///
    /// Defaults to the two-state reading so every existing constructor and
    /// test fixture still means exactly what it did.
    public let confidence: HermesCLIOutcome.Confidence

    public init(
        serverName: String,
        succeeded: Bool,
        output: String,
        tools: [String],
        elapsed: TimeInterval,
        confidence: HermesCLIOutcome.Confidence? = nil
    ) {
        self.serverName = serverName
        self.succeeded = succeeded
        self.output = output
        self.tools = tools
        self.elapsed = elapsed
        self.confidence = confidence ?? (succeeded ? .confirmed : .failed)
    }
}
