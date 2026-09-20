import Foundation
import Observation
import ScarfCore
import AVFoundation
import UIKit

// ScarfGo's Live Voice lifecycle (P5b). Binds the shared ScarfCore engine
// (`VoiceConversationEngine`, P4) to the phone: the composer gate, the
// dictation/live-voice exclusivity, the microphone permission, the
// AVAudioSession, and every teardown path. An open GPT-Live session bills
// $0.05/min on the host's OpenAI key, so every way out of the Chat screen
// ends it.

// MARK: - Composer gate (pure)

/// What the composer shows for Live Voice and whether dictation may run.
/// Pure so the rules are unit-tested without a view.
enum VoiceLiveComposerGate {
    enum Entry: Equatable {
        /// Not rendered at all (charter C1: a host that isn't ready renders
        /// the composer exactly as before).
        case hidden
        /// Rendered but not tappable (chat not connected, or a dictation
        /// take is running).
        case disabled
        case enabled
    }

    static func entry(
        availability: VoiceLiveAvailability,
        chatReady: Bool,
        dictationIdle: Bool,
        liveVoiceActive: Bool
    ) -> Entry {
        guard availability.isReady else { return .hidden }
        guard chatReady, dictationIdle, !liveVoiceActive else { return .disabled }
        return .enabled
    }

    /// Hold-to-talk dictation is off while a Live Voice session holds the
    /// microphone (and, as before, while the chat isn't connected).
    static func dictationAllowed(chatReady: Bool, liveVoiceActive: Bool) -> Bool {
        chatReady && !liveVoiceActive
    }
}

// MARK: - Collaborators (protocols so the model is testable)

/// Why a session was torn down from outside the session screen.
enum VoiceLiveTeardownTrigger: Equatable, Sendable {
    /// The app left the foreground (ScarfGo has no background-audio mode).
    case backgrounded
    /// Chat left the screen: a tab switch, a server or profile switch.
    case viewDisappeared
    /// The chat's ACP session changed under the voice session.
    case sessionChanged
    /// The session sheet was dismissed (swipe down or Done).
    case sheetDismissed
    /// A phone call, Siri or another app took the audio session.
    case audioInterrupted
    /// The chat's ACP connection to Hermes died (or is reconnecting), so
    /// no spoken request could reach Hermes any more.
    case hermesConnectionLost
}

/// Why the HOST (not the engine) ended the session, when the sheet should
/// say so. The engine reports these as a plain `.userEnded`. Mirrors the
/// Mac's `VoiceLiveController.EndNote`.
enum VoiceLiveEndNote: Equatable, Sendable {
    case hermesConnectionLost
}

/// Microphone permission, the same system permission P1 dictation uses
/// (`AVAudioApplication.recordPermission`). Live Voice needs only the
/// microphone — no speech recognition, which happens at OpenAI.
enum VoiceLiveMicrophonePermission: Equatable, Sendable {
    case granted
    case undetermined
    case denied
}

protocol VoiceLiveMicrophonePermissionChecking: Sendable {
    func status() -> VoiceLiveMicrophonePermission
    func request() async -> Bool
}

/// The app's AVAudioSession for a two-way voice call.
@MainActor
protocol VoiceLiveAudioSessionControlling: AnyObject {
    func activate()
    func deactivate()
}

/// `UIApplication.beginBackgroundTask` behind a seam.
@MainActor
protocol VoiceLiveBackgroundTaskRunning: AnyObject {
    func begin() -> Int
    func end(_ token: Int)
}

/// Something the composer says about Live Voice outside the session sheet.
enum VoiceLiveComposerNotice: Equatable, Sendable {
    /// The microphone is denied; offer the Settings link.
    case microphoneDenied
    /// A call or Siri took the audio and the session ended.
    case interrupted
    /// The chat lost its connection to Hermes and the session ended.
    case hermesConnectionLost
    /// A spoken request arrived while Hermes worked on a typed one, so it
    /// wasn't sent (t-2140ec98). The session keeps running.
    case busyWithTypedTurn
}

/// Somewhere the composer's Live Voice hint can be shown.
/// `ChatController` holds one weakly so `submitVoiceTurn` can explain why a
/// spoken request wasn't sent, without owning the session model.
@MainActor
protocol VoiceLiveComposerNoticing: AnyObject {
    func showComposerNotice(_ notice: VoiceLiveComposerNotice)
}

// MARK: - Session model

@MainActor
@Observable
final class VoiceLiveSessionModel: VoiceLiveComposerNoticing {

    /// One running (or just-finished) session: the engine the sheet binds
    /// to, which engine it is (the sheet's cost and privacy copy differ),
    /// and the web view bridge the sheet must keep mounted
    /// (`VoiceLiveMediaHostView`). Chained sessions have no bridge; tests
    /// pass `bridge: nil` for either engine.
    struct Session {
        let engine: any VoiceConversationEngine
        let kind: VoiceEngineKind
        let bridge: WebViewVoiceMediaBridge?

        init(engine: any VoiceConversationEngine, kind: VoiceEngineKind = .gptLive, bridge: WebViewVoiceMediaBridge? = nil) {
            self.engine = engine
            self.kind = kind
            self.bridge = bridge
        }
    }

    /// Builds the session for the engine the host's `voice.voice_chat_mode`
    /// resolved to (``VoiceLiveAvailability/engineKind``). The KIND is an
    /// argument rather than baked into the model, because one Chat screen
    /// can switch modes under it without being rebuilt.
    typealias SessionFactory = @MainActor (VoiceEngineKind, any VoiceTurnHost) -> Session

    /// The current or last session. Kept after it ends so the sheet can
    /// show how it ended; replaced by the next `begin`.
    private(set) var session: Session?
    /// Drives the session sheet.
    var isPresented = false
    private(set) var composerNotice: VoiceLiveComposerNotice?
    /// Set when the host ended the session for a reason the sheet shows.
    /// Cleared by the next `begin`.
    private(set) var endNote: VoiceLiveEndNote?
    /// The app's `AVAudioSession` is still configured for this session.
    /// Stays true from ``begin(host:dictationIdle:)`` until the deferred
    /// release has actually run — which is AFTER ``isActive`` goes false,
    /// because the release waits for WebKit to let the microphone go.
    private(set) var holdsAudioSession = false
    /// A start is waiting for the user to agree to send their data to this
    /// recipient (drives the consent sheet). Nothing is asked of the
    /// microphone, the audio session or the host until ``acceptConsent()``.
    var pendingConsent: VoiceDataRecipient?

    /// A session exists and has not ended (connecting through ending).
    var isActive: Bool { session?.engine.phase.isActive ?? false }

    /// Push-to-talk dictation must stand down for this whole window, not
    /// just while the session is active: a hold started between the end of
    /// the session and the deferred `setActive(false)` was cut off by it.
    ///
    /// ``isBeginning`` is part of the window too. The chained branch of
    /// ``begin(host:engine:dictationIdle:)`` suspends on TWO system dialogs
    /// (speech recognition, then the microphone) before any session exists,
    /// so `isActive` and `holdsAudioSession` are both false for as long as
    /// the user reads them. Without this term the dictation button stayed
    /// enabled behind the prompts, and a hold started there ran its
    /// recognizer straight into the audio session and microphone tap that
    /// `begin` opens the moment authorization returns.
    var blocksDictation: Bool { isActive || holdsAudioSession || isBeginning }

    @ObservationIgnored private let makeSession: SessionFactory
    @ObservationIgnored private let audioSession: any VoiceLiveAudioSessionControlling
    @ObservationIgnored private let backgroundTasks: any VoiceLiveBackgroundTaskRunning
    @ObservationIgnored private let microphone: any VoiceLiveMicrophonePermissionChecking
    @ObservationIgnored private let consent: VoiceDataConsentStore
    /// Who the engine `makeSession` builds sends data to directly, per
    /// engine kind. GPT-Live declares OpenAI; the chained engine transcribes
    /// on-device and declares nothing, so it never asks for consent.
    @ObservationIgnored private let externalRecipient: @MainActor (VoiceEngineKind) -> VoiceDataRecipient?
    /// Speech-recognition + microphone authorization for the chained engine
    /// (two separate TCC entries). Behind a seam so tests never touch the
    /// real microphone or the real Speech framework.
    @ObservationIgnored private let speechAuthorizer: any VoiceLiveSpeechAuthorizing
    @ObservationIgnored private let teardownGrace: Duration
    @ObservationIgnored private var audioSessionActive = false
    /// Bumped by every ``releaseAudioSession()``, so a deferred deactivate
    /// that lost its race — another release, or a new session — is skipped
    /// instead of handing the audio session back under whoever holds it now.
    @ObservationIgnored private var audioSessionGeneration = 0
    /// A start is past its guards and waiting on the system permission
    /// dialogs. Observed (not `@ObservationIgnored`) because
    /// ``blocksDictation`` reads it and the composer's dictation button
    /// must redraw when it changes.
    private(set) var isBeginning = false
    /// Bumped by every teardown, so a `begin` suspended on the microphone
    /// prompt doesn't open a session after the user already left Chat.
    @ObservationIgnored private var teardownGeneration = 0
    @ObservationIgnored private var noticeGeneration = 0

    /// `AVAudioSession.interruptionNotification` listener. `nonisolated(unsafe)`
    /// per the "MainActor + @Observable deinit Task cleanup" convention.
    @ObservationIgnored
    private nonisolated(unsafe) var interruptionTask: Task<Void, Never>?

    /// Production wiring: GPT-Live over the WKWebView bridge, the host-side
    /// session exchange on `context`, the real audio session, background
    /// tasks and microphone permission.
    convenience init(context: ServerContext) {
        // One app-owned `AVAudioSession`: the chained listener and the
        // Hermes/AVAudioPlayer speaker both run on the session
        // `VoiceLiveAVAudioSession` configures (playAndRecord + voiceChat +
        // defaultToSpeaker), so the microphone stays open while the reply
        // plays. `AppleOnDeviceVoiceListener` is handed that same owner
        // through its seam, so its default never fights this one.
        let owner = VoiceLiveAVAudioSession()
        self.init(
            makeSession: { kind, host in
                switch kind {
                case .gptLive:
                    let bridge = WebViewVoiceMediaBridge()
                    let engine = GPTLiveEngine(
                        bridge: bridge,
                        exchange: VoiceLiveHostExchange(context: context),
                        turnHost: host
                    )
                    return Session(engine: engine, kind: .gptLive, bridge: bridge)
                case .chained:
                    let engine = ChainedVoiceEngine(
                        listener: AppleOnDeviceVoiceListener(audioSession: VoiceLiveAudioSessionAdapter(owner: owner)),
                        speaker: FallbackVoiceSpeaker(
                            primary: HermesVoiceSpeaker(context: context),
                            fallback: SystemVoiceSpeaker()
                        ),
                        turnHost: host
                    )
                    return Session(engine: engine, kind: .chained, bridge: nil)
                }
            },
            externalRecipient: { kind in Self.productionRecipient(for: kind) },
            audioSession: owner,
            backgroundTasks: UIKitBackgroundTaskRunner(),
            microphone: AVMicrophonePermissionClient(),
            consent: .shared,
            speechAuthorizer: AppleSpeechAuthorizer()
        )
        observeAudioInterruptions()
    }

    /// Who the engine for `kind` sends the user's voice to directly — the
    /// production answer, used by ``init(context:)`` and asserted directly
    /// by tests (a test that hardcodes the same mapping into its own
    /// harness proves nothing about the app). GPT-Live streams audio to
    /// OpenAI and must ask first; the chained engine transcribes on this
    /// iPhone and declares no recipient, so it never asks.
    static func productionRecipient(for kind: VoiceEngineKind) -> VoiceDataRecipient? {
        switch kind {
        case .gptLive: return GPTLiveEngine.externalRecipient
        case .chained: return ChainedVoiceEngine.externalRecipient
        }
    }

    /// Test seam: every collaborator injected; no system notifications.
    init(
        makeSession: @escaping SessionFactory,
        externalRecipient: @escaping @MainActor (VoiceEngineKind) -> VoiceDataRecipient?,
        audioSession: any VoiceLiveAudioSessionControlling,
        backgroundTasks: any VoiceLiveBackgroundTaskRunning,
        microphone: any VoiceLiveMicrophonePermissionChecking,
        consent: VoiceDataConsentStore,
        teardownGrace: Duration = .seconds(5),
        speechAuthorizer: any VoiceLiveSpeechAuthorizing = AlwaysAuthorizedSpeech()
    ) {
        self.makeSession = makeSession
        self.externalRecipient = externalRecipient
        self.speechAuthorizer = speechAuthorizer
        self.consent = consent
        self.audioSession = audioSession
        self.backgroundTasks = backgroundTasks
        self.microphone = microphone
        self.teardownGrace = teardownGrace
    }

    deinit {
        interruptionTask?.cancel()
    }

    // MARK: Start

    /// Start a session for `host`. Refuses while dictation holds the
    /// microphone (`dictationIdle == false`) or a session is already
    /// running. The first start on this device for an engine that sends
    /// data to a third party only raises ``pendingConsent`` (the consent
    /// sheet); the view calls `begin` again after ``acceptConsent()``. Then
    /// it asks for the microphone — the same system prompt P1 dictation
    /// uses — so a denial costs nothing and opens no sheet.
    /// `dictationIdle` is an autoclosure because it is read TWICE: once up
    /// front, and again after the permission prompts return, which can be
    /// many seconds later. The caller passes the live expression
    /// (`pushToTalk.phase == .idle`) and both reads see the truth.
    func begin(
        host: any VoiceTurnHost,
        engine kind: VoiceEngineKind = .gptLive,
        dictationIdle: @autoclosure () -> Bool
    ) async {
        guard dictationIdle(), !isActive, !isBeginning else { return }
        if let recipient = VoiceDataConsent.pendingRecipient(for: externalRecipient(kind), store: consent) {
            pendingConsent = recipient
            return
        }
        pendingConsent = nil
        isBeginning = true
        defer { isBeginning = false }
        composerNotice = nil
        endNote = nil
        let generation = teardownGeneration

        switch kind {
        case .gptLive:
            // GPT-Live transcribes at OpenAI: the microphone is the only
            // permission it needs.
            switch microphone.status() {
            case .granted:
                break
            case .denied:
                showComposerNotice(.microphoneDenied)
                return
            case .undetermined:
                guard await microphone.request() else {
                    showComposerNotice(.microphoneDenied)
                    return
                }
                guard generation == teardownGeneration else { return }
            }
        case .chained:
            // Chained transcribes on this device, so it needs BOTH speech
            // recognition and the microphone — two TCC entries with two
            // different Settings rows. A denial is shown in the sheet with
            // the right row named, not as a bare "try again".
            let denial = await speechAuthorizer.authorize()
            guard generation == teardownGeneration else { return }
            if let denial {
                present(failure: Self.failure(for: denial), kind: kind)
                return
            }
        }

        // The permission prompts above are the only suspension points in a
        // start, and a dictation take can begin behind them (the user can
        // still reach the composer). Re-assert the guard we checked at the
        // top before claiming the audio session and opening the tap.
        guard dictationIdle() else { return }

        audioSession.activate()
        audioSessionActive = true
        holdsAudioSession = true
        audioSessionGeneration += 1
        let next = makeSession(kind, host)
        session = next
        isPresented = true
        await next.engine.start()
        // `start` returns once the media is up (or failed); a failure is a
        // terminal phase the sheet shows. Release the audio if so.
        phaseDidChange()
    }

    /// The engine's own mapping, repeated here because the authorization
    /// happens BEFORE the listener exists (`ChainedVoiceEngine.failure(for:)`
    /// is internal to ScarfCore). Same three outcomes the listener throws.
    static func failure(for error: VoiceListenerError) -> VoiceSessionFailure {
        switch error {
        case .speechRecognitionDenied: return .speechRecognitionDenied
        case .recognizerUnavailable, .onDeviceRecognitionUnsupported: return .speechRecognitionUnavailable
        case .microphoneDenied: return .microphoneDenied
        case .audioEngineFailed(let detail), .recognitionFailed(let detail):
            return .mediaUnavailable(detail: detail)
        }
    }

    /// Show a start-time failure in the session sheet without ever opening
    /// the microphone or the audio session. The sheet binds to
    /// `VoiceConversationEngine`, so the failure travels as a session that
    /// is born terminal (``StillbornVoiceEngine``) and renders through the
    /// same localized failure copy as any other.
    private func present(failure: VoiceSessionFailure, kind: VoiceEngineKind) {
        session = Session(engine: StillbornVoiceEngine(failure: failure), kind: kind, bridge: nil)
        isPresented = true
    }

    // MARK: Consent

    /// Continue on the consent sheet: remember it on this device. The view
    /// then calls `begin` for the session the user asked for.
    func acceptConsent() {
        guard let recipient = pendingConsent else { return }
        pendingConsent = nil
        consent.recordConsent(to: recipient)
    }

    /// Cancel on the consent sheet (or swiping it away): nothing starts,
    /// nothing is billed, and the next start asks again.
    func declineConsent() {
        pendingConsent = nil
    }

    // MARK: End

    /// The End button: graceful (GPT-Live waits up to 15 s for the vendor's
    /// final usage figure).
    func endFromUser() {
        session?.engine.end(reason: .userEnded)
    }

    func toggleMute() {
        session?.engine.toggleMute()
    }

    /// End now, from outside the session screen. On iOS the close and the
    /// WebKit teardown are asynchronous, so run them inside a background
    /// task: otherwise a backgrounding app can be suspended before the
    /// vendor hears the close, and the session keeps billing until the
    /// vendor's own timeout.
    func teardown(_ trigger: VoiceLiveTeardownTrigger) {
        teardownGeneration += 1
        // The engine reports every host-driven end as a plain `.userEnded`,
        // so the reason the user needs is carried here (the Mac does the
        // same through `VoiceLiveController.endNote`).
        if trigger == .hermesConnectionLost, isActive { endNote = .hermesConnectionLost }
        // Leaving Chat takes an unanswered consent sheet with it.
        if trigger == .viewDisappeared || trigger == .sessionChanged {
            pendingConsent = nil
        }
        if trigger == .sheetDismissed || trigger == .viewDisappeared || trigger == .backgrounded {
            isPresented = false
        }
        guard let engine = session?.engine, engine.phase.isActive else {
            releaseAudioSession()
            return
        }
        let token = backgroundTasks.begin()
        engine.endImmediately(reason: .userEnded)
        releaseAudioSession()
        if trigger == .audioInterrupted { showComposerNotice(.interrupted) }
        // The sheet may already have been swiped away, so the composer says
        // it too — this end is not something the user asked for.
        if trigger == .hermesConnectionLost { showComposerNotice(.hermesConnectionLost) }
        let grace = teardownGrace
        let tasks = backgroundTasks
        Task { @MainActor in
            try? await Task.sleep(for: grace)
            tasks.end(token)
        }
    }

    /// Call when the engine's phase changes (the sheet observes it). A
    /// terminal phase hands the audio session back to other apps.
    func phaseDidChange() {
        guard let phase = session?.engine.phase, phase.isTerminal else { return }
        releaseAudioSession()
    }

    /// The Settings link / Done on a composer notice.
    func dismissComposerNotice() {
        composerNotice = nil
    }

    // MARK: Internals

    /// Hand the audio session back to other apps, but only once WebKit has
    /// actually stopped the microphone and playback
    /// (`VoiceConversationEngine.waitForMediaRelease`, bounded): deactivating
    /// while its capture unit still runs fails as "session busy" and the
    /// other app's audio never resumes. A session started in the meantime
    /// keeps the audio session.
    ///
    /// The chained engine leans on a DIFFERENT half of that contract: it
    /// does not override `waitForMediaRelease()`, so the default no-op
    /// returns at once and the deactivate below runs essentially inline.
    /// That is only safe because `ChainedVoiceEngine.complete()` calls
    /// `listener.stop()` and `speaker.stop()` SYNCHRONOUSLY before it
    /// publishes the terminal phase that brings us here — the microphone
    /// and the player are already down by the time we deactivate. If the
    /// chained engine ever grows an asynchronous stop (a fade-out, a
    /// drain), it must override `waitForMediaRelease()` at the same time,
    /// or this deactivate will land under a running player.
    private func releaseAudioSession() {
        guard audioSessionActive else { return }
        audioSessionActive = false
        audioSessionGeneration += 1
        let mine = audioSessionGeneration
        let engine = session?.engine
        let audioSession = audioSession
        Task { @MainActor [weak self] in
            await engine?.waitForMediaRelease()
            guard let self, self.audioSessionGeneration == mine, !self.audioSessionActive else { return }
            audioSession.deactivate()
            self.holdsAudioSession = false
        }
    }

    func showComposerNotice(_ notice: VoiceLiveComposerNotice) {
        composerNotice = notice
        noticeGeneration += 1
        let mine = noticeGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.noticeGeneration == mine else { return }
            self.composerNotice = nil
        }
    }

    /// Internal (not private) so tests can drive it without a real
    /// notification. `began` ends the session: a call must not leave a
    /// billed session running behind it, and resuming a half-duplex
    /// conversation after a call is not what the user expects.
    func handleAudioSessionInterruption(began: Bool) {
        guard began, isActive else { return }
        teardown(.audioInterrupted)
    }

    private func observeAudioInterruptions() {
        interruptionTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification
            )
            for await notification in notifications {
                guard let self else { return }
                guard let info = notification.userInfo,
                      let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType) else { continue }
                self.handleAudioSessionInterruption(began: type == .began)
            }
        }
    }
}

// MARK: - Speech authorization seam

/// Speech-recognition + microphone authorization for the chained engine.
/// A seam so tests never touch the real Speech framework or microphone;
/// production is ``AppleSpeechAuthorizer`` over
/// `AppleOnDeviceVoiceListener.authorize()`.
protocol VoiceLiveSpeechAuthorizing: Sendable {
    /// `nil` means both permissions are granted.
    func authorize() async -> VoiceListenerError?
}

/// Production: the listener's own statics, which prompt for speech
/// recognition first and then the microphone.
struct AppleSpeechAuthorizer: VoiceLiveSpeechAuthorizing {
    func authorize() async -> VoiceListenerError? {
        await AppleOnDeviceVoiceListener.authorize()
    }
}

/// The default for the GPT-Live-only test seam (and any caller that never
/// mounts the chained engine): nothing to ask.
struct AlwaysAuthorizedSpeech: VoiceLiveSpeechAuthorizing {
    func authorize() async -> VoiceListenerError? { nil }
}

/// An engine that never ran: born in a terminal `.failed` phase so a
/// permission denial reaches the session sheet through the ordinary
/// `VoiceConversationEngine` surface. It owns no microphone, no audio
/// session and no host connection, so every control on it is a no-op.
@MainActor
@Observable
final class StillbornVoiceEngine: VoiceConversationEngine {
    let phase: VoiceConversationPhase
    let captions: [VoiceCaption] = []
    let micLevel: Double = 0
    let isMuted = false
    let elapsedSeconds: TimeInterval = 0
    let approximateCostUSD: Double = 0
    let notice: VoiceSessionNotice? = nil

    init(failure: VoiceSessionFailure) {
        phase = .failed(failure)
    }

    func start() async {}
    func end(reason: VoiceSessionEndReason) {}
    func endImmediately(reason: VoiceSessionEndReason) {}
    func toggleMute() {}
}

/// Hands ``AppleOnDeviceVoiceListener`` the app's own audio-session owner.
/// P7c owns the iOS audio-session policy: `VoiceLiveAVAudioSession` is the
/// single place that sets playAndRecord/voiceChat/defaultToSpeaker and
/// restores the app's prior configuration, and the model's generation-guarded
/// deferred release is the only thing that deactivates it. The listener's own
/// `DefaultVoiceAudioSession` would set the category again on `start()` and
/// deactivate it on `stop()` — under the speaker, mid-session — so it is
/// replaced by this no-op adapter.
@MainActor
final class VoiceLiveAudioSessionAdapter: VoiceAudioSessionControlling {
    private weak var owner: VoiceLiveAVAudioSession?

    init(owner: VoiceLiveAVAudioSession) {
        self.owner = owner
    }

    /// Already active: ``VoiceLiveSessionModel/begin(host:engine:dictationIdle:)``
    /// activated the owner before the engine was built.
    func activateForVoiceConversation() throws {}

    /// Deliberately nothing. The model releases the session after the
    /// engine's media is down, under a generation guard.
    func deactivate() {}
}

// MARK: - Production collaborators

/// Play-and-record in voice-chat mode, speaker by default, Bluetooth HFP
/// (AirPods) allowed: the call-style session a two-way voice conversation
/// needs. WebKit captures through the voice-processing I/O unit (AEC), which
/// `.voiceChat` expects. P1 dictation claims the session with
/// `.measurement` only for the length of a take and hands it back
/// (`notifyOthersOnDeactivation`); the composer never runs both at once.
@MainActor
final class VoiceLiveAVAudioSession: VoiceLiveAudioSessionControlling {
    /// The `AVAudioSession` members Live Voice touches, behind a seam so
    /// the save/restore is testable without a real audio session.
    /// `AVAudioSession` satisfies it as it stands.
    protocol System: AnyObject {
        var category: AVAudioSession.Category { get }
        var mode: AVAudioSession.Mode { get }
        var categoryOptions: AVAudioSession.CategoryOptions { get }
        func setCategory(
            _ category: AVAudioSession.Category,
            mode: AVAudioSession.Mode,
            options: AVAudioSession.CategoryOptions
        ) throws
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
    }

    /// What the app was configured for before Live Voice took the session.
    private struct Configuration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private let session: any System
    private var previous: Configuration?

    init(session: (any System)? = nil) {
        self.session = session ?? AVAudioSession.sharedInstance()
    }

    func activate() {
        previous = Configuration(
            category: session.category, mode: session.mode, options: session.categoryOptions)
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true, options: [])
    }

    /// Hand the session back AND put the app on the category it had before.
    /// Without the restore the app stayed on `.playAndRecord` / `.voiceChat`
    /// / speaker for the rest of its life: every later sound — a
    /// notification, a spoken message — played through the call route, at
    /// call quality, with the microphone still claimed.
    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let previous {
            try? session.setCategory(previous.category, mode: previous.mode, options: previous.options)
            self.previous = nil
        }
    }
}

extension AVAudioSession: VoiceLiveAVAudioSession.System {}

@MainActor
final class UIKitBackgroundTaskRunner: VoiceLiveBackgroundTaskRunning {
    private var open: [Int: UIBackgroundTaskIdentifier] = [:]
    private var nextToken = 0

    func begin() -> Int {
        nextToken += 1
        let token = nextToken
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Scarf Live Voice teardown") { [weak self] in
            // Expiry: end it ourselves or iOS kills the app.
            MainActor.assumeIsolated { self?.end(token) }
        }
        open[token] = identifier
        return token
    }

    func end(_ token: Int) {
        guard let identifier = open.removeValue(forKey: token), identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

struct AVMicrophonePermissionClient: VoiceLiveMicrophonePermissionChecking {
    func status() -> VoiceLiveMicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .undetermined: return .undetermined
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
