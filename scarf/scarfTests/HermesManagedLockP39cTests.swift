import Foundation
import Testing
@testable import scarf
@testable import ScarfCore

/// P39c — the second review of P39's read-only lock.
///
/// Two findings: the Secrets tab's whole-tab lock blacked out a READ
/// ("Check Status" + its selectable output panel), and the Advanced tab's
/// lock covered an app-local control that no Hermes ever refuses.
@Suite("P39c — the read-only lock covers writes only")
struct HermesManagedLockP39cTests {

    // MARK: - Which tabs may be blacked out wholesale

    /// The three tabs that carry a read the user still needs on a managed
    /// host lock their own write controls instead.
    @Test(arguments: [
        SettingsView.SettingsTab.advanced,
        SettingsView.SettingsTab.secrets,
        SettingsView.SettingsTab.security,
    ])
    func aTabWithAReadIsNotBlackedOutWholesale(_ tab: SettingsView.SettingsTab) {
        #expect(tab.locksWholeTabWhenManaged == false)
    }

    /// The remaining nine are write controls end to end, and the walk of all
    /// eleven non-Advanced tabs (P39c) found no copy / export / check /
    /// open-in-Finder / text-selection affordance in any of them.
    @Test func theWriteOnlyTabsStillLockWholesale() {
        let scoped: Set<SettingsView.SettingsTab> = [.advanced, .secrets, .security]
        let wholesale = SettingsView.SettingsTab.allCases.filter { !scoped.contains($0) }
        #expect(wholesale.count == 9)
        for tab in wholesale {
            #expect(tab.locksWholeTabWhenManaged, "\(tab) should still lock wholesale")
        }
    }

    /// No tab outside the scoped three may carry a read affordance inside its
    /// wholesale lock. `.disabled` reaches every descendant, so a new
    /// `textSelection` / Copy / Export / Reveal in one of these files is the
    /// shape that has to fail here rather than ship dark.
    @Test(arguments: [
        "AgentTab", "AuxiliaryTab", "BrowserTab", "DisplayTab", "GeneralTab",
        "MemoryTab", "TerminalTab", "VoiceTab", "WebToolsTab",
    ])
    func aWholesaleLockedTabCarriesNoReadAffordance(_ tab: String) throws {
        let source = try Self.source("scarf/Features/Settings/Views/Tabs/\(tab).swift")
        for affordance in [".textSelection(", "NSPasteboard", "NSWorkspace.shared.activateFileViewerSelecting", "ShareLink("] {
            #expect(source.contains(affordance) == false, "\(tab) grew \(affordance) inside a wholesale lock")
        }
    }

    // MARK: - Secrets: the write rows lock, the status read does not

    /// `bitwardenStatus()` shells `hermes secrets bitwarden status`, whose
    /// `cmd_status` (`hermes_cli/secrets_cli.py:248-282` @ v2026.9.7) calls
    /// `load_config()` and `find_bws(install_if_missing=False)` and writes
    /// nothing — no `save_config`, no `save_env_value`. The button and its
    /// `.textSelection` panel must sit AFTER the last section lock.
    @Test func theSecretsTabLocksItsWriteRowsAndNotItsStatusRead() throws {
        let source = try Self.source("scarf/Features/Settings/Views/Tabs/SecretsTab.swift")
        #expect(source.contains(".disabled(viewModel.isManagedHost)"))

        let lastLock = try #require(source.range(of: ".disabled(viewModel.isManagedHost)", options: .backwards))
        let check = try #require(source.range(of: "Button(\"Check Status\")"))
        let selection = try #require(source.range(of: ".textSelection(.enabled)"))
        #expect(check.lowerBound > lastLock.upperBound)
        #expect(selection.lowerBound > lastLock.upperBound)
    }

    // MARK: - Security: the Add button locks, the reads do not

    /// The only write in Allowlist Suggestions is the per-row Add
    /// (`approvals suggest --apply`, which rewrites `command_allowlist`); the
    /// proposal pattern next to it stays selectable.
    @Test func theSecurityTabLocksTheProposalWriteAndNotThePattern() throws {
        let source = try Self.source("scarf/Features/Settings/Views/Tabs/SecurityTab.swift")
        #expect(source.contains(".disabled(viewModel.applyingProposalN != nil || viewModel.isManagedHost)"))

        // The selectable pattern sits above the button's lock, inside the
        // same row, and is NOT covered by any section lock of its own.
        let selection = try #require(source.range(of: ".textSelection(.enabled)"))
        let rowLock = try #require(source.range(of: ".disabled(viewModel.applyingProposalN != nil || viewModel.isManagedHost)"))
        #expect(selection.lowerBound < rowLock.lowerBound)

        // And the two ReadOnlyRows — the only view of what the managed layer
        // pinned — are not inside a locked section.
        let domains = try #require(source.range(of: "ReadOnlyRow(label: \"Domains\""))
        let blocklistLock = try #require(source.range(of: "ToggleRow(label: \"Enabled\", isOn: viewModel.config.security.blocklistEnabled) { viewModel.setBlocklistEnabled($0) }\n                .disabled(viewModel.isManagedHost)"))
        #expect(domains.lowerBound > blocklistLock.upperBound)
    }

    // MARK: - Advanced: the app-local toggle is outside the lock

    /// `usageAnalyticsSection` is Scarf's own swift-stats `UserDefaults`
    /// state — it never reaches `HermesConfig` and never shells `config set`,
    /// so a managed Hermes has nothing to refuse. It sat inside the
    /// `Group{…}.disabled(isManagedHost)`, which made the one setting a
    /// managed host CAN change the one it could not.
    @Test func theAppLocalAnalyticsToggleIsOutsideTheAdvancedLock() throws {
        let source = try Self.source("scarf/Features/Settings/Views/Tabs/AdvancedTab.swift")
        let lock = try #require(source.range(of: ".disabled(viewModel.isManagedHost)\n"))
        let call = try #require(source.range(of: "\n        usageAnalyticsSection\n"))
        #expect(call.lowerBound > lock.upperBound)
    }

    // MARK: - Helpers

    static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: root.appendingPathComponent("scarf").appendingPathComponent(relative), encoding: .utf8)
    }
}
