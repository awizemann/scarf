import Testing
import Foundation
@testable import ScarfCore

/// The engine-agnostic voice model: phase reducer (adapted from
/// @danmarauda's PR #143 `RealtimeVoicePhaseTests`), wire decoding against
/// the Hermes desktop's event shapes at v2026.9.14, client-event encoding,
/// page-message decoding, and cost/idle math.
@Suite struct VoiceConversationCoreTests {

    typealias R = VoiceConversationReducer

    private func live(_ phase: VoiceConversationPhase = .listening, speaking: Bool = false, delegation: Bool = false) -> VoiceConversationState {
        VoiceConversationState(phase: phase, assistantSpeaking: speaking, delegationActive: delegation)
    }

    // MARK: reducer

    @Test func happyPathConnectsThenListens() {
        var s = VoiceConversationState()
        s = R.reduce(s, .sessionLive)
        #expect(s.phase == .idle)   // a live echo before start is ignored
        s = R.reduce(s, .startRequested)
        #expect(s.phase == .connecting)
        s = R.reduce(s, .sessionLive)
        #expect(s.phase == .listening)
    }

    @Test func speakingWinsThenThinkingThenListening() {
        var s = live()
        s = R.reduce(s, .delegationStarted)
        #expect(s.phase == .thinking)
        s = R.reduce(s, .assistantSpeaking(true))
        #expect(s.phase == .speaking)          // "checking on that…" while Hermes works
        s = R.reduce(s, .assistantSpeaking(false))
        #expect(s.phase == .thinking)
        s = R.reduce(s, .delegationSettled)
        #expect(s.phase == .listening)
    }

    @Test func flagsTrackedWhileConnectingApplyOnceLive() {
        var s = R.reduce(VoiceConversationState(), .startRequested)
        s = R.reduce(s, .assistantSpeaking(true))
        #expect(s.phase == .connecting)
        s = R.reduce(s, .sessionLive)
        #expect(s.phase == .speaking)
    }

    @Test func endRequestedOnlyFromConnectingOrLive() {
        #expect(R.reduce(live(.thinking), .endRequested).phase == .ending)
        #expect(R.reduce(live(.connecting), .endRequested).phase == .ending)
        #expect(R.reduce(VoiceConversationState(), .endRequested).phase == .idle)
        #expect(R.reduce(live(.ending), .endRequested).phase == .ending)
    }

    @Test func endingIgnoresLiveTransitions() {
        let ending = live(.ending)
        #expect(R.reduce(ending, .assistantSpeaking(true)).phase == .ending)
        #expect(R.reduce(ending, .delegationStarted).phase == .ending)
        #expect(R.reduce(ending, .sessionLive).phase == .ending)
        #expect(R.reduce(ending, .ended(.userEnded)).phase == .ended(.userEnded))
    }

    @Test func terminalOutcomesClearFlags() {
        let s = R.reduce(live(.speaking, speaking: true, delegation: true), .failed(.connectionLost))
        #expect(s == VoiceConversationState(phase: .failed(.connectionLost)))
    }

    @Test func terminalPhasesIgnoreEverythingButANewStart() {
        for terminal in [VoiceConversationPhase.ended(.idleTimeout), .failed(.connectTimedOut)] {
            let s = VoiceConversationState(phase: terminal)
            for event: VoiceConversationEvent in [.sessionLive, .assistantSpeaking(true), .delegationStarted,
                                                  .endRequested, .ended(.userEnded), .failed(.connectionLost)] {
                #expect(R.reduce(s, event).phase == terminal)
            }
            #expect(R.reduce(s, .startRequested).phase == .connecting)
        }
        #expect(VoiceConversationPhase.idle.isTerminal == false)
        #expect(VoiceConversationPhase.ended(.stopPhrase).isTerminal)
    }

    @Test func startWhileActiveIsANoOp() {
        #expect(R.reduce(live(), .startRequested) == live())
    }

    @Test func onlyHostConfigurationFailuresAreSetupHints() {
        #expect(VoiceSessionFailure.host(.noKey).setupHint)
        #expect(VoiceSessionFailure.host(.unsupported).setupHint)
        #expect(VoiceSessionFailure.host(.interpreterNotFound(detail: "x")).setupHint)
        #expect(!VoiceSessionFailure.host(.vendor(status: 401, detail: "bad key")).setupHint)
        #expect(!VoiceSessionFailure.connectionLost.setupHint)
        #expect(VoiceSessionFailure.closedByVendor(reason: "max_duration", usageSeconds: 1799.6).englishDescription
                == "Live Voice ended: max_duration (1800 s).")
    }

    // MARK: server events — shapes from voice-live.ts:38-50, :373-441 @ v2026.9.14

    @Test func decodesTheDesktopEventShapes() {
        #expect(VoiceLiveServerEvent.decode(#"{"type":"session.started","event_id":"ev_1","session":{"id":"sess_123"}}"#)
                == .sessionStarted(id: "sess_123"))
        #expect(VoiceLiveServerEvent.decode(#"{"type":"session.input_transcript.delta","event_id":"ev_2","delta":"What is ","start_ms":1500,"end_ms":2500}"#)
                == .transcript(.init(speaker: .user, text: "What is ", startMs: 1500, endMs: 2500)))
        #expect(VoiceLiveServerEvent.decode(#"{"type":"session.output_transcript.delta","delta":"Hi","start_ms":0,"end_ms":1000.5}"#)
                == .transcript(.init(speaker: .assistant, text: "Hi", startMs: 0, endMs: 1000)))
        #expect(VoiceLiveServerEvent.decode(#"{"type":"session.delegation.created","event_id":"ev_3","delegation":{"id":"del_1","type":"client","target":"backend"}}"#)
                == .delegationCreated(id: "del_1"))
        #expect(VoiceLiveServerEvent.decode(#"{"type":"error","error":{"type":"invalid_request_error","code":"rate_limited","message":"slow down","client_event_id":"say_4"}}"#)
                == .error(code: "rate_limited", message: "slow down"))
        #expect(VoiceLiveServerEvent.decode(#"{"type":"session.closed","reason":"client_requested","usage":{"seconds":42.5}}"#)
                == .closed(reason: "client_requested", usageSeconds: 42.5))
    }

    @Test func missingFieldsDefaultLikeTheDesktop() {
        #expect(VoiceLiveServerEvent.decode(#"{"type":"session.started"}"#) == .sessionStarted(id: nil))
        #expect(VoiceLiveServerEvent.decode(#"{"type":"session.input_transcript.delta"}"#)
                == .transcript(.init(speaker: .user, text: "", startMs: 0, endMs: 0)))
        #expect(VoiceLiveServerEvent.decode(#"{"type":"error"}"#) == .error(code: nil, message: "GPT-Live error"))
        #expect(VoiceLiveServerEvent.decode(#"{"type":"session.closed"}"#) == .closed(reason: "closed", usageSeconds: nil))
        #expect(VoiceLiveServerEvent.decode(#"{"type":"session.delegation.created","delegation":{}}"#) == .other(type: "session.delegation.created"))
    }

    @Test func junkIsDroppedAndUnknownTypesAreIgnored() {
        #expect(VoiceLiveServerEvent.decode("not json") == nil)
        #expect(VoiceLiveServerEvent.decode(#"{"delta":"x"}"#) == nil)
        #expect(VoiceLiveServerEvent.decode(#"{"type":"session.commentary.done"}"#) == .other(type: "session.commentary.done"))
        #expect(VoiceLiveServerEvent.ignoredErrorCode == "context_injection_incomplete")
    }

    // MARK: client events — voice-live.ts:444-507

    @Test func clientEventsMatchTheDesktopWire() {
        var events = VoiceLiveClientEvents()
        #expect(events.encode(.thinking(delegationID: "del_1", content: "  Hermes is\nworking  ")) ==
                [#"{"content":"Hermes is working","delegation_id":"del_1","event_id":"think_1","type":"session.thinking.append"}"#])
        #expect(events.encode(.commentary(delegationID: "del_1", content: "It is sunny.")) ==
                [#"{"content":"It is sunny.","delegation_id":"del_1","event_id":"say_2","type":"session.commentary.append"}"#])
        #expect(events.encode(.instructions(content: " Respond now. ")) ==
                [#"{"content":"Respond now.","delegation_id":null,"event_id":"instr_3","type":"session.instructions.append"}"#])
        #expect(events.encode(.mute) == [#"{"event_id":"mute_4","type":"session.input_audio.mute"}"#])
        #expect(events.encode(.unmute) == [#"{"event_id":"unmute_5","type":"session.input_audio.unmute"}"#])
        #expect(events.encode(.close) == [#"{"type":"session.close"}"#])
        #expect(events.encode(.commentary(delegationID: nil, content: "  ")).isEmpty)
        #expect(events.encode(.thinking(delegationID: nil, content: "")).isEmpty)
    }

    @Test func longCommentaryIsChunkedIntoSeparateAppends() throws {
        var events = VoiceLiveClientEvents()
        let reply = String(repeating: "This is a sentence about the result. ", count: 80)
        let sent = events.encode(.commentary(delegationID: "d", content: reply))
        #expect(sent.count > 1)
        for json in sent {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect((object["content"] as? String ?? "").count <= VoiceLiveText.appendCharLimit)
        }
    }

    @Test func thinkingIsCappedAtTheAppendLimit() throws {
        var events = VoiceLiveClientEvents()
        let json = try #require(events.encode(.thinking(delegationID: "d", content: String(repeating: "a", count: 3_000))).first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["content"] as? String)?.count == 1_400)
    }

    // MARK: page → Swift messages

    @Test func pageMessagesDecode() {
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "ready", "secure": true]) == .pageReady(secureContext: true))
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "offer", "sdp": "v=0\r\n"]) == .offer(sdp: "v=0\r\n"))
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "channelOpen"]) == .channelOpen)
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "event", "data": "{}"]) == .serverMessage("{}"))
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "speaking", "value": true]) == .assistantSpeaking(true))
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "level", "value": 0.4]) == .micLevel(0.4))
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "level", "value": 7]) == .micLevel(1))
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "closed", "reason": "connection_lost"]) == .transportClosed(reason: "connection_lost"))
    }

    @Test func malformedPageMessagesAreIgnored() {
        #expect(VoiceMediaEvent.decode(messageBody: "offer") == nil)
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "offer"]) == nil)
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "offer", "sdp": ""]) == nil)
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "event", "data": 3]) == nil)
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "level", "value": "loud"]) == nil)
        #expect(VoiceMediaEvent.decode(messageBody: ["type": "eval", "code": "x"]) == nil)
    }

    // MARK: cost + idle

    @Test func costIsFiveCentsAMinute() {
        #expect(VoiceSessionCost.gptLiveUSDPerMinute == 0.05)
        #expect(VoiceSessionCost.approximateUSD(seconds: 60) == 0.05)
        #expect(abs(VoiceSessionCost.approximateUSD(seconds: 90) - 0.075) < 1e-12)
        #expect(VoiceSessionCost.approximateUSD(seconds: -5) == 0)
    }

    @Test func meterUsesTheClockUntilTheVendorReportsUsage() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var meter = VoiceSessionMeter()
        #expect(meter.elapsed(at: t0) == 0)
        meter.start(at: t0)
        #expect(meter.elapsed(at: t0.addingTimeInterval(120)) == 120)
        #expect(abs(meter.approximateCostUSD(at: t0.addingTimeInterval(120)) - 0.10) < 1e-12)
        meter.stop(at: t0.addingTimeInterval(130), billedSeconds: nil)
        #expect(meter.elapsed(at: t0.addingTimeInterval(999)) == 130)   // frozen
        var billed = VoiceSessionMeter()
        billed.start(at: t0)
        billed.stop(at: t0.addingTimeInterval(130), billedSeconds: 127.5)
        #expect(billed.elapsed(at: t0.addingTimeInterval(999)) == 127.5)
    }

    @Test func idleMonitorHonoursBusyAndTimeout() {
        let t0 = Date(timeIntervalSince1970: 0)
        var idle = VoiceIdleMonitor(now: t0)
        #expect(idle.timeout == 180)
        #expect(!idle.isIdle(at: t0.addingTimeInterval(179), busy: false))
        #expect(idle.isIdle(at: t0.addingTimeInterval(180), busy: false))
        #expect(!idle.isIdle(at: t0.addingTimeInterval(500), busy: true))
        idle.noteActivity(at: t0.addingTimeInterval(100))
        #expect(!idle.isIdle(at: t0.addingTimeInterval(200), busy: false))
        idle.noteActivity(at: t0.addingTimeInterval(50))   // never moves backwards
        #expect(idle.isIdle(at: t0.addingTimeInterval(280), busy: false))
        #expect(!VoiceIdleMonitor(timeout: 0, now: t0).isIdle(at: t0.addingTimeInterval(1e6), busy: false))
    }

    // MARK: reply extraction for RichChatViewModel hosts

    @Test func replyIsTheAssistantTextAfterTheVoiceTurn() {
        func message(_ id: Int, _ role: String, _ content: String) -> HermesMessage {
            HermesMessage(id: id, sessionId: "s", role: role, content: content, toolCallId: nil, toolCalls: [],
                          toolName: nil, timestamp: nil, tokenCount: nil, finishReason: nil, reasoning: nil)
        }
        let messages = [
            message(1, "user", "earlier"), message(2, "assistant", "old answer"),
            message(-1, "user", "what is the weather"), message(-2, "assistant", "Checking."),
            message(-3, "tool", "{...}"), message(0, "assistant", "It is sunny."),
        ]
        #expect(VoiceTurnReply.latest(in: messages, forPrompt: "what is the weather", isStreaming: true)
                == VoiceTurnReply(text: "Checking.\n\nIt is sunny.", isStreaming: true))
        #expect(VoiceTurnReply.latest(in: messages, forPrompt: "something else", isStreaming: false) == nil)
        #expect(VoiceTurnReply.latest(in: Array(messages.prefix(3)), forPrompt: "what is the weather", isStreaming: true) == nil)
    }

    /// A superseding turn is stored as Hermes's rewrite
    /// (`_attach_interrupted_prompt`, acp_adapter/server.py:201-202 @
    /// v2026.9.14); a transcript reloaded from state.db must still match.
    @Test func replyMatchesHermessInterruptRewriteOfTheRow() {
        func message(_ id: Int, _ role: String, _ content: String) -> HermesMessage {
            HermesMessage(id: id, sessionId: "s", role: role, content: content, toolCallId: nil, toolCalls: [],
                          toolName: nil, timestamp: nil, tokenCount: nil, finishReason: nil, reasoning: nil)
        }
        let rewritten = "book the dentist friday\n\nUser correction/guidance after interrupt: no, thursday"
        let messages = [message(9, "user", rewritten), message(10, "assistant", "Moved to Thursday.")]
        #expect(VoiceTurnReply.latest(in: messages, forPrompt: "no, thursday", isStreaming: false)
                == VoiceTurnReply(text: "Moved to Thursday.", isStreaming: false))
        #expect(VoiceTurnReply.latest(in: messages, forPrompt: "thursday", isStreaming: false) == nil)
    }
}
