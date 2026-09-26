import Testing
@testable import ScarfCore

/// P0 groundwork for v0.21.4 (v2026.9.21) and v0.21.5 (v2026.9.24): the
/// `isV0214OrLater` / `isV0215OrLater` convenience predicates and their MARK
/// groups in `HermesCapabilities.swift`. Verified at the tags:
/// `git -C ~/.hermes/hermes-agent show v2026.9.21:pyproject.toml` reads
/// `version = "0.21.4"`; `v2026.9.24:pyproject.toml` reads `version = "0.21.5"`.
/// No feature flag lives here yet — those are added by the phases that use
/// them (see `documents/plans/2026-09-26-hermes-v0-21-5-release-plan.md`).
@Suite struct HermesV0214V0215Tests {
    // MARK: parsing the real version lines

    @Test func parseV0214ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 21, patch: 4))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 9, day: 21))
        #expect(caps.detected)
    }

    /// The installed fork's own `--version` shape: a second parenthesized
    /// clause after the date trails the line. The parser only reads the
    /// FIRST `(...)` pair for the date version and stops there, so the
    /// fork suffix must not disturb semver/date parsing.
    @Test func parseV0214ForkReleaseLine() {
        let caps = HermesCapabilities.parseLine(
            "Hermes Agent v0.21.4 (2026.9.21) · upstream ce374bc1 · local 3f246940 (+31971 carried commits)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 21, patch: 4))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 9, day: 21))
        #expect(caps.detected)
        #expect(caps.isV0214OrLater)
        #expect(!caps.isV0215OrLater)
    }

    @Test func parseV0215ReleaseLine() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")
        #expect(caps.semver == HermesCapabilities.SemVer(major: 0, minor: 21, patch: 5))
        #expect(caps.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 9, day: 24))
        #expect(caps.detected)
    }

    // MARK: predicates at floor

    @Test func isV0214OrLater_v0214HostTrue() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
        #expect(caps.isV0214OrLater)
    }

    @Test func isV0215OrLater_v0215HostTrue() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")
        #expect(caps.isV0215OrLater)
    }

    // MARK: a v0.21.3 host has both off

    @Test func v0213HostHidesBothV0214AndV0215() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
        #expect(caps.isV0213OrLater)
        #expect(!caps.isV0214OrLater)
        #expect(!caps.isV0215OrLater)
    }

    @Test func emptyHidesBothV0214AndV0215() {
        #expect(!HermesCapabilities.empty.isV0214OrLater)
        #expect(!HermesCapabilities.empty.isV0215OrLater)
    }

    // MARK: a v0.21.4 host has 0.21.4 on, 0.21.5 off

    @Test func v0214HostHasV0214OnAndV0215Off() {
        let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.4 (2026.9.21)")
        #expect(caps.isV0214OrLater)
        #expect(!caps.isV0215OrLater)
        // A patch does not roll back an older floor.
        #expect(caps.isV0213OrLater)
    }

    // MARK: a later patch/minor still has both on

    @Test func laterReleasesStillEnableBothPredicates() {
        for line in ["Hermes Agent v0.21.6 (2026.10.1)", "Hermes Agent v0.22.0 (2026.10.15)"] {
            let caps = HermesCapabilities.parseLine(line)
            #expect(caps.isV0214OrLater, "\(line)")
            #expect(caps.isV0215OrLater, "\(line)")
        }
    }
}
