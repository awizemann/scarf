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
/// With a `gate` it also STANDS IN for the two system dialogs — `authorize()`
/// suspends until the test opens it, which is the window `begin` spends with
/// no session and no audio session but the microphone about to open.
struct FakeSpeechAuthorizer: VoiceLiveSpeechAuthorizing {
    let denial: VoiceListenerError?
    let gate: Gate?
    private let calls = Counter()

    init(denial: VoiceListenerError? = nil, gate: Gate? = nil) {
        self.denial = denial
        self.gate = gate
    }

    var callCount: Int { calls.value }

    func authorize() async -> VoiceListenerError? {
        calls.bump()
        await gate?.wait()
        return denial
    }

    /// A one-shot latch: `wait()` suspends until `open()`.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            guard lock.withLock({ !opened }) else { return }
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    if opened { return true }
                    waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                opened = true
                let w = waiter
                waiter = nil
                return w
            }
            waiting?.resume()
        }
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

    /// Whether the composer would let a dictation hold start, re-read on
    /// every `begin` (the argument is an autoclosure).
    let dictation = DictationState()

    final class DictationState {
        var isIdle = true
    }

    init(
        speechDenial: VoiceListenerError? = nil,
        micStatus: VoiceLiveMicrophonePermission = .granted,
        speechGate: FakeSpeechAuthorizer.Gate? = nil
    ) {
        let consent = Self.emptyConsent()
        self.consent = consent
        let mic = FakeMicrophone(micStatus)
        self.mic = mic
        let speech = FakeSpeechAuthorizer(denial: speechDenial, gate: speechGate)
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
            // The PRODUCTION mapping, not a restatement of it: a harness
            // that hardcodes `chained -> nil` proves nothing about the app.
            externalRecipient: { kind in VoiceLiveSessionModel.productionRecipient(for: kind) },
            audioSession: audio,
            backgroundTasks: tasks,
            microphone: mic,
            consent: consent,
            teardownGrace: .milliseconds(20),
            speechAuthorizer: speech
        )
    }

    var engine: FakeVoiceEngine? { engines.made.last }

    /// Yield until `begin` has reached the (gated) authorizer, bounded so a
    /// start that never gets there can't spin forever.
    func reachedTheAuthorizer(within yields: Int = 10_000) async -> Bool {
        for _ in 0..<yields {
            if speech.callCount > 0 { return true }
            await Task.yield()
        }
        return false
    }

    func beginChained() async {
        await model.begin(host: NullTurnHost(), engine: .chained, dictationIdle: dictation.isIdle)
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

    /// The chained start suspends on two system dialogs with no session and
    /// no audio session, so neither `isActive` nor `holdsAudioSession` is
    /// set — and the dictation button must STILL be off. Otherwise a hold
    /// started behind the prompts meets the microphone tap `begin` opens
    /// the instant authorization returns.
    @Test func dictationIsBlockedWhileTheChainedPermissionPromptsAreUp() async {
        let gate = FakeSpeechAuthorizer.Gate()
        let h = ChainedHarness(speechGate: gate)
        let start = Task { await h.beginChained() }
        // Let `begin` reach the authorizer. Bounded, so a `begin` that
        // never gets there fails the test instead of hanging the suite.
        #expect(await h.reachedTheAuthorizer())
        #expect(!h.model.isActive, "no session exists yet")
        #expect(!h.model.holdsAudioSession, "the audio session isn't claimed yet")
        #expect(h.model.isBeginning)
        #expect(h.model.blocksDictation, "dictation could start behind the permission prompts")
        #expect(!VoiceLiveComposerGate.dictationAllowed(
            chatReady: true, liveVoiceActive: h.model.blocksDictation))

        gate.open()
        await start.value
        #expect(h.model.blocksDictation)
        #expect(h.audio.activations == 1)
    }

    /// Belt and braces for the same race: if a hold DID get through while
    /// the prompts were up, the resumed `begin` re-reads the guard it
    /// checked at the top and mounts nothing at all.
    @Test func aStartWhoseDictationWentBusyDuringAuthorizeMountsNothing() async {
        let gate = FakeSpeechAuthorizer.Gate()
        let h = ChainedHarness(speechGate: gate)
        let start = Task { await h.beginChained() }
        #expect(await h.reachedTheAuthorizer())
        // A dictation take started behind the prompts.
        h.dictation.isIdle = false
        gate.open()
        await start.value

        #expect(h.engines.made.isEmpty, "a session opened the mic under dictation's recognizer")
        #expect(h.audio.activations == 0, "the audio session was reconfigured under dictation")
        #expect(!h.model.isPresented)
        #expect(!h.model.blocksDictation, "the abandoned start must not keep dictation off")
    }

    // MARK: Production wiring

    /// The consent rule the APP runs, asserted on the app's own mapping
    /// rather than on a harness restatement of it.
    @Test func theProductionRecipientMappingIsWhatDecidesConsent() async {
        #expect(VoiceLiveSessionModel.productionRecipient(for: .chained) == nil,
                "chained transcribes on-device and must declare no recipient")
        #expect(VoiceLiveSessionModel.productionRecipient(for: .gptLive) == .openAI)
        #expect(VoiceLiveSessionModel.productionRecipient(for: .chained)
                == ChainedVoiceEngine.externalRecipient)
        #expect(VoiceLiveSessionModel.productionRecipient(for: .gptLive)
                == GPTLiveEngine.externalRecipient)

        // And a begin driven THROUGH that mapping behaves accordingly.
        let h = ChainedHarness()
        await h.beginChained()
        #expect(h.model.pendingConsent == nil)
        #expect(h.engines.kinds == [.chained])

        let g = ChainedHarness()
        await g.model.begin(host: NullTurnHost(), engine: .gptLive, dictationIdle: true)
        #expect(g.model.pendingConsent == .openAI)
        #expect(g.engines.made.isEmpty)
    }

    // MARK: Audio-session release ordering

    /// `releaseAudioSession()` deactivates as soon as `waitForMediaRelease()`
    /// returns, and the chained engine doesn't override it — so the whole
    /// safety of that deactivate rests on `ChainedVoiceEngine.complete()`
    /// stopping the listener and the speaker SYNCHRONOUSLY before it
    /// publishes the terminal phase. Assert the order on the real engine.
    @Test func theChainedEngineStopsItsMediaBeforeTheAudioSessionIsHandedBack() async {
        let listener = FakeVoiceListener()
        let speaker = RecordingVoiceSpeaker()
        let audio = OrderRecordingAudioSession(listener: listener, speaker: speaker)
        let model = VoiceLiveSessionModel(
            makeSession: { kind, host in
                .init(
                    engine: ChainedVoiceEngine(listener: listener, speaker: speaker, turnHost: host),
                    kind: kind,
                    bridge: nil
                )
            },
            externalRecipient: { VoiceLiveSessionModel.productionRecipient(for: $0) },
            audioSession: audio,
            backgroundTasks: FakeBackgroundTasks(),
            microphone: FakeMicrophone(.granted),
            consent: ChainedHarness.emptyConsent(),
            teardownGrace: .milliseconds(20),
            speechAuthorizer: FakeSpeechAuthorizer()
        )

        await model.begin(host: NullTurnHost(), engine: .chained, dictationIdle: true)
        #expect(model.isActive)
        #expect(speaker.stopCount == 0)
        #expect(audio.deactivations == 0)

        model.teardown(.sheetDismissed)
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))

        #expect(audio.deactivations == 1)
        // The counts AT the moment of deactivate, not afterwards.
        #expect(audio.speakerStopsAtDeactivate == [1],
                "the audio session was deactivated with the speaker still running")
        #expect(audio.listenerStopsAtDeactivate == [1],
                "the audio session was deactivated with the microphone still open")
    }
}

// MARK: - Real-engine fakes (release ordering)

/// A `VoiceListener` with no microphone: the stream stays open until `stop()`.
@MainActor
final class FakeVoiceListener: VoiceListener {
    private var continuation: AsyncStream<VoiceListenerEvent>.Continuation?
    var stopCount = 0

    func start() throws -> AsyncStream<VoiceListenerEvent> {
        AsyncStream { self.continuation = $0 }
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func setPaused(_ paused: Bool) {}

    func setPlaybackActive(_ active: Bool) { playbackActive.append(active) }

    /// Every playback transition the engine announced, in order.
    var playbackActive: [Bool] = []
}

/// A `VoiceSpeaker` with no audio: counts `stop()`.
@MainActor
final class RecordingVoiceSpeaker: VoiceSpeaker {
    var isSpeaking = false
    var stopCount = 0
    func speak(_ text: String) async throws {}
    func stop() { stopCount += 1 }
}

/// Records what the engine's media had already done at each `deactivate()`.
@MainActor
final class OrderRecordingAudioSession: VoiceLiveAudioSessionControlling {
    private let listener: FakeVoiceListener
    private let speaker: RecordingVoiceSpeaker
    var activations = 0
    var deactivations = 0
    var speakerStopsAtDeactivate: [Int] = []
    var listenerStopsAtDeactivate: [Int] = []

    init(listener: FakeVoiceListener, speaker: RecordingVoiceSpeaker) {
        self.listener = listener
        self.speaker = speaker
    }

    func activate() { activations += 1 }

    func deactivate() {
        deactivations += 1
        speakerStopsAtDeactivate.append(speaker.stopCount)
        listenerStopsAtDeactivate.append(listener.stopCount)
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
        // The GATE itself, not just the capability flag behind it — an
        // assertion on the flag alone passed against the old v0.21.3 gate.
        #expect(!SettingsView.showsVoiceConversationSection(capabilities: Self.v0200))
        #expect(!SettingsView.showsVoiceConversationSection(capabilities: .empty))
        #expect(SettingsView.showsVoiceConversationSection(capabilities: Self.v0201),
                "v0.20.1 can speak, so the free chained path is offered")
        #expect(SettingsView.showsVoiceConversationSection(capabilities: Self.v0213))
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
    }

    /// An absent `tts.provider` is Hermes's own default, `edge` — and the
    /// row's NAME and its BADGE must agree about that. They used to
    /// disagree: the label said "edge" while the badge said nothing.
    @Test func anUnsetProviderReadsAsHermesDefaultInBothTheLabelAndTheBadge() {
        #expect(SettingsView.ttsProviderLabel(of: "") == "edge")
        #expect(SettingsView.ttsProviderLabel(of: "   ") == "edge")
        #expect(SettingsView.ttsCost(of: "") == .free, "unset is edge, which is free")
        #expect(SettingsView.ttsCost(of: "   ") == .free)
        // One rule: the badge is exactly the cost of the name the row shows.
        for raw in ["", "  ", "edge", " piper ", "openai", "something-new"] {
            #expect(SettingsView.ttsCost(of: raw)
                    == SettingsView.ttsCost(of: SettingsView.ttsProviderLabel(of: raw)),
                    "badge and label disagree for \(raw.debugDescription)")
        }
        #expect(SettingsView.ttsProviderLabel(of: " piper ") == "piper")
    }
}
