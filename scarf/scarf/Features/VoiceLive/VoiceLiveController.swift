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

    @ObservationIgnored private let makeSession: SessionFactory
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(makeSession: SessionFactory? = nil) {
        self.makeSession = makeSession ?? Self.gptLive
    }

    /// A session exists and hasn't finished (connecting through ending).
    var isSessionActive: Bool { engine?.phase.isActive ?? false }

    /// Start a new session in `context`'s chat. No-op while one is active.
    /// A finished session still on screen is replaced.
    func start(context: ServerContext, host: any VoiceTurnHost) {
        guard !isSessionActive else { return }
        // GPT-Live owns the speaker: silence any message being read aloud.
        // (The Mac has no auto-speak, so there is nothing else to mute.)
        MessageSpeechService.shared.stop()
        let session = makeSession(context, host)
        engine = session.engine
        bridge = session.bridge
        let engine = session.engine
        startTask = Task { await engine.start() }
    }

    /// End gracefully: GPT-Live closes the vendor session and waits for its
    /// billed seconds. The panel stays up to show the result.
    func end() {
        engine?.end(reason: .userEnded)
    }

    /// End now, without waiting: window close, session/server/profile
    /// switch, leaving the chat, app quit. Safe to call at any time.
    func endImmediately() {
        engine?.endImmediately(reason: .userEnded)
    }

    /// Close the panel. Ends a still-running session first.
    func dismiss() {
        endImmediately()
        startTask?.cancel()
        startTask = nil
        engine = nil
        bridge = nil
    }

    func toggleMute() {
        engine?.toggleMute()
    }
}
