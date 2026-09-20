import Foundation
import Observation
import ScarfCore

/// One window's Live Voice session: owns the engine and its media bridge,
/// and is the single place the window starts, ends and dismisses a session.
/// Owned by `ChatViewModel` (per window, per server/profile), which is the
/// engine's `VoiceTurnHost`.
///
/// The panel (`VoiceLivePanel`) is on screen while `engine != nil`: through
/// the session and afterwards, so the user can read how it ended (idle
/// auto-end, a setup failure) before closing it. The bridge's web view is
/// hosted by the panel, which keeps it in the window hierarchy for the whole
/// session (WebKit plays no remote audio from a detached web view).
///
/// Only ONE session runs app-wide (``VoiceLiveSessionRegistry``): a start in
/// another window is refused while this one holds the session.
///
/// Every teardown path must reach ``endImmediately()`` — the engine can't
/// clean up in `deinit`, and a dropped engine keeps billing.
@MainActor
@Observable
final class VoiceLiveController {

    /// What `start` builds: the engine the UI binds to and, for GPT-Live,
    /// the WebKit bridge the panel must host. Tests inject a fake engine
    /// and no bridge.
    struct Session {
        let engine: any VoiceConversationEngine
        let bridge: WebViewVoiceMediaBridge?
    }

    typealias SessionFactory = @MainActor (ServerContext, any VoiceTurnHost) -> Session

    /// Permission prompts an engine needs cleared before it starts.
    /// Returns `nil` when everything is granted. Chained needs speech
    /// recognition AND the microphone (two separate TCC entries); GPT-Live
    /// needs neither here, because its microphone lives inside the web
    /// view, which asks WebKit's own way.
    typealias Authorizer = @MainActor () async -> VoiceListenerError?

    /// Everything that differs between the two engines the one composer
    /// button mounts (``VoiceEngineKind``). Injectable so tests never touch
    /// a microphone, a speech recognizer or a synthesizer.
    struct Wiring {
        let makeSession: SessionFactory
        /// Who this engine sends the user's data to directly, or `nil` when
        /// nothing leaves the user's devices and Hermes host — chained is
        /// `nil` (on-device transcription), so it never asks for consent.
        let externalRecipient: VoiceDataRecipient?
        let authorize: Authorizer?

        init(
            makeSession: @escaping SessionFactory,
            externalRecipient: VoiceDataRecipient? = nil,
            authorize: Authorizer? = nil
        ) {
            self.makeSession = makeSession
            self.externalRecipient = externalRecipient
            self.authorize = authorize
        }

        /// This wiring with the hardware swapped out and its CONSENT
        /// CONTRACT kept. Tests build their fakes through here rather than
        /// through `Wiring.init`, whose `externalRecipient` default is
        /// `nil`: a test that re-declared the recipient would pass even if
        /// the app shipped a different one.
        func replacingHardware(
            makeSession: @escaping SessionFactory,
            authorize: Authorizer?
        ) -> Wiring {
            Wiring(
                makeSession: makeSession,
                externalRecipient: externalRecipient,
                authorize: authorize
            )
        }
    }

    /// Why a start the user asked for produced no session.
    enum StartRefusal: Equatable {
        /// Another window holds the app's one Live Voice session.
        case blockedByAnotherWindow
    }

    /// Why the HOST (not the engine) ended the session, when the panel
    /// should say so. The engine reports these as a plain `.userEnded`.
    enum EndNote: Equatable {
        /// The chat's ACP connection to Hermes died, so no spoken request
        /// could reach Hermes any more.
        case hermesConnectionLost
    }

    /// Production wiring (the P4 contract): GPT-Live over a WKWebView, with
    /// the session exchange run on the Hermes host so the OpenAI key never
    /// leaves it.
    static let gptLive: SessionFactory = { context, host in
        let bridge = WebViewVoiceMediaBridge()
        let engine = GPTLiveEngine(
            bridge: bridge,
            exchange: VoiceLiveHostExchange(context: context),
            turnHost: host
        )
        return Session(engine: engine, bridge: bridge)
    }

    /// Production wiring for the FREE path (P7b): on-device speech in, an
    /// ordinary Hermes turn, spoken audio out. No web view to host, no
    /// vendor, no key and no cost.
    ///
    /// The speaker honours the Settings › Voice "Playback Engine" choice,
    /// the same client-side preference the per-message speaker button uses:
    /// Hermes Voice synthesizes through the host's `tts.*` provider and
    /// drops to this Mac's voice for any sentence the host can't speak;
    /// System Voice never leaves the Mac at all. No capability check is
    /// needed here — the chained engine only mounts above
    /// `hasHermesSpeechSynthesis`, which is exactly what
    /// `PlaybackEngine.resolve` gates "hermes" on.
    static let chained: SessionFactory = { context, host in
        let box = ChainedEngineBox()
        let preference = UserDefaults.standard.string(forKey: MessageSpeechService.engineKey)
        let speaker: any VoiceSpeaker
        if VoiceLiveController.chainedPlaybackEngine(preference: preference) == .hermes {
            speaker = FallbackVoiceSpeaker(
                primary: HermesVoiceSpeaker(context: context),
                fallback: SystemVoiceSpeaker(),
                // One banner line per session, not per sentence.
                onFirstFallback: { box.engine?.noteSpeechFallback() }
            )
        } else {
            speaker = SystemVoiceSpeaker()
        }
        let engine = ChainedVoiceEngine(
            listener: AppleOnDeviceVoiceListener(),
            speaker: speaker,
            turnHost: host
        )
        box.engine = engine
        return Session(engine: engine, bridge: nil)
    }

    /// Breaks the speaker ↔ engine cycle: the fallback speaker's one-time
    /// notice has to reach an engine that does not exist yet when the
    /// speaker is built.
    @MainActor
    private final class ChainedEngineBox {
        weak var engine: ChainedVoiceEngine?
    }

    /// The chained wiring THE APP SHIPS, as one value the production
    /// initializer and the tests both point at: the free path's factory,
    /// its external recipient — `nil`, which is the whole reason a chained
    /// start never raises the consent sheet — and the TCC prompts it needs
    /// cleared first.
    static var chainedProduction: Wiring {
        Wiring(
            makeSession: Self.chained,
            // On-device transcription: nothing to consent to.
            externalRecipient: ChainedVoiceEngine.externalRecipient,
            authorize: { await AppleOnDeviceVoiceListener.authorize() }
        )
    }

    /// Which engine actually speaks a chained reply, read from the one
    /// client-side preference the chained factory reads (the Settings ›
    /// Voice "Playback Engine" picker, shared with the per-message speaker
    /// button). The privacy line and the Settings rows MUST derive from
    /// this rather than from the host's `tts.provider` alone — with System
    /// Voice chosen the provider is never asked to speak anything, so
    /// naming it (and billing it) would be a lie.
    ///
    /// No capability argument: the chained engine only mounts above
    /// `hasHermesSpeechSynthesis`, which is exactly what
    /// `PlaybackEngine.resolve` gates "hermes" on.
    nonisolated static func chainedPlaybackEngine(
        preference: String?
    ) -> HermesSpeechService.PlaybackEngine {
        preference == HermesSpeechService.PlaybackEngine.hermes.rawValue ? .hermes : .system
    }

    private(set) var engine: (any VoiceConversationEngine)?
    private(set) var bridge: WebViewVoiceMediaBridge?
    /// Which engine the current (or last) session mounts. `nil` before the
    /// first start.
    private(set) var engineKind: VoiceEngineKind?
    /// A start that never produced a session because a permission the
    /// engine needs was refused. The panel shows it with the same copy an
    /// engine failure gets; cleared by the next start and by `dismiss`.
    private(set) var startFailure: VoiceSessionFailure?
    /// Set when the host ended the session for a reason the panel shows.
    /// Cleared by the next start and by `dismiss`.
    private(set) var endNote: EndNote?
    /// Why the last ``start(context:host:)`` refused, when the user asked
    /// for a session and got nothing. Cleared by the next start and by
    /// ``consumeStartRefusal()``.
    private(set) var startRefusal: StartRefusal?

    /// `start` has built the engine but its start task hasn't run yet
    /// (the engine is still `.idle`). Counts as holding the session, so a
    /// second window can't slip a start into that gap, and an end in it
    /// cancels the start instead of being lost on an idle engine.
    private(set) var isStartPending = false
    /// A start is waiting for the user to agree to send their data to this
    /// recipient (the consent sheet is up). Nothing is built or billed until
    /// ``acceptConsent()``; ``declineConsent()`` drops the start.
    private(set) var pendingConsent: VoiceDataRecipient?

    /// One wiring per engine kind. `start` picks by the readiness
    /// verdict's ``VoiceLiveAvailability/engineKind``.
    @ObservationIgnored private let gptLiveWiring: Wiring
    @ObservationIgnored private let chainedWiring: Wiring
    @ObservationIgnored private let registry: VoiceLiveSessionRegistry
    @ObservationIgnored private let consent: VoiceDataConsentStore
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// - Parameters:
    ///   - makeSession: overrides how the GPT-Live session is built (tests).
    ///   - externalRecipient: who that engine sends data to; `nil` means it
    ///     keeps everything local and never asks for consent.
    ///   - chained: overrides the whole chained wiring (tests inject a fake
    ///     listener, speaker and authorizer so no hardware is touched).
    init(
        makeSession: SessionFactory? = nil,
        externalRecipient: VoiceDataRecipient? = GPTLiveEngine.externalRecipient,
        chained: Wiring? = nil,
        registry: VoiceLiveSessionRegistry? = nil,
        consent: VoiceDataConsentStore? = nil
    ) {
        self.gptLiveWiring = Wiring(
            makeSession: makeSession ?? Self.gptLive,
            externalRecipient: externalRecipient
        )
        self.chainedWiring = chained ?? Self.chainedProduction
        self.registry = registry ?? .shared
        self.consent = consent ?? .shared
    }

    private func wiring(for kind: VoiceEngineKind) -> Wiring {
        switch kind {
        case .gptLive: return gptLiveWiring
        case .chained: return chainedWiring
        }
    }

    /// A session exists and hasn't finished (connecting through ending).
    var isSessionActive: Bool { engine?.phase.isActive ?? false }

    /// This window holds the app's one Live Voice session: starting or
    /// running.
    var holdsSession: Bool { isStartPending || isSessionActive }

    /// Another window holds the app's Live Voice session, so this one
    /// can't start.
    var isBlockedByAnotherWindow: Bool { registry.isHeld(byAnotherThan: self) }

    /// Start a new session in `context`'s chat. No-op while this window's
    /// session is starting or running, or while another window holds one.
    /// A finished session still on screen is replaced.
    ///
    /// The first start on this Mac for an engine that sends data to a third
    /// party only raises ``pendingConsent`` (the consent sheet); the caller
    /// starts again after ``acceptConsent()``.
    func start(context: ServerContext, host: any VoiceTurnHost, engineKind: VoiceEngineKind = .gptLive) {
        guard !holdsSession else { return }
        // The consent sheet can be up for minutes, and another window may
        // claim the app's one session while it is. Silently returning here
        // meant the user pressed Continue and nothing at all happened —
        // record the refusal so the chat can say why.
        guard !isBlockedByAnotherWindow else {
            pendingConsent = nil
            // The refusal is this start's answer: a permission failure from
            // an EARLIER start must not still be on the panel underneath it.
            startFailure = nil
            startRefusal = .blockedByAnotherWindow
            return
        }
        let wiring = self.wiring(for: engineKind)
        if let recipient = VoiceDataConsent.pendingRecipient(for: wiring.externalRecipient, store: consent) {
            pendingConsent = recipient
            // Likewise: no stale "Allow Scarf in Speech Recognition" under
            // the consent sheet.
            startFailure = nil
            return
        }
        pendingConsent = nil
        startRefusal = nil
        startFailure = nil
        // A start always REPLACES a finished session that is still on the
        // panel. `VoiceLivePanel` renders `engine` first and `startFailure`
        // only when there is none, so leaving the ended engine here made a
        // refused "Start Again" look dead: the panel went on showing the
        // session that already ended. `holdsSession` is false above, so
        // nothing live is dropped.
        engine = nil
        bridge = nil
        // The voice session owns the speaker, whichever engine it is:
        // silence any message being read aloud. (The Mac has no auto-speak,
        // so there is nothing else to mute.)
        MessageSpeechService.shared.stop()
        registry.claim(self)
        endNote = nil
        self.engineKind = engineKind
        // `isStartPending` covers the whole build — including the chained
        // permission prompts, which can sit in front of the user for a long
        // time — so `holdsSession` is true throughout and a second window
        // cannot slip a start into the gap.
        isStartPending = true
        startTask = Task { [weak self] in
            // An end before this ran cancelled it; the engine never starts.
            guard !Task.isCancelled else { return }
            // Chained needs speech recognition and the microphone before it
            // can open an audio tap. A refusal stops here: no engine is
            // built, nothing is opened, and the panel says which permission
            // and where to grant it.
            if let authorize = wiring.authorize, let denial = await authorize() {
                guard let self, !Task.isCancelled else { return }
                self.isStartPending = false
                self.startFailure = Self.failure(for: denial)
                return
            }
            guard let self, !Task.isCancelled else { return }
            let session = wiring.makeSession(context, host)
            self.engine = session.engine
            self.bridge = session.bridge
            // No suspension between here and the engine's own
            // `.startRequested`, so `holdsSession` never reads false in
            // between.
            self.isStartPending = false
            await session.engine.start()
        }
    }

    /// A refused permission as the panel reports it. Mirrors
    /// `ChainedVoiceEngine`'s own mapping, for the denials that are caught
    /// before any engine exists.
    private static func failure(for error: VoiceListenerError) -> VoiceSessionFailure {
        switch error {
        case .speechRecognitionDenied: return .speechRecognitionDenied
        case .recognizerUnavailable, .onDeviceRecognitionUnsupported: return .speechRecognitionUnavailable
        case .microphoneDenied: return .microphoneDenied
        case .audioEngineFailed(let detail), .recognitionFailed(let detail):
            return .mediaUnavailable(detail: detail)
        }
    }

    /// Read and clear ``startRefusal`` — the caller shows it once
    /// (`ChatViewModel.startVoiceLive`).
    func consumeStartRefusal() -> StartRefusal? {
        defer { startRefusal = nil }
        return startRefusal
    }

    /// Continue on the consent sheet: remember the consent on this Mac.
    /// The caller then starts the session (`ChatViewModel.acceptVoiceLiveConsent`).
    func acceptConsent() {
        guard let recipient = pendingConsent else { return }
        pendingConsent = nil
        consent.recordConsent(to: recipient)
    }

    /// Cancel on the consent sheet: nothing starts, nothing is billed, and
    /// the next start asks again.
    func declineConsent() {
        pendingConsent = nil
    }

    /// End gracefully: GPT-Live closes the vendor session and waits for its
    /// billed seconds. The panel stays up to show the result.
    func end() {
        if cancelPendingStart() { return }
        engine?.end(reason: .userEnded)
    }

    /// End now, without waiting: window close, session/server/profile
    /// switch, leaving the chat, app quit. Safe to call at any time.
    func endImmediately() {
        // Leaving the chat takes an unanswered consent sheet with it.
        pendingConsent = nil
        if cancelPendingStart() { return }
        engine?.endImmediately(reason: .userEnded)
    }

    /// End now because the chat lost its ACP connection to Hermes; the
    /// panel says why. No-op without a session.
    func endForLostConnection() {
        guard holdsSession else { return }
        if isSessionActive { endNote = .hermesConnectionLost }
        endImmediately()
    }

    /// Close the panel. Ends a still-running session first.
    func dismiss() {
        endImmediately()
        startTask?.cancel()
        startTask = nil
        engine = nil
        bridge = nil
        endNote = nil
        startFailure = nil
    }

    func toggleMute() {
        engine?.toggleMute()
    }

    /// An end that arrives before the start task ran: cancel the start and
    /// drop the never-started session (nothing was opened or billed, so
    /// there is nothing for the panel to report). Returns whether it did.
    ///
    /// Cancelling does NOT take down a permission prompt that is already in
    /// front of the user: `AppleOnDeviceVoiceListener.authorize()` wraps
    /// TCC's own callback APIs, which have no cancellation. The prompt
    /// stays up until the user answers it, and the start task's
    /// `Task.isCancelled` guard after the `await` drops that late answer —
    /// so an end during the prompt never mounts a session.
    private func cancelPendingStart() -> Bool {
        guard isStartPending else { return false }
        startTask?.cancel()
        startTask = nil
        isStartPending = false
        engine = nil
        bridge = nil
        return true
    }
}

/// The app's one Live Voice session. Each window owns a
/// ``VoiceLiveController``, but a second concurrent session would bill the
/// host's OpenAI key twice and fight over the microphone and speaker, so a
/// start is refused while another window holds the session (the ScarfGo
/// rule too: it refuses a start while something else holds the mic).
/// Refusing, rather than ending the other window's session, never cuts off a
/// conversation — or the Hermes turn it is waiting on — from a window the
/// user isn't looking at; that window's panel shows the session and its End
/// button.
@MainActor
@Observable
final class VoiceLiveSessionRegistry {
    static let shared = VoiceLiveSessionRegistry()

    /// The controller that claimed the session last. Weak: a closed
    /// window's controller must not pin the session (its teardown ended it).
    @ObservationIgnored private weak var holder: VoiceLiveController?
    /// Observed stand-in for `holder`, so views re-evaluate on a claim.
    private var holderID: ObjectIdentifier?

    init() {}

    func claim(_ controller: VoiceLiveController) {
        holder = controller
        holderID = ObjectIdentifier(controller)
    }

    /// Some window other than `controller`'s holds a starting or running
    /// session.
    func isHeld(byAnotherThan controller: VoiceLiveController) -> Bool {
        _ = holderID
        guard let holder, holder !== controller else { return false }
        return holder.holdsSession
    }

    /// Any window holds a starting or running session (the message speaker
    /// buttons stand down while one does).
    var isAnySessionActive: Bool {
        _ = holderID
        return holder?.holdsSession ?? false
    }
}
