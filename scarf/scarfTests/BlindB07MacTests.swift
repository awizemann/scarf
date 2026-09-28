import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Blind re-audit phase B07, Mac side: the Terminal settings pickers
/// (S05-F1, S05-F2) and the honest Hermes Voice fallback (S14-F1 / S03-F1).
@Suite struct BlindB07MacTests {

    // MARK: - S05-F1 Modal mode

    /// Hermes accepts exactly auto/direct/managed
    /// (tools/tool_backend_helpers.py:14-15 @ v2026.9.24); anything else is
    /// coerced to auto, so always/never must not be offered.
    @Test func modalModeOffersHermessOwnValues() {
        #expect(SettingsViewModel.modalModes(current: "auto") == ["auto", "direct", "managed"])
        #expect(SettingsViewModel.modalModes(current: "managed") == ["auto", "direct", "managed"])
        #expect(!SettingsViewModel.modalModes().contains("always"))
        #expect(!SettingsViewModel.modalModes().contains("never"))
        // A value an older Scarf wrote stays visible rather than blank.
        #expect(SettingsViewModel.modalModes(current: "never") == ["auto", "direct", "managed", "never"])
    }

    // MARK: - S05-F2 Vercel Sandbox backend

    @Test func terminalBackendsFollowTheVercelBands() {
        let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")
        let v0190 = HermesCapabilities.parseLine("Hermes Agent v0.19.0 (2026.7.20)")
        let base = ["local", "docker", "singularity", "modal", "daytona", "ssh"]
        #expect(SettingsViewModel.terminalBackends(capabilities: v0215, current: "local") == base + ["vercel_sandbox"])
        #expect(SettingsViewModel.terminalBackends(capabilities: v0190, current: "local") == base)
        // Unknown version keeps the prior list (C1).
        #expect(SettingsViewModel.terminalBackends(capabilities: .empty, current: "local") == base)
        // A stored backend the list does not name (a plugin backend, or
        // vercel_sandbox on a host Scarf can't version) is appended.
        #expect(SettingsViewModel.terminalBackends(capabilities: .empty, current: "vercel_sandbox") == base + ["vercel_sandbox"])
        #expect(SettingsViewModel.terminalBackends(capabilities: v0215, current: "my_plugin") == base + ["vercel_sandbox", "my_plugin"])
    }

    // MARK: - S14-F1 / S03-F1 Hermes Voice fallback is reported

    @Test func fallbackReasonNamesTheMissingPythonWithoutTheHostDetail() {
        let secret = "sk-proj-DEADBEEFnotarealkey"
        let noPython = HermesSpeechService.SpeechError.synthesisFailed(
            "SCARF_TTS_ERROR: no Python interpreter found for /home/u/.local/bin/hermes \(secret)")
        let reason = MessageSpeechService.fallbackReason(for: noPython)
        #expect(reason.contains("Python"))
        #expect(!reason.contains(secret))
        #expect(!reason.contains("/home/u"))

        let generic = MessageSpeechService.fallbackReason(
            for: HermesSpeechService.SpeechError.synthesisFailed("openai: invalid_api_key \(secret)"))
        #expect(!generic.contains(secret))
        #expect(!generic.isEmpty)

        struct Other: Error {}
        #expect(!MessageSpeechService.fallbackReason(for: Other()).isEmpty)
        #expect(MessageSpeechService.fallbackReason(
            for: HermesSpeechService.SpeechError.transportFailed("x")) != generic)
    }

    @Test func speakerButtonSaysWhenTheSystemVoiceTookOver() {
        let plain = SpeakMessageButtonState(isPlaying: true, isLoading: false, liveVoiceActive: false)
        let fellBack = SpeakMessageButtonState(
            isPlaying: true, isLoading: false, liveVoiceActive: false, fallbackReason: "Scarf couldn't reach the server.")
        #expect(fellBack.help.contains("system voice"))
        #expect(fellBack.help.contains("Scarf couldn't reach the server."))
        #expect(fellBack.accessibilityValue != plain.accessibilityValue)
        #expect(plain.fallbackReason == nil)
        // Once playback ends the notice is gone from the button.
        let ended = SpeakMessageButtonState(
            isPlaying: false, isLoading: false, liveVoiceActive: false, fallbackReason: "x")
        #expect(!ended.help.contains("system voice"))
        #expect(fellBack.help.hasPrefix("Stop speaking"))
        #expect(!plain.help.contains("system voice"))
    }
}
