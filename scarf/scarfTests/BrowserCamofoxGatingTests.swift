import Testing
import Foundation
import ScarfCore
@testable import scarf

/// S3 (t-78996849): Camofox left core and `browser.record_sessions` was
/// removed at v0.22.6; `auxiliary.skills_hub` was removed at v0.23.0.
@Suite struct BrowserCamofoxGatingTests {
    static let v0225 = HermesCapabilities.parseLine("Hermes Agent v0.22.5 (2026.9.24)")
    static let v0226 = HermesCapabilities.parseLine("Hermes Agent v0.22.6 (2026.10.8)")
    static let v0230 = HermesCapabilities.parseLine("Hermes Agent v0.23.0 (2026.11.1)")

    private let all: [(id: String, label: String)] = [
        ("", "Auto"), ("local", "Local"), ("camofox", "Camofox"),
    ]

    private func ids(_ caps: HermesCapabilities, current: String = "", installed: Bool?) -> [String] {
        BrowserTab.providerRows(all, capabilities: caps, current: current, camofoxInstalled: installed).map(\.id)
    }

    @Test func flagsFlipAtTheirReleases() {
        #expect(!Self.v0225.hasCamofoxLeftCore)
        #expect(Self.v0226.hasCamofoxLeftCore)
        #expect(Self.v0226.hasBrowserRecordSessionsRemoved)
        #expect(!Self.v0226.hasSkillsHubAuxRemoved)
        #expect(Self.v0230.hasSkillsHubAuxRemoved)
    }

    @Test func preV0226HostIsUnchanged() {
        for installed in [nil, false, true] as [Bool?] {
            #expect(ids(Self.v0225, installed: installed) == ["", "local", "camofox"])
            #expect(BrowserTab.showsCamofoxSection(capabilities: Self.v0225, camofoxInstalled: installed))
            #expect(!BrowserTab.showsCamofoxMissingNote(capabilities: Self.v0225, current: "camofox", camofoxInstalled: installed))
        }
        #expect(BrowserTab.showsRecordSessions(capabilities: Self.v0225))
        #expect(BrowserTab.showsRecordSessions(capabilities: .empty))
    }

    @Test func camofoxRowNeedsThePluginOnV0226() {
        #expect(ids(Self.v0226, installed: nil) == ["", "local"])
        #expect(ids(Self.v0226, installed: false) == ["", "local"])
        #expect(ids(Self.v0226, installed: true) == ["", "local", "camofox"])
        #expect(!BrowserTab.showsCamofoxSection(capabilities: Self.v0226, camofoxInstalled: false))
        #expect(!BrowserTab.showsCamofoxSection(capabilities: Self.v0226, camofoxInstalled: nil))
        #expect(BrowserTab.showsCamofoxSection(capabilities: Self.v0226, camofoxInstalled: true))
        #expect(!BrowserTab.showsRecordSessions(capabilities: Self.v0226))
    }

    @Test func storedCamofoxStaysVisibleWithNoteWhenPluginMissing() {
        #expect(ids(Self.v0226, current: "camofox", installed: false) == ["", "local", "camofox"])
        #expect(BrowserTab.showsCamofoxMissingNote(capabilities: Self.v0226, current: "camofox", camofoxInstalled: false))
        // No note before the roster lands, nor once the plugin is there.
        #expect(!BrowserTab.showsCamofoxMissingNote(capabilities: Self.v0226, current: "camofox", camofoxInstalled: nil))
        #expect(!BrowserTab.showsCamofoxMissingNote(capabilities: Self.v0226, current: "camofox", camofoxInstalled: true))
        #expect(!BrowserTab.showsCamofoxMissingNote(capabilities: Self.v0226, current: "local", camofoxInstalled: false))
    }

    @Test func skillsHubAuxRowGoneOnV0230Only() {
        #expect(AuxiliaryTab.tasks(capabilities: Self.v0226).map(\.key).contains("skills_hub"))
        #expect(!AuxiliaryTab.tasks(capabilities: Self.v0230).map(\.key).contains("skills_hub"))
        #expect(AuxiliaryTab.tasks(capabilities: nil).map(\.key).contains("skills_hub"))
    }
}
