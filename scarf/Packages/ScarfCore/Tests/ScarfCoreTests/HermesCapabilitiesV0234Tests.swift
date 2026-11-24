import Testing
import Foundation
@testable import ScarfCore

/// The v0.23.1–v0.23.4 patch floors. Each flag must be off one patch below
/// its floor, on at the floor, on at v0.23.4, and off on an undetected host.
@Suite struct HermesCapabilitiesV0234Tests {

    static func caps(_ semver: String) -> HermesCapabilities {
        HermesCapabilities.parseLine("Hermes Agent v\(semver) (2026.11.20) · stable · local abc1234def56")
    }

    /// (name, flag, first patch that has it)
    static var floors: [(String, KeyPath<HermesCapabilities, Bool>, Int)] { [
        ("isV0231OrLater", \.isV0231OrLater, 1),
        ("hasYuanbaoLeftCore", \.hasYuanbaoLeftCore, 1),
        ("isV0232OrLater", \.isV0232OrLater, 2),
        ("hasWebhookSignatureOption", \.hasWebhookSignatureOption, 2),
        ("hasWebhookMaskedSecret", \.hasWebhookMaskedSecret, 2),
        ("hasCronWrapResponse", \.hasCronWrapResponse, 2),
        ("hasGatewayRestartWhenIdle", \.hasGatewayRestartWhenIdle, 2),
        ("isV0233OrLater", \.isV0233OrLater, 3),
        ("hasPromptCacheTTLAutoDefault", \.hasPromptCacheTTLAutoDefault, 3),
    ] }

    @Test func parsesV0234() {
        let c = Self.caps("0.23.4")
        #expect(c.semver == HermesCapabilities.SemVer(major: 0, minor: 23, patch: 4))
        #expect(c.isV0233OrLater)
    }

    @Test(arguments: floors.map(\.0))
    func flagTurnsOnExactlyAtItsFloor(_ name: String) {
        let (_, flag, floor) = Self.floors.first { $0.0 == name }!
        #expect(!Self.caps("0.23.\(floor - 1)")[keyPath: flag], "\(name) on below its floor")
        #expect(Self.caps("0.23.\(floor)")[keyPath: flag], "\(name) off at its floor")
        #expect(Self.caps("0.23.4")[keyPath: flag], "\(name) off at v0.23.4")
        #expect(Self.caps("0.24.0")[keyPath: flag], "\(name) off on a later minor")
    }

    @Test func olderAndUndetectedHostsHideAll() {
        for (name, flag, _) in Self.floors {
            #expect(!Self.caps("0.22.6")[keyPath: flag], "\(name) on at v0.22.6")
            #expect(!HermesCapabilities.empty[keyPath: flag], "\(name) on when undetected")
        }
    }
}
