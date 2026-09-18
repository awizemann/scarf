import Foundation
import Observation

/// GPT-Live: one full-duplex OpenAI voice model owns the microphone and the
/// speaker and DELEGATES every real request to Hermes as an ordinary ACP
/// turn in the active chat. Hermes stays the agent (model, tools, memory,
/// approvals); the voice paraphrases Hermes's answer aloud.
///
/// A port of the Hermes desktop's conversation loop,
/// `apps/desktop/src/app/chat/composer/hooks/use-voice-live-conversation.ts`
/// @ v2026.9.14:
/// - **Start**: the media bridge opens the mic and produces an offer; the
///   host exchange (``VoiceLiveSessionExchanging``) trades it for the
///   vendor's answer with the key held on the Hermes host.
/// - **Delegation** (`:261-296`): build the turn from the transcript window;
///   a spoken stop phrase ends the session instead; a still-running turn is
///   cancelled AND awaited before the new one is submitted (Hermes drops the
///   voice note of a prompt queued behind a running turn).
/// - **Reply** (`:351-432`): every 200 ms, speak newly completed sentences
///   of the reply; on settle, speak the tail. Tool progress goes out as a
///   quiet thinking note. A turn that settles with nothing spoken says so.
/// - **Stop phrase** on the user transcript after 1.5 s of quiet (`:221-242`)
///   — the voice model answers a bare "stop" itself and never delegates it.
/// - **End**: `session.close`, then up to 15 s for `session.closed` (which
///   carries the billed seconds) before teardown (`voice-live.ts:495-507`).
///
/// Scarf additions: elapsed time + approximate cost, an idle auto-end (no
/// speech either side for 3 minutes by default), and a start timeout.
///
/// Timing is driven by ``tick()`` (a 200 ms loop in production, called
/// directly by tests with an injected clock), so every timer in the loop is
/// deterministic under test.
@MainActor
@Observable
public final class GPTLiveEngine: VoiceConversationEngine {

    public struct Configuration: Sendable {
        /// Idle auto-end; `0` disables it.
        public var idleTimeout: TimeInterval = VoiceIdleMonitor.defaultTimeout
        /// `SUBMIT_SETTLE_GRACE_MS` (`use-voice-live-conversation.ts:12`).
        public var submitSettleGrace: TimeInterval = 15
        /// `UTTERANCE_SETTLE_MS` (`:15`).
        public var utteranceSettle: TimeInterval = 1.5
        /// `CLOSE_TIMEOUT_MS` (`voice-live.ts:73`).
        public var closeTimeout: TimeInterval = 15
        /// From start to `session.started`: mic prompt + ICE gathering (10 s)
        /// + the host exchange (45 s) + connect.
        public var startTimeout: TimeInterval = 75
        /// The reply-drive cadence (`:428`). `nil` = no internal loop (tests
        /// call `tick()`).
        public var tickInterval: Duration? = .milliseconds(200)
        /// Captions kept for the UI.
        public var maxCaptions = 100

        public init() {}
    }

    // MARK: Observable state (the VoiceConversationEngine surface)

    public private(set) var phase: VoiceConversationPhase = .idle
    public private(set) var captions: [VoiceCaption] = []
    public private(set) var micLevel: Double = 0
    public private(set) var isMuted = false
    public private(set) var elapsedSeconds: TimeInterval = 0
    public private(set) var approximateCostUSD: Double = 0
    public private(set) var notice: String?
    /// The vendor session id, once known.
    public private(set) var sessionID: String?

    // MARK: Dependencies

    @ObservationIgnored private let bridge: any VoiceMediaBridge
    @ObservationIgnored private let exchange: any VoiceLiveSessionExchanging
    @ObservationIgnored private weak var turnHost: (any VoiceTurnHost)?
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let clock: @MainActor () -> Date

    // MARK: Session state

    private struct Delegation {
        let id: String
        let request: VoiceTurnRequest
        var submittedAt: Date?
        var observed = false
        var spokenLength = 0
        var lastTool: String?
    }

    @ObservationIgnored private var state = VoiceConversationState()
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var transcript: [VoiceTranscriptFragment] = []
    @ObservationIgnored private var captionCounter = 0
    @ObservationIgnored private var delegation: Delegation?
    @ObservationIgnored private var submitTask: Task<Void, Never>?
    @ObservationIgnored private var exchangeTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var utterance = ""
    @ObservationIgnored private var lastUserFragmentAt: Date?
    @ObservationIgnored private var channelOpen = false
    @ObservationIgnored private var answerApplied = false
    @ObservationIgnored private var startedAt = Date.distantPast
    @ObservationIgnored private var closeDeadline: Date?
    @ObservationIgnored private var endReason: VoiceSessionEndReason?
    @ObservationIgnored private var meter = VoiceSessionMeter()
    @ObservationIgnored private var idle: VoiceIdleMonitor
    @ObservationIgnored private var clientEvents = VoiceLiveClientEvents()

    public init(
        bridge: any VoiceMediaBridge,
        exchange: any VoiceLiveSessionExchanging,
        turnHost: any VoiceTurnHost,
        configuration: Configuration = Configuration(),
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.bridge = bridge
        self.exchange = exchange
        self.turnHost = turnHost
        self.configuration = configuration
        self.clock = clock
        self.idle = VoiceIdleMonitor(timeout: configuration.idleTimeout, now: clock())
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !state.phase.isActive else { return }
        epoch += 1
        let myEpoch = epoch
        resetSession()
        apply(.startRequested)
        startedAt = clock()
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        startTickLoop()
        do {
            try await bridge.startMedia()
        } catch {
            guard myEpoch == epoch, state.phase == .connecting else { return }
            finish(failure: String(localized: "Couldn't open the microphone for Live Voice: \(error.localizedDescription)"))
        }
    }

    public func end(reason: VoiceSessionEndReason) {
        guard state.phase.isActive, state.phase != .ending else { return }
        endReason = endReason ?? reason
        guard state.phase.isLive, channelOpen else {
            // Nothing to close gracefully: not connected yet (desktop:
            // `send` fails → finish immediately).
            finish(remoteReason: "close_requested", usageSeconds: nil)
            return
        }
        send(.close)
        closeDeadline = clock().addingTimeInterval(configuration.closeTimeout)
        apply(.endRequested)
    }

    public func endImmediately(reason: VoiceSessionEndReason) {
        guard state.phase.isActive else { return }
        endReason = endReason ?? reason
        if channelOpen { send(.close) }   // best effort: the vendor stops billing sooner
        finish(remoteReason: "close_requested", usageSeconds: nil)
    }

    public func toggleMute() {
        guard state.phase.isActive else { return }
        isMuted.toggle()
        bridge.setMicrophoneEnabled(!isMuted)
        send(isMuted ? .mute : .unmute)
    }

    /// Full duplex has no turn boundary; this nudges the voice to answer now
    /// (the desktop's `stopTurn`, `use-voice-live-conversation.ts:443-446`).
    public func respondNow() {
        guard state.phase.isLive else { return }
        send(.instructions(content: "The user has finished speaking. Respond now to what they said."))
    }

    // MARK: - Media events

    func handle(_ event: VoiceMediaEvent) {
        guard state.phase.isActive else { return }
        switch event {
        case .pageReady:
            break
        case .offer(let sdp):
            exchangeOffer(sdp)
        case .channelOpen:
            channelOpen = true
        case .serverMessage(let raw):
            if let serverEvent = VoiceLiveServerEvent.decode(raw) { handle(serverEvent) }
        case .assistantSpeaking(let speaking):
            idle.noteActivity(at: clock())
            apply(.assistantSpeaking(speaking))
        case .micLevel(let level):
            if abs(level - micLevel) >= 0.02 || (level == 0) != (micLevel == 0) { micLevel = level }
        case .transportClosed(let reason):
            finish(remoteReason: reason, usageSeconds: nil)
        }
    }

    func handle(_ event: VoiceLiveServerEvent) {
        switch event {
        case .sessionStarted(let id):
            sessionID = id ?? sessionID
            channelOpen = true
            idle.noteActivity(at: clock())
            apply(.sessionLive)
        case .transcript(let fragment):
            appendTranscript(fragment)
        case .delegationCreated(let id):
            handleDelegation(id)
        case .error(let code, let message):
            guard code != VoiceLiveServerEvent.ignoredErrorCode else { return }
            notice = message
        case .closed(let reason, let usage):
            finish(remoteReason: reason, usageSeconds: usage)
        case .other:
            break
        }
    }

    // MARK: - Start: offer → host exchange → answer

    private func exchangeOffer(_ sdp: String) {
        guard state.phase == .connecting, exchangeTask == nil, !answerApplied else { return }
        let myEpoch = epoch
        let history = VoiceLiveText.liveHistory(from: turnHost?.voiceSeedTurns() ?? [])
        let exchange = self.exchange
        exchangeTask = Task { [weak self] in
            let result: Result<VoiceLiveSessionAnswer, Error>
            do {
                result = .success(try await exchange.createSession(offerSDP: sdp, history: history))
            } catch {
                result = .failure(error)
            }
            guard let self, myEpoch == self.epoch, self.state.phase == .connecting else { return }
            self.exchangeTask = nil
            switch result {
            case .success(let answer):
                // Billing starts once the vendor has created the session.
                self.meter.start(at: self.clock())
                self.sessionID = answer.sessionID
                self.answerApplied = true
                do {
                    try await self.bridge.applyAnswer(sdp: answer.sdp)
                } catch {
                    guard myEpoch == self.epoch, self.state.phase.isActive else { return }
                    self.finish(failure: String(localized: "Live Voice couldn't connect its audio: \(error.localizedDescription)"))
                }
            case .failure(let error):
                self.finish(failure: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Transcript + captions

    private func appendTranscript(_ fragment: VoiceTranscriptFragment) {
        let now = clock()
        idle.noteActivity(at: now)
        transcript.append(fragment)
        if transcript.count > 2_000 { transcript.removeFirst(transcript.count - 1_500) }   // voice-live.ts:398-402
        if let last = captions.last, last.speaker == fragment.speaker {
            captions[captions.count - 1].text += fragment.text
        } else if !fragment.text.isEmpty {
            captionCounter += 1
            captions.append(VoiceCaption(id: captionCounter, speaker: fragment.speaker, text: fragment.text))
            if captions.count > configuration.maxCaptions { captions.removeFirst(captions.count - configuration.maxCaptions) }
        }
        if fragment.speaker == .user {
            utterance += fragment.text
            lastUserFragmentAt = now
        }
    }

    // MARK: - Delegation → Hermes turn

    private func handleDelegation(_ id: String) {
        guard state.phase.isLive else { return }
        let built = VoiceLiveText.delegationPrompt(VoiceLiveText.contextWindow(transcript))
        if !built.prompt.isEmpty, VoiceLiveText.isStopCommand(built.prompt) {
            end(reason: .stopPhrase)
            return
        }
        let request = VoiceTurnRequest(id: id, prompt: built.prompt, context: built.context)
        delegation = Delegation(id: id, request: request)
        apply(.delegationStarted)

        // Serialize cancel+submit: a delegation that is superseded while it
        // waits never submits (the "still current" checks), and a newer one
        // never races an older one's cancel.
        let previous = submitTask
        let myEpoch = epoch
        submitTask = Task { [weak self] in
            await previous?.value
            guard let self, self.isCurrent(id, epoch: myEpoch) else { return }
            guard let host = self.turnHost else {
                self.send(.commentary(delegationID: id, content: Self.unreachableReply))
                self.settleDelegation()
                return
            }
            if host.isVoiceTurnBusy {
                await host.cancelActiveVoiceTurn()
                guard self.isCurrent(id, epoch: myEpoch) else { return }
            }
            self.delegation?.submittedAt = self.clock()
            do {
                try await host.submitVoiceTurn(request)
            } catch {
                guard self.isCurrent(id, epoch: myEpoch) else { return }
                self.send(.commentary(delegationID: id, content: Self.unreachableReply))
                self.settleDelegation()
            }
        }
    }

    /// Spoken when a delegation can't be submitted (`:290-295`).
    static let unreachableReply = "Sorry, I could not reach Hermes for that request."

    private func isCurrent(_ id: String, epoch myEpoch: Int) -> Bool {
        myEpoch == epoch && state.phase.isLive && delegation?.id == id
    }

    /// One pass of the desktop's reply-drive effect for the active
    /// delegation (`use-voice-live-conversation.ts:359-426`).
    private func driveDelegation(now: Date) {
        guard var current = delegation, let submittedAt = current.submittedAt, let host = turnHost else { return }
        let busy = host.isVoiceTurnBusy
        if busy { current.observed = true }

        if let tool = host.activeVoiceToolName, tool != current.lastTool {
            current.lastTool = tool
            send(.thinking(delegationID: current.id, content: "Hermes is working: \(tool). Not done yet."))
        }

        if let reply = host.voiceTurnReply(for: current.id) {
            current.observed = true
            let spoken = Array(VoiceLiveText.sanitizeForSpeech(reply.text))
            if reply.isStreaming || busy {
                // Append only completed sentences while streaming; the tail
                // lands on settle.
                let boundary = Self.lastSentenceBoundary(in: spoken)
                let cut = boundary > current.spokenLength ? boundary + 1 : current.spokenLength
                if cut > current.spokenLength, cut <= spoken.count {
                    send(.commentary(delegationID: current.id, content: String(spoken[current.spokenLength..<cut])))
                    current.spokenLength = cut
                }
                delegation = current
                return
            }
            if spoken.count > current.spokenLength {
                send(.commentary(delegationID: current.id, content: String(spoken[current.spokenLength...])))
                current.spokenLength = spoken.count
            }
            delegation = current
            settleDelegation()
            return
        }

        // The submit lags the turn: give it time to be seen running before
        // reading "idle and no reply" as a finished turn.
        if !busy, current.observed || now.timeIntervalSince(submittedAt) > configuration.submitSettleGrace {
            if current.spokenLength == 0 {
                send(.thinking(delegationID: current.id, content: "Hermes finished that request without a spoken result."))
            }
            delegation = current
            settleDelegation()
            return
        }
        delegation = current
    }

    /// JS `spoken.lastIndexOf('. ', spoken.length - 2)`: the index of the
    /// last ". " that starts at or before `count - 2`, else -1.
    static func lastSentenceBoundary(in text: [Character]) -> Int {
        guard text.count >= 2 else { return -1 }
        var index = text.count - 2
        while index >= 0 {
            if text[index] == ".", index + 1 < text.count, text[index + 1] == " " { return index }
            index -= 1
        }
        return -1
    }

    private func settleDelegation() {
        delegation = nil
        idle.noteActivity(at: clock())
        apply(.delegationSettled)
    }

    // MARK: - Tick

    /// Advance every timer once: start and close timeouts, the stop-phrase
    /// utterance check, the reply drive, the idle auto-end, and the
    /// elapsed/cost readout. Called every 200 ms while a session is active.
    public func tick() {
        let now = clock()
        guard state.phase.isActive else { return }

        if state.phase == .connecting, now.timeIntervalSince(startedAt) >= configuration.startTimeout {
            finish(failure: String(localized: "Live Voice took too long to connect."))
            return
        }
        if let deadline = closeDeadline, now >= deadline {
            finish(remoteReason: "close_requested", usageSeconds: nil)
            return
        }
        refreshMeter(now: now)
        guard state.phase.isLive else { return }

        if let last = lastUserFragmentAt, now.timeIntervalSince(last) >= configuration.utteranceSettle {
            let spoken = utterance
            utterance = ""
            lastUserFragmentAt = nil
            if VoiceLiveText.isStopCommand(spoken) {
                end(reason: .stopPhrase)
                return
            }
        }

        driveDelegation(now: now)

        if idle.isIdle(at: now, busy: delegation != nil || state.assistantSpeaking) {
            end(reason: .idleTimeout)
        }
    }

    private func startTickLoop() {
        tickTask?.cancel()
        guard let interval = configuration.tickInterval else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func refreshMeter(now: Date) {
        let elapsed = meter.elapsed(at: now).rounded(.down)
        if elapsed != elapsedSeconds {
            elapsedSeconds = elapsed
            approximateCostUSD = meter.approximateCostUSD(at: now)
        }
    }

    // MARK: - Finish

    private func finish(remoteReason: String, usageSeconds: Double?) {
        guard state.phase.isActive else { return }
        if let endReason {
            complete(.ended(endReason), usageSeconds: usageSeconds)
        } else {
            complete(.failed(Self.message(forCloseReason: remoteReason, usageSeconds: usageSeconds)), usageSeconds: usageSeconds)
        }
    }

    private func finish(failure message: String) {
        guard state.phase.isActive else { return }
        complete(.failed(message), usageSeconds: nil)
    }

    private func complete(_ event: VoiceConversationEvent, usageSeconds: Double?) {
        let now = clock()
        bridge.teardown()
        bridge.onEvent = nil
        tickTask?.cancel()
        tickTask = nil
        exchangeTask?.cancel()
        exchangeTask = nil
        submitTask = nil       // the Hermes turn itself is left to finish in the chat
        delegation = nil
        closeDeadline = nil
        channelOpen = false
        meter.stop(at: now, billedSeconds: usageSeconds)
        elapsedSeconds = meter.elapsed(at: now).rounded(.down)
        approximateCostUSD = meter.approximateCostUSD(at: now)
        micLevel = 0
        isMuted = false
        epoch += 1
        apply(event)
    }

    /// User-facing copy for a close the user didn't ask for.
    static func message(forCloseReason reason: String, usageSeconds: Double?) -> String {
        switch reason {
        case "connection_lost":
            return String(localized: "The Live Voice connection dropped.")
        case "microphone_denied":
            return String(localized: "Scarf can't use the microphone. Allow microphone access in System Settings, then try again.")
        case "web_process_terminated":
            return String(localized: "Live Voice stopped unexpectedly.")
        default:
            if let usageSeconds {
                return String(localized: "Live Voice ended: \(reason) (\(Int(usageSeconds.rounded())) s).")
            }
            return String(localized: "Live Voice ended: \(reason).")
        }
    }

    // MARK: - Helpers

    private func apply(_ event: VoiceConversationEvent) {
        let next = VoiceConversationReducer.reduce(state, event)
        state = next
        if phase != next.phase { phase = next.phase }
    }

    private func send(_ event: VoiceLiveClientEvent) {
        for json in clientEvents.encode(event) { bridge.send(json) }
    }

    private func resetSession() {
        transcript = []
        captions = []
        captionCounter = 0
        delegation = nil
        submitTask = nil
        exchangeTask = nil
        utterance = ""
        lastUserFragmentAt = nil
        channelOpen = false
        answerApplied = false
        closeDeadline = nil
        endReason = nil
        meter = VoiceSessionMeter()
        idle = VoiceIdleMonitor(timeout: configuration.idleTimeout, now: clock())
        clientEvents = VoiceLiveClientEvents()
        elapsedSeconds = 0
        approximateCostUSD = 0
        micLevel = 0
        isMuted = false
        notice = nil
        sessionID = nil
    }
}
