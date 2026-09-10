import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Whole-surface audit P20 — the Mac-target half: the two writers whose key
/// choice was wrong, and the two voice pickers whose rosters were short.
///
/// Hermes claims verified at tag `v2026.9.7`, with floors walked across all 32
/// `v2026.*` tags.
@Suite struct SettingsP20ConfigDefaultsTests {

    private static func caps(_ version: String) -> HermesCapabilities {
        HermesCapabilities.parse("Hermes Agent v\(version) (2026.1.1)")
    }

    // MARK: - `multiplex_profiles` writes to the key in effect

    /// `GatewayConfig.from_dict` resolves this as `data.get("multiplex_profiles")`
    /// and only falls through to `nested_gateway.get(...)` when that is `None`
    /// (`gateway/config.py:708-710` @ v2026.9.7). So with a non-null top-level
    /// key present, unconditionally writing `gateway.multiplex_profiles`
    /// changed a key the host never reads: the save toast said "Saved" and
    /// routing stayed off.
    ///
    /// Fails before P20, which always returned the `gateway.` spelling.
    @Test func multiplexWriteTargetsTheKeyInEffect() {
        #expect(SettingsViewModel.multiplexProfilesKey(isTopLevel: true) == "multiplex_profiles")
        #expect(SettingsViewModel.multiplexProfilesKey(isTopLevel: false) == "gateway.multiplex_profiles")
    }

    /// End to end through the parser: the shape that used to be a dead end
    /// (top-level key set, `gateway.` key written) now routes to the top-level
    /// spelling, and a config with only the nested spelling still routes there.
    @Test func multiplexWriteTargetFollowsTheParsedConfig() {
        let topLevel = HermesConfig(yaml: "multiplex_profiles: false\n")
        #expect(SettingsViewModel.multiplexProfilesKey(
            isTopLevel: topLevel.profileRoutes.multiplexIsTopLevel
        ) == "multiplex_profiles")

        let nested = HermesConfig(yaml: "gateway:\n  multiplex_profiles: false\n")
        #expect(SettingsViewModel.multiplexProfilesKey(
            isTopLevel: nested.profileRoutes.multiplexIsTopLevel
        ) == "gateway.multiplex_profiles")

        // A NULL top-level key is not "in effect" — Hermes falls through to
        // the nested one — so the write must too.
        let nulled = HermesConfig(yaml: "multiplex_profiles: null\ngateway:\n  multiplex_profiles: false\n")
        #expect(SettingsViewModel.multiplexProfilesKey(
            isTopLevel: nulled.profileRoutes.multiplexIsTopLevel
        ) == "gateway.multiplex_profiles")
    }

    // MARK: - Voice provider rosters (product decision 4)

    /// Hermes's `BUILTIN_TTS_PROVIDERS`
    /// (`tools/tts_command_provider.py:269` @ v2026.9.7) carries eleven names;
    /// Scarf's picker offered nine, so a config pinned to `gemini` or
    /// `kittentts` had no selectable row. Both have been in the roster since
    /// tag v2026.4.23 (v0.11.0) — neither name occurs in `tools/tts_tool.py`
    /// at v2026.4.16 (v0.10.0) — so they are floor-gated at v0.11.0, and
    /// `deepinfra` at v0.19.0 (v2026.7.20).
    @Test func ttsRosterMatchesHermesBuiltinsOnATargetHost() {
        let all = SettingsViewModel.ttsProviders(capabilities: Self.caps("0.21.1"))
        #expect(Set(all) == Set([
            "edge", "elevenlabs", "openai", "minimax", "mistral",
            "neutts", "piper", "xai", "gemini", "kittentts", "deepinfra",
        ]))
    }

    /// C1: a pre-floor host must not be offered a provider it cannot dispatch.
    @Test func ttsRosterIsFloorGated() {
        let old = SettingsViewModel.ttsProviders(capabilities: Self.caps("0.10.0"))
        #expect(!old.contains("gemini"))
        #expect(!old.contains("kittentts"))
        #expect(!old.contains("deepinfra"))
        let v011 = SettingsViewModel.ttsProviders(capabilities: Self.caps("0.11.0"))
        #expect(v011.contains("gemini"))
        #expect(v011.contains("kittentts"))
        #expect(!v011.contains("deepinfra"))
        // An UNDETECTED host is below every floor.
        let unknown = SettingsViewModel.ttsProviders(capabilities: .empty)
        #expect(!unknown.contains("gemini"))
    }

    /// The existing picker convention: a stored value outside the roster is
    /// APPENDED rather than dropped, so a plugin-registered provider
    /// (`PluginContext.register_tts_provider`) renders as a real selection
    /// instead of a blank the next save would overwrite.
    @Test func ttsRosterAppendsAnUnrecognisedStoredValue() {
        let out = SettingsViewModel.ttsProviders(
            capabilities: Self.caps("0.21.1"), current: "my-plugin-tts"
        )
        #expect(out.last == "my-plugin-tts")
        // A recognised value is not duplicated.
        let dedup = SettingsViewModel.ttsProviders(capabilities: Self.caps("0.21.1"), current: "edge")
        #expect(dedup.filter { $0 == "edge" }.count == 1)
    }

    /// `BUILTIN_STT_PROVIDERS` (`tools/transcription_common.py:45` @
    /// v2026.9.7) gains `elevenlabs` and `deepinfra` at tag v2026.7.20
    /// (v0.19.0); v2026.7.7.2 (v0.18.2) has neither.
    @Test func sttRosterAddsTheV019CloudProvidersBehindTheirFloor() {
        let target = SettingsViewModel.sttProviders(capabilities: Self.caps("0.21.1")).map(\.id)
        #expect(target.contains("elevenlabs"))
        #expect(target.contains("deepinfra"))
        let old = SettingsViewModel.sttProviders(capabilities: Self.caps("0.18.2")).map(\.id)
        #expect(!old.contains("elevenlabs"))
        #expect(!old.contains("deepinfra"))
        // `local_command` is a mechanism, not a pickable provider.
        #expect(!target.contains("local_command"))
        // The "Auto (unset)" row stays first on every host.
        #expect(target.first == "")
    }

    /// Same append rule as the TTS picker.
    @Test func sttRosterAppendsAnUnrecognisedStoredValue() {
        let out = SettingsViewModel.sttProviders(
            capabilities: Self.caps("0.21.1"), current: "my-plugin-stt"
        )
        #expect(out.last?.id == "my-plugin-stt")
        #expect(out.last?.label == "my-plugin-stt")
    }
}
