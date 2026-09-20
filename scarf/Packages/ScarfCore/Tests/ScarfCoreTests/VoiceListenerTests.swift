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

        /// One buffer of silence, as the audio thread would deliver it.
        func push() {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
            buffer.frameLength = 64
            onBuffer?(buffer)
        }
    }

    @MainActor final class StubAudioSession: VoiceAudioSessionControlling {
        private(set) var activations = 0
        private(set) var deactivations = 0
        func activateForVoiceConversation() throws { activations += 1 }
        func deactivate() { deactivations += 1 }
    }

    // MARK: harness

    let recognizer = FakeRecognizer()
    let tap = FakeTap()
    let session = StubAudioSession()
    var authorized = true

    private func makeListener() -> AppleOnDeviceVoiceListener {
        AppleOnDeviceVoiceListener(
            audioSession: session,
            makeRecognizer: { [recognizer] _ in recognizer },
            makeAudioTap: { [tap] in tap },
            isSpeechAuthorized: { [authorized] in authorized })
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
}
