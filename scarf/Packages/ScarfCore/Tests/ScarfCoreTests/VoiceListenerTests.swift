import Testing
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
