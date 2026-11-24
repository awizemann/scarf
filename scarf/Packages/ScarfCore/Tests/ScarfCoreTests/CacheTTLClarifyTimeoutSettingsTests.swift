import Testing
import Foundation
@testable import ScarfCore

/// `prompt_caching.cache_ttl` and `agent.clarify_timeout`: a present value is
/// shown verbatim; an absent key shows the host's own default for its version.
@Suite struct CacheTTLClarifyTimeoutSettingsTests {

    static func caps(_ semver: String) -> HermesCapabilities {
        HermesCapabilities.parseLine("Hermes Agent v\(semver) (2026.11.20) · stable · local abc1234def56")
    }

    static let empty = HermesConfig(yaml: "model:\n  default: x\n")

    @Test(arguments: [
        ("0.12.0", "5m"), ("0.21.5", "5m"), ("0.23.2", "5m"),
        ("0.23.3", "auto"), ("0.23.4", "auto"),
    ])
    func absentCacheTTLShowsHostDefault(_ v: String, _ expected: String) {
        #expect(Self.empty.cacheTTL == "")
        #expect(Self.empty.displayCacheTTL(capabilities: Self.caps(v)) == expected)
    }

    @Test func undetectedHostKeepsOldDefaultAndOptions() {
        #expect(Self.empty.displayCacheTTL(capabilities: .empty) == "5m")
        #expect(Self.empty.cacheTTLOptions(capabilities: .empty) == ["5m", "1h"])
    }

    @Test func presentCacheTTLWinsAndCommentIsStripped() {
        let c = HermesConfig(yaml: "prompt_caching:\n  cache_ttl: \"1h\"  # long\n")
        #expect(c.displayCacheTTL(capabilities: Self.caps("0.23.4")) == "1h")
    }

    @Test(arguments: [
        ("0.21.5", ["5m", "1h"]),
        ("0.23.2", ["5m", "1h"]),
        ("0.23.3", ["5m", "1h", "auto"]),
        ("0.23.4", ["5m", "1h", "auto"]),
    ])
    func pickerOptionsPerVersion(_ v: String, _ expected: [String]) {
        #expect(Self.empty.cacheTTLOptions(capabilities: Self.caps(v)) == expected)
    }

    /// A host whose config says "auto" below the auto floor (or any
    /// hand-written value) must not render a blank picker.
    @Test func presentValueOutsideOptionsIsOffered() {
        let c = HermesConfig(yaml: "prompt_caching:\n  cache_ttl: auto\n")
        let caps = Self.caps("0.21.4")
        #expect(c.displayCacheTTL(capabilities: caps) == "auto")
        #expect(c.cacheTTLOptions(capabilities: caps).contains("auto"))
    }

    @Test(arguments: [
        ("0.14.0", 600), ("0.17.0", 600), ("0.18.0", 3600),
        ("0.23.0", 3600), ("0.23.1", 90), ("0.23.4", 90),
    ])
    func absentClarifyTimeoutShowsHostDefault(_ v: String, _ expected: Int) {
        #expect(Self.empty.clarifyTimeout == nil)
        #expect(Self.empty.displayClarifyTimeout(capabilities: Self.caps(v)) == expected)
    }

    @Test func presentClarifyTimeoutWins() {
        let c = HermesConfig(yaml: "agent:\n  clarify_timeout: 300\n")
        #expect(c.clarifyTimeout == 300)
        #expect(c.displayClarifyTimeout(capabilities: Self.caps("0.23.4")) == 300)
    }

    @Test(arguments: [("0.14.0", false), ("0.23.0", false), ("0.23.1", true), ("0.23.4", true)])
    func clarifyTimeoutFieldFloor(_ v: String, _ shown: Bool) {
        #expect(Self.caps(v).hasClarifyTimeout == shown)
        #expect(HermesCapabilities.empty.hasClarifyTimeout == false)
    }

    @Test(arguments: [("0.21.5", false), ("0.23.2", false), ("0.23.3", true)])
    func autoAcceptedFloor(_ v: String, _ on: Bool) {
        #expect(Self.caps(v).hasPromptCacheTTLAuto == on)
    }

    @Test func legacyKeyWinsAndIsWrittenFromV0191() {
        let c = HermesConfig(yaml: "agent:\n  clarify_timeout: 300\nclarify:\n  timeout: 120\n")
        let new = Self.caps("0.19.1"), old = Self.caps("0.19.0")
        #expect(c.displayClarifyTimeout(capabilities: new) == 120)
        #expect(c.clarifyTimeoutConfigKey(capabilities: new) == "clarify.timeout")
        #expect(c.displayClarifyTimeout(capabilities: old) == 300)
        #expect(c.clarifyTimeoutConfigKey(capabilities: old) == "agent.clarify_timeout")
        #expect(c.clarifyTimeoutConfigKey(capabilities: .empty) == "agent.clarify_timeout")
    }

    @Test func withoutLegacyKeyWritesAgentKey() {
        let c = HermesConfig(yaml: "agent:\n  clarify_timeout: 300\n")
        #expect(c.clarifyTimeoutConfigKey(capabilities: Self.caps("0.23.4")) == "agent.clarify_timeout")
    }

    @Test(arguments: [("0", 0), ("-1", 0)])
    func nonPositiveMeansUnlimitedFromV0191(_ raw: String, _ shown: Int) {
        let c = HermesConfig(yaml: "agent:\n  clarify_timeout: \(raw)\n")
        #expect(c.displayClarifyTimeout(capabilities: Self.caps("0.23.4")) == shown)
        #expect(Self.caps("0.19.1").hasClarifyTimeoutResolver)
        #expect(!Self.caps("0.19.0").hasClarifyTimeoutResolver)
    }
}
