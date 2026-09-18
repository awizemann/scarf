import Testing
import Foundation
@testable import ScarfCore

/// The GPT-Live conversation loop with a fake media bridge, a fake host
/// exchange and a fake chat — no WebKit, no network, no OpenAI. Timers run
/// on an injected clock through `tick()`. Behaviour mirrors the Hermes
/// desktop's `use-voice-live-conversation.ts` @ v2026.9.14.
@MainActor
@Suite(.serialized) struct GPTLiveEngineTests {

    // MARK: fakes

    final class FakeBridge: VoiceMediaBridge {
        var onEvent: (@MainActor @Sendable (VoiceMediaEvent) -> Void)?
        var startError: Error?
        var answers: [String] = []
        var sent: [String] = []
        var micEnabled: [Bool] = []
        var teardowns = 0

        func startMedia() async throws {
            if let startError { throw startError }
        }
        func applyAnswer(sdp: String) async throws { answers.append(sdp) }
        func send(_ json: String) { sent.append(json) }
        func setMicrophoneEnabled(_ enabled: Bool) { micEnabled.append(enabled) }
        func teardown() { teardowns += 1 }

        func emit(_ event: VoiceMediaEvent) { onEvent?(event) }
        func server(_ json: String) { emit(.serverMessage(json)) }

        /// Decoded client events of one type.
        func sent(type: String) -> [[String: Any]] {
            sent.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .filter { $0["type"] as? String == type }
        }
        func spoken() -> [String] { sent(type: "session.commentary.append").compactMap { $0["content"] as? String } }
        func thoughts() -> [String] { sent(type: "session.thinking.append").compactMap { $0["content"] as? String } }
    }

    final class FakeExchange: VoiceLiveSessionExchanging, @unchecked Sendable {
        private let lock = NSLock()
        private var _result: Result<VoiceLiveSessionAnswer, Error> = .success(.init(sessionID: "sess_x", sdp: "v=0 answer\r\n"))
        private var _offers: [String] = []
        private var _histories: [[VoiceLiveHistoryMessage]] = []
        var delay: Duration = .zero

        var result: Result<VoiceLiveSessionAnswer, Error> {
            get { lock.withLock { _result } }
            set { lock.withLock { _result = newValue } }
        }
        var offers: [String] { lock.withLock { _offers } }
        var histories: [[VoiceLiveHistoryMessage]] { lock.withLock { _histories } }

        func createSession(offerSDP: String, history: [VoiceLiveHistoryMessage]) async throws -> VoiceLiveSessionAnswer {
            lock.withLock { _offers.append(offerSDP); _histories.append(history) }
            if delay != .zero { try? await Task.sleep(for: delay) }
            return try result.get()
        }
    }

    final class FakeHost: VoiceTurnHost {
        var isVoiceTurnBusy = false
        var activeVoiceToolName: String?
        var submitted: [VoiceTurnRequest] = []
        var log: [String] = []
        var replies: [String: VoiceTurnReply] = [:]
        var submitError: Error?
        var seed: [VoiceLiveText.SeedTurn] = []

        func submitVoiceTurn(_ request: VoiceTurnRequest) async throws {
            log.append("submit \(request.id)")
            if let submitError { throw submitError }
            submitted.append(request)
            isVoiceTurnBusy = true
        }
        func cancelActiveVoiceTurn() async {
            log.append("cancel begin")
            try? await Task.sleep(for: .milliseconds(20))   // the in-flight sendPrompt returning
            isVoiceTurnBusy = false
            log.append("cancel end")
        }
        func voiceTurnReply(for requestID: String) -> VoiceTurnReply? { replies[requestID] }
        func voiceSeedTurns() -> [VoiceLiveText.SeedTurn] { seed }
    }

    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    final class Clock { var now = Date(timeIntervalSince1970: 1_000_000) }

    // MARK: harness

    let bridge = FakeBridge()
    let exchange = FakeExchange()
    let host = FakeHost()
    let clock = Clock()
    let engine: GPTLiveEngine

    init() {
        var config = GPTLiveEngine.Configuration()
        config.tickInterval = nil
        let clock = self.clock
        engine = GPTLiveEngine(bridge: bridge, exchange: exchange, turnHost: host, configuration: config, clock: { clock.now })
    }

    private func advance(_ seconds: TimeInterval) {
        clock.now = clock.now.addingTimeInterval(seconds)
        engine.tick()
    }

    private func settle(_ condition: @MainActor () -> Bool = { false }) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Start, exchange, and go live.
    private func goLive() async {
        let answered = bridge.answers.count
        await engine.start()
        bridge.emit(.offer(sdp: "v=0 offer\r\n"))
        await settle { bridge.answers.count == answered + 1 }
        bridge.emit(.channelOpen)
        bridge.server(#"{"type":"session.started","session":{"id":"sess_x"}}"#)
    }

    private func user(_ text: String, at ms: Int = 1_000) {
        bridge.server(#"{"type":"session.input_transcript.delta","delta":"\#(text)","start_ms":\#(ms),"end_ms":\#(ms + 500)}"#)
    }

    private func assistant(_ text: String, at ms: Int = 500) {
        bridge.server(#"{"type":"session.output_transcript.delta","delta":"\#(text)","start_ms":\#(ms),"end_ms":\#(ms + 400)}"#)
    }

    private func delegate(_ id: String) {
        bridge.server(#"{"type":"session.delegation.created","delegation":{"id":"\#(id)","type":"client","target":"backend"}}"#)
    }

    // MARK: start

    @Test func startExchangesTheOfferOnTheHostAndGoesLive() async {
        host.seed = [.init(role: .user, text: "hello"), .init(role: .assistant, text: "hi there")]
        await goLive()
        #expect(exchange.offers == ["v=0 offer\r\n"])
        #expect(exchange.histories.first?.map(\.role) == [.user, .assistant])
        #expect(bridge.answers == ["v=0 answer\r\n"])
        #expect(engine.phase == .listening)
        #expect(engine.sessionID == "sess_x")
    }

    @Test func missingKeyFailsWithTheSetupMessageAndChargesNothing() async {
        exchange.result = .failure(VoiceLiveHostError.noKey)
        await engine.start()
        bridge.emit(.offer(sdp: "v=0"))
        await settle { engine.phase.isTerminal }
        guard case .failed(let message) = engine.phase else { Issue.record("\(engine.phase)"); return }
        #expect(message.contains("OPENAI_API_KEY"))
        #expect(bridge.answers.isEmpty)
        #expect(bridge.teardowns == 1)
        #expect(engine.approximateCostUSD == 0)
    }

    @Test func microphoneFailureFailsTheStart() async {
        bridge.startError = Boom()
        await engine.start()
        guard case .failed(let message) = engine.phase else { Issue.record("\(engine.phase)"); return }
        #expect(message.contains("boom"))
        #expect(bridge.teardowns == 1)
    }

    @Test func transportClosedWhileConnectingNamesTheReason() async {
        await engine.start()
        bridge.emit(.transportClosed(reason: "microphone_denied"))
        guard case .failed(let message) = engine.phase else { Issue.record("\(engine.phase)"); return }
        #expect(message.contains("microphone"))
    }

    @Test func startTimesOut() async {
        await engine.start()
        advance(74)
        #expect(engine.phase == .connecting)
        advance(2)
        guard case .failed = engine.phase else { Issue.record("\(engine.phase)"); return }
        #expect(bridge.teardowns == 1)
    }

    @Test func anAnswerThatArrivesAfterEndIsNeverApplied() async {
        exchange.delay = .milliseconds(60)
        await engine.start()
        bridge.emit(.offer(sdp: "v=0"))
        engine.end(reason: .userEnded)
        #expect(engine.phase == .ended(.userEnded))
        try? await Task.sleep(for: .milliseconds(120))
        #expect(bridge.answers.isEmpty)
        #expect(bridge.sent.isEmpty)
    }

    // MARK: delegation → Hermes turn

    @Test func delegationSubmitsTheLastUtteranceWithTheExchangeAsContext() async {
        await goLive()
        assistant("How can I help?")
        user("What is ", at: 1_000)
        user("the weather in Paris?", at: 1_500)
        delegate("del_1")
        await settle { host.submitted.count == 1 }
        let request = host.submitted.first
        #expect(request?.id == "del_1")
        #expect(request?.prompt == "What is the weather in Paris?")
        #expect(request?.context == "Voice assistant: How can I help?\nUser: What is the weather in Paris?")
        #expect(request?.contextNotes == [VoiceLiveTurnNote.contextNote(context: request?.context ?? "")])
        #expect(engine.phase == .thinking)
    }

    @Test func streamingReplyIsSpokenSentenceBySentenceThenTheTail() async {
        await goLive()
        user("weather?")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.replies["d1"] = VoiceTurnReply(text: "It is **sunny** today. The high is", isStreaming: true)
        advance(0.2)
        #expect(bridge.spoken() == ["It is sunny today."])
        advance(0.2)
        #expect(bridge.spoken() == ["It is sunny today."])   // nothing new completed
        host.replies["d1"] = VoiceTurnReply(text: "It is **sunny** today. The high is 21 degrees.", isStreaming: false)
        host.isVoiceTurnBusy = false
        advance(0.2)
        #expect(bridge.spoken() == ["It is sunny today.", "The high is 21 degrees."])
        #expect(engine.phase == .listening)
        #expect(bridge.spoken().allSatisfy { !$0.contains("*") })
    }

    @Test func toolProgressIsAQuietThinkingNoteOncePerTool() async {
        await goLive()
        user("run the tests")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.activeVoiceToolName = "terminal"
        advance(0.2)
        advance(0.2)
        host.activeVoiceToolName = "read_file"
        advance(0.2)
        #expect(bridge.thoughts() == ["Hermes is working: terminal. Not done yet.", "Hermes is working: read_file. Not done yet."])
    }

    @Test func aTurnThatSettlesWithNothingToSaySaysSo() async {
        await goLive()
        user("tidy up")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        advance(0.2)                       // seen busy
        host.isVoiceTurnBusy = false       // finished, no reply text
        advance(0.2)
        #expect(bridge.thoughts() == ["Hermes finished that request without a spoken result."])
        #expect(engine.phase == .listening)
    }

    @Test func anUnobservedTurnSettlesOnlyAfterTheGrace() async {
        await goLive()
        user("hello?")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.isVoiceTurnBusy = false       // never seen running (the ack lags)
        advance(10)
        #expect(engine.phase == .thinking)
        advance(6)
        #expect(engine.phase == .listening)
        #expect(bridge.thoughts().count == 1)
    }

    @Test func aNewDelegationCancelsAndAwaitsTheBusyTurnBeforeSubmitting() async {
        await goLive()
        user("book the dentist friday")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        #expect(host.isVoiceTurnBusy)
        user(" no, thursday", at: 3_000)
        delegate("d2")
        await settle { host.submitted.count == 2 }
        #expect(host.log == ["submit d1", "cancel begin", "cancel end", "submit d2"])
        #expect(host.submitted.last?.prompt == "book the dentist friday no, thursday")
        // d1's late reply is never spoken for d2.
        host.replies["d1"] = VoiceTurnReply(text: "Booked Friday.", isStreaming: false)
        advance(0.2)
        #expect(bridge.spoken().isEmpty)
    }

    @Test func aSubmitFailureApologisesAndSettles() async {
        host.submitError = Boom()
        await goLive()
        user("do it")
        delegate("d1")
        await settle { engine.phase == .listening }
        #expect(bridge.spoken() == [GPTLiveEngine.unreachableReply])
    }

    // MARK: stop phrases

    @Test func aDelegatedStopPhraseEndsInsteadOfSubmitting() async {
        await goLive()
        user("Stop.")
        delegate("d1")
        #expect(engine.phase == .ending)
        #expect(bridge.sent(type: "session.close").count == 1)
        await settle()
        #expect(host.submitted.isEmpty)
        bridge.server(#"{"type":"session.closed","reason":"client_requested","usage":{"seconds":12}}"#)
        #expect(engine.phase == .ended(.stopPhrase))
    }

    @Test func aStopPhraseEndsAfterAQuietPause() async {
        await goLive()
        user("that's ")
        user("all")
        advance(1.0)
        #expect(engine.phase == .listening)
        advance(0.6)
        #expect(engine.phase == .ending)
    }

    @Test func aRequestThatMentionsStopDoesNotEnd() async {
        await goLive()
        user("stop the docker container")
        advance(2)
        #expect(engine.phase == .listening)
    }

    // MARK: end, idle, cost

    @Test func gracefulEndWaitsForUsageThenReportsIt() async {
        await goLive()
        advance(90)
        #expect(engine.elapsedSeconds == 90)
        #expect(abs(engine.approximateCostUSD - 0.075) < 1e-9)
        engine.end(reason: .userEnded)
        #expect(engine.phase == .ending)
        #expect(bridge.teardowns == 0)
        bridge.server(#"{"type":"session.closed","reason":"client_requested","usage":{"seconds":93}}"#)
        #expect(engine.phase == .ended(.userEnded))
        #expect(engine.elapsedSeconds == 93)
        #expect(abs(engine.approximateCostUSD - 0.0775) < 1e-9)
        #expect(bridge.teardowns == 1)
    }

    @Test func endGivesUpWaitingAfterFifteenSeconds() async {
        await goLive()
        engine.end(reason: .userEnded)
        advance(14)
        #expect(engine.phase == .ending)
        advance(2)
        #expect(engine.phase == .ended(.userEnded))
        #expect(bridge.teardowns == 1)
    }

    @Test func endImmediatelyTearsDownAtOnce() async {
        await goLive()
        engine.endImmediately(reason: .userEnded)
        #expect(bridge.sent(type: "session.close").count == 1)
        #expect(bridge.teardowns == 1)
        #expect(engine.phase == .ended(.userEnded))
    }

    @Test func idleSessionsEndThemselves() async {
        await goLive()
        advance(179)
        #expect(engine.phase == .listening)
        advance(2)
        #expect(engine.phase == .ending)
        bridge.server(#"{"type":"session.closed","reason":"client_requested","usage":{"seconds":181}}"#)
        #expect(engine.phase == .ended(.idleTimeout))
    }

    @Test func speechResetsTheIdleClockAndHermesWorkPausesIt() async {
        await goLive()
        advance(170)
        user("one more thing")
        advance(170)
        #expect(engine.phase == .listening)
        delegate("d1")
        await settle { host.submitted.count == 1 }
        advance(400)                        // Hermes still busy: never idle
        #expect(engine.phase == .thinking)
        host.isVoiceTurnBusy = false
        advance(0.2)                        // settles; the idle clock restarts here
        advance(179)
        #expect(engine.phase == .listening)
        advance(2)
        #expect(engine.phase == .ending)
    }

    @Test func anUnrequestedCloseIsAFailureWithTheReason() async {
        await goLive()
        bridge.server(#"{"type":"session.closed","reason":"max_duration","usage":{"seconds":1800}}"#)
        guard case .failed(let message) = engine.phase else { Issue.record("\(engine.phase)"); return }
        #expect(message.contains("max_duration"))
        #expect(engine.elapsedSeconds == 1800)
        #expect(abs(engine.approximateCostUSD - 1.5) < 1e-9)
    }

    @Test func connectionLossFails() async {
        await goLive()
        bridge.emit(.transportClosed(reason: "connection_lost"))
        #expect(engine.phase == .failed(GPTLiveEngine.message(forCloseReason: "connection_lost", usageSeconds: nil)))
    }

    // MARK: captions, notices, mute, restart

    @Test func captionsMergeBySpeaker() async {
        await goLive()
        assistant("Hi, how ")
        assistant("can I help?")
        user("What's up")
        #expect(engine.captions.map(\.text) == ["Hi, how can I help?", "What's up"])
        #expect(engine.captions.map(\.speaker) == [.assistant, .user])
    }

    @Test func vendorErrorsAreNoticesExceptLateInjections() async {
        await goLive()
        bridge.server(#"{"type":"error","error":{"code":"context_injection_incomplete","message":"late"}}"#)
        #expect(engine.notice == nil)
        bridge.server(#"{"type":"error","error":{"code":"rate_limited","message":"Slow down"}}"#)
        #expect(engine.notice == "Slow down")
        #expect(engine.phase == .listening)
    }

    @Test func muteDisablesTheTrackAndTellsTheVendor() async {
        await goLive()
        engine.toggleMute()
        #expect(engine.isMuted)
        #expect(bridge.micEnabled == [false])
        #expect(bridge.sent(type: "session.input_audio.mute").count == 1)
        engine.toggleMute()
        #expect(bridge.micEnabled == [false, true])
        #expect(bridge.sent(type: "session.input_audio.unmute").count == 1)
    }

    @Test func assistantSpeakingDrivesThePhase() async {
        await goLive()
        bridge.emit(.assistantSpeaking(true))
        #expect(engine.phase == .speaking)
        bridge.emit(.assistantSpeaking(false))
        #expect(engine.phase == .listening)
    }

    @Test func theEngineCanStartAgainAfterEnding() async {
        await goLive()
        engine.endImmediately(reason: .userEnded)
        await goLive()
        #expect(engine.phase == .listening)
        #expect(engine.captions.isEmpty)
        #expect(exchange.offers.count == 2)
    }
}
