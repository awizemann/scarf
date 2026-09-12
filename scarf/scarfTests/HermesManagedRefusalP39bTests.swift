import Foundation
import Testing
@testable import scarf
@testable import ScarfCore

/// The Mac half of the round-4 review of P39.
@Suite("P39b — the scoped read-only lock and the partial-write banner")
struct HermesManagedLockP39bTests {

    // MARK: - The lock's blast radius (round-4 finding 3)

    /// `.disabled` reaches EVERY descendant, so the tab-wide lock P39 shipped
    /// took the Advanced tab's reads down with its writes: Config
    /// Diagnostics' "Check" (`_cmd_config_check` mutates nothing,
    /// `hermes_cli/config.py:3693-3720`), "Backup Now", the Raw Config
    /// show/hide disclosure, ScarfMon's "Copy as JSON", and the text
    /// selection in each of their output panels. A managed host has more
    /// reason to read its own config than any other.
    @Test func theAdvancedTabIsNotBlackedOutWholesale() {
        #expect(SettingsView.SettingsTab.advanced.locksWholeTabWhenManaged == false)
    }

    /// The tabs that are write controls end to end still take the cheap
    /// wholesale lock. `.secrets` and `.security` joined `.advanced` in the
    /// exempt set in P39c — each carries a READ (see
    /// `HermesManagedLockP39cTests`), and this assertion used to claim the
    /// opposite of what the Secrets tab needed.
    @Test func everyOtherTabStillLocksWholesale() {
        let scoped: Set<SettingsView.SettingsTab> = [.advanced, .secrets, .security]
        for tab in SettingsView.SettingsTab.allCases where !scoped.contains(tab) {
            #expect(tab.locksWholeTabWhenManaged, "\(tab) should still lock wholesale")
        }
    }

    /// The `.disabled` in `SettingsView` is the one that used to be
    /// unconditional. Scanned, because the modifier itself is not reachable
    /// from a view model.
    @Test func theSettingsPaneLockIsQualifiedBySelectedTab() throws {
        let source = try Self.source("scarf/Features/Settings/Views/SettingsView.swift")
        #expect(source.contains(".disabled(viewModel.isManagedHost && selectedTab.locksWholeTabWhenManaged)"))
        #expect(source.contains(".disabled(viewModel.isManagedHost)\n") == false)
    }

    /// And the Advanced tab carries the lock itself, over its write controls:
    /// the Group of toggles, `config migrate` (which DOES reach `save_config`,
    /// `hermes_cli/config.py:3653`) and Restore. Not over Check or Backup Now.
    @Test func theAdvancedTabLocksItsOwnWriteControls() throws {
        let source = try Self.source("scarf/Features/Settings/Views/Tabs/AdvancedTab.swift")
        #expect(source.contains(".disabled(viewModel.isManagedHost)"))
        #expect(source.contains(".disabled(viewModel.backupInProgress || viewModel.isManagedHost)"))

        // "Check" and "Backup Now" must sit BELOW the locked Group.
        let lock = try #require(source.range(of: ".disabled(viewModel.isManagedHost)\n"))
        let check = try #require(source.range(of: "Button(\"Check\")"))
        let backup = try #require(source.range(of: "Label(\"Backup Now\""))
        let raw = try #require(source.range(of: "private var rawConfigSection"))
        let scarfMon = try #require(source.range(of: "ScarfMonDiagnosticsSection()"))
        #expect(check.lowerBound > lock.upperBound)
        #expect(backup.lowerBound > lock.upperBound)
        #expect(raw.lowerBound > lock.upperBound)
        #expect(scarfMon.lowerBound > lock.upperBound)
    }

    // MARK: - The partial write reaches the banner (round-4 finding 4)

    /// A refused `.env` mirror is a SUCCESS carrying a warning, and the
    /// warning is what the banner says — not the bare "Saved <key>" that
    /// would hide it.
    @Test func aPartialWriteBannersTheWarningRatherThanABareSaved() throws {
        let outcome = HermesConfigSet.judge(
            output: """
            Cannot set TERMINAL_ENV: it is managed by your administrator (/etc/hermes/.env) and cannot be changed.
            ✓ Set terminal.env = tmux in /Users/a/.hermes/config.yaml
            """,
            exitCode: 0
        )
        #expect(outcome.succeeded)
        let warning = try #require(outcome.warning)
        #expect(warning.contains("Cannot set TERMINAL_ENV"))

        let source = try Self.source("scarf/Features/Settings/ViewModels/SettingsViewModel.swift")
        #expect(source.contains("outcome.warning"))
    }

    /// A plain write still gets the plain sentence.
    @Test func aCleanWriteCarriesNoWarning() {
        let outcome = HermesConfigSet.judge(
            output: "✓ Set display.streaming = true in /Users/a/.hermes/config.yaml",
            exitCode: 0
        )
        #expect(outcome.succeeded)
        #expect(outcome.warning == nil)
    }

    // MARK: - The new strings are in the catalogue (round-4 finding 6)

    @Test(arguments: [
        "This Hermes is managed by %@. Settings are read-only here — edit them through your package manager's configuration and re-deploy.",
        "This Hermes installation is managed; settings are read-only",
        "Saved to config.yaml; the .env mirror was refused: %@",
    ])
    func theNewStringsAreInTheCatalogueInAllSixLocales(_ key: String) throws {
        let url = Self.repoRoot.appendingPathComponent("scarf/scarf/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any])
        let locs = try #require(entry["localizations"] as? [String: Any])
        for locale in ["de", "es", "fr", "ja", "pt-BR", "zh-Hans"] {
            #expect(locs[locale] != nil, "\(key) is missing \(locale)")
        }
    }

    // MARK: - Helpers

    static func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("scarf").appendingPathComponent(relative), encoding: .utf8)
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // scarfTests
            .deletingLastPathComponent()   // scarf
            .deletingLastPathComponent()   // repo root
    }
}
