import Testing
import Foundation
@testable import ScarfCore

/// Phase 8 (final) of the Hermes v0.20.4 parity cycle — MCP catalog surface
/// growth (6 → 20 optional entries) plus per-server `identity_header`,
/// `strict_redirect_headers`, and stdio `cwd`. This file covers the model
/// itself: init defaults, presence/absence round-tripping, and the static
/// catalog roster's integrity. The YAML read/patch regression test lives in
/// the main `scarf` target — see `HermesFileServiceConfigParityTests`
/// (HermesFileService owns file I/O, which isn't available to this
/// package's test target).
@Suite("HermesMCPServer v0.20.4 fields")
struct HermesMCPServerV0204Tests {

    private func makeServer(
        identityHeader: MCPIdentityHeader? = nil,
        strictRedirectHeaders: Bool? = nil,
        cwd: String? = nil
    ) -> HermesMCPServer {
        HermesMCPServer(
            name: "test_server",
            transport: .http,
            command: nil,
            args: [],
            url: "https://example.com/mcp",
            auth: nil,
            env: [:],
            headers: [:],
            timeout: nil,
            connectTimeout: nil,
            enabled: true,
            toolsInclude: [],
            toolsExclude: [],
            resourcesEnabled: false,
            promptsEnabled: false,
            hasOAuthToken: false,
            identityHeader: identityHeader,
            strictRedirectHeaders: strictRedirectHeaders,
            cwd: cwd
        )
    }

    // MARK: - Defaults (absent forms)

    @Test func newFieldsDefaultToNilWhenOmitted() {
        let server = makeServer()
        #expect(server.identityHeader == nil)
        #expect(server.strictRedirectHeaders == nil)
        #expect(server.cwd == nil)
    }

    // MARK: - Presence (dict / full forms)

    @Test func identityHeaderStaticFormRoundTrips() {
        let header = MCPIdentityHeader(name: "X-User-Id", valueFrom: .static, value: "alice")
        let server = makeServer(identityHeader: header)
        #expect(server.identityHeader?.name == "X-User-Id")
        #expect(server.identityHeader?.valueFrom == .static)
        #expect(server.identityHeader?.value == "alice")
    }

    @Test func identityHeaderProfileFormRoundTrips() {
        let header = MCPIdentityHeader(name: "X-User-Id", valueFrom: .profile, value: "")
        let server = makeServer(identityHeader: header)
        #expect(server.identityHeader?.valueFrom == .profile)
        // Profile mode ignores `value` at connect time, but the model still
        // carries whatever was stored — this only asserts identity, not
        // Hermes's runtime resolution behavior.
        #expect(server.identityHeader?.value == "")
    }

    @Test func strictRedirectHeadersRoundTripsBothBoolValues() {
        #expect(makeServer(strictRedirectHeaders: true).strictRedirectHeaders == true)
        #expect(makeServer(strictRedirectHeaders: false).strictRedirectHeaders == false)
    }

    @Test func cwdRoundTrips() {
        #expect(makeServer(cwd: "/Users/alice/project").cwd == "/Users/alice/project")
    }

    // Equatable is synthesized over the stored properties, so asserting that
    // two servers built from identical inputs compare equal only restates
    // the compiler's own behavior. The behavior worth pinning is how the
    // YAML READ PATH treats malformed `identity_header` /
    // `strict_redirect_headers` shapes against Hermes's validation — that
    // needs `HermesFileService`, which lives in the main app target, so
    // those tests are in `scarfTests/HermesMCPServerV0204RegressionTests`
    // (`MalformedIdentityHeaderReadTests`).
}

/// Roster integrity for the static optional-MCP catalog snapshot (v0.21.0:
/// 65 entries, up from 20 at v0.20.4).
@Suite("OptionalMCPCatalog roster")
struct OptionalMCPCatalogTests {

    @Test func hasExactlySixtyFiveEntries() {
        #expect(OptionalMCPCatalog.entries.count == 65)
    }

    /// Blender was removed from the upstream catalog before v0.20.4 and
    /// stays absent in v0.21.0 — confirmed against the manifest directory
    /// (no `optional-mcps/blender/` at v2026.8.31).
    @Test func blenderStaysExcluded() {
        #expect(!OptionalMCPCatalog.entries.contains { $0.name == "blender" })
    }

    @Test func noDuplicateNames() {
        let names = OptionalMCPCatalog.entries.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func everyEntryHasNonEmptyNameAndDescription() {
        for entry in OptionalMCPCatalog.entries {
            #expect(!entry.name.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!entry.description.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @Test func apiKeyEntriesCarryTheirRequiredEnvVars() {
        // Only auth-type entries that actually prompt for a credential
        // (api_key) are required to name env vars; oauth/none entries
        // legitimately have none per their manifests.
        for entry in OptionalMCPCatalog.entries where entry.authKind == .apiKey {
            #expect(!entry.requiredEnvVars.isEmpty, "\(entry.name) is api_key-authed but names no env vars")
            #expect(entry.requiredEnvVars.filter(\.isEmpty).isEmpty)
        }
        for entry in OptionalMCPCatalog.entries where entry.authKind != .apiKey {
            #expect(entry.requiredEnvVars.isEmpty, "\(entry.name) is \(entry.authKind.rawValue) but names env vars")
        }
    }

    /// n8n's manifest declares TWO required env vars — `N8N_BASE_URL`
    /// (non-secret, defaulted) and `N8N_API_KEY` (secret). Modelling only
    /// the key would leave a prefilled bridge pointing nowhere.
    @Test func n8nRequiresBothBaseURLAndAPIKey() {
        let n8n = OptionalMCPCatalog.entries.first { $0.name == "n8n" }
        #expect(n8n?.requiredEnvVars == ["N8N_BASE_URL", "N8N_API_KEY"])
    }

    /// The three `/sse`-suffixed endpoints whose manifests declare
    /// `type: http`. `hermes mcp install` writes no `transport:` key for
    /// them; prefilling `.sse` would route Hermes to `sse_client`, a
    /// different protocol that also hard-fails with
    /// `strict_redirect_headers`.
    @Test func httpManifestsWithSSEShapedURLsStayHTTP() {
        for name in ["asana", "paypal", "square"] {
            let entry = OptionalMCPCatalog.entries.first { $0.name == name }
            #expect(entry?.transport == .http, "\(name) must mirror its manifest's transport.type (http)")
            #expect(entry?.url?.hasSuffix("/sse") == true, "\(name) fixture assumption: url still ends in /sse")
        }
    }

    /// Atlassian's manifest was fixed to point at `/v1/mcp/authv2` — the old
    /// `/v1/sse` path 404s (deprecated by Atlassian after June 30, 2026).
    @Test func atlassianURLIsTheLiveEndpoint() {
        let atlassian = OptionalMCPCatalog.entries.first { $0.name == "atlassian" }
        #expect(atlassian?.url == "https://mcp.atlassian.com/v1/mcp/authv2")
        #expect(atlassian?.transport == .http)
    }

    /// No roster entry may claim SSE unless a manifest actually declares
    /// `transport.type: sse` — none does at v2026.8.31.
    @Test func noEntryDeclaresSSETransport() {
        #expect(!OptionalMCPCatalog.entries.contains { $0.transport == .sse })
    }

    /// `tools.default_excluded` is new at v0.21.0 (25 manifests declare it)
    /// and is mutually exclusive with `tools.default_enabled` per the
    /// manifest schema (mcp_catalog.py `_parse_manifest`).
    @Test func exactlyTwentyFiveEntriesDeclareDefaultExcludedTools() {
        let withExcluded = OptionalMCPCatalog.entries.filter { !$0.defaultExcludedTools.isEmpty }
        #expect(withExcluded.count == 25)
    }

    @Test func defaultEnabledAndDefaultExcludedAreMutuallyExclusive() {
        for entry in OptionalMCPCatalog.entries {
            #expect(entry.defaultEnabledTools.isEmpty || entry.defaultExcludedTools.isEmpty, "\(entry.name) declares both default_enabled and default_excluded")
        }
    }

    /// Spot-check one `default_excluded` entry against its manifest
    /// verbatim (attio: `tools.default_excluded: [whoami, query-particle-sql]`).
    @Test func attioDefaultExcludedToolsMatchManifest() {
        let attio = OptionalMCPCatalog.entries.first { $0.name == "attio" }
        #expect(attio?.defaultExcludedTools == ["whoami", "query-particle-sql"])
        #expect(attio?.defaultEnabledTools.isEmpty == true)
    }

    /// figma's description is the manifest's `description:` verbatim,
    /// including the endpoint + auth tail that a reflow once dropped.
    @Test func figmaDescriptionIsVerbatim() {
        let figma = OptionalMCPCatalog.entries.first { $0.name == "figma" }
        #expect(figma?.description == "Official Figma remote MCP — design context, Code Connect, and write-to-canvas via https://mcp.figma.com/mcp (OAuth).")
    }

    @Test func httpAndSSEEntriesCarryAURL() {
        for entry in OptionalMCPCatalog.entries where entry.transport != .stdio {
            #expect(entry.url != nil && !(entry.url ?? "").isEmpty, "\(entry.name) is \(entry.transport.id) but has no url")
        }
    }
}
