import Testing
import Foundation
@testable import ScarfCore

/// The v0.22.6 / v0.23.0 capability groups. Floors are where the tagged
/// source first carries each surface (see the MARK sections in
/// `HermesCapabilities.swift`); several v0.23.0 release-note items already
/// ship at v0.22.6.
@Suite struct HermesCapabilitiesV0230Tests {

    static var v0226Floors: [(String, KeyPath<HermesCapabilities, Bool>)] { [
        ("isV0226OrLater", \.isV0226OrLater),
        ("hasACPConfigOptions", \.hasACPConfigOptions),
        ("hasModelReset", \.hasModelReset),
        ("hasCopilotLeftCore", \.hasCopilotLeftCore),
        ("hasCamofoxLeftCore", \.hasCamofoxLeftCore),
        ("hasBrowserRecordSessionsRemoved", \.hasBrowserRecordSessionsRemoved),
        ("hasCronCancel", \.hasCronCancel),
        ("hasCronCatchUpGrace", \.hasCronCatchUpGrace),
        ("hasSessionsRefreshPrompts", \.hasSessionsRefreshPrompts),
        ("hasCuratorLock", \.hasCuratorLock),
        ("hasSessionsNonZeroExit", \.hasSessionsNonZeroExit),
    ] }

    static var v0230Floors: [(String, KeyPath<HermesCapabilities, Bool>)] { [
        ("isV0230OrLater", \.isV0230OrLater),
        ("hasACPServiceTierOption", \.hasACPServiceTierOption),
        ("hasSkillsHubAuxRemoved", \.hasSkillsHubAuxRemoved),
        ("hasPluginsAutoUpdateVerb", \.hasPluginsAutoUpdateVerb),
    ] }

    static var allNewFlags: [(String, KeyPath<HermesCapabilities, Bool>)] {
        v0226Floors + v0230Floors
    }

    /// The real installed line: a git build past the tag, dirty, with the
    /// frozen (stale) date suffix.
    static let v0230RealLine = "Hermes Agent v0.23.0+209.g90d6b98.dirty (2026.9.24) · stable · local 90d6b98fd86d"
    static let v0226Line = "Hermes Agent v0.22.6 (2026.9.24) · stable · local abc1234def56"

    static func caps(_ line: String) -> HermesCapabilities { HermesCapabilities.parseLine(line) }

    // MARK: parse

    @Test func parseRealV0230DirtyGitLine() {
        let c = Self.caps(Self.v0230RealLine)
        #expect(c.semver == HermesCapabilities.SemVer(major: 0, minor: 23, patch: 0))
        #expect(c.dateVersion == HermesCapabilities.DateVersion(year: 2026, month: 9, day: 24))
        #expect(c.detected)
        #expect(c.isV0230OrLater)
    }

    @Test func parseV0226Line() {
        let c = Self.caps(Self.v0226Line)
        #expect(c.semver == HermesCapabilities.SemVer(major: 0, minor: 22, patch: 6))
        #expect(c.isV0226OrLater)
        #expect(!c.isV0230OrLater)
    }

    // MARK: all-on

    @Test func v0230EveryNewFlagOn() {
        let c = Self.caps(Self.v0230RealLine)
        for (name, flag) in Self.allNewFlags {
            #expect(c[keyPath: flag], "\(name)")
        }
        // Older floors stay on.
        #expect(c.isV0225OrLater)
        #expect(c.hasCatalogSingularity)
        #expect(c.hasGatewayRewindCommands)
    }

    // MARK: floors

    @Test func v0226FloorOnlyOpensTheV0226Group() {
        let c = Self.caps(Self.v0226Line)
        for (name, flag) in Self.v0226Floors {
            #expect(c[keyPath: flag], "\(name)")
        }
        for (name, flag) in Self.v0230Floors {
            #expect(!c[keyPath: flag], "\(name)")
        }
    }

    @Test func v0227StillBelowTheV0230Group() {
        let c = Self.caps("Hermes Agent v0.22.7 (2026.9.24)")
        for (name, flag) in Self.v0230Floors {
            #expect(!c[keyPath: flag], "\(name)")
        }
    }

    // MARK: degradation

    @Test func v0225HostHasEveryVersionGatedNewFlagOff() {
        let c = Self.caps("Hermes Agent v0.22.5 (2026.9.24) · stable · local bf0203a794a0")
        for (name, flag) in Self.v0226Floors + Self.v0230Floors {
            #expect(!c[keyPath: flag], "\(name)")
        }
    }

    @Test func undetectedHostHidesEveryNewFlag() {
        for (name, flag) in Self.allNewFlags {
            #expect(!HermesCapabilities.empty[keyPath: flag], "\(name)")
        }
    }

    // MARK: patch-still-on

    @Test func laterPatchesKeepFlagsOn() {
        for line in ["Hermes Agent v0.23.1 (2026.9.24)", "Hermes Agent v0.24.0 (2026.9.24)"] {
            let c = Self.caps(line)
            for (name, flag) in Self.allNewFlags {
                #expect(c[keyPath: flag], "\(name) @ \(line)")
            }
        }
    }
}
