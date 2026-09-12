import Testing
import Foundation
@testable import ScarfCore

/// Parser tests for the `hermes gateway list` text table (Hermes v0.16 has
/// no `--json` flag). Pure — no transport, no process calls.
@Suite struct HermesGatewayListServiceTests {

    @Test func parsesLiveSampleOneRunningTwoStopped() throws {
        // The exact live v0.16 output: 1 running default + 2 stopped.
        let text = """
        Gateways:
          ✓ default (current)        — PID 44417
          ✗ scarfbox-smoke           — not running
          ✗ scarfbox-test            — not running
        """
        let snap = HermesGatewayListService.parse(text)
        try #require(snap?.profiles.count == 3)

        #expect(snap?.profiles[0].profile == "default")
        #expect(snap?.profiles[0].isRunning == true)
        #expect(snap?.profiles[0].pid == 44417)
        
        #expect(snap?.profiles[1].profile == "scarfbox-smoke")
        #expect(snap?.profiles[1].isRunning == false)
        #expect(snap?.profiles[1].pid == nil)

        #expect(snap?.profiles[2].profile == "scarfbox-test")
        #expect(snap?.profiles[2].isRunning == false)
        #expect(snap?.profiles[2].pid == nil)
    }

    @Test func parsesSingleRunningProfile() throws {
        let text = """
        Gateways:
          ✓ default        — PID 1234
        """
        let snap = HermesGatewayListService.parse(text)
        try #require(snap?.profiles.count == 1)
        #expect(snap?.profiles[0].profile == "default")
        #expect(snap?.profiles[0].pid == 1234)
        #expect(snap?.profiles[0].isRunning == true)
            }

    @Test func parsesSingleStoppedProfile() throws {
        let text = """
        Gateways:
          ✗ default        — not running
        """
        let snap = HermesGatewayListService.parse(text)
        try #require(snap?.profiles.count == 1)
        #expect(snap?.profiles[0].profile == "default")
        #expect(snap?.profiles[0].isRunning == false)
        #expect(snap?.profiles[0].pid == nil)
    }

    @Test func stripsCurrentMarkerFromProfileName() {
        // A `(current)` marker after the profile name must not leak into it.
        let text = """
        Gateways:
          ✓ work (current)        — PID 99
        """
        let snap = HermesGatewayListService.parse(text)
        #expect(snap?.profiles[0].profile == "work")
        #expect(snap?.profiles[0].pid == 99)
    }

    @Test func returnsNilOnEmptyString() {
        #expect(HermesGatewayListService.parse("") == nil)
    }

    @Test func returnsNilOnWhitespaceOnly() {
        #expect(HermesGatewayListService.parse("   \n  \n") == nil)
    }

    @Test func returnsNilOnHeaderOnlyNoProfiles() {
        // Just the header, no profile rows → no recognizable entries → nil.
        #expect(HermesGatewayListService.parse("Gateways:\n") == nil)
    }

    @Test func returnsNilOnGarbageInput() {
        #expect(HermesGatewayListService.parse("this is not gateway output") == nil)
    }

    // MARK: - headerDigest

    @Test func headerDigestEmptyProfiles() {
        let snap = GatewayListSnapshot(profiles: [])
        #expect(snap.headerDigest == "no profiles configured")
    }

    @Test func headerDigestSingleProfileRunning() {
        let snap = GatewayListSnapshot(profiles: [
            .init(profile: "default", isRunning: true, pid: 100)
        ])
        #expect(snap.headerDigest == "default profile · running")
    }

    @Test func headerDigestSingleProfileStopped() {
        let snap = GatewayListSnapshot(profiles: [
            .init(profile: "default", isRunning: false, pid: nil)
        ])
        #expect(snap.headerDigest == "default profile · stopped")
    }

    @Test func headerDigestMultipleProfilesSomeRunning() {
        let snap = GatewayListSnapshot(profiles: [
            .init(profile: "work", isRunning: true, pid: 1),
            .init(profile: "home", isRunning: false, pid: nil),
            .init(profile: "extra", isRunning: true, pid: 2)
        ])
        // 3 profiles total, 2 running. No platform clause: `gateway list`
        // prints no platform column and has no `--json` form.
        #expect(snap.headerDigest == "3 profiles (2 running)")
    }

    @Test func headerDigestMultipleProfilesNoneRunning() {
        let snap = GatewayListSnapshot(profiles: [
            .init(profile: "a", isRunning: false, pid: nil),
            .init(profile: "b", isRunning: false, pid: nil)
        ])
        #expect(snap.headerDigest == "2 profiles (0 running)")
    }
}
