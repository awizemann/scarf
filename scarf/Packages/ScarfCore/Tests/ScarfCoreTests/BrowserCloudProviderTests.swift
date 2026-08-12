import Testing
import Foundation
@testable import ScarfCore

/// `browser.cloud_provider` — the real Hermes browser provider-selection key.
///
/// Scarf <= 2.18.1 read and wrote `browser.backend`, which has never been a
/// Hermes config key in any released version (verified by grepping every
/// `v2026.*` tag of the Hermes repo). `browser.cloud_provider` has existed
/// since Hermes v0.4.0 (`v2026.3.23`), below Scarf's minimum supported host,
/// so the key needs no capability gate.
@Suite("browser.cloud_provider")
struct BrowserCloudProviderTests {

    @Test func readsRealKey() {
        let cfg = HermesConfig(yaml: """
        browser:
          cloud_provider: browserbase
        """)
        #expect(cfg.browserCloudProvider == "browserbase")
    }

    /// Every provider id Hermes accepts must survive the round trip verbatim,
    /// including the hyphen in `browser-use` (the plugin's `provider.name`).
    @Test(arguments: ["local", "camofox", "browser-use", "browserbase", "firecrawl"])
    func roundTripsEveryValidProviderId(_ id: String) {
        let cfg = HermesConfig(yaml: """
        browser:
          cloud_provider: \(id)
        """)
        #expect(cfg.browserCloudProvider == id)
    }

    @Test func quotedValueIsUnquoted() {
        let cfg = HermesConfig(yaml: """
        browser:
          cloud_provider: "browser-use"
        """)
        #expect(cfg.browserCloudProvider == "browser-use")
    }

    /// Unset is NOT `local`: with the key absent Hermes auto-detects
    /// (Browser Use, then Browserbase, by credentials). The empty string must
    /// therefore stay distinguishable from an explicit `local`.
    @Test func unsetKeyIsEmptyNotLocal() {
        let cfg = HermesConfig(yaml: """
        browser:
          inactivity_timeout: 60
        """)
        #expect(cfg.browserCloudProvider == "")
        #expect(cfg.browser.inactivityTimeout == 60)
    }

    @Test func emptyConfigIsEmptyProvider() {
        #expect(HermesConfig(yaml: "").browserCloudProvider == "")
        #expect(HermesConfig.empty.browserCloudProvider == "")
    }

    /// The legacy Scarf-invented `browser.backend` is deliberately NOT read
    /// back. Hermes ignores it entirely, so surfacing it in the picker would
    /// show an inert value as if it were the live provider.
    @Test func legacyScarfBackendKeyIsIgnored() {
        let cfg = HermesConfig(yaml: """
        browser:
          backend: firecrawl
        """)
        #expect(cfg.browserCloudProvider == "")
    }

    /// A config carrying both keys (a user upgrading from an old Scarf) must
    /// report only what Hermes will actually honour.
    @Test func realKeyWinsWhenBothPresent() {
        let cfg = HermesConfig(yaml: """
        browser:
          backend: browseruse
          cloud_provider: local
        """)
        #expect(cfg.browserCloudProvider == "local")
    }

    /// `browser.cloud_provider` must not disturb the sibling `browser:` keys
    /// that share the block.
    @Test func siblingBrowserKeysStillParse() {
        let cfg = HermesConfig(yaml: """
        browser:
          cloud_provider: camofox
          command_timeout: 45
          record_sessions: true
          allow_private_urls: true
          camofox:
            managed_persistence: true
        """)
        #expect(cfg.browserCloudProvider == "camofox")
        #expect(cfg.browser.commandTimeout == 45)
        #expect(cfg.browser.recordSessions)
        #expect(cfg.browser.allowPrivateURLs)
        #expect(cfg.browser.camofoxManagedPersistence)
    }

    /// A present-but-empty value parses to `""`, indistinguishable from an
    /// absent key at the model layer — which is exactly why the write path
    /// must never produce it (Hermes normalizes it to `local`).
    @Test func presentButEmptyValueParsesAsEmpty() {
        let cfg = HermesConfig(yaml: """
        browser:
          cloud_provider: ""
        """)
        #expect(cfg.browserCloudProvider == "")
    }

    // MARK: - `hermes config unset` capability (v0.19+)

    /// The "auto-detect" row removes the key, and `hermes config unset`
    /// only exists on v0.19+ (Hermes 53adb3fd97, first shipped in
    /// v2026.7.20 = 0.19.0).
    @Test func configUnsetIsGatedAtV019() {
        func caps(_ v: String) -> HermesCapabilities {
            HermesCapabilities.parseLine("Hermes Agent v\(v)")
        }
        #expect(caps("0.18.9").hasConfigUnset == false)
        #expect(caps("0.19.0").hasConfigUnset == true)
        #expect(caps("0.20.0").hasConfigUnset == true)
        // Unknown version → conservative false, so the row hides rather than
        // issuing a command the host may not have.
        #expect(HermesCapabilities.empty.hasConfigUnset == false)
    }

    /// An unknown value (typo, uninstalled third-party plugin) is passed
    /// through rather than coerced — Hermes warns and auto-detects, and Scarf
    /// must not silently rewrite the user's file contents in the model.
    @Test func unknownProviderIsPreserved() {
        let cfg = HermesConfig(yaml: """
        browser:
          cloud_provider: some-third-party
        """)
        #expect(cfg.browserCloudProvider == "some-third-party")
    }
}
