import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Pins the Mac app's config-read path to ScarfCore's canonical parser.
///
/// Regression guard for the Settings "dropdowns save but never show the
/// selected value" bug: `HermesFileService.parseConfig` was a duplicated
/// copy of `HermesConfig(yaml:)` and drifted — v0.17/v0.18 keys
/// (`web.search_backend`, `curator.consolidate`, `image_gen.model`, …)
/// were added only to the ScarfCore copy, so after every save the Mac
/// reload snapped those fields back to defaults and the Picker rendered
/// a stale/blank selection. `loadConfig()` now routes through
/// `HermesConfig(yaml:)`; these tests fail if a second mapping ever
/// reappears on the app side or the round-trip loses a key again.
///
/// The service-level assertion IS the VM/Picker contract:
/// `SettingsViewModel.setSetting` does `config = fileService.loadConfig()`
/// after a successful `hermes config set`, and every `PickerRow` reads
/// its `selection` straight off `viewModel.config`.
struct HermesFileServiceConfigParityTests {

    /// Shape mirrors a real v0.17 `~/.hermes/config.yaml` (the exact
    /// sections Hermes's YAML dumper emits), restricted to the keys the
    /// drifted Mac parser used to drop plus a few long-standing ones to
    /// prove the parser swap lost nothing.
    private static let fixtureYAML = """
    model:
      default: llama3.1:8b
      provider: ollama
      base_url: http://127.0.0.1:11434/v1
      context_length: 32768
    max_concurrent_sessions: 5
    display:
      personality: kawaii
      resume_display: minimal
      busy_input_mode: queue
      timestamps: true
      language: en
    terminal:
      backend: docker
      docker_extra_args:
        - --privileged
        - --network=host
    web:
      backend: tavily
      search_backend: firecrawl
      extract_backend: exa
    image_gen:
      model: dall-e-3
    openrouter:
      response_cache: true
    curator:
      consolidate: true
    platforms:
      telegram:
        extra:
          rich_messages: false
          status_indicator: true
      whatsapp_cloud:
        extra:
          phone_number_id: '123456'
          dm_policy: allowlist
    human_delay:
      mode: 'off'
    """

    private func loadFixture() throws -> (config: HermesConfig, cleanup: () -> Void) {
        let home = try TempHermesHome()
        try Self.fixtureYAML.write(
            toFile: home.context.paths.configYAML,
            atomically: true,
            encoding: .utf8
        )
        let config = HermesFileService(context: home.context).loadConfig()
        return (config, home.cleanup)
    }

    /// The dropdowns Alan hit: Web Tools search/extract/combined backends.
    /// Pre-fix the Mac parser read NO `web.*` key, so the pickers rendered
    /// a blank selection forever no matter what was saved.
    @Test func webToolsBackendsRoundTrip() throws {
        let (config, cleanup) = try loadFixture()
        defer { cleanup() }
        #expect(config.webToolsBackend == "tavily")
        #expect(config.webToolsSearchBackend == "firecrawl")
        #expect(config.webToolsExtractBackend == "exa")
    }

    /// The rest of the drifted key set — every Settings surface that
    /// saved-but-never-displayed on Mac.
    @Test func v017AndV018KeysRoundTrip() throws {
        let (config, cleanup) = try loadFixture()
        defer { cleanup() }
        #expect(config.curatorConsolidate == true)
        #expect(config.maxConcurrentSessions == 5)
        #expect(config.imageGenModel == "dall-e-3")
        #expect(config.openrouterResponseCacheEnabled == true)
        #expect(config.display.timestamps == true)
        #expect(config.terminal.dockerExtraArgs == ["--privileged", "--network=host"])
        #expect(config.telegram.richMessages == false)
        #expect(config.telegram.statusIndicator == true)
        #expect(config.whatsappCloud.phoneNumberID == "123456")
        #expect(config.whatsappCloud.dmPolicy == "allowlist")
    }

    /// Long-standing keys survive the parser swap (parity floor).
    @Test func classicKeysStillParse() throws {
        let (config, cleanup) = try loadFixture()
        defer { cleanup() }
        #expect(config.model == "llama3.1:8b")
        #expect(config.provider == "ollama")
        #expect(config.modelBaseURL == "http://127.0.0.1:11434/v1")
        #expect(config.modelContextLength == "32768")
        #expect(config.personality == "kawaii")
        #expect(config.display.resumeDisplay == "minimal")
        #expect(config.display.busyInputMode == "queue")
        #expect(config.display.language == "en")
        #expect(config.terminalBackend == "docker")
        #expect(config.humanDelay.mode == "off")
    }

    /// The save→reload flow the Settings pickers depend on: overwrite the
    /// file with a new value (what `hermes config set` does) and confirm a
    /// fresh `loadConfig()` — exactly what `setSetting` assigns back to
    /// `SettingsViewModel.config` — exposes the new selection.
    @Test func reloadAfterWriteExposesNewSelection() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let svc = HermesFileService(context: home.context)

        try "web:\n  search_backend: tavily\n".write(
            toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        #expect(svc.loadConfig().webToolsSearchBackend == "tavily")

        try "web:\n  search_backend: firecrawl\n".write(
            toFile: home.context.paths.configYAML, atomically: true, encoding: .utf8)
        #expect(svc.loadConfig().webToolsSearchBackend == "firecrawl")
    }
}
