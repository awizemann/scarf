import Testing
import Foundation
@testable import ScarfCore

/// The three-way voice verdict (P7): gpt-live, chained, or hidden. The
/// capability floors are the whole point — chained needs only v0.20.1
/// (`hasHermesSpeechSynthesis`), GPT-Live needs v0.21.3.
@Suite struct VoiceLiveReadinessTests {

    static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    static let v0212 = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
    static let v0201 = HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.8.1)")
    static let v0200 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.7.20)")

    @Test func theCapabilityFloorsAreTheOnesTheRuleAssumes() {
        #expect(Self.v0213.hasGPTLiveVoice)
        #expect(!Self.v0212.hasGPTLiveVoice)
        #expect(Self.v0201.hasHermesSpeechSynthesis)
        #expect(!Self.v0200.hasHermesSpeechSynthesis)
    }

    @Test func gptLiveModeOnACapableHostMountsGPTLive() {
        for mode in ["gpt-live", "gpt_live", "gptlive", "live"] {
            let verdict = VoiceLiveReadiness.availability(capabilities: Self.v0213, voiceChatMode: mode)
            #expect(verdict == .ready, "\(mode)")
            #expect(verdict.engineKind == .gptLive)
            #expect(verdict.isReady)
        }
    }

    /// Chained is Hermes's default, so an absent or empty key counts too.
    /// This is the case that used to be `.hidden(.chainedMode)` — the
    /// majority of hosts, with the button hidden on all of them.
    @Test func chainedModeMountsTheChainedEngine() {
        for mode: String? in ["chained", nil, "", "something-else"] {
            let verdict = VoiceLiveReadiness.availability(capabilities: Self.v0213, voiceChatMode: mode)
            #expect(verdict == .chainedReady, "\(mode ?? "nil")")
            #expect(verdict.engineKind == .chained)
            #expect(verdict.isReady)
        }
    }

    /// A host asking for gpt-live that is too old for it falls back to
    /// chained, exactly as the Hermes desktop does.
    @Test func gptLiveOnAnOldHostFallsBackToChained() {
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0212, voiceChatMode: "gpt-live") == .chainedReady)
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0201, voiceChatMode: "gpt-live") == .chainedReady)
    }

    @Test func belowTheSpeechFloorNothingIsShown() {
        for mode: String? in ["gpt-live", "chained", nil] {
            #expect(VoiceLiveReadiness.availability(capabilities: Self.v0200, voiceChatMode: mode) == .hidden(.hermesTooOld))
            #expect(VoiceLiveReadiness.availability(capabilities: .empty, voiceChatMode: mode) == .hidden(.hermesTooOld))
        }
        #expect(VoiceLiveAvailability.hidden(.hermesTooOld).engineKind == nil)
        #expect(!VoiceLiveAvailability.hidden(.hermesTooOld).isReady)
    }

    @Test func aParsedConfigDrivesTheSameVerdict() {
        let live = HermesConfig(yaml: "voice:\n  voice_chat_mode: gpt_live\n")
        let chained = HermesConfig(yaml: "voice:\n  record_key: ctrl+b\n")
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0213, config: live) == .ready)
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0213, config: chained) == .chainedReady)
        // Config not loaded yet: Hermes's default, which now has an engine.
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0213, config: nil) == .chainedReady)
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0200, config: nil) == .hidden(.hermesTooOld))
    }

    /// Chained never asks for consent: the audio is transcribed on-device.
    @Test func onlyGPTLiveDeclaresARecipient() {
        #expect(VoiceLiveAvailability.chainedReady.engineKind == .chained)
        #expect(VoiceDataRecipient.forMode(.chained) == nil)
        #expect(VoiceDataRecipient.forMode(.gptLive)?.id == "openai")
    }
}
