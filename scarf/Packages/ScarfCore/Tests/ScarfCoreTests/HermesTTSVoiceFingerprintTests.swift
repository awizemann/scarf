import Testing
import Foundation
@testable import ScarfCore

/// t-eb402e82: `HermesSpeechService.voiceFingerprint` used to track only the
/// handful of `tts.*` keys `VoiceSettings` has a typed field for, so it was
/// blind to the GLOBAL `tts.speed` (applies under every provider) and to
/// `tts.providers.<name>.*` sub-settings for command/plugin providers, which
/// fell into the `default: return provider` branch and keyed on the
/// provider name alone. Changing either kept `HermesTTSCache` serving
/// already-cached audio for previously-spoken text instead of
/// re-synthesizing with the new voice.
///
/// The fix folds `HermesConfig.voice.ttsSectionFingerprint` — a SHA-256 hash
/// of the ENTIRE parsed `tts:` section, built by
/// `HermesYAML.ttsSectionFingerprint` — into every cache key, so an edit
/// anywhere under `tts:` invalidates the cache regardless of whether Scarf
/// has a typed field for that particular key.
@Suite("HermesTTSCache voice fingerprint covers the whole tts: section")
struct HermesTTSVoiceFingerprintTests {

    private func yaml(_ ttsBlock: String) -> String {
        "tts:\n\(ttsBlock)\n"
    }

    // MARK: - HermesYAML.ttsSectionFingerprint

    @Test("a change to the global tts.speed key changes the fingerprint")
    func globalSpeedChangesFingerprint() {
        let a = HermesConfig(yaml: yaml("  provider: edge\n  speed: 1.0\n"))
        let b = HermesConfig(yaml: yaml("  provider: edge\n  speed: 1.5\n"))
        #expect(a.voice.ttsSectionFingerprint != b.voice.ttsSectionFingerprint)
    }

    @Test("a change to a command provider's sub-settings changes the fingerprint")
    func commandProviderSubSettingsChangeFingerprint() {
        let a = HermesConfig(yaml: yaml("""
              provider: mycommand
              providers:
                mycommand:
                  command: /usr/local/bin/say-v1
            """))
        let b = HermesConfig(yaml: yaml("""
              provider: mycommand
              providers:
                mycommand:
                  command: /usr/local/bin/say-v2
            """))
        #expect(a.voice.ttsSectionFingerprint != b.voice.ttsSectionFingerprint)
    }

    @Test("the same config serialized with keys in a different order fingerprints identically")
    func keyOrderDoesNotAffectFingerprint() {
        let a = HermesConfig(yaml: yaml("""
              provider: edge
              speed: 1.2
              edge:
                voice: en-US-AriaNeural
            """))
        let b = HermesConfig(yaml: yaml("""
              edge:
                voice: en-US-AriaNeural
              speed: 1.2
              provider: edge
            """))
        #expect(a.voice.ttsSectionFingerprint == b.voice.ttsSectionFingerprint)
        #expect(!a.voice.ttsSectionFingerprint.isEmpty)
    }

    @Test("HermesYAML.ttsSectionFingerprint ignores non-tts keys")
    func nonTTSKeysDoNotAffectFingerprint() {
        let a = HermesYAML.ttsSectionFingerprint(
            values: ["tts.provider": "edge", "stt.provider": "local"],
            lists: [:],
            maps: [:]
        )
        let b = HermesYAML.ttsSectionFingerprint(
            values: ["tts.provider": "edge", "stt.provider": "openai"],
            lists: [:],
            maps: [:]
        )
        #expect(a == b)
    }

    // MARK: - HermesSpeechService.voiceFingerprint end-to-end

    @Test("voiceFingerprint changes when only tts.speed changes, for a known provider")
    func voiceFingerprintChangesOnGlobalSpeedForEdgeProvider() {
        let configA = HermesConfig(yaml: yaml("  provider: edge\n  speed: 1.0\n  edge:\n    voice: en-US-AriaNeural\n"))
        let configB = HermesConfig(yaml: yaml("  provider: edge\n  speed: 1.5\n  edge:\n    voice: en-US-AriaNeural\n"))
        let fpA = HermesSpeechService.voiceFingerprint(provider: "edge", voice: configA.voice)
        let fpB = HermesSpeechService.voiceFingerprint(provider: "edge", voice: configB.voice)
        #expect(fpA != fpB, "changing only the global tts.speed must invalidate the cache")
    }

    @Test("voiceFingerprint changes when a command provider's own settings change")
    func voiceFingerprintChangesForCommandProviderSettings() {
        let configA = HermesConfig(yaml: yaml("""
              provider: mycommand
              providers:
                mycommand:
                  command: /usr/local/bin/say-v1
            """))
        let configB = HermesConfig(yaml: yaml("""
              provider: mycommand
              providers:
                mycommand:
                  command: /usr/local/bin/say-v2
            """))
        let fpA = HermesSpeechService.voiceFingerprint(provider: "mycommand", voice: configA.voice)
        let fpB = HermesSpeechService.voiceFingerprint(provider: "mycommand", voice: configB.voice)
        #expect(fpA != fpB, "editing a command provider's own config must invalidate the cache")
    }

    @Test("HermesTTSCache.cacheKey differs when only the section fingerprint differs")
    func cacheKeyDiffersOnFingerprintAlone() {
        let keyA = HermesTTSCache.cacheKey(
            server: "server", provider: "mycommand", voiceFingerprint: "mycommand|tts:aaa", text: "hello"
        )
        let keyB = HermesTTSCache.cacheKey(
            server: "server", provider: "mycommand", voiceFingerprint: "mycommand|tts:bbb", text: "hello"
        )
        #expect(keyA != keyB)
    }
}
