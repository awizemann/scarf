import Testing
import Foundation
@testable import ScarfCore

/// The chained conversation loop with a fake listener, a fake speaker and a
/// fake chat — no microphone, no speech framework, no host. Timers run on an
/// injected clock through `tick()`.
@MainActor
@Suite(.serialized) struct ChainedVoiceEngineTests {

    // MARK: fakes

    final class FakeListener: VoiceListener {
        var startError: VoiceListenerError?
        var starts = 0
        var stops = 0
        var pauses: [Bool] = []
        private var continuation: AsyncStream<VoiceListenerEvent>.Continuation?

        func start() throws -> AsyncStream<VoiceListenerEvent> {
            starts += 1
            if let startError { throw startError }
            let (stream, made) = AsyncStream<VoiceListenerEvent>.makeStream()
            continuation = made
            return stream
        }

        func stop() {
            stops += 1
            continuation?.finish()
            continuation = nil
        }

        func setPaused(_ paused: Bool) { pauses.append(paused) }

        /// Every playback transition the engine announced, in order.
        private(set) var playbackLog: [Bool] = []
        private(set) var playbackActive = false
        private var onset = VoiceSpeechOnsetDetector()

        func setPlaybackActive(_ active: Bool) {
            playbackLog.append(active)
            playbackActive = active
            onset.reset()
        }

        func emit(_ event: VoiceListenerEvent) { continuation?.yield(event) }

        /// One 100 ms tick of microphone level, put through the REAL onset
        /// rule (``VoiceSpeechOnsetDetector``) with the real triggers, so the
        /// engine sees exactly what the production listener would send.
        func pushLevel(_ level: Double) {
            continuation?.yield(.level(level))
            let trigger = playbackActive ? VoiceAudioLevel.bargeInOnsetLevel : VoiceAudioLevel.speechOnsetLevel
            if onset.note(level: level, trigger: trigger) { continuation?.yield(.speechStarted) }
        }
    }

    final class FakeSpeaker: VoiceSpeaker {
        private(set) var spoken: [String] = []
        private(set) var stops = 0
        var isSpeaking = false
        var throwsOnce = false
        /// When set, `speak` suspends until `stop()` or `release()`.
        var hold = false
        private var pending: CheckedContinuation<Void, Never>?

        func speak(_ text: String) async throws {
            spoken.append(text)
            isSpeaking = true
            defer { isSpeaking = false }
            if throwsOnce {
                throwsOnce = false
                throw Boom()
            }
            if hold { await withCheckedContinuation { pending = $0 } }
        }

        func stop() {
            stops += 1
            release()
        }

        func release() {
            guard let continuation = pending else { return }
            pending = nil
            continuation.resume()
        }
    }

    final class FakeHost: VoiceTurnHost {
        var isVoiceTurnBusy = false
        var activeVoiceToolName: String?
        var submitted: [VoiceTurnRequest] = []
        var replies: [String: VoiceTurnReply] = [:]
        var submitError: Error?
        var voiceChatID: String?

        func submitVoiceTurn(_ request: VoiceTurnRequest) async throws {
            if let submitError { throw submitError }
            submitted.append(request)
            isVoiceTurnBusy = true
        }
        func cancelActiveVoiceTurn() async { Issue.record("the chained engine must never cancel a turn") }
        func voiceTurnReply(for requestID: String) -> VoiceTurnReply? { replies[requestID] }
        func voiceSeedTurns() -> [VoiceLiveText.SeedTurn] { [] }
    }

    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    final class Clock { var now = Date(timeIntervalSince1970: 1_000_000) }

    // MARK: harness

    let listener = FakeListener()
    let speaker = FakeSpeaker()
    let host = FakeHost()
    let clock = Clock()
    let engine: ChainedVoiceEngine

    init() {
        var configuration = ChainedVoiceEngine.Configuration()
        configuration.tickInterval = nil
        engine = ChainedVoiceEngine(
            listener: listener, speaker: speaker, turnHost: host,
            configuration: configuration, clock: { [clock] in clock.now })
    }

    private func advance(_ seconds: TimeInterval) {
        clock.now = clock.now.addingTimeInterval(seconds)
        engine.tick()
    }

    /// Spin the main actor until `condition` holds (the listener stream and
    /// the speak/submit tasks are asynchronous). Never a fixed long sleep.
    private func settle(_ condition: @MainActor () -> Bool = { false }) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func say(_ text: String) async {
        listener.emit(.utterance(text))
        await settle { self.host.submitted.last?.prompt == VoiceLiveText.collapseWhitespace(text) }
    }

    private func reply(_ text: String, streaming: Bool = true, for id: String = "chained-1") {
        host.replies[id] = VoiceTurnReply(text: text, isStreaming: streaming)
        if !streaming { host.isVoiceTurnBusy = false }
    }

    // MARK: start

    @Test func startOpensTheListenerAndGoesLive() async {
        await engine.start()
        #expect(listener.starts == 1)
        #expect(engine.phase == .listening)
        #expect(engine.approximateCostUSD == 0)
    }

    @Test func aListenerThatCannotStartFailsTheSession() async {
        listener.startError = .onDeviceRecognitionUnsupported
        await engine.start()
        #expect(engine.phase == .failed(.speechRecognitionUnavailable))
        #expect(engine.phase.isTerminal)
    }

    @Test func deniedSpeechRecognitionIsItsOwnFailure() async {
        listener.startError = .speechRecognitionDenied
        await engine.start()
        #expect(engine.phase == .failed(.speechRecognitionDenied))
        #expect(VoiceSessionFailure.speechRecognitionDenied.setupHint)
    }

    @Test func deniedMicrophoneIsItsOwnFailure() async {
        listener.startError = .microphoneDenied
        await engine.start()
        #expect(engine.phase == .failed(.microphoneDenied))
    }

    // MARK: the turn

    @Test func anUtteranceSubmitsExactlyTheSpokenWords() async {
        await engine.start()
        await say("what is the weather")
        #expect(host.submitted.map(\.prompt) == ["what is the weather"])
        #expect(engine.phase == .thinking)
    }

    /// The persisted row is the spoken words; the OpenAI voice-live note is
    /// NOT attached (nothing paraphrases the reply here).
    @Test func theTurnCarriesTheChainedNoteNotTheVoiceLiveOne() async throws {
        await engine.start()
        await say("hello there")
        let request = try #require(host.submitted.first)
        #expect(request.noteStyle == .chained)
        #expect(request.prompt == "hello there")
        let note = try #require(request.contextNotes.first)
        #expect(note.uri == VoiceChainedTurnNote.uri)
        #expect(!note.text.contains(VoiceLiveTurnNote.note))
        #expect(note.text.contains("User: hello there"))
    }

    @Test func partialsBecomeTheUserCaptionAndTheUtteranceReplacesIt() async {
        await engine.start()
        listener.emit(.partial("what is"))
        listener.emit(.partial("what is the weather"))
        // Settle on the SECOND partial's text, not on "one caption": the
        // first partial already makes one caption, and under load the
        // second may not have landed when the count check passes.
        await settle { self.engine.captions.map(\.text) == ["what is the weather"] }
        #expect(engine.captions.map(\.text) == ["what is the weather"])
        await say("what is the weather today")
        #expect(engine.captions.count == 1)
        #expect(engine.captions.first?.text == "what is the weather today")
        #expect(engine.captions.first?.speaker == .user)
    }

    @Test func aStreamedReplyIsSpokenSentenceBySentenceInOrder() async {
        await engine.start()
        await say("tell me")
        reply("It is sunny. ")
        advance(0.2)
        await settle { !self.speaker.spoken.isEmpty }
        reply("It is sunny. And warm too. ")
        advance(0.2)
        await settle { self.speaker.spoken.count == 2 }
        reply("It is sunny. And warm too. Enjoy it.", streaming: false)
        advance(0.2)
        await settle { self.speaker.spoken.count == 3 }
        #expect(speaker.spoken == ["It is sunny.", "And warm too.", "Enjoy it."])
        #expect(engine.phase == .listening)
    }

    @Test func aTurnThatSaysNothingIsAnnounced() async {
        await engine.start()
        await say("do the thing")
        advance(0.2)                 // the turn is seen running…
        host.isVoiceTurnBusy = false // …and then finishes, saying nothing
        advance(0.2)
        await settle { !self.speaker.spoken.isEmpty }
        #expect(speaker.spoken == [ChainedVoiceEngine.silentReply])
        #expect(engine.phase == .listening)
    }

    @Test func aBusyChatIsToldAboutAndNeverCancelled() async {
        await engine.start()
        host.isVoiceTurnBusy = true          // a typed turn the user started
        listener.emit(.utterance("are you there"))
        await settle { !self.speaker.spoken.isEmpty }
        #expect(speaker.spoken == [ChainedVoiceEngine.busyReply])
        #expect(host.submitted.isEmpty)      // FakeHost records an Issue if cancelled
    }

    @Test func aTurnThatCannotBeSubmittedSaysSo() async {
        await engine.start()
        host.submitError = Boom()
        listener.emit(.utterance("hello"))
        await settle { !self.speaker.spoken.isEmpty }
        #expect(speaker.spoken == [ChainedVoiceEngine.unreachableReply])
    }

    // MARK: stop phrase

    @Test func aStopPhraseEndsTheSessionInsteadOfReachingHermes() async {
        await engine.start()
        listener.emit(.utterance("that's all"))
        await settle { self.engine.phase.isTerminal }
        #expect(engine.phase == .ended(.stopPhrase))
        #expect(host.submitted.isEmpty)
        #expect(listener.stops == 1)
        #expect(speaker.stops >= 1)
    }

    @Test func aStopWordInsideASentenceIsAnOrdinaryTurn() async {
        await engine.start()
        await say("stop the docker container")
        #expect(host.submitted.map(\.prompt) == ["stop the docker container"])
        #expect(!engine.phase.isTerminal)
    }

    // MARK: barge-in

    /// One loud tick is a door, a keyboard, or the reply itself leaking into
    /// the microphone — it must not cut the reply off. Held level is a
    /// person, and it must.
    @Test func onlyASustainedBurstStopsTheSpeaker() async {
        speaker.hold = true
        await engine.start()
        await say("tell me a long story")
        reply("Once upon a time. ")
        advance(0.2)
        await settle { self.engine.phase == .speaking }
        #expect(listener.playbackLog.last == true)   // the listener was told

        // One tick over the playback trigger: a transient, not a barge-in.
        listener.pushLevel(0.5)
        await settle { self.speaker.stops > 0 }
        #expect(speaker.stops == 0)
        #expect(engine.phase == .speaking)

        // Loud, but only at the IDLE trigger: the reply is playing, so this
        // is echo, not someone talking over it.
        for _ in 0..<6 { listener.pushLevel(0.2) }
        await settle { self.speaker.stops > 0 }
        #expect(speaker.stops == 0)

        // Held above the playback trigger: a real barge-in.
        for _ in 0..<3 { listener.pushLevel(0.5) }
        await settle { self.speaker.stops > 0 }
        #expect(speaker.stops == 1)
        #expect(engine.phase == .thinking)   // the reply stopped; the turn runs on
        #expect(listener.playbackLog.last == false)

        // Let the turn settle, then the utterance that follows is ordinary.
        speaker.hold = false
        reply("Once upon a time. The end.", streaming: false)
        advance(0.2)
        await settle { self.engine.phase == .listening }
        await say("actually tell me the weather")
        #expect(host.submitted.map(\.prompt) == ["tell me a long story", "actually tell me the weather"])
    }

    @Test func anUtteranceWhileSpeakingAlwaysCutsTheReplyShort() async {
        speaker.hold = true
        await engine.start()
        await say("first")
        reply("Talking now.", streaming: false)   // the turn is done; the reply plays
        advance(0.2)
        await settle { self.engine.phase == .speaking }
        // The speaker stays held, so it is provably still talking when the
        // utterance lands — releasing it first would race the stop.
        await say("second")
        #expect(speaker.stops >= 1)
        #expect(host.submitted.count == 2)
    }

    // MARK: mute

    @Test func mutePausesTheListener() async {
        await engine.start()
        listener.emit(.level(0.6))
        await settle { self.engine.micLevel > 0 }
        engine.toggleMute()
        #expect(engine.isMuted)
        #expect(listener.pauses == [true])
        #expect(engine.micLevel == 0)
        engine.toggleMute()
        #expect(!engine.isMuted)
        #expect(listener.pauses == [true, false])
    }

    // MARK: idle

    @Test func silenceEndsTheSessionAfterTheIdleTimeoutWithAWarningFirst() async {
        await engine.start()
        advance(VoiceIdleMonitor.defaultTimeout - 30)
        #expect(engine.notice == .endingSoon(reason: .idleTimeout, secondsLeft: 30))
        advance(30)
        #expect(engine.phase == .ended(.idleTimeout))
        #expect(listener.stops == 1)
    }

    @Test func aRunningTurnIsNeverIdle() async {
        await engine.start()
        await say("do something slow")
        advance(VoiceIdleMonitor.defaultTimeout + 10)
        #expect(engine.phase == .thinking)
    }

    // MARK: failures and teardown

    @Test func aListenerFailureFailsTheSession() async {
        await engine.start()
        listener.emit(.failed(.recognitionFailed(detail: "kaput")))
        await settle { self.engine.phase.isTerminal }
        #expect(engine.phase == .failed(.mediaUnavailable(detail: "kaput")))
    }

    @Test func endStopsTheListenerAndTheSpeaker() async {
        speaker.hold = true
        await engine.start()
        await say("hello")
        reply("Speaking. ")
        advance(0.2)
        await settle { self.engine.phase == .speaking }
        engine.end(reason: .userEnded)
        #expect(engine.phase == .ended(.userEnded))
        #expect(listener.stops == 1)
        #expect(speaker.stops == 1)
    }

    @Test func endImmediatelyStopsBothToo() async {
        await engine.start()
        engine.endImmediately(reason: .userEnded)
        #expect(engine.phase == .ended(.userEnded))
        #expect(listener.stops == 1)
        #expect(speaker.stops == 1)
    }

    @Test func elapsedCountsFromStartAndCostStaysZero() async {
        await engine.start()
        advance(65)
        #expect(engine.elapsedSeconds == 65)
        #expect(engine.approximateCostUSD == 0)
        engine.end(reason: .userEnded)
        advance(100)
        #expect(engine.elapsedSeconds == 65)    // frozen once ended
        #expect(engine.approximateCostUSD == 0)
    }

    @Test func theChainedEngineDeclaresNoExternalRecipient() {
        #expect(ChainedVoiceEngine.externalRecipient == nil)
        #expect(VoiceDataRecipient.forMode(.chained) == nil)
        #expect(VoiceDataRecipient.forMode(.gptLive) == .openAI)
    }

    // MARK: stalled turn (M2)

    /// The idle guard is disabled while a turn runs, so without a second cap
    /// a wedged Hermes turn would hold the microphone open forever.
    @Test func aWedgedTurnEndsTheSessionAtTheStalledTurnCap() async {
        await engine.start()
        await say("do something that hangs")
        host.isVoiceTurnBusy = true          // …and never answers

        advance(VoiceIdleMonitor.defaultTimeout + 10)
        #expect(engine.phase == .thinking)   // the idle cap alone never fires

        advance(540 - (VoiceIdleMonitor.defaultTimeout + 10))
        #expect(engine.notice == .endingSoon(reason: .turnStalled, secondsLeft: 60))
        advance(60)
        #expect(engine.phase == .ended(.turnStalled))
        #expect(listener.stops == 1)
    }

    /// Progress is not a stall: every observed change to the reply rearms it.
    @Test func replyProgressRearmsTheStalledTurnCap() async {
        await engine.start()
        await say("do something slow")
        host.isVoiceTurnBusy = true

        advance(300)
        // No sentence boundary yet, so nothing is spoken — this is progress
        // on the reply and nothing else.
        reply("working on it")
        advance(1)
        advance(590)
        #expect(engine.phase == .thinking)
        #expect(speaker.spoken.isEmpty)
        advance(10)
        #expect(engine.phase == .ended(.turnStalled))
    }

    // MARK: speak generations (M1)

    /// A barged-in chunk's `speak()` still returns. If that return clears the
    /// CURRENT speak task and pumps the queue, two chunks play at once.
    @Test func aStaleSpeakCompletionNeverStartsASecondChunk() async {
        speaker.hold = true
        await engine.start()
        await say("tell me a story")
        reply("One. ")
        advance(0.2)
        await settle { !self.speaker.spoken.isEmpty }
        #expect(speaker.spoken == ["One."])

        // Barge in, then queue two more chunks before the abandoned task can
        // resume — everything here is synchronous on purpose.
        clock.now = clock.now.addingTimeInterval(0.5)
        engine.handle(.speechStarted)
        #expect(speaker.stops == 1)
        reply("One. Two. ")
        engine.tick()
        reply("One. Two. Three.", streaming: false)
        engine.tick()

        await settle { self.speaker.spoken.count >= 3 }
        #expect(speaker.spoken == ["One.", "Two."])
        engine.end(reason: .userEnded)   // release the held chunk
    }

    // MARK: model context (L2)

    /// A dropped utterance was never said to Hermes, so neither it nor the
    /// canned line explaining the drop may turn up in the next turn's context.
    @Test func aDroppedUtteranceNeverJoinsTheModelContext() async throws {
        await engine.start()
        host.isVoiceTurnBusy = true
        listener.emit(.utterance("cancel the production deploy"))
        await settle { !self.speaker.spoken.isEmpty }
        #expect(speaker.spoken == [ChainedVoiceEngine.busyReply])
        #expect(host.submitted.isEmpty)

        host.isVoiceTurnBusy = false
        await say("what is the weather")
        let request = try #require(host.submitted.first)
        let note = try #require(request.contextNotes.first)
        #expect(!note.text.contains("production deploy"))
        #expect(!note.text.contains("still working"))
        #expect(note.text.contains("User: what is the weather"))
    }

    /// Same rule for an unreachable host.
    @Test func anUnsubmittableUtteranceNeverJoinsTheModelContextEither() async throws {
        await engine.start()
        host.submitError = Boom()
        listener.emit(.utterance("rotate the api key"))
        await settle { !self.speaker.spoken.isEmpty }
        #expect(speaker.spoken == [ChainedVoiceEngine.unreachableReply])

        host.submitError = nil
        await say("hello again")
        let request = try #require(host.submitted.first)
        let note = try #require(request.contextNotes.first)
        #expect(!note.text.contains("could not reach Hermes"))
        #expect(note.text.contains("User: hello again"))
    }
}

/// The Hermes→system TTS fallback.
@MainActor
@Suite struct FallbackVoiceSpeakerTests {

    final class StubSpeaker: VoiceSpeaker {
        private(set) var spoken: [String] = []
        var isSpeaking = false
        var failures = 0
        func speak(_ text: String) async throws {
            if failures > 0 {
                failures -= 1
                throw Failure()
            }
            spoken.append(text)
        }
        func stop() {}
        struct Failure: Error {}
    }

    /// A primary whose `speak()` suspends until `stop()` kills it — and which
    /// reports that kill as an ordinary error, the way a dropped SSH script
    /// does, rather than as a cancellation.
    final class HoldingSpeaker: VoiceSpeaker {
        var isSpeaking = false
        private var pending: CheckedContinuation<Void, Error>?

        func speak(_ text: String) async throws {
            isSpeaking = true
            defer { isSpeaking = false }
            try await withCheckedThrowingContinuation { pending = $0 }
        }

        func stop() {
            guard let continuation = pending else { return }
            pending = nil
            continuation.resume(throwing: Died())
        }

        struct Died: Error {}
    }

    @Test func aFailedChunkFallsBackToTheSystemVoice() async throws {
        let hermes = StubSpeaker()
        let system = StubSpeaker()
        hermes.failures = 1
        var notices = 0
        let speaker = FallbackVoiceSpeaker(primary: hermes, fallback: system) { notices += 1 }

        try await speaker.speak("first")
        #expect(hermes.spoken.isEmpty)
        #expect(system.spoken == ["first"])
        #expect(notices == 1)
        #expect(speaker.didFallBack)
    }

    @Test func theNoticeFiresOnlyOnce() async throws {
        let hermes = StubSpeaker()
        let system = StubSpeaker()
        hermes.failures = 3
        var notices = 0
        let speaker = FallbackVoiceSpeaker(primary: hermes, fallback: system) { notices += 1 }

        for text in ["one", "two", "three"] { try await speaker.speak(text) }
        #expect(system.spoken == ["one", "two", "three"])
        #expect(notices == 1)
    }

    /// Per chunk, not per session: a host that recovers is used again.
    @Test func aRecoveredHostSpeaksTheNextChunkItself() async throws {
        let hermes = StubSpeaker()
        let system = StubSpeaker()
        hermes.failures = 1
        let speaker = FallbackVoiceSpeaker(primary: hermes, fallback: system)

        try await speaker.speak("one")
        try await speaker.speak("two")
        #expect(system.spoken == ["one"])
        #expect(hermes.spoken == ["two"])
    }

    /// A stop can race the primary into reporting a plain (non-cancellation)
    /// error for the chunk it was told to abandon. The fallback must not then
    /// speak that whole chunk over the silence the user asked for.
    @Test func aStopRacingAPrimaryErrorDoesNotSpeakTheChunkAnyway() async throws {
        let hermes = HoldingSpeaker()
        let system = StubSpeaker()
        var notices = 0
        let speaker = FallbackVoiceSpeaker(primary: hermes, fallback: system) { notices += 1 }

        let speaking = Task { try await speaker.speak("a whole paragraph nobody wants to hear") }
        while !hermes.isSpeaking { await Task.yield() }
        speaker.stop()
        try await speaking.value

        #expect(system.spoken.isEmpty)
        #expect(!speaker.didFallBack)
        #expect(notices == 0)
    }

    /// The flag is per chunk: the next one still falls back normally.
    @Test func aLaterChunkStillFallsBackAfterAStop() async throws {
        let hermes = StubSpeaker()
        let system = StubSpeaker()
        let speaker = FallbackVoiceSpeaker(primary: hermes, fallback: system)
        speaker.stop()
        hermes.failures = 1
        try await speaker.speak("next")
        #expect(system.spoken == ["next"])
    }
}
