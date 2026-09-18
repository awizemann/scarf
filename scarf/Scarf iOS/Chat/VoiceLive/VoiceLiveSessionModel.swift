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
}

// MARK: - Session model

@MainActor
@Observable
final class VoiceLiveSessionModel {

    /// One running (or just-finished) session: the engine the sheet binds
    /// to, and the web view bridge the sheet must keep mounted
    /// (`VoiceLiveMediaHostView`). Tests pass `bridge: nil`.
    struct Session {
        let engine: any VoiceConversationEngine
        let bridge: WebViewVoiceMediaBridge?
    }

    typealias SessionFactory = @MainActor (any VoiceTurnHost) -> Session

    /// The current or last session. Kept after it ends so the sheet can
    /// show how it ended; replaced by the next `begin`.
    private(set) var session: Session?
    /// Drives the session sheet.
    var isPresented = false
    private(set) var composerNotice: VoiceLiveComposerNotice?

    /// A session exists and has not ended (connecting through ending).
    var isActive: Bool { session?.engine.phase.isActive ?? false }

    @ObservationIgnored private let makeSession: SessionFactory
    @ObservationIgnored private let audioSession: any VoiceLiveAudioSessionControlling
    @ObservationIgnored private let backgroundTasks: any VoiceLiveBackgroundTaskRunning
    @ObservationIgnored private let microphone: any VoiceLiveMicrophonePermissionChecking
    @ObservationIgnored private let teardownGrace: Duration
    @ObservationIgnored private var audioSessionActive = false
    @ObservationIgnored private var isBeginning = false
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
        self.init(
            makeSession: { host in
                let bridge = WebViewVoiceMediaBridge()
                let engine = GPTLiveEngine(
                    bridge: bridge,
                    exchange: VoiceLiveHostExchange(context: context),
                    turnHost: host
                )
                return Session(engine: engine, bridge: bridge)
            },
            audioSession: VoiceLiveAVAudioSession(),
            backgroundTasks: UIKitBackgroundTaskRunner(),
            microphone: AVMicrophonePermissionClient()
        )
        observeAudioInterruptions()
    }

    /// Test seam: every collaborator injected; no system notifications.
    init(
        makeSession: @escaping SessionFactory,
        audioSession: any VoiceLiveAudioSessionControlling,
        backgroundTasks: any VoiceLiveBackgroundTaskRunning,
        microphone: any VoiceLiveMicrophonePermissionChecking,
        teardownGrace: Duration = .seconds(5)
    ) {
        self.makeSession = makeSession
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
    /// running. Asks for the microphone first — the same system prompt P1
    /// dictation uses — so a denial costs nothing and opens no sheet.
    func begin(host: any VoiceTurnHost, dictationIdle: Bool) async {
        guard dictationIdle, !isActive, !isBeginning else { return }
        isBeginning = true
        defer { isBeginning = false }
        composerNotice = nil
        let generation = teardownGeneration

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

        audioSession.activate()
        audioSessionActive = true
        let next = makeSession(host)
        session = next
        isPresented = true
        await next.engine.start()
        // `start` returns once the media is up (or failed); a failure is a
        // terminal phase the sheet shows. Release the audio if so.
        phaseDidChange()
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

    private func releaseAudioSession() {
        guard audioSessionActive else { return }
        audioSessionActive = false
        audioSession.deactivate()
    }

    private func showComposerNotice(_ notice: VoiceLiveComposerNotice) {
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

// MARK: - Production collaborators

/// Play-and-record in voice-chat mode, speaker by default, Bluetooth HFP
/// (AirPods) allowed: the call-style session a two-way voice conversation
/// needs. WebKit captures through the voice-processing I/O unit (AEC), which
/// `.voiceChat` expects. P1 dictation claims the session with
/// `.measurement` only for the length of a take and hands it back
/// (`notifyOthersOnDeactivation`); the composer never runs both at once.
@MainActor
final class VoiceLiveAVAudioSession: VoiceLiveAudioSessionControlling {
    func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

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
