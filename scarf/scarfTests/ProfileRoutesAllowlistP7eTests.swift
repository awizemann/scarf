import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P7e item 1: `gateway.multiplex_profile_allowlist` is a WINDOW
/// (v0.20.1 – v0.21.2), not the audit's guessed `≥0.20.4` floor — the key
/// is removed by migration 43 at v0.21.3 (`config_migrations.py:640-649`
/// @ v2026.9.14) and every reader is gone in that same release. Below the
/// window the key was never read either. `SettingsViewModel.multiplexProfileAllowlistWarning`
/// must therefore stay silent outside `HermesCapabilities.hasMultiplexProfileAllowlist`,
/// whatever a stale `config.yaml` still contains.
@Suite struct ProfileRoutesAllowlistP7eTests {

    private static func caps(_ version: String) -> HermesCapabilities {
        HermesCapabilities.parse("Hermes Agent v\(version) (2026.1.1)")
    }

    @MainActor
    private static func vm(allowlist: [String]?) -> SettingsViewModel {
        let vm = SettingsViewModel()
        vm.config.multiplexProfileAllowlist = allowlist
        return vm
    }

    @Test func warningFiresInsideTheWindow() async {
        let warning = await MainActor.run {
            Self.vm(allowlist: ["worker"]).multiplexProfileAllowlistWarning(
                for: "other", capabilities: Self.caps("0.21.2"))
        }
        #expect(warning != nil)
        #expect(warning?.contains("other") == true)
    }

    @Test func warningIsSilentBelowTheFloor() async {
        let warning = await MainActor.run {
            Self.vm(allowlist: ["worker"]).multiplexProfileAllowlistWarning(
                for: "other", capabilities: Self.caps("0.20.0"))
        }
        #expect(warning == nil)
    }

    /// The regression this item exists to fix: v0.21.3+ deleted the key and
    /// stopped reading it, so the warning must not fire there even though a
    /// pre-migration config.yaml can still carry a stale allowlist.
    @Test func warningIsSilentAtAndAboveTheCeiling() async {
        for version in ["0.21.3", "0.21.4", "0.21.5"] {
            let warning = await MainActor.run {
                Self.vm(allowlist: ["worker"]).multiplexProfileAllowlistWarning(
                    for: "other", capabilities: Self.caps(version))
            }
            #expect(warning == nil, "expected silence at \(version)")
        }
    }

    @Test func defaultProfileIsAlwaysExempt() async {
        let warning = await MainActor.run {
            Self.vm(allowlist: ["worker"]).multiplexProfileAllowlistWarning(
                for: "default", capabilities: Self.caps("0.21.2"))
        }
        #expect(warning == nil)
    }

    @Test func nilAllowlistIsAlwaysSilent() async {
        let warning = await MainActor.run {
            Self.vm(allowlist: nil).multiplexProfileAllowlistWarning(
                for: "other", capabilities: Self.caps("0.21.2"))
        }
        #expect(warning == nil)
    }
}
