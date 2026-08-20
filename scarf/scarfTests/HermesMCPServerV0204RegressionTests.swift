import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Phase 8 (final) of the Hermes v0.20.4 parity cycle — the regression the
/// task spec called "the only thing preventing data loss": Hermes v0.20.4
/// added a per-server `identity_header:` nested block. `HermesFileService`'s
/// surgical `patchMCPServerField` line-patcher edits ONE named scalar/list/
/// sub-map at a time by locating it inside the entry's line range and
/// touching nothing outside that span. This suite pins that a nested block
/// the reader doesn't even know how to parse (an unrelated unknown key)
/// AND one it does (`identity_header:`) both survive byte-for-byte when an
/// unrelated sibling field is patched.
///
/// Sanity check (not asserted in code, done by inspection): if
/// `replaceOrInsertScalar`'s indent==4 key match were loosened to match ANY
/// line starting with the target key's first letter, or if the patcher
/// scanned by content instead of by indent-scoped key match, this test
/// would start failing — the identity_header block's nested `name:` /
/// `value_from:` / `value:` lines live at indent 6 and would never
/// spuriously match a scalar key search at indent 4 in the first place,
/// which is exactly the containment property being pinned here.
struct HermesMCPServerV0204RegressionTests {

    private static let fixtureYAML = """
    mcp_servers:
      remote_api:
        url: https://my-mcp-server.example.com/mcp
        headers:
          Authorization: Bearer sk-test
        identity_header:
          name: X-User-Id
          value_from: static
          value: alice
        # An unrelated nested block the reader has never heard of — proves
        # preservation doesn't depend on the key being modelled.
        custom_extension:
          future_key: some_value
          nested:
            deeper_key: deeper_value
        strict_redirect_headers: true
        timeout: 180
        enabled: true
    """

    private func loadFixture() throws -> (service: HermesFileService, home: TempHermesHome) {
        let home = try TempHermesHome()
        try Self.fixtureYAML.write(
            toFile: home.context.paths.configYAML,
            atomically: true,
            encoding: .utf8
        )
        return (HermesFileService(context: home.context), home)
    }

    /// Baseline: the reader models `identity_header` from the fixture
    /// correctly before any patch happens.
    @Test func readerParsesIdentityHeaderFromFixture() throws {
        let (service, home) = try loadFixture()
        defer { home.cleanup() }
        let servers = service.loadMCPServers()
        #expect(servers.count == 1)
        #expect(servers.first?.identityHeader?.name == "X-User-Id")
        #expect(servers.first?.identityHeader?.valueFrom == .static)
        #expect(servers.first?.identityHeader?.value == "alice")
        #expect(servers.first?.strictRedirectHeaders == true)
    }

    /// THE regression test. Patch an unrelated sibling scalar (`timeout`)
    /// via the same surgical patcher the editor UI uses, then assert:
    ///   1. The edited field actually changed (the patch did something).
    ///   2. `identity_header:` and its three nested lines are byte-for-byte
    ///      unchanged in the raw YAML.
    ///   3. The unrelated unknown `custom_extension:` block (including its
    ///      own nested sub-block) also survives untouched.
    ///   4. Re-reading through the model still parses `identity_header`
    ///      identically to the pre-patch read.
    @Test func patchingUnrelatedFieldPreservesIdentityHeaderBlock() throws {
        let (service, home) = try loadFixture()
        defer { home.cleanup() }

        let before = service.loadMCPServers().first
        #expect(before?.identityHeader != nil)

        let patched = service.setMCPServerTimeouts(name: "remote_api", timeout: 999, connectTimeout: nil)
        #expect(patched == true)

        let rawYAML = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)

        // (1) The edit actually landed.
        #expect(rawYAML.contains("timeout: 999"))

        // (2) identity_header block byte-for-byte intact, including indentation.
        #expect(rawYAML.contains("    identity_header:\n      name: X-User-Id\n      value_from: static\n      value: alice\n"))

        // (3) The wholly-unknown nested block also survives, deep nesting included.
        #expect(rawYAML.contains("custom_extension:"))
        #expect(rawYAML.contains("future_key: some_value"))
        #expect(rawYAML.contains("deeper_key: deeper_value"))

        // (4) Re-parse: identity_header still models identically post-patch.
        let after = service.loadMCPServers().first
        #expect(after?.identityHeader?.name == before?.identityHeader?.name)
        #expect(after?.identityHeader?.valueFrom == before?.identityHeader?.valueFrom)
        #expect(after?.identityHeader?.value == before?.identityHeader?.value)
        #expect(after?.strictRedirectHeaders == before?.strictRedirectHeaders)
        #expect(after?.timeout == 999)
    }

    /// Dedicated identity_header writer: overwriting the block in place
    /// (e.g. changing name) must not disturb the unrelated sibling
    /// `custom_extension` block or `strict_redirect_headers`.
    @Test func writingIdentityHeaderPreservesUnrelatedSiblingBlocks() throws {
        let (service, home) = try loadFixture()
        defer { home.cleanup() }

        let newHeader = MCPIdentityHeader(name: "X-Tenant-Id", valueFrom: .profile, value: "")
        let ok = service.setMCPServerIdentityHeader(name: "remote_api", header: newHeader)
        #expect(ok == true)

        let rawYAML = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        #expect(rawYAML.contains("name: X-Tenant-Id"))
        #expect(rawYAML.contains("value_from: profile"))
        // Profile mode omits `value:` entirely per Hermes's documented shape.
        #expect(!rawYAML.contains("value: alice"))
        // Sibling unknown block untouched.
        #expect(rawYAML.contains("custom_extension:"))
        #expect(rawYAML.contains("deeper_key: deeper_value"))
        #expect(rawYAML.contains("strict_redirect_headers: true"))

        let servers = service.loadMCPServers()
        #expect(servers.first?.identityHeader?.name == "X-Tenant-Id")
        #expect(servers.first?.identityHeader?.valueFrom == .profile)
    }

    /// Removing the identity_header block (nil) drops only that block.
    @Test func removingIdentityHeaderDropsOnlyThatBlock() throws {
        let (service, home) = try loadFixture()
        defer { home.cleanup() }

        let ok = service.setMCPServerIdentityHeader(name: "remote_api", header: nil)
        #expect(ok == true)

        let rawYAML = try String(contentsOfFile: home.context.paths.configYAML, encoding: .utf8)
        #expect(!rawYAML.contains("identity_header:"))
        #expect(!rawYAML.contains("X-User-Id"))
        // Everything else remains.
        #expect(rawYAML.contains("custom_extension:"))
        #expect(rawYAML.contains("strict_redirect_headers: true"))
        #expect(rawYAML.contains("Authorization: Bearer sk-test"))

        #expect(service.loadMCPServers().first?.identityHeader == nil)
    }
}

/// Behavioral cover for the `identity_header` / `strict_redirect_headers`
/// READ path against malformed or unusual YAML shapes.
///
/// The contract these pin is agreement with Hermes's own validation in
/// `tools/mcp_tool.py` (`_resolve_identity_header`, and the
/// `bool(config.get("strict_redirect_headers"))` read): what Scarf shows for
/// a given config must be what Hermes will actually do with it. Hermes never
/// fails a connection over a bad identity_header — it warns and ignores —
/// so Scarf models those blocks as absent rather than inventing a plausible
/// interpretation. Every fixture below stays byte-for-byte on disk either
/// way; only the modelled value is asserted.
struct MalformedIdentityHeaderReadTests {

    private func load(_ yaml: String) throws -> (servers: [HermesMCPServer], home: TempHermesHome) {
        let home = try TempHermesHome()
        try yaml.write(toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        return (HermesFileService(context: home.context).loadMCPServers(), home)
    }

    private func entry(_ block: String) -> String {
        """
        mcp_servers:
          remote_api:
            url: https://example.com/mcp
        \(block)
        """
    }

    /// Hermes: `value_from` must be 'static' or 'profile' — anything else
    /// warns and the header is ignored. Scarf drops it too rather than
    /// coercing to `.static`, which would show the user a header Hermes is
    /// not going to send.
    @Test func unknownValueFromDropsTheHeader() throws {
        let (servers, home) = try load(entry("""
            identity_header:
              name: X-User-Id
              value_from: profil
              value: alice
        """))
        defer { home.cleanup() }
        #expect(servers.first?.identityHeader == nil)
    }

    /// `value_from: static` with a blank value: Hermes requires a non-empty
    /// string `value` and ignores the block otherwise.
    @Test func staticWithEmptyValueDropsTheHeader() throws {
        let (servers, home) = try load(entry("""
            identity_header:
              name: X-User-Id
              value_from: static
              value: ""
        """))
        defer { home.cleanup() }
        #expect(servers.first?.identityHeader == nil)
    }

    /// Same rule when `value:` is missing entirely.
    @Test func staticWithMissingValueDropsTheHeader() throws {
        let (servers, home) = try load(entry("""
            identity_header:
              name: X-User-Id
              value_from: static
        """))
        defer { home.cleanup() }
        #expect(servers.first?.identityHeader == nil)
    }

    /// `(raw.get("value_from") or "static")` — an absent `value_from` means
    /// static, so a name+value pair is a valid header.
    @Test func absentValueFromDefaultsToStatic() throws {
        let (servers, home) = try load(entry("""
            identity_header:
              name: X-User-Id
              value: alice
        """))
        defer { home.cleanup() }
        #expect(servers.first?.identityHeader?.valueFrom == .static)
        #expect(servers.first?.identityHeader?.value == "alice")
    }

    /// …and so does an EMPTY `value_from`, since `"" or "static"` is
    /// `"static"` in Python. This is the one blank field that is not a
    /// rejection.
    @Test func emptyValueFromAlsoDefaultsToStatic() throws {
        let (servers, home) = try load(entry("""
            identity_header:
              name: X-User-Id
              value_from: ""
              value: alice
        """))
        defer { home.cleanup() }
        #expect(servers.first?.identityHeader?.valueFrom == .static)
    }

    /// A blank `name` is rejected regardless of the rest of the block.
    @Test func blankNameDropsTheHeader() throws {
        let (servers, home) = try load(entry("""
            identity_header:
              name: ""
              value_from: static
              value: alice
        """))
        defer { home.cleanup() }
        #expect(servers.first?.identityHeader == nil)
    }

    /// `profile` mode never reads `value` — Hermes substitutes the active
    /// profile name at connect time — so a stale `value:` must not make the
    /// block look static, and must not block it either.
    @Test func profileModeIgnoresValue() throws {
        let (servers, home) = try load(entry("""
            identity_header:
              name: X-User-Id
              value_from: PROFILE
              value: stale
        """))
        defer { home.cleanup() }
        #expect(servers.first?.identityHeader?.valueFrom == .profile)
        #expect(servers.first?.identityHeader?.value == "")
    }

    /// `bool(config.get("strict_redirect_headers"))` is Python truthiness
    /// over the PyYAML-decoded scalar, so the YAML 1.1 true spellings and a
    /// bare `1` are all enabled — Scarf must not read them as "unset".
    @Test func truthyScalarsEnableStrictRedirectHeaders() throws {
        for spelling in ["true", "True", "yes", "on", "1"] {
            let (servers, home) = try load(entry("    strict_redirect_headers: \(spelling)"))
            defer { home.cleanup() }
            #expect(servers.first?.strictRedirectHeaders == true, "\(spelling) should be truthy")
        }
    }

    @Test func falsyScalarsDisableStrictRedirectHeaders() throws {
        for spelling in ["false", "no", "off", "0"] {
            let (servers, home) = try load(entry("    strict_redirect_headers: \(spelling)"))
            defer { home.cleanup() }
            #expect(servers.first?.strictRedirectHeaders == false, "\(spelling) should be falsy")
        }
    }

    /// Absent key stays nil — distinct from an explicit `false`, because the
    /// writer preserves "unset" as an absent key rather than materializing
    /// a default into the user's config.
    @Test func absentStrictRedirectHeadersStaysNil() throws {
        let (servers, home) = try load(entry("    timeout: 30"))
        defer { home.cleanup() }
        #expect(servers.first?.strictRedirectHeaders == nil)
    }
}
