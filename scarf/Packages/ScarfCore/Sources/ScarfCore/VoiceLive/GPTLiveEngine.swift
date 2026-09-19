import Foundation
import Observation
import os

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
/// speech either side for 3 minutes by default), a stalled-turn auto-end (a
/// delegation with no user speech and no Hermes progress for 10 minutes,
/// e.g. a tool approval nobody answers), a notice before either, and a
/// connect timeout.
///
/// Known limit: a session ended while the host exchange runs (`end` during
/// connecting, or the connect timeout) may already exist at the vendor
/// (the script POSTed the offer) but has no media and no data channel, so
/// the client can't send `session.close` for it; the vendor ends it on its
/// own timeout. Whether that time is billed is unverified.
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
        /// Stalled-turn auto-end: a delegation open this long with no user
        /// speech and no progress from Hermes (new reply text or a new
        /// tool) ends the session. `0` disables it.
        public var stalledTurnTimeout: TimeInterval = 600
        /// How long before either auto-end the ``VoiceSessionNotice/endingSoon(reason:secondsLeft:)``
        /// notice shows.
        public var endWarningLead: TimeInterval = 60
        /// A cancelled Hermes turn that is still running after the host's
        /// bounded cancel wait: how long the new request waits for Hermes to
        /// go idle before the voice gives up on it. It is never submitted
        /// into a busy turn (Hermes would queue it text-only and the reply
        /// lookup would speak the OLD turn's answer).
        public var busyRetryWindow: TimeInterval = 30
        /// `SUBMIT_SETTLE_GRACE_MS` (`use-voice-live-conversation.ts:12`).
        public var submitSettleGrace: TimeInterval = 15
        /// `UTTERANCE_SETTLE_MS` (`:15`).
        public var utteranceSettle: TimeInterval = 1.5
        /// `CLOSE_TIMEOUT_MS` (`voice-live.ts:73`).
        public var closeTimeout: TimeInterval = 15
        /// From the offer to `session.started`: the host exchange (45 s) plus
        /// the WebRTC connect. The clock starts at the offer, not at start(),
        /// so a first-run microphone prompt the user takes time over never
        /// times out (nothing is billed before the exchange).
        public var connectTimeout: TimeInterval = 75
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
    public private(set) var notice: VoiceSessionNotice?
    /// The vendor session id, once known.
    public private(set) var sessionID: String?

    // MARK: Dependencies

    @ObservationIgnored private let bridge: any VoiceMediaBridge
    @ObservationIgnored private let exchange: any VoiceLiveSessionExchanging
    @ObservationIgnored private weak var turnHost: (any VoiceTurnHost)?
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let ledger: VoiceTextOnlyTurnLedger
    private static let logger = Logger(subsystem: "com.scarf", category: "LiveVoice")

    /// Where this engine sends the user's data directly, bypassing the
    /// Hermes host: the page streams microphone audio to OpenAI over WebRTC
    /// (so OpenAI also sees this device's network address), and each session
    /// is seeded with recent chat (``VoiceLiveText/liveHistory(from:maxMessages:maxChars:)``).
    /// The host only runs the session exchange. Apps ask for consent before
    /// the first session (``VoiceDataConsent``).
    public nonisolated static let externalRecipient: VoiceDataRecipient? = .openAI

    // MARK: Session state

    private struct Delegation {
        let id: String
        let prompt: String
        let context: String
        var submittedAt: Date?
        /// Set while the request waits for a slow-cancelled turn to end.
        var awaitingIdleSince: Date?
        var observed = false
        /// Characters of the RAW reply already spoken (or skipped as
        /// unspeakable). Progress is tracked on the raw text, not the
        /// sanitized one, whose earlier characters change as markdown
        /// completes (a table's delimiter row, a closing fence).
        var rawSpoken = 0
        /// The raw reply last processed: an unchanged reply is not re-scanned.
        var lastRaw: String?
        var spokeAnything = false
        var lastTool: String?
    }

    @ObservationIgnored private var state = VoiceConversationState()
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var transcript: [VoiceTranscriptFragment] = []
    @ObservationIgnored private var captionCounter = 0
    @ObservationIgnored private var delegation: Delegation?
    @ObservationIgnored private var submitTask: Task<Void, Never>?
    /// The text-only debt for a host with no ``VoiceTurnHost/voiceChatID``
    /// (hosts with one use the ledger, which outlives this engine). Set when
    /// a Hermes turn is cancelled; cleared once a text-only turn reaches
    /// Hermes. See ``VoiceTextOnlyTurnLedger``.
    @ObservationIgnored private var localTextOnlyPending = false
    @ObservationIgnored private var exchangeTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var utterance = ""
    @ObservationIgnored private var lastUserFragmentAt: Date?
    @ObservationIgnored private var channelOpen = false
    @ObservationIgnored private var answerApplied = false
    @ObservationIgnored private var offerAt: Date?
    @ObservationIgnored private var closeDeadline: Date?
    @ObservationIgnored private var endReason: VoiceSessionEndReason?
    @ObservationIgnored private var meter = VoiceSessionMeter()
    @ObservationIgnored private var idle: VoiceIdleMonitor
    @ObservationIgnored private var stall: VoiceIdleMonitor
    @ObservationIgnored private var clientEvents = VoiceLiveClientEvents()
    /// Bridge teardowns whose media hasn't reported released yet.
    @ObservationIgnored private var unreleasedTeardowns = 0
    @ObservationIgnored private var releaseWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Bound on ``waitForMediaRelease()``: the page's own flush is ~1.5 s.
    static let mediaReleaseTimeout: Duration = .seconds(3)

    public init(
        bridge: any VoiceMediaBridge,
        exchange: any VoiceLiveSessionExchanging,
        turnHost: any VoiceTurnHost,
        configuration: Configuration = Configuration(),
        textOnlyTurns: VoiceTextOnlyTurnLedger? = nil,
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.bridge = bridge
        self.exchange = exchange
        self.turnHost = turnHost
        self.configuration = configuration
        self.ledger = textOnlyTurns ?? .shared   // nil: the app-wide ledger
        self.clock = clock
        self.idle = VoiceIdleMonitor(timeout: configuration.idleTimeout, now: clock())
        self.stall = VoiceIdleMonitor(timeout: configuration.stalledTurnTimeout, now: clock())
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !state.phase.isActive else { return }
        epoch += 1
        let myEpoch = epoch
        resetSession()
        apply(.startRequested)
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        startTickLoop()
        do {
            try await bridge.startMedia()
            // Ended (or restarted) while the page loaded or the mic prompt
            // was up: the media that just opened belongs to no session.
            if myEpoch != epoch { tearDownMedia() }
        } catch {
            guard myEpoch == epoch, state.phase == .connecting else { return }
            finish(failure: Self.failure(forMediaStartError: error))
        }
    }

    /// A `startMedia()` throw. The page reports a getUserMedia failure as a
    /// `closed` message too, but the throw can win the race, so the
    /// exception name is mapped the same way here.
    static func failure(forMediaStartError error: Error) -> VoiceSessionFailure {
        let message = error.localizedDescription
        for (name, reason) in [("NotAllowedError", "microphone_denied"), ("SecurityError", "microphone_denied"),
                               ("NotReadableError", "microphone_busy"), ("AbortError", "microphone_busy"),
                               ("NotFoundError", "microphone_not_found"), ("OverconstrainedError", "microphone_not_found")]
        where message.hasPrefix(name) {
            return failure(forCloseReason: reason, usageSeconds: nil)
        }
        return .mediaUnavailable(detail: message)
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
        // The vendor stops billing on `session.close`. The bridge's teardown
        // releases the microphone at once but keeps the channel open for a
        // short, bounded flush, so this close actually leaves the machine.
        if channelOpen { send(.close) }
        finish(remoteReason: "close_requested", usageSeconds: nil)
    }

    public func waitForMediaRelease() async {
        guard unreleasedTeardowns > 0 else { return }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseWaiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.mediaReleaseTimeout)
                self?.releaseWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func tearDownMedia() {
        unreleasedTeardowns += 1
        bridge.teardown { [weak self] in self?.mediaDidRelease() }
    }

    private func mediaDidRelease() {
        unreleasedTeardowns = max(0, unreleasedTeardowns - 1)
        guard unreleasedTeardowns == 0 else { return }
        let waiters = releaseWaiters
        releaseWaiters = [:]
        for continuation in waiters.values { continuation.resume() }
    }

    public func toggleMute() {
        guard state.phase.isActive else { return }
        isMuted.toggle()
        bridge.setMicrophoneEnabled(!isMuted)   // the page remembers it for a track not open yet
        if channelOpen { send(isMuted ? .mute : .unmute) }
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
            // The data channel only opens once the answer is applied and
            // DTLS/SCTP connect, so the session is live now — the desktop
            // treats it as live from here too (voice-live.ts:319-336 →
            // use-voice-live-conversation.ts:312-321), not from
            // `session.started`, which may lag or never come.
            channelOpen = true
            if isMuted { send(.mute) }   // a mute pressed while connecting
            idle.noteActivity(at: clock())
            apply(.sessionLive)
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
            // Vendor wording is English and may echo request detail: log it,
            // show only the structured notice.
            Self.logger.notice("GPT-Live error \(code ?? "-", privacy: .public): \(VoiceLiveHostExchange.redact(message), privacy: .public)")
            notice = .vendorError(code: code)
        case .closed(let reason, let usage):
            finish(remoteReason: reason, usageSeconds: usage)
        case .other:
            break
        }
    }

    // MARK: - Start: offer → host exchange → answer

    private func exchangeOffer(_ sdp: String) {
        guard state.phase == .connecting, exchangeTask == nil, !answerApplied else { return }
        offerAt = clock()
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
                    // The detail is FIXED, never the error's own text: this
                    // throw is a raw WebKit `setRemoteDescription` exception,
                    // and WebKit quotes the offending SDP line back — which
                    // is where the ICE credentials and DTLS fingerprint live.
                    // `finish` logs the failure's description at .public, so
                    // the error text would land in the system log verbatim.
                    self.finish(failure: .audioConnectFailed(detail: "the audio answer could not be applied"))
                }
            case .failure(let error):
                self.finish(failure: .host(error as? VoiceLiveHostError ?? .transport(detail: VoiceLiveHostExchange.redact(error.localizedDescription))))
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
            stall.noteActivity(at: now)
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
        delegation = Delegation(id: id, prompt: built.prompt, context: built.context)
        stall = VoiceIdleMonitor(timeout: configuration.stalledTurnTimeout, now: clock())
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
                // The debt outlives THIS task (and this engine): if a newer
                // delegation supersedes this one while the cancel is awaited,
                // or the session ends, Hermes still holds the stored prompt.
                self.markTextOnlyPending(for: host)
                await host.cancelActiveVoiceTurn()
                guard self.isCurrent(id, epoch: myEpoch) else { return }
                if host.isVoiceTurnBusy {
                    // Slow cancel: the host's bounded wait ran out and the
                    // cancelled turn still runs. Submitting now would queue
                    // this request text-only behind it ("Queued for the next
                    // turn", `acp_adapter/server.py:696-715` @ v2026.9.14) and
                    // the reply lookup would speak the old turn's text. Say so
                    // and wait for Hermes to go idle (`tick()`).
                    self.delegation?.awaitingIdleSince = self.clock()
                    self.send(.commentary(delegationID: id, content: Self.stillBusyReply))
                    return
                }
            }
            await self.submit(id, to: host, epoch: myEpoch)
        }
    }

    /// Hand the current delegation to Hermes.
    ///
    /// A turn that follows a cancel goes TEXT-ONLY (Alan, 2026-09-18):
    /// Hermes's `cancel` stored the cancelled request (`server.py:617-619`)
    /// and only a text-only prompt consumes it, attaching it as
    /// "<cancelled>\n\nUser correction/guidance after interrupt: …"
    /// (`:680-693`). With the note it would leak into the next typed message
    /// instead. That one turn loses the voice note. The debt is paid only by
    /// a text-only submit that reached Hermes.
    private func submit(_ id: String, to host: any VoiceTurnHost, epoch myEpoch: Int) async {
        guard isCurrent(id, epoch: myEpoch), let current = delegation else { return }
        let chatID = host.voiceChatID
        let supersedes = isTextOnlyPending(chatID: chatID)
        let request = VoiceTurnRequest(
            id: id, prompt: current.prompt, context: current.context, supersedesCancelledTurn: supersedes)
        delegation?.submittedAt = clock()
        do {
            try await host.submitVoiceTurn(request)
            if supersedes { clearTextOnlyPending(chatID: chatID) }
        } catch {
            guard isCurrent(id, epoch: myEpoch) else { return }
            send(.commentary(delegationID: id, content: Self.unreachableReply))
            settleDelegation()
        }
    }

    /// While a request waits on a slow-cancelled turn: submit it once Hermes
    /// is idle, or give up after ``Configuration/busyRetryWindow``.
    private func driveAwaitingIdle(now: Date) {
        guard let current = delegation, let since = current.awaitingIdleSince, let host = turnHost else { return }
        if !host.isVoiceTurnBusy {
            delegation?.awaitingIdleSince = nil
            let previous = submitTask
            let myEpoch = epoch
            let id = current.id
            submitTask = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                await self.submit(id, to: host, epoch: myEpoch)
            }
        } else if now.timeIntervalSince(since) >= configuration.busyRetryWindow {
            send(.commentary(delegationID: current.id, content: Self.stillBusyGaveUpReply))
            settleDelegation()
        }
    }

    private func isTextOnlyPending(chatID: String?) -> Bool {
        guard let chatID else { return localTextOnlyPending }
        return ledger.isPending(chatID: chatID)
    }

    private func markTextOnlyPending(for host: any VoiceTurnHost) {
        if let chatID = host.voiceChatID { ledger.markPending(chatID: chatID) } else { localTextOnlyPending = true }
    }

    private func clearTextOnlyPending(chatID: String?) {
        if let chatID { ledger.clear(chatID: chatID) } else { localTextOnlyPending = false }
    }

    /// Spoken when a delegation can't be submitted (`:290-295`).
    static let unreachableReply = "Sorry, I could not reach Hermes for that request."
    /// Spoken when a cancelled turn is still running after the cancel wait.
    static let stillBusyReply = "Hermes is still finishing the previous request. I'll pass this on as soon as it's done."
    /// Spoken when Hermes stayed busy for the whole retry window.
    static let stillBusyGaveUpReply = "Hermes is still busy with the previous request, so I couldn't pass that on. Please ask again in a moment."

    private func isCurrent(_ id: String, epoch myEpoch: Int) -> Bool {
        myEpoch == epoch && state.phase.isLive && delegation?.id == id
    }

    /// One pass of the desktop's reply-drive effect for the active
    /// delegation (`use-voice-live-conversation.ts:359-426`).
    ///
    /// Unlike the desktop, progress is tracked on the RAW reply: while it
    /// streams, only the prefix up to ``VoiceLiveText/speakableBoundary(in:)``
    /// (a sentence end outside code, links and tables) is sanitized and
    /// spoken, one new segment at a time. Sanitizing the whole reply each
    /// pass and slicing it by a spoken count repeated or skipped text when a
    /// later chunk changed how earlier markdown sanitized, and re-ran every
    /// regex over the whole reply five times a second.
    private func driveDelegation(now: Date) {
        guard var current = delegation, let submittedAt = current.submittedAt, let host = turnHost else { return }
        let busy = host.isVoiceTurnBusy
        if busy { current.observed = true }

        if let tool = host.activeVoiceToolName, tool != current.lastTool {
            current.lastTool = tool
            stall.noteActivity(at: now)
            send(.thinking(delegationID: current.id, content: "Hermes is working: \(tool). Not done yet."))
        }

        if let reply = host.voiceTurnReply(for: current.id) {
            current.observed = true
            let streaming = reply.isStreaming || busy
            if reply.text != current.lastRaw || !streaming {
                current.lastRaw = reply.text
                let raw = Array(reply.text)
                current.rawSpoken = min(current.rawSpoken, raw.count)   // the reply was rewritten shorter
                let end = streaming ? VoiceLiveText.speakableBoundary(in: raw) : raw.count
                if end > current.rawSpoken {
                    let segment = VoiceLiveText.speechSegment(raw, current.rawSpoken..<end)
                    current.rawSpoken = end
                    stall.noteActivity(at: now)
                    if !segment.isEmpty {
                        send(.commentary(delegationID: current.id, content: segment))
                        current.spokeAnything = true
                    }
                }
            }
            delegation = current
            if !streaming { settleDelegation() }
            return
        }

        // The submit lags the turn: give it time to be seen running before
        // reading "idle and no reply" as a finished turn.
        if !busy, current.observed || now.timeIntervalSince(submittedAt) > configuration.submitSettleGrace {
            if !current.spokeAnything {
                send(.thinking(delegationID: current.id, content: "Hermes finished that request without a spoken result."))
            }
            delegation = current
            settleDelegation()
            return
        }
        delegation = current
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

        if state.phase == .connecting, let offerAt, now.timeIntervalSince(offerAt) >= configuration.connectTimeout {
            finish(failure: .connectTimedOut)
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

        driveAwaitingIdle(now: now)
        driveDelegation(now: now)
        driveAutoEnd(now: now)
    }

    /// The cost guards. Without a delegation: no speech either side for
    /// ``Configuration/idleTimeout``. With one: no user speech and no Hermes
    /// progress for ``Configuration/stalledTurnTimeout`` (a turn stuck on an
    /// approval would otherwise keep the session billing forever). Either
    /// shows ``VoiceSessionNotice/endingSoon(reason:secondsLeft:)`` first.
    private func driveAutoEnd(now: Date) {
        let speaking = state.assistantSpeaking
        let (monitor, reason) = delegation == nil ? (idle, VoiceSessionEndReason.idleTimeout) : (stall, .turnStalled)
        if monitor.isIdle(at: now, busy: speaking) {
            end(reason: reason)
            return
        }
        if !speaking, let remaining = monitor.remaining(at: now), remaining <= configuration.endWarningLead {
            let warning = VoiceSessionNotice.endingSoon(reason: reason, secondsLeft: Int(remaining.rounded(.up)))
            if notice != warning { notice = warning }
        } else if case .endingSoon = notice {
            notice = nil
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
            let failure = Self.failure(forCloseReason: remoteReason, usageSeconds: usageSeconds)
            // The vendor's close reason is logged, never shown.
            Self.logger.notice("Live Voice failed: \(VoiceLiveHostExchange.redact(failure.englishDescription), privacy: .public)")
            complete(.failed(failure), usageSeconds: usageSeconds)
        }
    }

    private func finish(failure: VoiceSessionFailure) {
        guard state.phase.isActive else { return }
        Self.logger.notice("Live Voice failed: \(VoiceLiveHostExchange.redact(failure.englishDescription), privacy: .public)")
        complete(.failed(failure), usageSeconds: nil)
    }

    private func complete(_ event: VoiceConversationEvent, usageSeconds: Double?) {
        let now = clock()
        tearDownMedia()
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
        if case .endingSoon = notice { notice = nil }
        epoch += 1
        apply(event)
    }

    /// A close the user didn't ask for: a page transport reason
    /// (`connection_lost`, `microphone_denied`, `microphone_busy`,
    /// `microphone_not_found`, `microphone_failed`, `web_process_terminated`)
    /// or the vendor's `session.closed` reason.
    static func failure(forCloseReason reason: String, usageSeconds: Double?) -> VoiceSessionFailure {
        switch reason {
        case "connection_lost": return .connectionLost
        case "microphone_denied": return .microphoneDenied
        case "microphone_busy": return .microphoneBusy
        case "microphone_not_found": return .microphoneNotFound
        case "microphone_failed": return .mediaUnavailable(detail: "getUserMedia failed")
        case "web_process_terminated": return .mediaProcessTerminated
        default: return .closedByVendor(reason: reason, usageSeconds: usageSeconds)
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
        offerAt = nil
        closeDeadline = nil
        endReason = nil
        meter = VoiceSessionMeter()
        idle = VoiceIdleMonitor(timeout: configuration.idleTimeout, now: clock())
        stall = VoiceIdleMonitor(timeout: configuration.stalledTurnTimeout, now: clock())
        clientEvents = VoiceLiveClientEvents()
        elapsedSeconds = 0
        approximateCostUSD = 0
        micLevel = 0
        isMuted = false
        notice = nil
        sessionID = nil
    }
}
