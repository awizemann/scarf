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
        /// When set, startMedia() suspends until the test resumes it.
        var holdStart = false
        var startContinuation: CheckedContinuation<Void, Never>?
        var answers: [String] = []
        var sent: [String] = []
        var micEnabled: [Bool] = []
        var teardowns = 0
        /// When set, teardown() keeps the media "held" until releaseMedia().
        var holdRelease = false
        var pendingReleases: [@MainActor @Sendable () -> Void] = []
        /// The order of close sends and teardowns, to prove the close leaves first.
        var order: [String] = []

        func startMedia() async throws {
            if holdStart { await withCheckedContinuation { startContinuation = $0 } }
            if let startError { throw startError }
        }
        func releaseStart() {
            startContinuation?.resume()
            startContinuation = nil
        }
        /// When set, applyAnswer() throws it — WebKit's raw
        /// setRemoteDescription exception, which quotes the SDP back.
        var answerError: Error?
        func applyAnswer(sdp: String) async throws {
            answers.append(sdp)
            if let answerError { throw answerError }
        }
        func send(_ json: String) {
            sent.append(json)
            if json.contains("session.close") { order.append("close") }
        }
        func setMicrophoneEnabled(_ enabled: Bool) { micEnabled.append(enabled) }
        func teardown(onReleased: (@MainActor @Sendable () -> Void)?) {
            teardowns += 1
            order.append("teardown")
            guard let onReleased else { return }
            if holdRelease { pendingReleases.append(onReleased) } else { onReleased() }
        }
        func releaseMedia() {
            let releases = pendingReleases
            pendingReleases = []
            for release in releases { release() }
        }

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
        var voiceChatID: String?
        /// A slow cancel: the host's bounded wait ends with the turn still running.
        var stillBusyAfterCancel = false

        func submitVoiceTurn(_ request: VoiceTurnRequest) async throws {
            log.append("submit \(request.id)")
            if let submitError { throw submitError }
            submitted.append(request)
            isVoiceTurnBusy = true
        }
        /// When set, cancelActiveVoiceTurn() suspends until the test resumes it.
        var holdCancel = false
        var cancelContinuation: CheckedContinuation<Void, Never>?
        func releaseCancel() {
            cancelContinuation?.resume()
            cancelContinuation = nil
        }

        func cancelActiveVoiceTurn() async {
            log.append("cancel begin")
            if holdCancel { await withCheckedContinuation { cancelContinuation = $0 } }
            try? await Task.sleep(for: .milliseconds(20))   // the in-flight sendPrompt returning
            if !stillBusyAfterCancel { isVoiceTurnBusy = false }
            log.append("cancel end")
        }
        func voiceTurnReply(for requestID: String) -> VoiceTurnReply? { replies[requestID] }
        func voiceSeedTurns() -> [VoiceLiveText.SeedTurn] { seed }
    }

    struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
    /// What the bridge throws for a JS exception: its message.
    struct ScriptError: LocalizedError { let errorDescription: String? }

    final class Clock { var now = Date(timeIntervalSince1970: 1_000_000) }

    // MARK: harness

    let bridge = FakeBridge()
    let exchange = FakeExchange()
    let host = FakeHost()
    let clock = Clock()
    let ledger = VoiceTextOnlyTurnLedger()
    let engine: GPTLiveEngine

    init() {
        engine = Self.makeEngine(bridge: bridge, exchange: exchange, host: host, clock: clock, ledger: ledger)
    }

    static func makeEngine(bridge: FakeBridge, exchange: FakeExchange, host: FakeHost, clock: Clock,
                           ledger: VoiceTextOnlyTurnLedger) -> GPTLiveEngine {
        var config = GPTLiveEngine.Configuration()
        config.tickInterval = nil
        return GPTLiveEngine(bridge: bridge, exchange: exchange, turnHost: host, configuration: config,
                             textOnlyTurns: ledger, clock: { clock.now })
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
        #expect(engine.phase == .failed(.host(.noKey)))
        guard case .failed(let failure) = engine.phase else { return }
        #expect(failure.setupHint)
        #expect(failure.englishDescription.contains("OPENAI_API_KEY"))
        #expect(bridge.answers.isEmpty)
        #expect(bridge.teardowns == 1)
        #expect(engine.approximateCostUSD == 0)
    }

    /// F3 #6: getUserMedia's exception name picks the failure, whichever of
    /// the page's `closed` message and the start's throw arrives first.
    @Test func microphoneErrorsMapByTheirDOMExceptionName() async {
        let map = { (message: String) in GPTLiveEngine.failure(forMediaStartError: ScriptError(errorDescription: message)) }
        #expect(map("NotAllowedError: The request is not allowed by the user agent") == .microphoneDenied)
        #expect(map("NotReadableError: Could not start audio source") == .microphoneBusy)
        #expect(map("NotFoundError: Requested device not found") == .microphoneNotFound)
        #expect(map("TypeError: undefined is not an object") == .mediaUnavailable(detail: "TypeError: undefined is not an object"))
        #expect(GPTLiveEngine.failure(forCloseReason: "microphone_busy", usageSeconds: nil) == .microphoneBusy)
        #expect(GPTLiveEngine.failure(forCloseReason: "microphone_not_found", usageSeconds: nil) == .microphoneNotFound)

        await engine.start()
        bridge.emit(.transportClosed(reason: "microphone_busy"))
        #expect(engine.phase == .failed(.microphoneBusy))
    }

    /// F6 #2: the applyAnswer throw is a raw WebKit exception whose text
    /// quotes the offending SDP line — ICE credentials and DTLS
    /// fingerprints. `finish` logs the failure at `privacy: .public`, so
    /// the detail must be fixed copy, never the error's own message.
    @Test func answerApplyFailureNeverQuotesTheSDP() async {
        bridge.answerError = ScriptError(
            errorDescription: "InvalidAccessError: Failed to set remote answer sdp: a=ice-pwd:SECRET is invalid")
        await engine.start()
        bridge.emit(.offer(sdp: "v=0 offer\r\n"))
        await settle { engine.phase.isTerminal }
        guard case .failed(let failure) = engine.phase else {
            Issue.record("expected a failure, got \(engine.phase)")
            return
        }
        #expect(!failure.englishDescription.contains("SECRET"))
        #expect(!failure.englishDescription.contains("ice-pwd"))
        #expect(failure == .audioConnectFailed(detail: "the audio answer could not be applied"))
    }

    @Test func microphoneFailureFailsTheStart() async {
        bridge.startError = Boom()
        await engine.start()
        #expect(engine.phase == .failed(.mediaUnavailable(detail: "boom")))
        #expect(bridge.teardowns == 1)
    }

    @Test func transportClosedWhileConnectingNamesTheReason() async {
        await engine.start()
        bridge.emit(.transportClosed(reason: "microphone_denied"))
        #expect(engine.phase == .failed(.microphoneDenied))
    }

    /// The connect clock starts at the offer: a slow first-run microphone
    /// prompt (before any offer) never times out.
    @Test func connectTimesOutFromTheOfferNotFromStart() async {
        await engine.start()
        advance(600)                       // the user is still deciding on the mic prompt
        #expect(engine.phase == .connecting)
        bridge.emit(.offer(sdp: "v=0"))
        await settle { bridge.answers.count == 1 }
        advance(74)
        #expect(engine.phase == .connecting)
        advance(2)
        #expect(engine.phase == .failed(.connectTimedOut))
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

    /// Review finding: ending while the page loads / the mic prompt is up
    /// must not leave the media running once startMedia() finally returns.
    @Test func endingDuringStartMediaTearsTheLateMediaDown() async {
        bridge.holdStart = true
        let starting = Task { await engine.start() }
        await settle { bridge.startContinuation != nil }
        engine.end(reason: .userEnded)
        #expect(engine.phase == .ended(.userEnded))
        let before = bridge.teardowns
        bridge.releaseStart()
        await starting.value
        #expect(bridge.teardowns == before + 1)
        #expect(engine.phase == .ended(.userEnded))
    }

    /// The desktop is live once the answer is applied; the data channel
    /// opening proves it even if `session.started` never arrives.
    @Test func theOpenChannelMakesTheSessionLiveWithoutSessionStarted() async {
        await engine.start()
        bridge.emit(.offer(sdp: "v=0"))
        await settle { bridge.answers.count == 1 }
        bridge.emit(.channelOpen)
        #expect(engine.phase == .listening)
        user("hello")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        #expect(host.submitted.first?.prompt == "hello")
        advance(80)                         // no connect timeout once live
        #expect(engine.phase.isLive)
    }

    /// Review finding: a mute pressed before the microphone opens must hold.
    @Test func muteWhileConnectingHoldsAndTellsTheVendorOnceOpen() async {
        await engine.start()
        engine.toggleMute()
        #expect(bridge.micEnabled == [false])
        #expect(bridge.sent.isEmpty)        // channel not open: nothing sent yet
        bridge.emit(.offer(sdp: "v=0"))
        await settle { bridge.answers.count == 1 }
        bridge.emit(.channelOpen)
        #expect(bridge.sent(type: "session.input_audio.mute").count == 1)
        #expect(engine.isMuted)
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
        // The first turn carries the voice note; the superseding one goes
        // text-only so Hermes consumes the cancelled request (server.py:680-693).
        #expect(host.submitted.first?.supersedesCancelledTurn == false)
        #expect(host.submitted.first?.contextNotes.count == 1)
        #expect(host.submitted.last?.supersedesCancelledTurn == true)
        #expect(host.submitted.last?.contextNotes.isEmpty == true)
        // d1's late reply is never spoken for d2.
        host.replies["d1"] = VoiceTurnReply(text: "Booked Friday.", isStreaming: false)
        advance(0.2)
        #expect(bridge.spoken().isEmpty)
    }

    /// Review finding: a third delegation arriving while the cancel for the
    /// second is still awaited must inherit the text-only debt — Hermes still
    /// holds the cancelled prompt, and the busy flag is already false by the
    /// time the third turn submits.
    @Test func aDelegationThatArrivesDuringTheCancelStillGoesTextOnly() async {
        await goLive()
        user("book the dentist friday")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.holdCancel = true
        user(" no, thursday", at: 3_000)
        delegate("d2")
        await settle { host.cancelContinuation != nil }
        user(" at nine", at: 4_000)
        delegate("d3")
        host.releaseCancel()
        await settle { host.submitted.count == 2 }
        #expect(host.submitted.map(\.id) == ["d1", "d3"])          // d2 was superseded while waiting
        #expect(host.submitted.last?.supersedesCancelledTurn == true)
        #expect(host.submitted.last?.contextNotes.isEmpty == true)
        // The debt is paid: the next turn after d3 settles carries its note.
        host.isVoiceTurnBusy = false
        host.replies["d3"] = VoiceTurnReply(text: "Booked.", isStreaming: false)
        advance(0.2)
        user(" thanks, and remind me", at: 9_000)
        delegate("d4")
        await settle { host.submitted.count == 3 }
        #expect(host.submitted.last?.supersedesCancelledTurn == false)
    }

    /// Only a turn that CANCELLED another is text-only: a delegation after
    /// the previous turn finished on its own keeps the note.
    @Test func aTurnAfterAFinishedTurnKeepsTheNote() async {
        await goLive()
        user("first")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.isVoiceTurnBusy = false
        host.replies["d1"] = VoiceTurnReply(text: "Done.", isStreaming: false)
        advance(0.2)
        user(" second", at: 5_000)
        delegate("d2")
        await settle { host.submitted.count == 2 }
        #expect(!host.log.contains("cancel begin"))
        #expect(host.submitted.last?.supersedesCancelledTurn == false)
        #expect(host.submitted.last?.contextNotes.count == 1)
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
        #expect(engine.phase == .failed(.closedByVendor(reason: "max_duration", usageSeconds: 1800)))
        #expect(engine.elapsedSeconds == 1800)
        #expect(abs(engine.approximateCostUSD - 1.5) < 1e-9)
    }

    @Test func connectionLossFails() async {
        await goLive()
        bridge.emit(.transportClosed(reason: "connection_lost"))
        #expect(engine.phase == .failed(.connectionLost))
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
        // Structured: the apps localize it; the vendor's wording is logged only.
        #expect(engine.notice == .vendorError(code: "rate_limited"))
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

    // MARK: F3 fixes

    /// F3 #1: the host's bounded cancel ran out and the cancelled turn still
    /// runs. The new request must NOT be submitted into it (Hermes would
    /// queue it text-only and the reply lookup would speak the old answer):
    /// the voice says so, and the request goes once Hermes is idle.
    @Test func aSlowCancelHoldsTheRequestUntilHermesIsIdle() async {
        await goLive()
        user("book the dentist friday")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.stillBusyAfterCancel = true
        user(" no, thursday", at: 3_000)
        delegate("d2")
        await settle { bridge.spoken().contains(GPTLiveEngine.stillBusyReply) }
        #expect(host.submitted.map(\.id) == ["d1"])
        #expect(bridge.spoken() == [GPTLiveEngine.stillBusyReply])
        advance(5)
        #expect(host.submitted.count == 1)                  // still busy: still held
        #expect(engine.phase == .thinking)
        host.isVoiceTurnBusy = false                         // the old turn finally returned
        advance(0.2)
        await settle { host.submitted.count == 2 }
        #expect(host.submitted.last?.id == "d2")
        #expect(host.submitted.last?.supersedesCancelledTurn == true)
    }

    @Test func aSlowCancelThatNeverEndsGivesUpAloud() async {
        await goLive()
        user("book the dentist friday")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.stillBusyAfterCancel = true
        user(" no, thursday", at: 3_000)
        delegate("d2")
        await settle { bridge.spoken().contains(GPTLiveEngine.stillBusyReply) }
        advance(29)
        #expect(engine.phase == .thinking)
        advance(2)
        #expect(bridge.spoken().last == GPTLiveEngine.stillBusyGaveUpReply)
        #expect(engine.phase == .listening)
        await settle()
        #expect(host.submitted.map(\.id) == ["d1"])
    }

    /// F3 #2: a delegation stuck on something (a tool approval nobody
    /// answers) no longer keeps the session billing forever: after 10
    /// minutes with no user speech and no Hermes progress it ends, with a
    /// notice first.
    @Test func aStalledTurnEndsTheSessionAfterTheCapWithANoticeFirst() async {
        await goLive()
        user("deploy it")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.activeVoiceToolName = "terminal"                // waiting on an approval
        advance(0.2)
        advance(530)
        #expect(engine.notice == nil)
        #expect(engine.phase == .thinking)
        advance(20)
        #expect(engine.notice == .endingSoon(reason: .turnStalled, secondsLeft: 50))
        advance(50)
        #expect(engine.phase == .ending)
        bridge.server(#"{"type":"session.closed","reason":"client_requested","usage":{"seconds":601}}"#)
        #expect(engine.phase == .ended(.turnStalled))
    }

    @Test func userSpeechOrHermesProgressResetsTheStallClock() async {
        await goLive()
        user("deploy it")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        advance(550)
        #expect(engine.notice == .endingSoon(reason: .turnStalled, secondsLeft: 50))
        user(" are you there?", at: 600_000)
        advance(0.2)
        #expect(engine.notice == nil)                        // the warning clears
        advance(500)
        host.replies["d1"] = VoiceTurnReply(text: "Deploying now. Step one", isStreaming: true)
        advance(0.2)                                         // progress: the clock restarts
        advance(590)
        #expect(engine.phase == .thinking)
        advance(20)
        #expect(engine.phase == .ending)
    }

    @Test func theIdleAutoEndWarnsAMinuteAhead() async {
        await goLive()
        advance(119)
        #expect(engine.notice == nil)
        advance(2)
        #expect(engine.notice == .endingSoon(reason: .idleTimeout, secondsLeft: 59))
        user("still here")
        advance(0.2)
        #expect(engine.notice == nil)
        #expect(engine.phase == .listening)
    }

    /// F3 #3: progress is tracked on the raw reply. A table whose delimiter
    /// row arrives later used to be spoken as text ("| Mr.") and then, once
    /// the table sanitized away, the spoken count skipped into the next
    /// sentence ("e rest is here.").
    @Test func streamingSpeechNeitherRepeatsNorSkipsWhenMarkdownCompletes() async {
        await goLive()
        user("who is on the list?")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.replies["d1"] = VoiceTurnReply(text: "Here it is.\n| Mr. A | 3 |\n", isStreaming: true)
        advance(0.2)
        #expect(bridge.spoken() == ["Here it is."])
        host.replies["d1"] = VoiceTurnReply(
            text: "Here it is.\n| Mr. A | 3 |\n|---|---|\n| Mr. B | 4 |\nThe rest is here. More", isStreaming: true)
        advance(0.2)
        #expect(bridge.spoken() == ["Here it is.", "The rest is here."])
        host.replies["d1"] = VoiceTurnReply(
            text: "Here it is.\n| Mr. A | 3 |\n|---|---|\n| Mr. B | 4 |\nThe rest is here. More to come.", isStreaming: false)
        host.isVoiceTurnBusy = false
        advance(0.2)
        #expect(bridge.spoken() == ["Here it is.", "The rest is here.", "More to come."])
    }

    @Test func streamingSpeechWaitsForACodeFenceToClose() async {
        await goLive()
        user("show me")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.replies["d1"] = VoiceTurnReply(text: "Run this. ```\nmake all. then\n", isStreaming: true)
        advance(0.2)
        #expect(bridge.spoken() == ["Run this."])
        host.replies["d1"] = VoiceTurnReply(text: "Run this. ```\nmake all. then\n```\nIt builds. Then", isStreaming: true)
        advance(0.2)
        #expect(bridge.spoken() == ["Run this.", "code block omitted It builds."])
    }

    /// Extra (F3): the text-only debt belongs to the chat, not to one engine.
    /// The apps build a new engine per voice session, so a cancel whose
    /// correction never reached Hermes must still make the next session's
    /// first turn text-only.
    @Test func theTextOnlyDebtOutlivesTheEngine() async {
        host.voiceChatID = "chat-1"
        await goLive()
        user("book the dentist friday")
        delegate("d1")
        await settle { host.submitted.count == 1 }
        host.holdCancel = true
        user(" no, thursday", at: 3_000)
        delegate("d2")
        await settle { host.cancelContinuation != nil }
        engine.endImmediately(reason: .userEnded)            // the user closes the panel mid-cancel
        host.releaseCancel()
        await settle()
        #expect(host.submitted.count == 1)
        #expect(ledger.isPending(chatID: "chat-1"))

        let second = Self.makeEngine(bridge: bridge, exchange: exchange, host: host, clock: clock, ledger: ledger)
        await second.start()
        bridge.emit(.offer(sdp: "v=0 offer\r\n"))
        await settle { bridge.answers.count == 2 }
        bridge.emit(.channelOpen)
        bridge.server(#"{"type":"session.input_transcript.delta","delta":"what's on today","start_ms":1000,"end_ms":1500}"#)
        bridge.server(#"{"type":"session.delegation.created","delegation":{"id":"e1"}}"#)
        await settle { host.submitted.count == 2 }
        #expect(host.submitted.last?.id == "e1")
        #expect(host.submitted.last?.supersedesCancelledTurn == true)
        #expect(!ledger.isPending(chatID: "chat-1"))          // paid
        #expect(!ledger.isPending(chatID: "chat-2"))
        second.endImmediately(reason: .userEnded)
    }

    /// F3 #4 (engine half): `endImmediately` sends `session.close` BEFORE the
    /// teardown, so the page's flush can deliver it.
    @Test func endImmediatelySendsTheCloseBeforeTearingDown() async {
        await goLive()
        engine.endImmediately(reason: .userEnded)
        #expect(bridge.order == ["close", "teardown"])
    }

    /// F3 #8 (engine half): iOS deactivates its audio session only once the
    /// media is released.
    @Test func waitForMediaReleaseReturnsOnlyAfterTheBridgeReleases() async {
        await engine.waitForMediaRelease()                   // nothing held: at once
        bridge.holdRelease = true
        await goLive()
        engine.endImmediately(reason: .userEnded)
        let released = Clock()                               // any reference box will do
        let engine = self.engine
        let waiter = Task { await engine.waitForMediaRelease(); released.now = .distantFuture }
        await settle()
        #expect(released.now != .distantFuture)
        bridge.releaseMedia()
        await waiter.value
        #expect(released.now == .distantFuture)
    }
}
