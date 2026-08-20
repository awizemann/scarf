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

    // MARK: - Equatable stability (encode→decode→re-encode stand-in: two
    // servers built from the same inputs must compare equal, and a field
    // change must be visible in the comparison — otherwise Equatable
    // silently ignores the new properties, which would mask data loss
    // elsewhere in the app (e.g. list diffing that skips real updates).

    @Test func equatableCoversIdentityHeader() {
        let a = makeServer(identityHeader: MCPIdentityHeader(name: "X-User-Id", value: "alice"))
        let b = makeServer(identityHeader: MCPIdentityHeader(name: "X-User-Id", value: "alice"))
        let c = makeServer(identityHeader: MCPIdentityHeader(name: "X-User-Id", value: "bob"))
        #expect(a == b)
        #expect(a != c)
    }

    @Test func equatableCoversStrictRedirectHeadersAndCwd() {
        let base = makeServer(strictRedirectHeaders: true, cwd: "/tmp")
        let sameAgain = makeServer(strictRedirectHeaders: true, cwd: "/tmp")
        let differentCwd = makeServer(strictRedirectHeaders: true, cwd: "/other")
        #expect(base == sameAgain)
        #expect(base != differentCwd)
    }
}

/// Roster integrity for the static optional-MCP catalog snapshot (v0.20.4:
/// 20 entries).
@Suite("OptionalMCPCatalog roster")
struct OptionalMCPCatalogTests {

    @Test func hasExactlyTwentyEntries() {
        #expect(OptionalMCPCatalog.entries.count == 20)
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

    @Test func apiKeyEntriesCarryARequiredEnvVar() {
        // Only auth-type entries that actually prompt for a credential
        // (api_key) are required to name the env var; oauth/none entries
        // legitimately have none per their manifests.
        for entry in OptionalMCPCatalog.entries where entry.authKind == .apiKey {
            #expect(!entry.requiredEnvVar.isEmpty, "\(entry.name) is api_key-authed but has no requiredEnvVar")
        }
    }

    @Test func httpAndSSEEntriesCarryAURL() {
        for entry in OptionalMCPCatalog.entries where entry.transport != .stdio {
            #expect(entry.url != nil && !(entry.url ?? "").isEmpty, "\(entry.name) is \(entry.transport.id) but has no url")
        }
    }
}
