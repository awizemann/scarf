import Testing
@testable import ScarfCore

/// `ConfigDottedKeySegment.escaped` is the single place Scarf neutralizes a
/// literal dot before interpolating user text into a `hermes config`
/// dotted key path. Covers both host generations per
/// `HermesCapabilities.hasConfigDottedKeyEscape` (v0.21+ escapes with
/// `\.`; older hosts have no escape syntax so dots are stripped) plus the
/// existing space→underscore rule folded into the same helper.
struct ConfigDottedKeySegmentTests {

    private static let v021 = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")
    private static let v0205 = HermesCapabilities.parseLine("Hermes Agent v0.20.5 (2026.8.19)")

    // MARK: - Dot-free segments: byte-identical on every host generation.

    @Test func dotFreeSegmentUnchangedOnNewHost() {
        #expect(ConfigDottedKeySegment.escaped("deploy", capabilities: Self.v021) == "deploy")
    }

    @Test func dotFreeSegmentUnchangedOnOldHost() {
        #expect(ConfigDottedKeySegment.escaped("deploy", capabilities: Self.v0205) == "deploy")
    }

    @Test func dotFreeSegmentUnchangedOnUndetectedCapabilities() {
        #expect(ConfigDottedKeySegment.escaped("deploy", capabilities: .empty) == "deploy")
    }

    // MARK: - Space sanitization (pre-existing rule) still applies.

    @Test func spacesBecomeUnderscoresOnNewHost() {
        #expect(ConfigDottedKeySegment.escaped("my command", capabilities: Self.v021) == "my_command")
    }

    @Test func spacesBecomeUnderscoresOnOldHost() {
        #expect(ConfigDottedKeySegment.escaped("my command", capabilities: Self.v0205) == "my_command")
    }

    // MARK: - Dotted segments: escaped on v0.21+, stripped on older hosts.

    @Test func dottedSegmentEscapedOnNewHost() {
        #expect(ConfigDottedKeySegment.escaped("v1.2 deploy", capabilities: Self.v021) == "v1\\.2_deploy")
    }

    @Test func dottedSegmentDotsStrippedOnOldHost() {
        #expect(ConfigDottedKeySegment.escaped("v1.2 deploy", capabilities: Self.v0205) == "v12_deploy")
    }

    @Test func dottedSegmentDotsStrippedWhenCapabilitiesUndetected() {
        // Safe-by-default: an as-yet-unprobed host (`.empty`) must not be
        // treated as v0.21+ — that would write an unescaped-looking `\.`
        // segment to a host that can't parse it.
        #expect(ConfigDottedKeySegment.escaped("v1.2", capabilities: .empty) == "v12")
    }

    @Test func multipleDotsAllEscapedOnNewHost() {
        #expect(ConfigDottedKeySegment.escaped("a.b.c", capabilities: Self.v021) == "a\\.b\\.c")
    }

    @Test func multipleDotsAllStrippedOnOldHost() {
        #expect(ConfigDottedKeySegment.escaped("a.b.c", capabilities: Self.v0205) == "abc")
    }

    @Test func providerLikeNameWithDotOnNewHost() {
        // CredentialPoolsViewModel's defensive call site.
        #expect(ConfigDottedKeySegment.escaped("qwen3.5-397b", capabilities: Self.v021) == "qwen3\\.5-397b")
    }
}
