import Testing
import AVFoundation
import Foundation
@testable import ScarfCore

/// The pure halves of the on-device listener: the end-of-utterance rule and
/// the level maths. No microphone, no Speech framework — everything the
/// `AppleOnDeviceVoiceListener` decides, decided here.
@Suite struct VoiceListenerTests {

    let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: end-of-utterance

    @Test func anUnchangingHypothesisEndsTheUtteranceAfterTheSilenceWindow() {
        var detector = VoiceUtteranceDetector(silence: 1.2)
        let changed = detector.note(partial: "what is", at: start)
        #expect(changed)
        let tooSoon = detector.settled(at: start.addingTimeInterval(1.1))
        #expect(tooSoon == nil)
        let finished = detector.settled(at: start.addingTimeInterval(1.2))
        #expect(finished == "what is")
        // …and it resets, so the next utterance starts clean.
        #expect(detector.text.isEmpty)
        let afterReset = detector.settled(at: start.addingTimeInterval(99))
        #expect(afterReset == nil)
    }

    /// A revision mid-thought restarts the window: the user is still talking,
    /// even though they paused.
    @Test func aChangedHypothesisRestartsTheSilenceWindow() {
        var detector = VoiceUtteranceDetector(silence: 1.2)
        detector.note(partial: "what is", at: start)
        let revised = detector.note(partial: "what is the weather", at: start.addingTimeInterval(1.0))
        #expect(revised)
        let tooSoon = detector.settled(at: start.addingTimeInterval(2.0))
        #expect(tooSoon == nil)
        let finished = detector.settled(at: start.addingTimeInterval(2.2))
        #expect(finished == "what is the weather")
    }

    @Test func anUnchangedHypothesisDoesNotCountAsAChange() {
        var detector = VoiceUtteranceDetector(silence: 1.2)
        detector.note(partial: "hello", at: start)
        let same = detector.note(partial: "hello", at: start.addingTimeInterval(0.5))
        #expect(!same)
        let padded = detector.note(partial: "  hello  ", at: start.addingTimeInterval(0.8))
        #expect(!padded)
        let finished = detector.settled(at: start.addingTimeInterval(1.2))
        #expect(finished == "hello")
    }

    @Test func anEmptyHypothesisNeverEndsAnUtterance() {
        var detector = VoiceUtteranceDetector(silence: 1.2)
        detector.note(partial: "   ", at: start)
        let settled = detector.settled(at: start.addingTimeInterval(60))
        #expect(settled == nil)
        let taken = detector.take()
        #expect(taken == nil)
    }

    @Test func takeForcesTheUtteranceOutForAFinalResult() {
        var detector = VoiceUtteranceDetector()
        detector.note(partial: "done", at: start)
        let first = detector.take()
        #expect(first == "done")
        let second = detector.take()
        #expect(second == nil)
    }

    @Test func resetDropsAHalfHeardUtterance() {
        var detector = VoiceUtteranceDetector(silence: 1.2)
        detector.note(partial: "muted words", at: start)
        detector.reset()
        let settled = detector.settled(at: start.addingTimeInterval(10))
        #expect(settled == nil)
    }

    // MARK: level

    @Test func silenceReadsAsZeroAndFullScaleAsOne() {
        #expect(VoiceAudioLevel.level(ofRMS: 0) == 0)
        #expect(VoiceAudioLevel.level(ofRMS: 1) == 1)
        // -50 dBFS is the floor: everything below it is silence.
        #expect(VoiceAudioLevel.level(ofRMS: pow(10, -50 / 20.0)) == 0)
        #expect(VoiceAudioLevel.level(ofSamples: []) == 0)
    }

    @Test func theMeterIsMonotonicAndBoundedTo0Through1() {
        var previous = -1.0
        for db in stride(from: -60.0, through: 0.0, by: 5.0) {
            let level = VoiceAudioLevel.level(ofRMS: pow(10, db / 20))
            #expect(level >= 0 && level <= 1)
            #expect(level >= previous)
            previous = level
        }
    }

    /// -25 dBFS is ordinary speech: it must land halfway up the meter, not
    /// pinned at either end (the reason the mapping is dB, not linear RMS).
    @Test func normalSpeechLandsInTheMiddleOfTheMeter() {
        let level = VoiceAudioLevel.level(ofRMS: pow(10, -25 / 20.0))
        #expect(abs(level - 0.5) < 0.01)
        #expect(level > VoiceAudioLevel.speechOnsetLevel)
    }

    @Test func roomToneStaysBelowTheSpeechOnsetThreshold() {
        // -45 dBFS: a quiet room.
        #expect(VoiceAudioLevel.level(ofRMS: pow(10, -45 / 20.0)) < VoiceAudioLevel.speechOnsetLevel)
    }

    @Test func rmsOverSamplesMatchesTheDirectRMSMapping() {
        let samples = [Float](repeating: 0.1, count: 512)
        // Float samples, Double maths: equal to within single precision.
        #expect(abs(VoiceAudioLevel.level(ofSamples: samples) - VoiceAudioLevel.level(ofRMS: 0.1)) < 1e-6)
    }

    // MARK: level box

    // MARK: end-of-utterance, audio gate

    /// Text stillness alone cuts a thinking pause off: the recognizer stops
    /// revising while the user is still making sound. The audio gate holds
    /// the utterance until the microphone is actually quiet.
    @Test func aStillHypothesisOverLiveAudioDoesNotSettleUntilItGoesQuiet() {
        var detector = VoiceUtteranceDetector(silence: 1.2)
        detector.note(partial: "what is the", at: start)
        // Still talking (or humming) for one second, same text.
        for step in stride(from: 0.0, through: 1.0, by: 0.1) {
            detector.note(level: 0.3, at: start.addingTimeInterval(step))
        }
        // Text has been still 1.2 s, but the mic was loud 0.2 s ago.
        detector.note(level: 0.02, at: start.addingTimeInterval(1.2))
        #expect(detector.settled(at: start.addingTimeInterval(1.2)) == nil)
        // Quiet from t=1.0: the window restarts from the last loud tick.
        for step in stride(from: 1.3, through: 2.1, by: 0.1) {
            detector.note(level: 0.02, at: start.addingTimeInterval(step))
        }
        #expect(detector.settled(at: start.addingTimeInterval(2.1)) == nil)
        detector.note(level: 0.0, at: start.addingTimeInterval(2.2))
        #expect(detector.settled(at: start.addingTimeInterval(2.2)) == "what is the")
    }

    /// A room whose noise floor never drops under the silence level (a fan,
    /// a café) must not make the session deaf: the audio gate can delay the
    /// utterance to at most twice the window, then the text rule decides.
    @Test func aNoisyRoomCanOnlyDelayTheUtteranceNotHoldIt() {
        var detector = VoiceUtteranceDetector(silence: 1.2)
        detector.note(partial: "what is the", at: start)
        for step in stride(from: 0.0, through: 2.3, by: 0.1) {
            detector.note(level: 0.3, at: start.addingTimeInterval(step))
        }
        #expect(detector.settled(at: start.addingTimeInterval(2.3)) == nil)
        detector.note(level: 0.3, at: start.addingTimeInterval(2.5))
        #expect(detector.settled(at: start.addingTimeInterval(2.5)) == "what is the")
    }

    @Test func aLevelBelowTheSilenceLevelNeverBlocksTheWindow() {
        var detector = VoiceUtteranceDetector(silence: 1.2)
        detector.note(partial: "hello", at: start)
        // Room tone all the way through.
        for step in stride(from: 0.0, through: 1.2, by: 0.1) {
            detector.note(level: 0.05, at: start.addingTimeInterval(step))
        }
        #expect(detector.settled(at: start.addingTimeInterval(1.2)) == "hello")
    }

    // MARK: sustained onset

    @Test func oneLoudTickIsNotASpeechOnsetButThreeAre() {
        var onset = VoiceSpeechOnsetDetector(requiredTicks: 3)
        var fired = onset.note(level: 0.6, trigger: 0.18)
        #expect(!fired)
        fired = onset.note(level: 0.0, trigger: 0.18)     // the run is broken
        #expect(!fired)
        fired = onset.note(level: 0.6, trigger: 0.18)
        #expect(!fired)
        fired = onset.note(level: 0.6, trigger: 0.18)
        #expect(!fired)
        fired = onset.note(level: 0.6, trigger: 0.18)
        #expect(fired)                                    // confirmed
        // …and it does not fire again while the level stays up.
        fired = onset.note(level: 0.6, trigger: 0.18)
        #expect(!fired)
    }

    /// The onset is released by quiet, not by the first dip: syllable gaps
    /// inside one sentence must not re-arm it.
    @Test func theOnsetIsHeldUntilTheLevelFallsWellBelowTheTrigger() {
        var onset = VoiceSpeechOnsetDetector(requiredTicks: 2)
        onset.note(level: 0.6, trigger: 0.2)
        let fired = onset.note(level: 0.6, trigger: 0.2)
        #expect(fired)
        onset.note(level: 0.15, trigger: 0.2)   // a gap, still not quiet
        #expect(onset.isSpeaking)
        onset.note(level: 0.05, trigger: 0.2)   // quiet
        #expect(!onset.isSpeaking)
    }

    @Test func theRaisedPlaybackTriggerIgnoresLevelsThatWouldTripTheIdleOne() {
        var onset = VoiceSpeechOnsetDetector(requiredTicks: 3)
        for _ in 0..<10 {
            let fired = onset.note(level: 0.3, trigger: VoiceAudioLevel.bargeInOnsetLevel)
            #expect(!fired)
        }
        // The same run at the idle trigger would have fired long ago.
        var idle = VoiceSpeechOnsetDetector(requiredTicks: 3)
        idle.note(level: 0.3, trigger: VoiceAudioLevel.speechOnsetLevel)
        idle.note(level: 0.3, trigger: VoiceAudioLevel.speechOnsetLevel)
        let idleFired = idle.note(level: 0.3, trigger: VoiceAudioLevel.speechOnsetLevel)
        #expect(idleFired)
    }

    @Test func theBargeInTriggerSitsBetweenEchoAndSpeech() {
        #expect(VoiceAudioLevel.bargeInOnsetLevel > VoiceAudioLevel.speechOnsetLevel)
        // Normal speech at -25 dBFS still clears it.
        #expect(VoiceAudioLevel.level(ofRMS: pow(10, -25 / 20.0)) > VoiceAudioLevel.bargeInOnsetLevel)
    }

    @Test func theLevelBoxHoldsThePeakBetweenTicksAndResets() {
        let box = VoiceInputLevelBox()
        box.record(rms: 0.01)
        box.record(rms: 0.5)
        box.record(rms: 0.02)
        #expect(box.take() == VoiceAudioLevel.level(ofRMS: 0.5))
        #expect(box.take() == 0)
    }
}


/// ``AppleOnDeviceVoiceListener`` itself, driven through its recognizer and
/// audio-tap seams: no microphone, no Speech framework, no authorization
/// prompt. What is pinned here is the privacy contract and the request
/// generations that keep a finished request's late callbacks from killing the
/// session or leaking a stale utterance.
@MainActor
@Suite struct AppleOnDeviceVoiceListenerTests {

    // MARK: fakes

    final class FakeRequest: VoiceRecognitionRequesting {
        var shouldReportPartialResults = false
        var requiresOnDeviceRecognition = false
        private(set) var appended = 0
        private(set) var finished = false
        func appendAudio(_ buffer: AVAudioPCMBuffer) { appended += 1 }
        func finishAudio() { finished = true }
    }

    final class FakeTask: VoiceRecognitionTasking {
        private(set) var cancels = 0
        func cancelRecognition() { cancels += 1 }
    }

    @MainActor final class FakeRecognizer: VoiceRecognizing {
        var isRecognizerAvailable = true
        var supportsOnDeviceRecognition = true
        private(set) var requests: [FakeRequest] = []
        private(set) var tasks: [FakeTask] = []

        func makeRequest() -> any VoiceRecognitionRequesting {
            let request = FakeRequest()
            requests.append(request)
            return request
        }

        func startTask(
            with request: any VoiceRecognitionRequesting,
            handler: @escaping @Sendable (VoiceRecognitionEvent) -> Void
        ) -> (any VoiceRecognitionTasking)? {
            let task = FakeTask()
            tasks.append(task)
            return task
        }
    }

    @MainActor final class FakeTap: VoiceAudioTapping {
        private(set) var stops = 0
        private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

        func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            self.onBuffer = onBuffer
        }

        func stop() {
            stops += 1
            onBuffer = nil
        }

        /// One buffer, as the audio thread would deliver it. `rms` is the
        /// constant sample value, so the buffer's RMS is exactly that.
        func push(rms: Double = 0) {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
            buffer.frameLength = 64
            if let channel = buffer.floatChannelData?[0] {
                for index in 0..<64 { channel[index] = Float(rms) }
            }
            onBuffer?(buffer)
        }

        /// The same, expressed on the 0…1 meter scale.
        func push(level: Double) {
            push(rms: level <= 0 ? 0 : pow(10, (level * -VoiceAudioLevel.floorDB + VoiceAudioLevel.floorDB) / 20))
        }
    }

    @MainActor final class StubAudioSession: VoiceAudioSessionControlling {
        private(set) var activations = 0
        private(set) var deactivations = 0
        func activateForVoiceConversation() throws { activations += 1 }
        func deactivate() { deactivations += 1 }
    }

    // MARK: harness

    /// A clock the test moves by hand.
    final class TestClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// Consumes the listener's stream as it runs, so a test can look at what
    /// has been emitted SO FAR without finishing the stream.
    @MainActor final class Collector {
        private(set) var events: [VoiceListenerEvent] = []
        private var task: Task<Void, Never>?

        init(_ stream: AsyncStream<VoiceListenerEvent>) {
            task = Task { @MainActor [weak self] in
                for await event in stream { self?.events.append(event) }
            }
        }

        /// Let the consuming task run: yields are enough, the stream buffers.
        func settle() async {
            for _ in 0..<50 { await Task.yield() }
        }
    }

    let recognizer = FakeRecognizer()
    let tap = FakeTap()
    let session = StubAudioSession()
    let clock = TestClock()
    var authorized = true

    private func makeListener() -> AppleOnDeviceVoiceListener {
        AppleOnDeviceVoiceListener(
            audioSession: session,
            clock: { [clock] in clock.now },
            makeRecognizer: { [recognizer] _ in recognizer },
            makeAudioTap: { [tap] in tap },
            isSpeechAuthorized: { [authorized] in authorized })
    }

    /// `count` ticks of the listener's loop at `level`, 100 ms apart.
    private func ticks(_ listener: AppleOnDeviceVoiceListener, _ count: Int, at level: Double) {
        for _ in 0..<count {
            tap.push(level: level)
            clock.advance(0.1)
            listener.tick()
        }
    }

    /// Everything the stream carried, once it is finished.
    private func drain(_ stream: AsyncStream<VoiceListenerEvent>) async -> [VoiceListenerEvent] {
        var events: [VoiceListenerEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    // MARK: privacy contract

    @Test func everyRequestDemandsOnDeviceRecognition() throws {
        let listener = makeListener()
        let stream = try listener.start()
        listener.handle(VoiceRecognitionEvent(transcript: "hello", isFinal: true),
                        generation: listener.requestGeneration)
        listener.stop()
        _ = stream
        #expect(recognizer.requests.count >= 2)   // the utterance restarted it
        #expect(recognizer.requests.allSatisfy { $0.requiresOnDeviceRecognition })
        #expect(recognizer.requests.allSatisfy { $0.shouldReportPartialResults })
    }

    @Test func aRecognizerWithoutOnDeviceSupportRefusesToStart() {
        recognizer.supportsOnDeviceRecognition = false
        let listener = makeListener()
        #expect(throws: VoiceListenerError.onDeviceRecognitionUnsupported) { try listener.start() }
        #expect(session.activations == 0)
        #expect(tap.stops == 0)
    }

    @Test func anUnavailableRecognizerAndAnUnauthorizedOneEachRefuse() {
        recognizer.isRecognizerAvailable = false
        #expect(throws: VoiceListenerError.recognizerUnavailable) { try self.makeListener().start() }
        recognizer.isRecognizerAvailable = true
        var denied = self
        denied.authorized = false
        #expect(throws: VoiceListenerError.speechRecognitionDenied) { try denied.makeListener().start() }
    }

    // MARK: generations

    @Test func anUtteranceRestartsRecognitionWithAFreshGeneration() throws {
        let listener = makeListener()
        let stream = try listener.start()
        let first = listener.requestGeneration
        listener.handle(VoiceRecognitionEvent(transcript: "what is the weather", isFinal: true),
                        generation: first)
        #expect(listener.requestGeneration == first + 1)
        #expect(recognizer.requests.first?.finished == true)
        #expect(recognizer.tasks.first?.cancels == 1)
        listener.stop()
        _ = stream
    }

    /// H1/M3: the request we just finished reports its own cancellation, and
    /// may report one last result, long after a new request is installed.
    /// Neither may fail the session or be heard a second time.
    @Test func aStaleCallbackIsIgnoredInsteadOfFailingTheSession() async throws {
        let listener = makeListener()
        let stream = try listener.start()
        let stale = listener.requestGeneration

        listener.handle(VoiceRecognitionEvent(transcript: "turn on the lights", isFinal: true),
                        generation: stale)
        // The old task's cancel error, and a late result from it.
        listener.handle(VoiceRecognitionEvent(errorMessage: "Recognition request was canceled"),
                        generation: stale)
        listener.handle(VoiceRecognitionEvent(transcript: "turn on the lights", isFinal: true),
                        generation: stale)
        listener.stop()

        let events = await drain(stream)
        // The new hypothesis is captioned once and submitted once: no
        // .failed, and no second utterance from the finished request.
        #expect(events == [.partial("turn on the lights"), .utterance("turn on the lights")])
    }

    /// An error on the CURRENT generation is a real failure and still ends it.
    @Test func aCurrentGenerationErrorStillFailsTheSession() async throws {
        let listener = makeListener()
        let stream = try listener.start()
        listener.handle(VoiceRecognitionEvent(errorMessage: "kaput"),
                        generation: listener.requestGeneration)
        let events = await drain(stream)
        #expect(events == [.failed(.recognitionFailed(detail: "kaput"))])
        #expect(tap.stops == 1)
        #expect(session.deactivations == 1)
    }

    // MARK: mute (H2)

    /// Mute is a real mute: the tap's buffers never reach the request, so
    /// nothing accumulates behind the mute to be submitted on unmute.
    @Test func mutedAudioNeverReachesTheRequestAndUnmuteStartsClean() async throws {
        let listener = makeListener()
        let stream = try listener.start()
        let before = listener.requestGeneration

        listener.setPaused(true)
        tap.push()
        tap.push()
        #expect(recognizer.requests.last?.appended == 0)
        #expect(listener.requestGeneration == before)   // still the same request
        // A hypothesis that somehow arrives while paused is not noted either.
        listener.handle(VoiceRecognitionEvent(transcript: "muted words", isFinal: true),
                        generation: listener.requestGeneration)
        listener.tick()

        listener.setPaused(false)
        #expect(listener.requestGeneration == before + 1)   // a fresh request
        tap.push()
        #expect(recognizer.requests.last?.appended == 1)
        listener.handle(VoiceRecognitionEvent(transcript: "unmuted words", isFinal: true),
                        generation: listener.requestGeneration)
        listener.stop()

        let events = await drain(stream)
        #expect(events == [.partial("unmuted words"), .utterance("unmuted words")])
    }

    // MARK: playback bleed and barge-in

    /// A single loud tick is a transient, not speech. A sustained run is.
    @Test func oneLoudTickDoesNotStartSpeechButASustainedRunDoes() async throws {
        let listener = makeListener()
        let collector = Collector(try listener.start())
        ticks(listener, 1, at: 0.6)
        ticks(listener, 1, at: 0.0)
        ticks(listener, 3, at: 0.6)
        listener.stop()
        await collector.settle()
        #expect(collector.events.filter { $0 == .speechStarted }.count == 1)
    }

    /// While the reply plays, echo that would clear the IDLE trigger must not
    /// barge in.
    @Test func duringPlaybackLevelsAtTheIdleTriggerDoNotBargeIn() async throws {
        let listener = makeListener()
        let collector = Collector(try listener.start())
        listener.setPlaybackActive(true)
        clock.advance(VoiceAudioLevel.bargeInGrace)   // past the grace
        ticks(listener, 10, at: 0.2)
        listener.stop()
        await collector.settle()
        #expect(!collector.events.contains(.speechStarted))
    }

    @Test func duringPlaybackASustainedLoudRunIsAConfirmedBargeIn() async throws {
        let listener = makeListener()
        let collector = Collector(try listener.start())
        listener.setPlaybackActive(true)
        clock.advance(VoiceAudioLevel.bargeInGrace)
        ticks(listener, 3, at: 0.6)
        listener.stop()
        await collector.settle()
        #expect(collector.events.contains(.speechStarted))
    }

    /// Inside the grace right after playback starts, nothing counts: the echo
    /// canceller has not converged yet.
    @Test func theGraceAfterPlaybackStartsSwallowsEvenALoudRun() async throws {
        let listener = makeListener()
        let collector = Collector(try listener.start())
        listener.setPlaybackActive(true)
        ticks(listener, 4, at: 0.9)   // 400 ms, still inside the 500 ms grace
        listener.stop()
        await collector.settle()
        #expect(!collector.events.contains(.speechStarted))
    }

    /// The bug that fed the loop: the recognizer transcribes the reply's own
    /// first words. They must never become an utterance, and the request must
    /// be restarted when playback ends so the recognizer forgets them too.
    @Test func aHypothesisHeardOnlyDuringPlaybackIsDroppedAndRecognitionRestarts() async throws {
        let listener = makeListener()
        let collector = Collector(try listener.start())
        let before = listener.requestGeneration

        listener.setPlaybackActive(true)
        listener.handle(VoiceRecognitionEvent(transcript: "Here's"), generation: listener.requestGeneration)
        listener.handle(VoiceRecognitionEvent(transcript: "Here's the", isFinal: true),
                        generation: listener.requestGeneration)
        // Even a long quiet stretch cannot settle it: it never reached the
        // detector at all.
        ticks(listener, 20, at: 0.0)
        listener.setPlaybackActive(false)
        #expect(listener.requestGeneration == before + 1)   // the recognizer was cleared

        // The real user now speaks, and that goes through normally.
        listener.handle(VoiceRecognitionEvent(transcript: "what is the weather", isFinal: true),
                        generation: listener.requestGeneration)
        listener.stop()
        await collector.settle()
        #expect(!collector.events.contains(.utterance("Here's the")))
        #expect(!collector.events.contains(.partial("Here's")))
        #expect(collector.events.contains(.utterance("what is the weather")))
    }

    /// Recognition lags the audio: the reply's last word can arrive as a
    /// transcript only AFTER playback ended. With echo cancellation working
    /// no bleed text is seen during playback, so the restart must not depend
    /// on having seen any -- otherwise that late word is a trusted hypothesis
    /// and, after 1.2 s of quiet, a phantom turn.
    @Test func playbackEndRestartsRecognitionEvenWhenNoBleedTextWasSeen() async throws {
        let listener = makeListener()
        let collector = Collector(try listener.start())
        let before = listener.requestGeneration
        listener.setPlaybackActive(true)
        ticks(listener, 10, at: 0.0)
        let staleGeneration = listener.requestGeneration
        listener.setPlaybackActive(false)
        #expect(listener.requestGeneration == before + 1)

        // The late callback belongs to the request that heard the reply.
        listener.handle(VoiceRecognitionEvent(transcript: "forecast", isFinal: true), generation: staleGeneration)
        ticks(listener, 20, at: 0.0)
        listener.stop()
        await collector.settle()
        #expect(!collector.events.contains(.utterance("forecast")))
        #expect(!collector.events.contains(.partial("forecast")))
    }

    /// A confirmed barge-in keeps its request: the user's words are on it.
    @Test func playbackEndAfterAConfirmedBargeInDoesNotRestartRecognition() async throws {
        let listener = makeListener()
        _ = Collector(try listener.start())
        listener.setPlaybackActive(true)
        clock.advance(VoiceAudioLevel.bargeInGrace)
        ticks(listener, 3, at: 0.6)   // confirmed: this restarts once, to drop the reply's words
        let afterBargeIn = listener.requestGeneration
        listener.setPlaybackActive(false)
        #expect(listener.requestGeneration == afterBargeIn)
        listener.stop()
    }

    /// A confirmed barge-in means the user IS talking over the reply, so what
    /// the recognizer hears from then on is theirs and is kept.
    @Test func aConfirmedBargeInKeepsTheUtteranceThatFollowsIt() async throws {
        let listener = makeListener()
        let collector = Collector(try listener.start())
        listener.setPlaybackActive(true)
        clock.advance(VoiceAudioLevel.bargeInGrace)
        ticks(listener, 3, at: 0.6)   // a confirmed onset
        listener.handle(VoiceRecognitionEvent(transcript: "no, stop that", isFinal: true),
                        generation: listener.requestGeneration)
        listener.stop()
        await collector.settle()
        #expect(collector.events.contains(.speechStarted))
        #expect(collector.events.contains(.utterance("no, stop that")))
    }

    /// End of utterance is gated on quiet audio as well as still text: a
    /// thinking pause with the microphone still live does not send early.
    @Test func aStillHypothesisOverLiveAudioDoesNotSettleUntilTheMicGoesQuiet() async throws {
        let listener = makeListener()
        let collector = Collector(try listener.start())
        listener.handle(VoiceRecognitionEvent(transcript: "what is the"), generation: listener.requestGeneration)
        ticks(listener, 20, at: 0.3)   // 2 s of unchanged text over live audio
        await collector.settle()
        #expect(!collector.events.contains(.utterance("what is the")))
        ticks(listener, 14, at: 0.0)   // 1.4 s of quiet
        listener.stop()
        await collector.settle()
        #expect(collector.events.contains(.utterance("what is the")))
    }
}
