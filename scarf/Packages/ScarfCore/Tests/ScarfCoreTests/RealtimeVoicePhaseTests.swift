import Testing
import Foundation
@testable import ScarfCore

/// The pure UI state machine for live voice — including the barge-in
/// transition (speaking → listening on user speech) and the
/// ended-vs-failed split on close.
@Suite struct RealtimeVoicePhaseTests {

    @Test func happyPathConnectsThenListens() {
        var phase = VoiceLivePhase.idle
        phase = VoiceLivePhaseReducer.next(phase, after: .sessionCreated(sessionID: "s1"))
        #expect(phase == .idle) // session echo before start is ignored

        phase = .connecting
        phase = VoiceLivePhaseReducer.next(phase, after: .sessionCreated(sessionID: "s1"))
        #expect(phase == .listening)
    }

    @Test func speakingBeginsWithOutputAndReturnsOnCompletion() {
        var phase = VoiceLivePhase.listening
        phase = VoiceLivePhaseReducer.next(phase, after: .outputItemStarted(itemID: "a"))
        #expect(phase == .speaking)
        phase = VoiceLivePhaseReducer.next(phase, after: .outputAudioDelta(itemID: "a", data: Data([0, 0])))
        #expect(phase == .speaking)
        phase = VoiceLivePhaseReducer.next(phase, after: .responseCompleted)
        #expect(phase == .listening)
    }

    @Test func bargeInCutsSpeakingBackToListening() {
        let phase = VoiceLivePhaseReducer.next(
            .speaking,
            after: .userSpeechStarted
        )
        #expect(phase == .listening)
    }

    @Test func responseCancelledAlsoReturnsTheFloor() {
        #expect(VoiceLivePhaseReducer.next(.speaking, after: .responseCancelled) == .listening)
    }

    @Test func sessionEchoesDoNotRegressASpeakingTurn() {
        // A late `session.updated` while the assistant talks must not
        // flip the phase back to listening.
        #expect(VoiceLivePhaseReducer.next(.speaking, after: .sessionUpdated) == .speaking)
    }

    @Test func transcriptDeltasNeverChangeThePhase() {
        #expect(VoiceLivePhaseReducer.next(.speaking, after: .assistantTranscriptDelta("hi")) == .speaking)
        #expect(VoiceLivePhaseReducer.next(.listening, after: .userTranscriptDelta("he")) == .listening)
        #expect(VoiceLivePhaseReducer.next(.listening, after: .userTranscriptCompleted("hey")) == .listening)
    }

    @Test func serverErrorFailsTheSession() {
        let phase = VoiceLivePhaseReducer.next(
            .listening,
            after: .errorOccurred(message: "quota exceeded", type: "rate_limit_error")
        )
        #expect(phase == .failed("quota exceeded"))
    }

    @Test func connectPhaseErrorBecomesFailed() {
        #expect(VoiceLivePhaseReducer.next(
            .connecting,
            after: .errorOccurred(message: "bad token", type: "invalid_request_error")
        ) == .failed("bad token"))
    }

    @Test func clientCloseEndsTheSession() {
        #expect(VoiceLivePhaseReducer.next(.listening, after: .closed(reason: .clientInitiated)) == .ended)
        #expect(VoiceLivePhaseReducer.next(.speaking, after: .closed(reason: .clientInitiated)) == .ended)
    }

    @Test func serverCloseMidSessionFailsWithRestartHint() {
        let phase = VoiceLivePhaseReducer.next(
            .speaking,
            after: .closed(reason: .serverClosed(detail: nil))
        )
        guard case .failed(let message) = phase else {
            Issue.record("expected failed, got \(phase)")
            return
        }
        #expect(message.contains("new session"))
    }

    @Test func transportFailureMidSessionFailsWithDetail() {
        let phase = VoiceLivePhaseReducer.next(
            .listening,
            after: .closed(reason: .transportFailed(detail: "connection lost"))
        )
        guard case .failed(let message) = phase else {
            Issue.record("expected failed, got \(phase)")
            return
        }
        #expect(message.contains("connection lost"))
    }

    @Test func closeDuringConnectingIsAFailureNotAnEnd() {
        // Socket died before session.started — that is a connect
        // failure; "ended" would imply a session existed.
        let phase = VoiceLivePhaseReducer.next(.connecting, after: .closed(reason: .serverClosed(detail: nil)))
        guard case .failed = phase else {
            Issue.record("expected failed, got \(phase)")
            return
        }
    }

    @Test func terminalPhasesIgnoreEverything() {
        for terminal in [VoiceLivePhase.ended, VoiceLivePhase.failed("x")] {
            #expect(VoiceLivePhaseReducer.next(terminal, after: .outputItemStarted(itemID: "a")) == terminal)
            #expect(VoiceLivePhaseReducer.next(terminal, after: .sessionCreated(sessionID: "s")) == terminal)
            #expect(VoiceLivePhaseReducer.next(terminal, after: .closed(reason: .serverClosed(detail: nil))) == terminal)
        }
        #expect(VoiceLivePhase.idle.isTerminal == false)
        #expect(VoiceLivePhase.ended.isTerminal)
    }

    @Test func outputEventsCannotWakeATerminalPhase() {
        // Audio deltas racing the user's stop button must not resurrect
        // an ended session into "speaking".
        #expect(VoiceLivePhaseReducer.next(.ended, after: .outputAudioDelta(itemID: "a", data: Data())) == .ended)
        #expect(VoiceLivePhaseReducer.next(.failed("x"), after: .outputItemStarted(itemID: "a")) == .failed("x"))
    }
}
