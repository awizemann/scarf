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

    private(set) var engine: (any VoiceConversationEngine)?
    private(set) var bridge: WebViewVoiceMediaBridge?
    /// Set when the host ended the session for a reason the panel shows.
    /// Cleared by the next start and by `dismiss`.
    private(set) var endNote: EndNote?
    /// `start` has built the engine but its start task hasn't run yet
    /// (the engine is still `.idle`). Counts as holding the session, so a
    /// second window can't slip a start into that gap, and an end in it
    /// cancels the start instead of being lost on an idle engine.
    private(set) var isStartPending = false

    @ObservationIgnored private let makeSession: SessionFactory
    @ObservationIgnored private let registry: VoiceLiveSessionRegistry
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(makeSession: SessionFactory? = nil, registry: VoiceLiveSessionRegistry? = nil) {
        self.makeSession = makeSession ?? Self.gptLive
        self.registry = registry ?? .shared
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
    func start(context: ServerContext, host: any VoiceTurnHost) {
        guard !holdsSession, !isBlockedByAnotherWindow else { return }
        // GPT-Live owns the speaker: silence any message being read aloud.
        // (The Mac has no auto-speak, so there is nothing else to mute.)
        MessageSpeechService.shared.stop()
        registry.claim(self)
        endNote = nil
        let session = makeSession(context, host)
        engine = session.engine
        bridge = session.bridge
        let engine = session.engine
        isStartPending = true
        startTask = Task { [weak self] in
            // An end before this ran cancelled it; the engine never starts.
            guard !Task.isCancelled else { return }
            // No suspension between here and the engine's own
            // `.startRequested`, so `holdsSession` never reads false in
            // between.
            self?.isStartPending = false
            await engine.start()
        }
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
    }

    func toggleMute() {
        engine?.toggleMute()
    }

    /// An end that arrives before the start task ran: cancel the start and
    /// drop the never-started session (nothing was opened or billed, so
    /// there is nothing for the panel to report). Returns whether it did.
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
