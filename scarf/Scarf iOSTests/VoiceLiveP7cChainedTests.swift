import Testing
import Foundation
import ScarfCore
@testable import scarf_mobile

// P7c (the free chained voice path on ScarfGo): which engine the session
// model mounts for a host's `voice.voice_chat_mode`, that chained asks for
// no consent and GPT-Live still does, that a speech-recognition denial is
// shown with the Settings row named instead of opening the microphone, that
// every teardown trigger ends a chained session too, that push-to-talk
// dictation stands down for it, and where Settings draws its version floor.
//
// Nothing here touches a microphone, the Speech framework or an audio
// session: the engine comes from the model's factory seam and the
// permissions from `VoiceLiveSpeechAuthorizing`.

// MARK: - Fakes

/// A scripted `VoiceLiveSpeechAuthorizing`: never prompts, counts calls.
struct FakeSpeechAuthorizer: VoiceLiveSpeechAuthorizing {
    let denial: VoiceListenerError?
    private let calls = Counter()

    init(denial: VoiceListenerError? = nil) {
        self.denial = denial
    }

    var callCount: Int { calls.value }

    func authorize() async -> VoiceListenerError? {
        calls.bump()
        return denial
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func bump() { lock.withLock { count += 1 } }
    }
}

// MARK: - Harness

@MainActor
private struct ChainedHarness {
    let model: VoiceLiveSessionModel
    let audio = FakeAudioSession()
    let tasks = FakeBackgroundTasks()
    let mic: FakeMicrophone
    let speech: FakeSpeechAuthorizer
    let consent: VoiceDataConsentStore
    let engines = Box()

    final class Box {
        var made: [FakeVoiceEngine] = []
        var kinds: [VoiceEngineKind] = []
        var phaseAfterStart: VoiceConversationPhase = .listening
    }

    /// A consent store over a throwaway defaults suite, with NOTHING
    /// accepted: the point of most of these tests is that chained never asks.
    static func emptyConsent() -> VoiceDataConsentStore {
        let suite = "scarf.tests.voiceP7c.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return VoiceDataConsentStore(defaults: defaults)
    }

    init(speechDenial: VoiceListenerError? = nil, micStatus: VoiceLiveMicrophonePermission = .granted) {
        let consent = Self.emptyConsent()
        self.consent = consent
        let mic = FakeMicrophone(micStatus)
        self.mic = mic
        let speech = FakeSpeechAuthorizer(denial: speechDenial)
        self.speech = speech
        let box = engines
        let audio = self.audio
        let tasks = self.tasks
        model = VoiceLiveSessionModel(
            makeSession: { kind, _ in
                let engine = FakeVoiceEngine()
                engine.phaseAfterStart = box.phaseAfterStart
                box.made.append(engine)
                box.kinds.append(kind)
                return .init(engine: engine, kind: kind, bridge: nil)
            },
            externalRecipient: { kind in kind == .chained ? nil : .openAI },
            audioSession: audio,
            backgroundTasks: tasks,
            microphone: mic,
            consent: consent,
            teardownGrace: .milliseconds(20),
            speechAuthorizer: speech
        )
    }

    var engine: FakeVoiceEngine? { engines.made.last }

    func beginChained() async {
        await model.begin(host: NullTurnHost(), engine: .chained, dictationIdle: true)
    }
}

// MARK: - Mounting

@Suite(.serialized) @MainActor struct VoiceLiveChainedSessionTests {

    @Test func aChainedHostMountsTheChainedEngineAndNeverAsksForConsent() async {
        let h = ChainedHarness()
        await h.beginChained()
        #expect(h.engines.kinds == [.chained])
        #expect(h.model.pendingConsent == nil, "chained transcribes on-device; nothing to consent to")
        #expect(h.model.session?.kind == .chained)
        #expect(h.engine?.startCount == 1)
        #expect(h.model.isPresented)
        // The app's own audio session is the one that gets claimed.
        #expect(h.audio.activations == 1)
        // Speech + microphone were both asked for, once.
        #expect(h.speech.callCount == 1)
        // …and the GPT-Live-only microphone client was NOT used: the
        // listener's own authorization covers both permissions.
        #expect(h.mic.requests == 0)
    }

    @Test func gptLiveOnTheSameModelStillAsksForConsentFirst() async {
        let h = ChainedHarness()
        await h.model.begin(host: NullTurnHost(), engine: .gptLive, dictationIdle: true)
        #expect(h.model.pendingConsent == .openAI)
        #expect(h.engines.made.isEmpty, "a session was built before consent")
        #expect(h.audio.activations == 0)
        #expect(h.speech.callCount == 0, "GPT-Live must not ask for on-device speech recognition")

        // The same model mounts chained without any of that.
        await h.beginChained()
        #expect(h.engines.kinds == [.chained])
        #expect(h.model.pendingConsent == nil)
    }

    // MARK: Permission denial

    @Test func deniedSpeechRecognitionFailsWithSetupGuidanceAndOpensNoMicrophone() async {
        let h = ChainedHarness(speechDenial: .speechRecognitionDenied)
        await h.beginChained()
        #expect(h.engines.made.isEmpty, "the engine must not be built after a denial")
        #expect(h.audio.activations == 0, "the audio session was claimed despite the denial")
        #expect(!h.model.blocksDictation)
        #expect(h.model.session?.engine.phase == .failed(.speechRecognitionDenied))
        #expect(h.model.isPresented, "the denial is explained in the sheet")
        // `setupHint` is what makes the sheet render the Settings steps
        // rather than a bare "try again".
        #expect(VoiceSessionFailure.speechRecognitionDenied.setupHint)
    }

    @Test func aLocaleWithNoOnDeviceModelFailsAsUnavailableNotAsAServerFallback() async {
        for denial in [VoiceListenerError.onDeviceRecognitionUnsupported, .recognizerUnavailable] {
            let h = ChainedHarness(speechDenial: denial)
            await h.beginChained()
            #expect(h.model.session?.engine.phase == .failed(.speechRecognitionUnavailable))
            #expect(h.engines.made.isEmpty)
        }
        #expect(VoiceSessionFailure.speechRecognitionUnavailable.setupHint)
    }

    @Test func aDeniedMicrophoneIsReportedAsTheMicrophoneNotAsSpeech() async {
        let h = ChainedHarness(speechDenial: .microphoneDenied)
        await h.beginChained()
        #expect(h.model.session?.engine.phase == .failed(.microphoneDenied))
    }

    // MARK: Teardown

    /// Every way out of the Chat screen ends a chained session too. It bills
    /// nothing, but it holds the microphone and the app's audio session.
    @Test func everyTeardownTriggerEndsAChainedSession() async {
        let triggers: [VoiceLiveTeardownTrigger] = [
            .backgrounded, .viewDisappeared, .sessionChanged,
            .sheetDismissed, .audioInterrupted, .hermesConnectionLost,
        ]
        for trigger in triggers {
            let h = ChainedHarness()
            await h.beginChained()
            #expect(h.model.isActive)
            h.model.teardown(trigger)
            #expect(h.engine?.immediateEndReasons == [.userEnded], "\(trigger) left a chained session running")
            #expect(!h.model.isActive)
            // The teardown runs inside a background task on every trigger,
            // so a backgrounding app isn't suspended mid-teardown.
            #expect(h.tasks.begun.count == 1, "\(trigger) tore down outside a background task")
        }
    }

    @Test func backgroundingEndsAChainedSessionInsideABackgroundTask() async {
        let h = ChainedHarness()
        await h.beginChained()
        h.model.teardown(.backgrounded)
        #expect(h.tasks.openCount == 1)
        #expect(!h.model.isPresented)
        // The token is closed once the grace elapses.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(h.tasks.openCount == 0)
    }

    @Test func anAudioInterruptionEndsAChainedSessionAndSaysSo() async {
        let h = ChainedHarness()
        await h.beginChained()
        h.model.handleAudioSessionInterruption(began: true)
        #expect(!h.model.isActive)
        #expect(h.model.composerNotice == .interrupted)
    }

    // MARK: Dictation exclusivity

    /// One microphone: push-to-talk dictation stands down for a chained
    /// session exactly as it does for GPT-Live, and stays down until the
    /// deferred `setActive(false)` has actually run.
    @Test func dictationIsBlockedForTheWholeChainedWindow() async {
        let h = ChainedHarness()
        await h.beginChained()
        #expect(h.model.blocksDictation)
        #expect(!VoiceLiveComposerGate.dictationAllowed(
            chatReady: true, liveVoiceActive: h.model.blocksDictation))

        h.engine?.holdMediaRelease = true
        h.model.teardown(.sheetDismissed)
        #expect(!h.model.isActive)
        // Still blocked: the audio session has not been handed back yet.
        #expect(h.model.blocksDictation)

        h.engine?.releaseMedia()
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!h.model.blocksDictation)
        #expect(h.audio.deactivations == 1)
    }

    /// And the reverse: a chained session refuses to start mid-dictation.
    @Test func aChainedSessionRefusesToStartWhileDictationHoldsTheMic() async {
        let h = ChainedHarness()
        await h.model.begin(host: NullTurnHost(), engine: .chained, dictationIdle: false)
        #expect(h.engines.made.isEmpty)
        #expect(h.speech.callCount == 0)
        #expect(h.audio.activations == 0)
    }
}

// MARK: - Settings

@Suite @MainActor struct VoiceConversationSettingsTests {

    private static let v0200 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.7.20)")
    private static let v0201 = HermesCapabilities.parseLine("Hermes Agent v0.20.1 (2026.7.28)")
    private static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")

    /// The section's gate (charter C1): below v0.20.1 Hermes can't speak at
    /// all, so Settings renders exactly as it did before P7c.
    @Test func theVoiceConversationSectionIsHiddenBelow0201() {
        #expect(!Self.v0200.hasHermesSpeechSynthesis)
        #expect(!HermesCapabilities.empty.hasHermesSpeechSynthesis)
        #expect(Self.v0201.hasHermesSpeechSynthesis)
        #expect(Self.v0213.hasHermesSpeechSynthesis)
        // And the mode PICKER needs v0.21.3: below it the key doesn't exist
        // and `IOSSettingsViewModel.saveVoiceChatMode` refuses to write it.
        #expect(!Self.v0201.hasGPTLiveVoice)
        #expect(Self.v0213.hasGPTLiveVoice)
    }

    @Test func theTextToSpeechRowBadgesFreeAndPaidProviders() {
        for provider in ["edge", "piper", "kittentts", "neutts", "EDGE", " piper "] {
            #expect(SettingsView.ttsCost(of: provider) == .free, "\(provider) should read as free")
        }
        for provider in ["openai", "elevenlabs", "xai", "deepinfra", "gemini", "mistral", "minimax"] {
            #expect(SettingsView.ttsCost(of: provider) == .paid, "\(provider) should read as paid")
        }
        // Anything Hermes adds later is labelled nothing rather than guessed.
        #expect(SettingsView.ttsCost(of: "something-new") == .unknown)
        #expect(SettingsView.ttsCost(of: "") == .unknown)
    }
}
