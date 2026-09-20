import Testing
import Foundation
import AVFoundation
import Observation
import ScarfCore
@testable import scarf_mobile

// P5b (Live Voice on ScarfGo): the composer gate, dictation/live-voice
// exclusivity, the session model's permission/audio/teardown rules, and the
// chat's VoiceTurnHost conformance against a scripted ACP channel.

// MARK: - Composer gate

@Suite struct VoiceLiveComposerGateTests {

    private static let v0213 = HermesCapabilities.parseLine("Hermes Agent v0.21.3 (2026.9.14)")
    private static let v0212 = HermesCapabilities.parseLine("Hermes Agent v0.21.2 (2026.9.11)")
    private static let v0200 = HermesCapabilities.parseLine("Hermes Agent v0.20.0 (2026.7.20)")

    @Test func hiddenUnlessReadyWhateverElseHolds() {
        for availability in [VoiceLiveAvailability.hidden(.hermesTooOld)] {
            for chatReady in [true, false] {
                for dictationIdle in [true, false] {
                    #expect(VoiceLiveComposerGate.entry(
                        availability: availability, chatReady: chatReady,
                        dictationIdle: dictationIdle, liveVoiceActive: false) == .hidden)
                }
            }
        }
    }

    /// P7c: chained is no longer hidden — it has an engine, and it is
    /// Hermes's DEFAULT mode, so the button shows on the majority of hosts.
    @Test func readinessFromCapabilitiesAndMode() {
        // Below v0.20.1 nothing can speak: hidden even in gpt-live mode (C1).
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0200, voiceChatMode: "gpt-live") == .hidden(.hermesTooOld))
        #expect(VoiceLiveReadiness.availability(capabilities: .empty, voiceChatMode: "gpt-live") == .hidden(.hermesTooOld))
        // v0.20.1-v0.21.2: too old for GPT-Live, but chained works.
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0212, voiceChatMode: "gpt-live") == .chainedReady)
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0212, voiceChatMode: nil) == .chainedReady)
        // Capable host, chained (or config not read yet): chained.
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0213, voiceChatMode: nil) == .chainedReady)
        #expect(VoiceLiveReadiness.availability(capabilities: Self.v0213, voiceChatMode: "chained") == .chainedReady)
        // Capable host in gpt-live mode (any Hermes spelling): ready.
        for raw in ["gpt-live", "gpt_live", "live"] {
            #expect(VoiceLiveReadiness.availability(capabilities: Self.v0213, voiceChatMode: raw) == .ready)
        }
        // And each verdict names the engine the composer mounts.
        #expect(VoiceLiveAvailability.ready.engineKind == .gptLive)
        #expect(VoiceLiveAvailability.chainedReady.engineKind == .chained)
        #expect(VoiceLiveAvailability.hidden(.hermesTooOld).engineKind == nil)
    }

    @Test func bothEnginesRenderTheSameEntry() {
        for availability in [VoiceLiveAvailability.ready, .chainedReady] {
            #expect(VoiceLiveComposerGate.entry(
                availability: availability, chatReady: true,
                dictationIdle: true, liveVoiceActive: false) == .enabled)
        }
    }

    @Test func disabledWhileDictatingOrDisconnectedOrAlreadyLive() {
        #expect(VoiceLiveComposerGate.entry(availability: .ready, chatReady: true, dictationIdle: true, liveVoiceActive: false) == .enabled)
        #expect(VoiceLiveComposerGate.entry(availability: .ready, chatReady: true, dictationIdle: false, liveVoiceActive: false) == .disabled)
        #expect(VoiceLiveComposerGate.entry(availability: .ready, chatReady: false, dictationIdle: true, liveVoiceActive: false) == .disabled)
        #expect(VoiceLiveComposerGate.entry(availability: .ready, chatReady: true, dictationIdle: true, liveVoiceActive: true) == .disabled)
    }

    @Test func dictationOffWhileLiveVoiceHoldsTheMic() {
        #expect(VoiceLiveComposerGate.dictationAllowed(chatReady: true, liveVoiceActive: false))
        #expect(!VoiceLiveComposerGate.dictationAllowed(chatReady: true, liveVoiceActive: true))
        #expect(!VoiceLiveComposerGate.dictationAllowed(chatReady: false, liveVoiceActive: false))
    }
}

// MARK: - Session model fakes

@MainActor
@Observable
final class FakeVoiceEngine: VoiceConversationEngine {
    var phase: VoiceConversationPhase = .idle
    var captions: [VoiceCaption] = []
    var micLevel: Double = 0
    var isMuted = false
    var elapsedSeconds: TimeInterval = 0
    var approximateCostUSD: Double = 0
    var notice: VoiceSessionNotice?

    var startCount = 0
    /// When set, `waitForMediaRelease()` suspends until `releaseMedia()`.
    var holdMediaRelease = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForMediaRelease() async {
        guard holdMediaRelease else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func releaseMedia() {
        holdMediaRelease = false
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }
    var endReasons: [VoiceSessionEndReason] = []
    var immediateEndReasons: [VoiceSessionEndReason] = []
    /// What `start()` leaves the phase at.
    var phaseAfterStart: VoiceConversationPhase = .connecting

    func start() async {
        startCount += 1
        phase = phaseAfterStart
    }

    func end(reason: VoiceSessionEndReason) {
        endReasons.append(reason)
        if phase.isActive { phase = .ending }
    }

    func endImmediately(reason: VoiceSessionEndReason) {
        immediateEndReasons.append(reason)
        if phase.isActive { phase = .ended(reason) }
    }

    func toggleMute() { isMuted.toggle() }
}

/// Collects the composer hints `submitVoiceTurn` raises (t-2140ec98).
@MainActor
final class FakeComposerNotices: VoiceLiveComposerNoticing {
    var notices: [VoiceLiveComposerNotice] = []
    func showComposerNotice(_ notice: VoiceLiveComposerNotice) { notices.append(notice) }
}

@MainActor
final class FakeAudioSession: VoiceLiveAudioSessionControlling {
    var activations = 0
    var deactivations = 0
    func activate() { activations += 1 }
    func deactivate() { deactivations += 1 }
}

@MainActor
final class FakeBackgroundTasks: VoiceLiveBackgroundTaskRunning {
    var begun: [Int] = []
    var ended: [Int] = []
    private var next = 0
    func begin() -> Int { next += 1; begun.append(next); return next }
    func end(_ token: Int) { ended.append(token) }
    var openCount: Int { begun.count - ended.count }
}

final class FakeMicrophone: VoiceLiveMicrophonePermissionChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: VoiceLiveMicrophonePermission
    private let grantOnRequest: Bool
    private let requestDelay: Duration
    private var _requests = 0

    init(_ status: VoiceLiveMicrophonePermission, grantOnRequest: Bool = true, requestDelay: Duration = .zero) {
        _status = status
        self.grantOnRequest = grantOnRequest
        self.requestDelay = requestDelay
    }

    var requests: Int { lock.withLock { _requests } }

    func status() -> VoiceLiveMicrophonePermission { lock.withLock { _status } }

    func request() async -> Bool {
        lock.withLock { _requests += 1 }
        if requestDelay > .zero { try? await Task.sleep(for: requestDelay) }
        return grantOnRequest
    }
}

@MainActor
final class NullTurnHost: VoiceTurnHost {
    var isVoiceTurnBusy: Bool { false }
    var activeVoiceToolName: String? { nil }
    func submitVoiceTurn(_ request: VoiceTurnRequest) async throws {}
    func cancelActiveVoiceTurn() async {}
    func voiceTurnReply(for requestID: String) -> VoiceTurnReply? { nil }
    func voiceSeedTurns() -> [VoiceLiveText.SeedTurn] { [] }
}

@MainActor
private struct Harness {
    let model: VoiceLiveSessionModel
    let audio = FakeAudioSession()
    let tasks = FakeBackgroundTasks()
    let engines: EngineBox

    final class EngineBox {
        var made: [FakeVoiceEngine] = []
        /// Which engine each `begin` asked the factory for.
        var kinds: [VoiceEngineKind] = []
        var phaseAfterStart: VoiceConversationPhase = .connecting
    }

    let consent: VoiceDataConsentStore

    /// A consent store over a throwaway defaults suite (never the real
    /// one). `accepted` pre-records the OpenAI consent, so the lifecycle
    /// tests start sessions without the sheet.
    static func consentStore(accepted: Bool = true) -> VoiceDataConsentStore {
        let suite = "scarf.tests.voiceLiveIOS.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = VoiceDataConsentStore(defaults: defaults)
        if accepted { store.recordConsent(to: .openAI) }
        return store
    }

    init(
        mic: FakeMicrophone = FakeMicrophone(.granted),
        grace: Duration = .milliseconds(20),
        externalRecipient: VoiceDataRecipient? = .openAI,
        consent: VoiceDataConsentStore? = nil,
        speechAuthorizer: any VoiceLiveSpeechAuthorizing = AlwaysAuthorizedSpeech()
    ) {
        let consent = consent ?? Self.consentStore()
        self.consent = consent
        let box = EngineBox()
        engines = box
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
            // The chained engine declares no recipient, exactly as
            // `ChainedVoiceEngine.externalRecipient` does in production.
            externalRecipient: { kind in kind == .chained ? nil : externalRecipient },
            audioSession: audio,
            backgroundTasks: tasks,
            microphone: mic,
            consent: consent,
            teardownGrace: grace,
            speechAuthorizer: speechAuthorizer
        )
    }

    var engine: FakeVoiceEngine? { engines.made.last }
}

// MARK: - Session model

/// The audio session is released on a task that first awaits the engine's
/// media release; let it run.
@MainActor
private func drainAudioRelease() async {
    for _ in 0..<10 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

@Suite(.serialized) @MainActor struct VoiceLiveSessionModelTests {

    /// F3 #8: the audio session is deactivated only after WebKit released
    /// the microphone and playback, so other apps' audio can resume.
    @Test func theAudioSessionIsReleasedOnlyAfterTheMediaIs() async {
        let h = Harness()
        h.engines.phaseAfterStart = .listening
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        h.engine?.holdMediaRelease = true
        h.model.teardown(.sheetDismissed)
        await drainAudioRelease()
        #expect(h.audio.deactivations == 0)   // WebKit still holds the mic
        h.engine?.releaseMedia()
        await drainAudioRelease()
        #expect(h.audio.deactivations == 1)
    }

    /// A new session that started while the old media was still releasing
    /// keeps the audio session.
    @Test func aNewSessionKeepsTheAudioSessionALateReleaseWouldDrop() async {
        let h = Harness()
        h.engines.phaseAfterStart = .listening
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        let first = h.engine
        first?.holdMediaRelease = true
        h.model.teardown(.sessionChanged)
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        first?.releaseMedia()
        await drainAudioRelease()
        #expect(h.audio.activations == 2)
        #expect(h.audio.deactivations == 0)
    }

    // MARK: F4: consent before the first session

    @Test func theFirstBeginAsksForConsentAndTouchesNothing() async {
        let mic = FakeMicrophone(.undetermined)
        let h = Harness(mic: mic, consent: Harness.consentStore(accepted: false))
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.model.pendingConsent == .openAI)
        #expect(h.engines.made.isEmpty, "a session was built before consent")
        #expect(mic.requests == 0, "the microphone prompt came before consent")
        #expect(h.audio.activations == 0)
        #expect(!h.model.isPresented)

        // Continue, then the view begins again: the session starts.
        h.model.acceptConsent()
        #expect(h.model.pendingConsent == nil)
        #expect(h.consent.hasConsented(to: .openAI))
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.engines.made.count == 1)
        #expect(h.engine?.startCount == 1)
    }

    @Test func cancelOnTheConsentStartsNothingAndAsksAgain() async {
        let h = Harness(consent: Harness.consentStore(accepted: false))
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        h.model.declineConsent()
        #expect(h.model.pendingConsent == nil)
        #expect(h.engines.made.isEmpty)
        #expect(h.audio.activations == 0)
        #expect(!h.consent.hasConsented(to: .openAI))
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.model.pendingConsent == .openAI)
        #expect(h.engines.made.isEmpty)
    }

    @Test func consentIsRememberedPerRecipientUntilReset() async {
        let consent = Harness.consentStore(accepted: false)
        let first = Harness(consent: consent)
        await first.model.begin(host: NullTurnHost(), dictationIdle: true)
        first.model.acceptConsent()

        // A new model (a relaunch, another chat) over the same store: no sheet.
        let second = Harness(consent: consent)
        await second.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(second.model.pendingConsent == nil)
        #expect(second.engines.made.count == 1)

        // Another recipient still asks.
        let acme = VoiceDataRecipient(id: "acme", displayName: "Acme", disclosureVersion: 1)
        let other = Harness(externalRecipient: acme, consent: consent)
        await other.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(other.model.pendingConsent == acme)
        #expect(other.engines.made.isEmpty)

        // Settings reset: asks again.
        consent.resetConsent(for: .openAI)
        let third = Harness(consent: consent)
        await third.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(third.model.pendingConsent == .openAI)
        #expect(third.engines.made.isEmpty)
    }

    @Test func anEngineWithNoExternalRecipientNeverAsks() async {
        let h = Harness(externalRecipient: nil, consent: Harness.consentStore(accepted: false))
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.model.pendingConsent == nil)
        #expect(h.engines.made.count == 1)
    }

    @Test func leavingChatDropsAPendingConsent() async {
        let h = Harness(consent: Harness.consentStore(accepted: false))
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        h.model.teardown(.viewDisappeared)
        #expect(h.model.pendingConsent == nil)
    }

    @Test func beginStartsSessionWithAudioAndSheet() async {
        let h = Harness()
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.engines.made.count == 1)
        #expect(h.engine?.startCount == 1)
        #expect(h.audio.activations == 1)
        #expect(h.model.isPresented)
        #expect(h.model.isActive)
    }

    @Test func beginRefusedWhileDictating() async {
        let h = Harness()
        await h.model.begin(host: NullTurnHost(), dictationIdle: false)
        #expect(h.engines.made.isEmpty)
        #expect(h.audio.activations == 0)
        #expect(!h.model.isPresented)
    }

    @Test func beginRefusedWhileAlreadyLive() async {
        let h = Harness()
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.engines.made.count == 1)
    }

    @Test func deniedMicrophoneShowsNoticeAndOpensNothing() async {
        let h = Harness(mic: FakeMicrophone(.denied))
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.model.composerNotice == .microphoneDenied)
        #expect(h.engines.made.isEmpty)
        #expect(h.audio.activations == 0)
        #expect(!h.model.isPresented)
    }

    @Test func undeterminedMicrophoneAsksFirst() async {
        let granted = FakeMicrophone(.undetermined, grantOnRequest: true)
        let h1 = Harness(mic: granted)
        await h1.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(granted.requests == 1)
        #expect(h1.engines.made.count == 1)

        let refused = FakeMicrophone(.undetermined, grantOnRequest: false)
        let h2 = Harness(mic: refused)
        await h2.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(refused.requests == 1)
        #expect(h2.engines.made.isEmpty)
        #expect(h2.model.composerNotice == .microphoneDenied)
    }

    /// Leaving Chat while the system microphone prompt is up must not open
    /// a (billed) session behind the user's back once they answer it.
    @Test func teardownDuringMicrophonePromptCancelsTheStart() async {
        let mic = FakeMicrophone(.undetermined, grantOnRequest: true, requestDelay: .milliseconds(100))
        let h = Harness(mic: mic)
        let begin = Task { await h.model.begin(host: NullTurnHost(), dictationIdle: true) }
        try? await Task.sleep(for: .milliseconds(20))
        h.model.teardown(.viewDisappeared)
        await begin.value
        #expect(h.engines.made.isEmpty)
        #expect(h.audio.activations == 0)
    }

    @Test(arguments: [
        VoiceLiveTeardownTrigger.backgrounded, .viewDisappeared, .sessionChanged, .sheetDismissed,
        .audioInterrupted, .hermesConnectionLost,
    ])
    func everyTeardownTriggerEndsImmediatelyInsideABackgroundTask(_ trigger: VoiceLiveTeardownTrigger) async {
        let h = Harness()
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        h.model.teardown(trigger)
        #expect(h.engine?.immediateEndReasons == [.userEnded])
        #expect(!h.model.isActive)
        #expect(h.tasks.begun.count == 1)
        // The background task is held for the grace period, then released.
        #expect(h.tasks.openCount == 1)
        await drainAudioRelease()
        #expect(h.audio.deactivations == 1)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(h.tasks.openCount == 0)
    }

    @Test func teardownHidesTheSheetForLeaveTriggers() async {
        for trigger in [VoiceLiveTeardownTrigger.backgrounded, .viewDisappeared, .sheetDismissed] {
            let h = Harness()
            await h.model.begin(host: NullTurnHost(), dictationIdle: true)
            h.model.teardown(trigger)
            #expect(!h.model.isPresented, "\(trigger)")
        }
    }

    @Test func teardownWithNoSessionIsANoOp() {
        let h = Harness()
        h.model.teardown(.backgrounded)
        h.model.teardown(.viewDisappeared)
        #expect(h.tasks.begun.isEmpty)
        #expect(h.audio.deactivations == 0)
    }

    @Test func teardownAfterTheSessionEndedDoesNotBeginAnotherTask() async {
        let h = Harness()
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        h.engine?.phase = .ended(.idleTimeout)
        h.model.phaseDidChange()
        h.model.teardown(.sheetDismissed)
        #expect(h.tasks.begun.isEmpty)
        #expect(h.engine?.immediateEndReasons.isEmpty == true)
        await drainAudioRelease()
        #expect(h.audio.deactivations == 1)
    }

    @Test func endButtonIsGracefulNotImmediate() async {
        let h = Harness()
        h.engines.phaseAfterStart = .listening
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        h.model.endFromUser()
        #expect(h.engine?.endReasons == [.userEnded])
        #expect(h.engine?.immediateEndReasons.isEmpty == true)
        #expect(h.audio.deactivations == 0)   // still ending
        h.engine?.phase = .ended(.userEnded)
        h.model.phaseDidChange()
        await drainAudioRelease()
        #expect(h.audio.deactivations == 1)
        h.model.phaseDidChange()
        #expect(h.audio.deactivations == 1)   // released once
    }

    @Test func failedStartReleasesTheAudioSession() async {
        let h = Harness()
        h.engines.phaseAfterStart = .failed(.host(.noKey))
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.audio.activations == 1)
        await drainAudioRelease()
        #expect(h.audio.deactivations == 1)
        // The sheet stays up to show the setup guidance.
        #expect(h.model.isPresented)
        if case .failed(let failure)? = h.engine?.phase {
            #expect(failure.setupHint)
        } else {
            Issue.record("expected a failed phase")
        }
    }

    @Test func interruptionEndsTheSessionWithANotice() async {
        let h = Harness()
        h.engines.phaseAfterStart = .listening
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        h.model.handleAudioSessionInterruption(began: false)
        #expect(h.model.isActive)
        h.model.handleAudioSessionInterruption(began: true)
        #expect(!h.model.isActive)
        #expect(h.model.composerNotice == .interrupted)
        #expect(h.engine?.immediateEndReasons == [.userEnded])
    }

    @Test func interruptionWithNoSessionDoesNothing() {
        let h = Harness()
        h.model.handleAudioSessionInterruption(began: true)
        #expect(h.model.composerNotice == nil)
        #expect(h.tasks.begun.isEmpty)
    }

    @Test func tryAgainAfterAnEndStartsAFreshEngine() async {
        let h = Harness()
        h.engines.phaseAfterStart = .failed(.host(.noKey))
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        h.engines.phaseAfterStart = .connecting
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.engines.made.count == 2)
        #expect(h.model.isActive)
    }
}

// MARK: - ChatController as VoiceTurnHost

@Suite(.serialized) @MainActor struct ChatControllerVoiceTurnHostTests {

    /// Scripted ACP peer. Records every request. `session/prompt` either
    /// replies at once (one chunk, then the result) or, when `holdPrompts`
    /// is set, waits until a `session/cancel` arrives and then returns
    /// `stopReason: cancelled`. `neverAnswer` leaves prompts hanging.
    actor ScriptedChannel: ACPChannel {
        static let sessionId = "voice-p5b"
        static let replyText = "Thursday at 3 works."

        nonisolated let incoming: AsyncThrowingStream<String, Error>
        nonisolated let stderr: AsyncThrowingStream<String, Error>
        private let incomingCont: AsyncThrowingStream<String, Error>.Continuation
        private let stderrCont: AsyncThrowingStream<String, Error>.Continuation
        private(set) var closed = false
        private(set) var requests: [[String: Any]] = []
        private var heldPromptIDs: [Int] = []
        var holdPrompts = false
        var neverAnswer = false
        /// How many prompts `holdPrompts` actually holds. Prompts beyond it
        /// are answered at once — how Hermes treats a prompt that arrives
        /// mid-turn ("Queued for the next turn": it returns immediately and
        /// runs inside the FIRST prompt's turn).
        var holdLimit: Int?
        private var heldCount = 0

        var diagnosticID: String? { "fake-voice-p5b-channel" }
        var isClosed: Bool { closed }

        init() {
            let (inStream, inCont) = AsyncThrowingStream<String, Error>.makeStream()
            let (errStream, errCont) = AsyncThrowingStream<String, Error>.makeStream()
            incoming = inStream
            incomingCont = inCont
            stderr = errStream
            stderrCont = errCont
        }

        func configure(hold: Bool = false, never: Bool = false, holdLimit: Int? = nil) {
            holdPrompts = hold
            neverAnswer = never
            self.holdLimit = holdLimit
        }

        /// Answer every held prompt without a `session/cancel` — so a test
        /// can let a turn finish normally after asserting nothing cancelled it.
        func releaseHeld(stopReason: String = "end_turn") {
            for held in heldPromptIDs { yield(result(id: held, stopReason: stopReason)) }
            heldPromptIDs = []
        }

        func methods() -> [String] { requests.compactMap { $0["method"] as? String } }

        func promptBlocks() -> [[[String: Any]]] {
            requests.filter { ($0["method"] as? String) == "session/prompt" }
                .compactMap { ($0["params"] as? [String: Any])?["prompt"] as? [[String: Any]] }
        }

        func send(_ line: String) async throws {
            guard !closed, let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            requests.append(obj)
            let id = obj["id"] as? Int
            switch method {
            case "initialize":
                if let id { yield(["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]]) }
            case "session/new":
                if let id { yield(["jsonrpc": "2.0", "id": id, "result": ["sessionId": Self.sessionId]]) }
            case "session/prompt":
                guard let id else { return }
                if neverAnswer { return }
                if holdPrompts, holdLimit.map({ heldCount < $0 }) ?? true {
                    heldCount += 1
                    heldPromptIDs.append(id)
                    return
                }
                yield(chunk(Self.replyText))
                try? await Task.sleep(nanoseconds: 50_000_000)
                yield(result(id: id, stopReason: "end_turn"))
            case "session/cancel":
                if let id { yield(["jsonrpc": "2.0", "id": id, "result": [:] as [String: Any]]) }
                for held in heldPromptIDs { yield(result(id: held, stopReason: "cancelled")) }
                heldPromptIDs = []
            default:
                break
            }
        }

        func close() async {
            closed = true
            incomingCont.finish()
            stderrCont.finish()
        }

        private func chunk(_ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "method": "session/update", "params": [
                "sessionId": Self.sessionId,
                "update": ["sessionUpdate": "agent_message_chunk", "content": ["text": text]] as [String: Any],
            ] as [String: Any]]
        }

        private func result(id: Int, stopReason: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "result": ["stopReason": stopReason, "usage": [:] as [String: Any]] as [String: Any]]
        }

        private func yield(_ obj: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: data, encoding: .utf8) else { return }
            incomingCont.yield(line)
        }
    }

    /// A connected controller over `channel`, with a hermetic config.yaml
    /// (model set, gpt-live mode) served by LocalTransport.
    private func connectedController(_ channel: ScriptedChannel) async throws -> (ChatController, () -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-p5b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try """
        model:
          default: test-model
          provider: test-provider
        voice:
          voice_chat_mode: gpt_live
        """.write(to: tmp.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let config = SSHConfig(host: "fake.invalid", remoteHome: tmp.path, hermesBinaryHint: "/nonexistent/scarf-test-hermes")
        let ctx = ServerContext(id: UUID(), displayName: "fake", kind: .ssh(config))
        let prior = ServerContext.sshTransportFactory
        ServerContext.sshTransportFactory = { id, _, _ in LocalTransport(contextID: id) }
        let controller = ChatController(context: ctx)
        controller.clientFactory = { _ in ACPClient(context: ctx) { _ in channel } }
        await controller.start()
        let cleanup = {
            ServerContext.sshTransportFactory = prior
            try? FileManager.default.removeItem(at: tmp)
        }
        return (controller, cleanup)
    }

    private static func request(_ prompt: String, id: String = "del_1") -> VoiceTurnRequest {
        VoiceTurnRequest(id: id, prompt: prompt, context: "User: \(prompt)")
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func submitThrowsWhenTheChatIsNotReady() async {
        let ctx = ServerContext(id: UUID(), displayName: "x", kind: .ssh(SSHConfig(host: "fake.invalid")))
        let controller = ChatController(context: ctx)
        await #expect(throws: VoiceTurnSubmitError.chatNotReady) {
            try await controller.submitVoiceTurn(Self.request("hello"))
        }
        #expect(controller.vm.messages.isEmpty)
    }

    @Test func submitAddsTheBubbleFirstSendsTheNoteAndSynthesizesCompletion() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        guard controller.state == .ready else { Issue.record("not ready: \(controller.state)"); return }

        let request = Self.request("the dentist one, thursday not friday")
        try await controller.submitVoiceTurn(request)
        // Rule 1: the bubble is there by the time submit returns, and the
        // turn counts as busy before its Task has even started.
        #expect(controller.vm.messages.last?.role == "user")
        #expect(controller.vm.messages.last?.content == request.prompt)
        #expect(controller.isVoiceTurnBusy)
        #expect(controller.voiceTurnReply(for: request.id) == nil)

        await waitUntil { !controller.isVoiceTurnBusy }
        #expect(controller.promptsInFlight == 0)
        #expect(controller.vm.isAgentWorking == false)

        // The wire: the voice note as an embedded resource BEFORE the text.
        let blocks = await channel.promptBlocks()
        #expect(blocks.count == 1)
        #expect(blocks.first?.first?["type"] as? String == "resource")
        #expect(blocks.first?.last?["type"] as? String == "text")
        #expect(blocks.first?.last?["text"] as? String == request.prompt)

        let reply = controller.voiceTurnReply(for: request.id)
        #expect(reply?.text.contains(ScriptedChannel.replyText) == true)
        #expect(reply?.isStreaming == false)
        #expect(controller.voiceTurnReply(for: "unknown") == nil)
    }

    @Test func cancelWaitsForTheCancelledPromptToReturn() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        guard controller.state == .ready else { Issue.record("not ready"); return }
        await channel.configure(hold: true)

        try await controller.submitVoiceTurn(Self.request("first"))
        try? await Task.sleep(for: .milliseconds(200))   // let the prompt reach the channel
        #expect(controller.promptsInFlight == 1)

        await controller.cancelActiveVoiceTurn()
        // Returned only once the held sendPrompt came back (cancelled).
        #expect(controller.promptsInFlight == 0)
        #expect(await channel.methods().contains("session/cancel"))
    }

    @Test func cancelIsBoundedWhenTheHostNeverAnswers() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        guard controller.state == .ready else { Issue.record("not ready"); return }
        await channel.configure(never: true)
        controller.voiceCancelTimeout = .milliseconds(300)

        try await controller.submitVoiceTurn(Self.request("stuck"))
        let clock = ContinuousClock()
        let start = clock.now
        await controller.cancelActiveVoiceTurn()
        let waited = clock.now - start
        #expect(waited >= .milliseconds(250))
        #expect(waited < .seconds(3))
        #expect(controller.promptsInFlight == 1)   // still hung; the engine moves on
    }

    @Test func cancelWithNothingRunningReturnsAtOnce() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        await controller.cancelActiveVoiceTurn()
        #expect(await channel.methods().contains("session/cancel") == false)
    }

    // MARK: - t-2140ec98: voice never cancels a typed turn (Mac parity)

    /// A typed turn does NOT read as a voice turn: the engine cancels
    /// whatever reads busy, so counting it would silently kill typed work.
    @Test func aTypedTurnIsNotAVoiceTurn() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        guard controller.state == .ready else { Issue.record("not ready"); return }
        await channel.configure(hold: true)
        controller.draft = "typed"
        let send = Task { await controller.send() }
        await waitUntil { controller.promptsInFlight == 1 }

        #expect(!controller.isVoiceTurnBusy)
        #expect(controller.isBusyWithNonVoiceTurn)

        await channel.releaseHeld()
        await send.value
        #expect(controller.promptsInFlight == 0)
        // A typed prompt carries no voice note.
        let blocks = await channel.promptBlocks()
        #expect(blocks.first?.map { $0["type"] as? String } == ["text"])
    }

    /// The whole rule end to end: while a typed turn runs, a voice cancel
    /// sends no `session/cancel`, the spoken request is not sent, the voice
    /// is told why, and the composer explains it.
    @Test func voiceNeitherCancelsNorInterruptsATypedTurn() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        guard controller.state == .ready else { Issue.record("not ready"); return }
        let notices = FakeComposerNotices()
        controller.voiceComposerNotices = notices
        await channel.configure(hold: true)
        controller.draft = "a long typed request"
        let send = Task { await controller.send() }
        await waitUntil { controller.promptsInFlight == 1 }

        await controller.cancelActiveVoiceTurn()
        #expect(await channel.methods().contains("session/cancel") == false,
                "a voice cancel killed the running typed turn")

        let request = Self.request("what's on thursday", id: "busy_1")
        try await controller.submitVoiceTurn(request)   // returns, never throws
        #expect(await channel.promptBlocks().count == 1,
                "the spoken request was sent while the typed turn ran")
        #expect(!controller.vm.messages.contains { $0.role == "user" && $0.content == request.prompt })
        // The voice says so instead, in full, and the composer shows why.
        #expect(controller.voiceTurnReply(for: request.id)
                == VoiceTurnReply(text: ChatController.voiceBusyReply, isStreaming: false))
        #expect(notices.notices == [.busyWithTypedTurn])

        await channel.releaseHeld()
        await send.value
    }

    /// A typed prompt queued inside a running VOICE turn makes Hermes busy
    /// with a typed request too: the voice must not cancel that run.
    @Test func aTypedPromptQueuedBehindAVoiceTurnIsNotCancelled() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        guard controller.state == .ready else { Issue.record("not ready"); return }
        await channel.configure(hold: true, holdLimit: 1)

        try await controller.submitVoiceTurn(Self.request("a spoken request", id: "v1"))
        await waitUntil { controller.promptsInFlight == 1 }
        #expect(controller.isVoiceTurnBusy)

        // Hermes answers the queued typed prompt at once and runs it inside
        // the voice turn's run.
        controller.draft = "typed while the voice turn runs"
        await controller.send()
        await waitUntil { controller.promptsInFlight == 1 }

        #expect(!controller.isVoiceTurnBusy, "the voice would cancel a run carrying typed work")
        #expect(controller.isBusyWithNonVoiceTurn)
        await controller.cancelActiveVoiceTurn()
        #expect(await channel.methods().contains("session/cancel") == false)

        await channel.releaseHeld()
        await waitUntil { controller.promptsInFlight == 0 }
    }

    /// Per-turn tokens: the queued turn's return settles only its own turn.
    /// It must not finalize the transcript while the first turn still runs.
    @Test func aQueuedTurnsReturnDoesNotEndTheRunningTurn() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        guard controller.state == .ready else { Issue.record("not ready"); return }
        await channel.configure(hold: true, holdLimit: 1)

        controller.draft = "first, a long typed turn"
        let first = Task { await controller.send() }
        await waitUntil { controller.promptsInFlight == 1 }
        controller.draft = "second, typed while it runs"
        await controller.send()   // answered at once by Hermes
        await waitUntil { controller.promptsInFlight == 1 }

        // The queued turn has returned; the chat is still working.
        #expect(controller.promptsInFlight == 1)
        #expect(controller.vm.isAgentWorking,
                "the queued turn's return cleared the working state while the first turn ran")
        #expect(controller.state == .ready)

        await channel.releaseHeld()
        await first.value
        await waitUntil { !controller.vm.isAgentWorking }
        #expect(controller.promptsInFlight == 0)
        #expect(!controller.vm.isAgentWorking)
    }

    /// A voice cancel still cancels VOICE turns, and waits for every one of
    /// them to return (the older turn returns last).
    @Test func voiceStillCancelsItsOwnTurnsAndWaitsForThemAll() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        guard controller.state == .ready else { Issue.record("not ready"); return }
        await channel.configure(hold: true)

        try await controller.submitVoiceTurn(Self.request("first spoken", id: "v1"))
        await waitUntil { controller.promptsInFlight == 1 }
        try await controller.submitVoiceTurn(Self.request("second spoken", id: "v2"))
        await waitUntil { controller.promptsInFlight == 2 }
        #expect(controller.isVoiceTurnBusy)

        await controller.cancelActiveVoiceTurn()
        #expect(await channel.methods().contains("session/cancel"))
        #expect(controller.promptsInFlight == 0, "the cancel returned before every voice turn did")
        #expect(!controller.isVoiceTurnBusy)
    }

    @Test func seedTurnsKeepOnlyUserAndAssistantText() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        guard controller.state == .ready else { Issue.record("not ready"); return }
        try await controller.submitVoiceTurn(Self.request("hi there"))
        await waitUntil { !controller.isVoiceTurnBusy }
        let seeds = controller.voiceSeedTurns()
        #expect(seeds.first == VoiceLiveText.SeedTurn(role: .user, text: "hi there"))
        #expect(seeds.contains { $0.role == .assistant && $0.text.contains(ScriptedChannel.replyText) })
        #expect(seeds.allSatisfy { !$0.text.isEmpty })
    }

    @Test func voiceChatModeIsReadFromTheHostConfig() async throws {
        let channel = ScriptedChannel()
        let (controller, cleanup) = try await connectedController(channel)
        defer { cleanup() }
        #expect(controller.voiceChatModeRaw == nil)
        await controller.refreshVoiceChatMode()
        #expect(VoiceChatMode.parse(controller.voiceChatModeRaw) == .gptLive)
    }
}


// MARK: - F6: a dead Hermes connection ends the session

@Suite(.serialized) @MainActor struct VoiceLiveConnectionLostTests {

    /// An open GPT-Live session bills $0.05/min and every spoken turn
    /// throws `.chatNotReady` once the ACP connection is gone: the chat
    /// state leaving `.ready` must end it, exactly as the Mac's
    /// `ChatViewModel.handleConnectionDied` does.
    @Test func chatStatesOtherThanReadyEndLiveVoice() {
        #expect(!ChatController.State.ready.endsLiveVoice)
        for state: ChatController.State in [
            .failed("ssh closed"),
            .offline(reason: "no route"),
            .reconnecting(attempt: 1, of: 5),
            .connecting,
            .idle,
        ] {
            #expect(state.endsLiveVoice, "\(state) left Live Voice running")
        }
    }

    /// Teardown for a lost connection ends the session immediately, keeps
    /// the sheet up, and says why — both on the sheet (the end note) and on
    /// the composer, for a user who had already swiped the sheet away.
    @Test func teardownForALostConnectionEndsTheSessionWithItsNote() async {
        let h = Harness()
        h.engines.phaseAfterStart = .listening
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.model.isActive)

        h.model.teardown(.hermesConnectionLost)

        #expect(h.engine?.immediateEndReasons == [.userEnded])
        #expect(!h.model.isActive)
        #expect(h.model.endNote == .hermesConnectionLost)
        #expect(h.model.composerNotice == .hermesConnectionLost)
        // The sheet stays up so the user can read how it ended.
        #expect(h.model.isPresented)
        #expect(h.tasks.begun.count == 1, "the close must run inside a background task")
        await drainAudioRelease()
        #expect(h.audio.deactivations == 1)
    }

    /// The note belongs to ONE session: the next start clears it.
    @Test func theNextSessionStartsWithoutTheNote() async {
        let h = Harness()
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        h.model.teardown(.hermesConnectionLost)
        #expect(h.model.endNote == .hermesConnectionLost)
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.model.endNote == nil)
        #expect(h.model.composerNotice == nil)
    }
}

// MARK: - F6: the audio session is restored, and released once

@Suite(.serialized) @MainActor struct VoiceLiveAudioSessionRestoreTests {

    /// Stands in for `AVAudioSession`: remembers what it was configured
    /// with, so the save/restore can be asserted.
    final class FakeSystemSession: VoiceLiveAVAudioSession.System {
        var category: AVAudioSession.Category = .ambient
        var mode: AVAudioSession.Mode = .default
        var categoryOptions: AVAudioSession.CategoryOptions = []
        var actives: [Bool] = []

        func setCategory(
            _ category: AVAudioSession.Category,
            mode: AVAudioSession.Mode,
            options: AVAudioSession.CategoryOptions
        ) throws {
            self.category = category
            self.mode = mode
            self.categoryOptions = options
        }

        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
            actives.append(active)
        }
    }

    /// Live Voice puts the app on `.playAndRecord` / `.voiceChat` /
    /// speaker for the length of a call. It never put it back, so every
    /// later sound in the app — and every other app's — ran on a call
    /// session until ScarfGo was relaunched.
    @Test func deactivateRestoresThePreSessionConfiguration() {
        let system = FakeSystemSession()
        system.category = .playback
        system.mode = .spokenAudio
        system.categoryOptions = [.duckOthers]
        let audio = VoiceLiveAVAudioSession(session: system)

        audio.activate()
        #expect(system.category == .playAndRecord)
        #expect(system.mode == .voiceChat)

        audio.deactivate()
        #expect(system.category == .playback, "the app stayed on the call category")
        #expect(system.mode == .spokenAudio)
        #expect(system.categoryOptions == [.duckOthers])
        #expect(system.actives == [true, false])
    }

    /// A second call captures the configuration the app is actually on,
    /// not Live Voice's own leftovers.
    @Test func aSecondSessionRestoresTheSameConfiguration() {
        let system = FakeSystemSession()
        system.category = .playback
        let audio = VoiceLiveAVAudioSession(session: system)
        audio.activate()
        audio.deactivate()
        audio.activate()
        audio.deactivate()
        #expect(system.category == .playback)
    }

    /// Two teardowns in a row each schedule a deferred `deactivate()`
    /// behind `waitForMediaRelease()`. Only the last one may fire:
    /// otherwise a stale release hands the audio session back under a
    /// push-to-talk take the user started in the meantime.
    @Test func aStaleDeferredDeactivateIsSkipped() async {
        let h = Harness()
        h.engines.phaseAfterStart = .listening
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        let first = h.engine
        first?.holdMediaRelease = true
        h.model.teardown(.sheetDismissed)

        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        let second = h.engine
        second?.holdMediaRelease = true
        h.model.teardown(.sheetDismissed)

        first?.releaseMedia()
        second?.releaseMedia()
        await drainAudioRelease()
        #expect(h.audio.deactivations == 1, "a stale deferred deactivate fired")
    }

    /// Dictation stays off until the audio session is actually back: the
    /// composer used to re-enable it the instant `isActive` flipped, so a
    /// hold started in that window was cut by the late `setActive(false)`.
    @Test func dictationStaysBlockedUntilTheAudioSessionIsReleased() async {
        let h = Harness()
        h.engines.phaseAfterStart = .listening
        await h.model.begin(host: NullTurnHost(), dictationIdle: true)
        #expect(h.model.holdsAudioSession)
        h.engine?.holdMediaRelease = true
        h.model.teardown(.sheetDismissed)

        #expect(!h.model.isActive)
        #expect(h.model.holdsAudioSession, "the audio session is still ours")
        #expect(h.model.blocksDictation, "dictation was re-enabled before the release")

        h.engine?.releaseMedia()
        await drainAudioRelease()
        #expect(!h.model.holdsAudioSession)
        #expect(!h.model.blocksDictation)
    }
}
