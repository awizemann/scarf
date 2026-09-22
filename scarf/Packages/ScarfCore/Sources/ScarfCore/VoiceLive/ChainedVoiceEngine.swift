import Foundation
import Observation
import os

/// The chained voice engine: on-device speech in, an ordinary Hermes turn in
/// the middle, spoken audio out. Hermes's own default `voice_chat_mode`, and
/// the free path — no OpenAI key, no per-minute cost, and a lower Hermes
/// floor (v0.20.1 `hasHermesSpeechSynthesis`) than GPT-Live's v0.21.3.
///
/// Design A of `documents/plans/2026-09-19-voice-p7-free-voice-path.md`.
/// "Chained" is not a server-side conversation engine — the Hermes desktop's
/// chained mode is a CLIENT loop over three independent capabilities, and so
/// is this. The loop:
///
/// 1. **Listen.** ``VoiceListener`` streams partials (shown as the user's
///    caption) and, after its silence window, one `.utterance`.
/// 2. **Stop phrase.** A whole-utterance stop phrase ends the session instead
///    of reaching Hermes (``VoiceLiveText/isStopCommand(_:)``), exactly as in
///    ``GPTLiveEngine``.
/// 3. **Turn.** `.thinking`, then ``VoiceTurnHost/submitVoiceTurn(_:)`` with
///    the spoken words as the prompt — the chat bubble and the persisted row
///    are the user's words and nothing else.
/// 4. **Speak.** Poll `voiceTurnReply` / `isVoiceTurnBusy` on the same 200 ms
///    cadence GPT-Live uses, speak each newly completed sentence as it
///    streams (``VoiceLiveText/speakableBoundary(in:)`` → `speechSegment` →
///    `chunkForCommentary`), then go back to listening.
///
/// **Half duplex with barge-in, and no self-listening.** The listener keeps
/// running while the reply is spoken, so the user can interrupt — but the
/// microphone also hears the reply itself, so the engine tells the listener
/// when playback starts and stops (``VoiceListener/setPlaybackActive(_:)``)
/// and the LISTENER owns every echo rule: the OS's voice-processing (echo
/// cancelling) input chain, a raised onset trigger and a half-second grace
/// while the reply plays, an onset that must be SUSTAINED (not one loud
/// tick), and the discarding of any hypothesis that began during playback
/// without a confirmed onset. The engine therefore keeps NO grace of its own:
/// a `.speechStarted` that arrives here is already a qualified barge-in, and
/// it stops the speaker and drops the unspoken queue. The utterance that
/// follows is an ordinary turn.
///
/// **It never cancels a running Hermes turn.** GPT-Live cancels because its
/// vendor keeps talking regardless; here, a busy chat simply means the user
/// spoke while Hermes was working. Cancelling would take a typed turn away
/// from the user (t-2140ec98, the same rule ScarfGo's Live Voice follows), so
/// the engine speaks a short "still working" line and drops the utterance.
/// Consequently it never owes Hermes a text-only turn and never touches
/// ``VoiceTextOnlyTurnLedger``.
///
/// **Cost is 0 and nothing leaves the device but text.** Audio is transcribed
/// on-device (``AppleOnDeviceVoiceListener``), so ``externalRecipient`` is
/// `nil` and no consent is asked. Reply text does reach the host's TTS
/// provider (and, for Hermes's default `edge`, Microsoft) — that is the
/// host's own configuration, which Settings explains in P7c.
///
/// Timing is driven by ``tick()`` (a 200 ms loop in production, called
/// directly by tests with an injected clock), so every timer is deterministic
/// under test.
@MainActor
@Observable
public final class ChainedVoiceEngine: VoiceConversationEngine {

    public struct Configuration: Sendable {
        /// Idle auto-end: no utterance, no speech and no Hermes turn for this
        /// long. `0` disables it. Nothing is billed, but a forgotten open
        /// microphone is its own problem, so the guard is kept.
        public var idleTimeout: TimeInterval = VoiceIdleMonitor.defaultTimeout
        /// Stalled-turn auto-end, mirroring ``GPTLiveEngine``: a Hermes turn
        /// open this long with no user speech and no reply progress ends the
        /// session (``VoiceSessionEndReason/turnStalled``). Nothing is billed
        /// here, but a wedged turn would otherwise disable the idle guard
        /// forever and leave the microphone open indefinitely. `0` disables.
        public var stalledTurnTimeout: TimeInterval = 600
        /// How long before the auto-end the ``VoiceSessionNotice/endingSoon(reason:secondsLeft:)``
        /// notice shows.
        public var endWarningLead: TimeInterval = 60
        /// `SUBMIT_SETTLE_GRACE_MS` equivalent: how long an idle host with no
        /// reply is tolerated before the turn is read as finished.
        public var submitSettleGrace: TimeInterval = 15
        /// The reply-drive cadence. `nil` = no internal loop (tests call
        /// `tick()`).
        public var tickInterval: Duration? = .milliseconds(200)
        /// Captions kept for the UI.
        public var maxCaptions = 100
        /// Spoken turns kept as model context for the next request.
        public var maxContextTurns = 12

        public init() {}
    }

    // MARK: Observable state (the VoiceConversationEngine surface)

    public private(set) var phase: VoiceConversationPhase = .idle
    public private(set) var captions: [VoiceCaption] = []
    public private(set) var micLevel: Double = 0
    public private(set) var isMuted = false
    public private(set) var elapsedSeconds: TimeInterval = 0
    /// Always 0: on-device STT, a turn the user pays for anyway, and a host
    /// TTS provider that is free by default.
    public private(set) var approximateCostUSD: Double = 0
    public private(set) var notice: VoiceSessionNotice?

    // MARK: Dependencies

    @ObservationIgnored private let listener: any VoiceListener
    @ObservationIgnored private let speaker: any VoiceSpeaker
    @ObservationIgnored private weak var turnHost: (any VoiceTurnHost)?
    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let clock: @MainActor () -> Date
    private static let logger = Logger(subsystem: "com.scarf", category: "LiveVoice")

    /// Nothing is sent outside the user's devices and Hermes host: the audio
    /// is transcribed on-device and only text crosses to the host the chat
    /// already talks to. No consent is asked (``VoiceDataConsent``).
    public nonisolated static let externalRecipient: VoiceDataRecipient? = nil

    // MARK: Session state

    /// The Hermes turn in flight, and how much of its reply has been spoken.
    private struct Turn {
        let id: String
        let prompt: String
        var submittedAt: Date?
        var observed = false
        /// Characters of the RAW reply already spoken (or skipped as
        /// unspeakable). Tracked on the raw text, not the sanitized one,
        /// whose earlier characters change as markdown completes.
        var rawSpoken = 0
        /// The raw reply last processed: an unchanged reply is not re-scanned.
        var lastRaw: String?
        var spokeAnything = false
    }

    @ObservationIgnored private var state = VoiceConversationState()
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var captionCounter = 0
    /// The caption the current partial hypothesis is being written into.
    @ObservationIgnored private var partialCaptionID: Int?
    @ObservationIgnored private var turn: Turn?
    @ObservationIgnored private var submitTask: Task<Void, Never>?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var speakTask: Task<Void, Never>?
    /// Monotonic, bumped whenever the current chunk is abandoned (barge-in, a
    /// new utterance, the end of the session) and by every ``pumpSpeech()``.
    /// A speak task whose generation is stale must not clear ``speakTask`` nor
    /// pump the queue — doing so starts a SECOND concurrent chunk alongside
    /// the one that replaced it.
    @ObservationIgnored private var speakGeneration = 0
    @ObservationIgnored private var speechQueue: [String] = []
    /// The recent spoken exchange, model input only (never a persisted row).
    @ObservationIgnored private var spokenTurns: [(speaker: VoiceTranscriptFragment.Speaker, text: String)] = []
    @ObservationIgnored private var meter = VoiceSessionMeter()
    @ObservationIgnored private var idle: VoiceIdleMonitor
    /// The stalled-turn guard: armed when a turn starts, reset by every
    /// observed reply change.
    @ObservationIgnored private var stall: VoiceIdleMonitor
    @ObservationIgnored private var turnCounter = 0

    public init(
        listener: any VoiceListener,
        speaker: any VoiceSpeaker,
        turnHost: any VoiceTurnHost,
        configuration: Configuration = Configuration(),
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.listener = listener
        self.speaker = speaker
        self.turnHost = turnHost
        self.configuration = configuration
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

        let stream: AsyncStream<VoiceListenerEvent>
        do {
            stream = try listener.start()
        } catch {
            finish(failure: Self.failure(for: error))
            return
        }
        // The microphone is open, so the session is live from here: unlike
        // GPT-Live there is no vendor handshake to wait for.
        meter.start(at: clock())
        idle.noteActivity(at: clock())
        apply(.sessionLive)
        startTickLoop()
        listenTask = Task { [weak self] in
            for await event in stream {
                guard let self, myEpoch == self.epoch else { return }
                self.handle(event)
            }
        }
    }

    public func end(reason: VoiceSessionEndReason) {
        guard state.phase.isActive else { return }
        // Nothing to close gracefully: no vendor session, no billed seconds.
        complete(.ended(reason))
    }

    public func endImmediately(reason: VoiceSessionEndReason) {
        end(reason: reason)
    }

    public func toggleMute() {
        guard state.phase.isActive else { return }
        isMuted.toggle()
        listener.setPaused(isMuted)
        if isMuted, micLevel != 0 { micLevel = 0 }
    }

    // MARK: - Listener events

    func handle(_ event: VoiceListenerEvent) {
        guard state.phase.isActive else { return }
        let now = clock()
        switch event {
        case .level(let level):
            guard !isMuted else { return }
            if abs(level - micLevel) >= 0.02 || (level == 0) != (micLevel == 0) { micLevel = level }

        case .speechStarted:
            idle.noteActivity(at: now)
            bargeIn()

        case .partial(let text):
            idle.noteActivity(at: now)
            updatePartialCaption(text)

        case .utterance(let text):
            idle.noteActivity(at: now)
            // `partialCaptionID` is NOT cleared here: `appendCaption` uses it
            // to overwrite the hypothesis caption with the final words,
            // instead of leaving both on screen.
            handle(utterance: text)

        case .failed(let error):
            finish(failure: Self.failure(for: error))
        }
    }

    /// A confirmed speech onset while the reply plays: stop talking and throw
    /// away what has not been spoken yet. There is no grace here — the
    /// listener already applied its own (a sustained level over the raised
    /// playback trigger, after a half-second settling window), and a second
    /// grace with a different meaning would only make the two disagree.
    private func bargeIn() {
        guard state.assistantSpeaking else { return }
        cancelSpeech()
        setAssistantSpeaking(false)
    }

    /// Flip the speaking flag AND tell the listener, so its echo rules turn
    /// on and off with the actual playback. Every transition goes through
    /// here; nothing calls `apply(.assistantSpeaking(_:))` directly.
    private func setAssistantSpeaking(_ speaking: Bool) {
        apply(.assistantSpeaking(speaking))
        listener.setPlaybackActive(speaking)
    }

    /// Abandon the chunk being spoken and everything queued behind it. The
    /// generation bump is what makes the abandoned task inert: its
    /// `speak(_:)` still RETURNS (a stop is a normal outcome, not an error),
    /// and without the bump that return would clear the new ``speakTask`` and
    /// pump a second chunk alongside it.
    private func cancelSpeech() {
        speechQueue.removeAll()
        speaker.stop()
        speakTask?.cancel()
        speakTask = nil
        speakGeneration += 1
    }

    private func handle(utterance raw: String) {
        let spoken = VoiceLiveText.collapseWhitespace(raw)
        guard !spoken.isEmpty, state.phase.isLive else { return }
        if VoiceLiveText.isStopCommand(spoken) {
            appendCaption(speaker: .user, text: spoken)
            end(reason: .stopPhrase)
            return
        }
        appendCaption(speaker: .user, text: spoken)

        // A new utterance always cuts the reply short — the user is talking
        // over it on purpose, whatever the level meter thought.
        if state.assistantSpeaking {
            cancelSpeech()
            setAssistantSpeaking(false)
        }

        // The model context records what was actually SAID TO HERMES. A
        // dropped utterance (no host, or a turn already running) never
        // reaches it, so noting it here would put words the host was never
        // told into the next request's context — along with the canned line
        // explaining why they were dropped.
        guard let host = turnHost else {
            speak(Self.unreachableReply, note: false)
            return
        }
        // Never cancel: the running turn may be one the user typed.
        guard !host.isVoiceTurnBusy, turn == nil else {
            speak(Self.busyReply, note: false)
            return
        }

        turnCounter += 1
        let id = "chained-\(turnCounter)"
        turn = Turn(id: id, prompt: spoken)
        noteSpokenTurn(.user, spoken)
        stall = VoiceIdleMonitor(timeout: configuration.stalledTurnTimeout, now: clock())
        apply(.delegationStarted)

        let context = contextWindow()
        let myEpoch = epoch
        let previous = submitTask
        submitTask = Task { [weak self] in
            await previous?.value
            guard let self, self.isCurrent(id, epoch: myEpoch) else { return }
            await self.submit(id: id, prompt: spoken, context: context, to: host, epoch: myEpoch)
        }
    }

    private func submit(id: String, prompt: String, context: String, to host: any VoiceTurnHost, epoch myEpoch: Int) async {
        let request = VoiceTurnRequest(id: id, prompt: prompt, context: context, noteStyle: .chained)
        turn?.submittedAt = clock()
        do {
            try await host.submitVoiceTurn(request)
        } catch {
            guard isCurrent(id, epoch: myEpoch) else { return }
            Self.logger.notice("Chained voice turn could not be submitted: \(VoiceLiveHostExchange.redact(error.localizedDescription), privacy: .public)")
            // The host refused the turn, so these words were never said to
            // Hermes: take them back out of the model context.
            dropSpokenTurn(.user, prompt)
            speak(Self.unreachableReply, note: false)
            settleTurn()
        }
    }

    private func isCurrent(_ id: String, epoch myEpoch: Int) -> Bool {
        myEpoch == epoch && state.phase.isLive && turn?.id == id
    }

    /// Spoken when the turn could not be handed to Hermes at all.
    static let unreachableReply = "Sorry, I could not reach Hermes for that request."
    /// Spoken when a turn (typed or spoken) is already running. The chained
    /// engine never cancels one, so the utterance is dropped, not queued.
    static let busyReply = "Hermes is still working on the previous request. Please ask again once it's done."
    /// Spoken when a turn finished with nothing speakable in it.
    static let silentReply = "Hermes finished that request without a spoken result."

    // MARK: - Reply → speech

    /// One pass of the reply drive for the active turn. Mirrors
    /// ``GPTLiveEngine``'s: progress is tracked on the RAW reply and only the
    /// new, sentence-aligned segment is sanitized, because sanitizing the
    /// whole reply each pass repeats or skips text when a later chunk changes
    /// how earlier markdown sanitizes.
    private func driveTurn(now: Date) {
        guard var current = turn, let submittedAt = current.submittedAt, let host = turnHost else { return }
        let busy = host.isVoiceTurnBusy
        if busy { current.observed = true }

        if let reply = host.voiceTurnReply(for: current.id) {
            current.observed = true
            idle.noteActivity(at: now)
            let streaming = reply.isStreaming || busy
            if reply.text != current.lastRaw || !streaming {
                // Progress: this turn is working, not wedged.
                stall.noteActivity(at: now)
                current.lastRaw = reply.text
                let raw = Array(reply.text)
                current.rawSpoken = min(current.rawSpoken, raw.count)   // the reply was rewritten shorter
                let end = streaming ? VoiceLiveText.speakableBoundary(in: raw) : raw.count
                if end > current.rawSpoken {
                    let segment = VoiceLiveText.speechSegment(raw, current.rawSpoken..<end)
                    current.rawSpoken = end
                    if !segment.isEmpty {
                        speak(segment)
                        current.spokeAnything = true
                    }
                }
            }
            turn = current
            if !streaming { settleTurn() }
            return
        }

        // The submit lags the turn: give it time to be seen running before
        // reading "idle and no reply" as a finished turn.
        if !busy, current.observed || now.timeIntervalSince(submittedAt) > configuration.submitSettleGrace {
            if !current.spokeAnything { speak(Self.silentReply) }
            turn = current
            settleTurn()
            return
        }
        turn = current
    }

    private func settleTurn() {
        turn = nil
        idle.noteActivity(at: clock())
        apply(.delegationSettled)
    }

    /// Queue one already-sanitized piece of speech, split to the same
    /// append-sized chunks GPT-Live uses so a very long sentence is broken on
    /// a sentence boundary rather than mid-word.
    ///
    /// - Parameter note: whether the words join the model context. `false`
    ///   for the canned lines that explain a DROPPED utterance: they are
    ///   Scarf talking to the user, not part of the exchange Hermes sees.
    private func speak(_ text: String, note: Bool = true) {
        let chunks = VoiceLiveText.chunkForCommentary(text)
        guard !chunks.isEmpty else { return }
        speechQueue.append(contentsOf: chunks)
        for chunk in chunks { appendCaption(speaker: .assistant, text: chunk) }
        if note { noteSpokenTurn(.assistant, chunks.joined(separator: " ")) }
        pumpSpeech()
    }

    /// Speak the queue, one chunk at a time, in order.
    private func pumpSpeech() {
        guard speakTask == nil, state.phase.isActive else { return }
        guard !speechQueue.isEmpty else {
            if state.assistantSpeaking {
                        setAssistantSpeaking(false)
            }
            return
        }
        let chunk = speechQueue.removeFirst()
        if !state.assistantSpeaking {
            setAssistantSpeaking(true)
        }
        let myEpoch = epoch
        speakGeneration += 1
        let myGeneration = speakGeneration
        speakTask = Task { [weak self] in
            guard let self else { return }
            // A speaker error is already the fallback speaker's business; if
            // even the fallback failed, dropping the chunk beats stalling the
            // conversation on it.
            try? await self.speaker.speak(chunk)
            guard myEpoch == self.epoch, myGeneration == self.speakGeneration else { return }
            self.speakTask = nil
            self.idle.noteActivity(at: self.clock())
            self.pumpSpeech()
        }
    }

    // MARK: - Captions and context

    private func updatePartialCaption(_ text: String) {
        let clean = VoiceLiveText.collapseWhitespace(text)
        guard !clean.isEmpty else { return }
        if let id = partialCaptionID, let index = captions.lastIndex(where: { $0.id == id }) {
            captions[index].text = clean
            return
        }
        captionCounter += 1
        partialCaptionID = captionCounter
        captions.append(VoiceCaption(id: captionCounter, speaker: .user, text: clean))
        trimCaptions()
    }

    private func appendCaption(speaker: VoiceTranscriptFragment.Speaker, text: String) {
        guard !text.isEmpty else { return }
        // A finished utterance replaces the partial caption it grew from.
        if speaker == .user, let id = partialCaptionID, let index = captions.lastIndex(where: { $0.id == id }) {
            captions[index].text = text
            partialCaptionID = nil
            return
        }
        if let last = captions.last, last.speaker == speaker, last.id != partialCaptionID {
            captions[captions.count - 1].text += " " + text
            return
        }
        captionCounter += 1
        captions.append(VoiceCaption(id: captionCounter, speaker: speaker, text: text))
        trimCaptions()
    }

    private func trimCaptions() {
        guard captions.count > configuration.maxCaptions else { return }
        captions.removeFirst(captions.count - configuration.maxCaptions)
    }

    private func noteSpokenTurn(_ speaker: VoiceTranscriptFragment.Speaker, _ text: String) {
        let clean = VoiceLiveText.collapseWhitespace(text)
        guard !clean.isEmpty else { return }
        if let last = spokenTurns.last, last.speaker == speaker {
            spokenTurns[spokenTurns.count - 1].text += " " + clean
        } else {
            spokenTurns.append((speaker, clean))
        }
        if spokenTurns.count > configuration.maxContextTurns {
            spokenTurns.removeFirst(spokenTurns.count - configuration.maxContextTurns)
        }
    }

    /// Undo ``noteSpokenTurn(_:_:)`` for words that turned out never to reach
    /// Hermes (the host refused the submit). The context must describe the
    /// exchange the host actually had, or the next turn is answered against a
    /// question it was never asked.
    private func dropSpokenTurn(_ speaker: VoiceTranscriptFragment.Speaker, _ text: String) {
        let clean = VoiceLiveText.collapseWhitespace(text)
        guard !clean.isEmpty, let last = spokenTurns.last, last.speaker == speaker else { return }
        if last.text == clean {
            spokenTurns.removeLast()
        } else if last.text.hasSuffix(" " + clean) {
            spokenTurns[spokenTurns.count - 1].text.removeLast(clean.count + 1)
        }
    }

    /// The recent spoken exchange, in the same `User:` / `Assistant:` shape
    /// GPT-Live uses. Model input only — the persisted row is the prompt.
    private func contextWindow() -> String {
        spokenTurns
            .map { "\($0.speaker == .user ? "User" : "Assistant"): \($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: - Tick

    /// Advance every timer once: the reply drive, the idle auto-end, and the
    /// elapsed readout. Called every 200 ms while a session is active.
    public func tick() {
        let now = clock()
        guard state.phase.isActive else { return }
        refreshMeter(now: now)
        guard state.phase.isLive else { return }
        driveTurn(now: now)
        driveAutoEnd(now: now)
    }

    /// Two guards, exactly as ``GPTLiveEngine`` has them. Without a turn: no
    /// speech either side for ``Configuration/idleTimeout``. With one: no user
    /// speech and no reply progress for ``Configuration/stalledTurnTimeout``,
    /// so a wedged Hermes turn cannot hold the microphone open forever.
    private func driveAutoEnd(now: Date) {
        // A reply playing is activity, not idleness.
        let busy = state.assistantSpeaking || !speechQueue.isEmpty
        let (monitor, reason) = turn == nil ? (idle, VoiceSessionEndReason.idleTimeout) : (stall, .turnStalled)
        if monitor.isIdle(at: now, busy: busy) {
            end(reason: reason)
            return
        }
        if !busy, let remaining = monitor.remaining(at: now), remaining <= configuration.endWarningLead {
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
        if elapsed != elapsedSeconds { elapsedSeconds = elapsed }
    }

    // MARK: - Notices

    /// Called by the app's ``FallbackVoiceSpeaker`` when a chunk drops to the
    /// system voice, so the banner can say so once.
    public func noteSpeechFallback() {
        guard state.phase.isActive, notice != .speechFallback else { return }
        notice = .speechFallback
    }

    // MARK: - Finish

    private func finish(failure: VoiceSessionFailure) {
        guard state.phase.isActive else { return }
        Self.logger.notice("Chained voice failed: \(VoiceLiveHostExchange.redact(failure.englishDescription), privacy: .public)")
        complete(.failed(failure))
    }

    private func complete(_ event: VoiceConversationEvent) {
        let now = clock()
        listener.setPlaybackActive(false)
        listener.stop()
        speaker.stop()
        listenTask?.cancel()
        listenTask = nil
        tickTask?.cancel()
        tickTask = nil
        speakTask?.cancel()
        speakTask = nil
        speakGeneration += 1
        submitTask = nil        // the Hermes turn itself is left to finish in the chat
        speechQueue = []
        turn = nil
        meter.stop(at: now, billedSeconds: nil)
        elapsedSeconds = meter.elapsed(at: now).rounded(.down)
        micLevel = 0
        isMuted = false
        if case .endingSoon = notice { notice = nil }
        epoch += 1
        apply(event)
    }

    /// Map a listener failure onto the engine's terminal failure. The apps
    /// localize one sentence per case.
    static func failure(for error: Error) -> VoiceSessionFailure {
        switch error as? VoiceListenerError {
        case .speechRecognitionDenied: return .speechRecognitionDenied
        case .recognizerUnavailable, .onDeviceRecognitionUnsupported: return .speechRecognitionUnavailable
        case .microphoneDenied: return .microphoneDenied
        case .audioEngineFailed(let detail): return .mediaUnavailable(detail: detail)
        case .recognitionFailed(let detail): return .mediaUnavailable(detail: detail)
        case nil: return .mediaUnavailable(detail: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func apply(_ event: VoiceConversationEvent) {
        let next = VoiceConversationReducer.reduce(state, event)
        state = next
        if phase != next.phase { phase = next.phase }
    }

    private func resetSession() {
        captions = []
        captionCounter = 0
        partialCaptionID = nil
        turn = nil
        turnCounter = 0
        submitTask = nil
        listenTask = nil
        speakTask = nil
        speakGeneration += 1
        speechQueue = []
        spokenTurns = []
        meter = VoiceSessionMeter()
        idle = VoiceIdleMonitor(timeout: configuration.idleTimeout, now: clock())
        stall = VoiceIdleMonitor(timeout: configuration.stalledTurnTimeout, now: clock())
        elapsedSeconds = 0
        approximateCostUSD = 0
        micLevel = 0
        isMuted = false
        notice = nil
    }
}
