import Foundation
import Observation
#if canImport(os)
import os
#endif
#if os(iOS)
import AVFoundation
#endif

/// Combined state of the two permissions push-to-talk dictation needs:
/// microphone capture and speech recognition.
public enum PushToTalkPermission: Equatable, Sendable {
    case granted
    /// At least one system prompt has never been shown — hold-to-talk
    /// can't record yet but the user can still grant from a hold.
    case undetermined
    case microphoneDenied
    case speechDenied
    /// Parental controls / MDM — the user can't fix this from Settings.
    case restricted
}

/// Permission surface behind a protocol so the state machine's
/// permission flow is testable without system alerts. The synchronous
/// snapshot drives the instant hold path; `requestAuthorization` presents
/// the system prompts for anything still undetermined.
public protocol PushToTalkPermissionChecking: Sendable {
    func authorizationStatus() -> PushToTalkPermission
    func requestAuthorization() async -> PushToTalkPermission
}

/// One memo recording into a file URL chosen by the factory. MainActor
/// because the controller that drives it is — the AVFoundation calls
/// involved are cheap enough to never warrant a background hop.
@MainActor
public protocol AudioMemoRecording: AnyObject {
    /// Begin writing to the URL the receiver was constructed with.
    /// Returns false when the hardware/input stream couldn't start.
    @discardableResult
    func record() -> Bool
    /// Finish the take and finalize the file on disk.
    func stop()
    /// Discard the take and delete the file.
    func cancel()
}

/// Constructs recorders pointed at a caller-chosen file URL.
@MainActor
public protocol AudioMemoRecorderFactory {
    func makeRecorder(fileURL: URL) throws -> any AudioMemoRecording
}

/// Transcribes a finished audio file. Runs off the MainActor — the
/// controller awaits it and resumes with a plain String.
public protocol SpeechTranscribing: Sendable {
    /// Returns the best transcript, or an empty string when nothing
    /// recognizable was captured. Throws when recognition couldn't run.
    func transcribe(fileAt url: URL) async throws -> String
}

/// User-facing outcome the composer renders above the text field.
/// An enum (not a String) so the view maps each case to a localizable
/// literal — dynamic strings would silently leak English.
public enum PushToTalkNotice: Equatable, Sendable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case permissionsRestricted
    /// On-device transcription isn't available for the current
    /// locale/device. Refused before recording started — never a
    /// silent fall back to server-side recognition.
    case onDeviceUnavailable
    case recorderFailed
    case transcriptionFailed
    case nothingHeard
    case cancelled
    /// A phone call / Siri / another app claimed the audio session
    /// mid-take. The partial recording is discarded, matching a
    /// user-initiated cancel.
    case interrupted

    /// Whether the composer should offer a "Settings" deep link next
    /// to this notice — only for denials the user can actually fix
    /// from Settings (restricted-by-MDM and on-device-unsupported
    /// have no Settings toggle to flip).
    public var opensSystemSettings: Bool {
        switch self {
        case .microphonePermissionDenied, .speechPermissionDenied:
            return true
        case .permissionsRestricted, .onDeviceUnavailable, .recorderFailed,
             .transcriptionFailed, .nothingHeard, .cancelled, .interrupted:
            return false
        }
    }
}

/// State machine for the composer's hold-to-talk mic button: hold
/// records a WAV memo into tmp, release transcribes it on-device, and
/// the transcript is delivered as *editable draft text* — never sent.
/// Transport-free by design; every collaborator is an injected
/// protocol with an AVFoundation/Speech-backed default.
@MainActor
@Observable
public final class PushToTalkController {
    public enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    /// One finished transcript. The id makes every delivery a distinct
    /// value so the composer's `.onChange(of: transcript)` fires even
    /// when two takes in a row produce identical text.
    public struct TranscriptDelivery: Equatable, Sendable {
        public let id: Int
        public let text: String
    }

    public private(set) var phase: Phase = .idle
    public private(set) var notice: PushToTalkNotice?
    public private(set) var transcript: TranscriptDelivery?

    private let permissions: any PushToTalkPermissionChecking
    private let recorderFactory: any AudioMemoRecorderFactory
    private let transcriber: any SpeechTranscribing
    private let dictationAvailability: any OnDeviceDictationAvailabilityChecking
    private let makeFileURL: @Sendable () -> URL

    private var activeRecorder: (any AudioMemoRecording)?
    private var activeFileURL: URL?
    private var transcriptionTask: Task<Void, Never>?
    private var nextTranscriptID = 0

    /// Upper bound on how long a single take may sit in `.transcribing`.
    /// `OnDeviceSpeechTranscriber`'s `SFSpeechRecognizer` completion
    /// handler can simply never fire (an OS-level hiccup, not something
    /// this app controls) — without this, a hung callback parks the
    /// composer in `.transcribing` forever, which disables both
    /// dictation and Live Voice (`VoiceLiveComposerGate.dictationAllowed`
    /// requires `dictationIdle`) until the app relaunches. See
    /// `transcribe(with:url:timeout:)`.
    private let transcriptionTimeout: Duration

    #if os(iOS)
    /// Listens for `AVAudioSession.interruptionNotification` (phone
    /// call, Siri, another app grabbing the mic) for the lifetime of
    /// the controller. Cancelled in `deinit` — `nonisolated(unsafe)`
    /// because a class's `deinit` is always nonisolated (no `isolated
    /// deinit` here) and plain `nonisolated` isn't legal on a mutable
    /// stored property; `Task.cancel()` is documented thread-safe from
    /// any context, so touching this property from `deinit` can't race
    /// anything that matters despite the lack of compiler-enforced
    /// synchronization. `@ObservationIgnored` since view bodies never
    /// read this bookkeeping property.
    @ObservationIgnored
    private nonisolated(unsafe) var interruptionObserverTask: Task<Void, Never>?
    #endif

    /// Auto-clear window for `notice` — mirrors `RichChatViewModel`'s
    /// transient-hint lifetime so both strips behave the same.
    /// Injectable so a test can prove the window without waiting it out.
    private let noticeLifetime: Duration
    /// Bumped by every ``showNotice(_:)``, so each notice's own timer
    /// clears only the notice it scheduled. Identical notices in a row
    /// (two silent takes) are two notices, not one.
    private var noticeGeneration = 0

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf.ios", category: "PushToTalk")
    #endif

    /// Production wiring: real permission prompts, AVAudioRecorder
    /// memos into the app's tmp directory, on-device SFSpeechRecognizer.
    public init() {
        self.permissions = PushToTalkPermissionClient()
        self.recorderFactory = AVAudioMemoRecorderFactory()
        self.transcriber = OnDeviceSpeechTranscriber()
        self.dictationAvailability = OnDeviceDictationAvailabilityClient()
        self.makeFileURL = { Self.defaultMemoURL() }
        self.transcriptionTimeout = .seconds(20)
        self.noticeLifetime = .seconds(4)
        self.startObservingAudioInterruptionsIfNeeded()
    }

    /// Test seam — every collaborator injected. `transcriptionTimeout`
    /// defaults generously (never hit by the fast-resolving mocks most
    /// tests use) but is overridable so a test can prove the bounded
    /// timeout actually fires without waiting out the production value.
    public init(
        permissions: any PushToTalkPermissionChecking,
        recorderFactory: any AudioMemoRecorderFactory,
        transcriber: any SpeechTranscribing,
        dictationAvailability: any OnDeviceDictationAvailabilityChecking,
        makeFileURL: @escaping @Sendable () -> URL,
        transcriptionTimeout: Duration = .seconds(20),
        noticeLifetime: Duration = .seconds(4)
    ) {
        self.permissions = permissions
        self.recorderFactory = recorderFactory
        self.transcriber = transcriber
        self.dictationAvailability = dictationAvailability
        self.makeFileURL = makeFileURL
        self.transcriptionTimeout = transcriptionTimeout
        self.noticeLifetime = noticeLifetime
        // Deliberately NOT observing real AVAudioSession notifications
        // in tests — `handleAudioSessionInterruption(began:)` is called
        // directly instead, so a test doesn't depend on posting a real
        // system notification.
    }

    #if os(iOS)
    deinit {
        interruptionObserverTask?.cancel()
    }
    #endif

    /// Production-only: route `AVAudioSession.interruptionNotification`
    /// into `handleAudioSessionInterruption`. A phone call or Siri
    /// request grabs the shared audio session out from under an
    /// in-progress take; without this the controller would stay stuck
    /// in `.recording` (the finger is usually still down) with a
    /// recorder that's no longer capturing real audio.
    private func startObservingAudioInterruptionsIfNeeded() {
        #if os(iOS)
        interruptionObserverTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification
            )
            for await notification in notifications {
                guard let self else { return }
                guard
                    let info = notification.userInfo,
                    let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: rawType)
                else { continue }
                self.handleAudioSessionInterruption(began: type == .began)
            }
        }
        #endif
    }

    /// Fresh memo URL in the app's tmp directory. Public static so
    /// nothing about the location is private to an instance.
    nonisolated public static func defaultMemoURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scarf-dictation-\(UUID().uuidString).wav")
    }

    // MARK: - Gesture entry points

    /// The mic button's long-press threshold completed. With both
    /// permissions already granted this starts recording synchronously;
    /// undetermined permissions trigger the system prompts (recording
    /// then starts on the NEXT hold — the finger that opened the alert
    /// is gone by the time it's answered); denials surface a notice.
    public func holdBegan() {
        guard phase == .idle else { return }
        switch permissions.authorizationStatus() {
        case .granted:
            startRecording()
        case .undetermined:
            Task { [weak self] in
                guard let self else { return }
                let resolved = await self.permissions.requestAuthorization()
                if let denial = Self.denialNotice(for: resolved) {
                    self.showNotice(denial)
                }
            }
        case let denied:
            if let denial = Self.denialNotice(for: denied) {
                showNotice(denial)
            }
        }
    }

    /// The finger lifted (anywhere within the cancel radius). Stops the
    /// take and kicks transcription; the transcript lands in
    /// `transcript` when recognition finishes.
    public func holdReleased() {
        guard phase == .recording, let recorder = activeRecorder else { return }
        recorder.stop()
        activeRecorder = nil
        let url = activeFileURL
        activeFileURL = nil
        guard let url else {
            phase = .idle
            return
        }
        phase = .transcribing
        let transcriber = self.transcriber
        let timeout = self.transcriptionTimeout
        transcriptionTask = Task { [weak self, transcriber, timeout] in
            // `any Error` isn't Sendable under strict concurrency — carry
            // the detail back as a String instead (same pattern the iOS
            // attachment ingestion uses).
            var text: String?
            var failureDetail: String?
            var onDeviceUnavailable = false
            do {
                text = try await Self.transcribe(with: transcriber, url: url, timeout: timeout)
            } catch let error as DictationError where error.reason == .onDeviceRecognitionUnsupported {
                // Distinct from a generic failure — the composer should
                // say "not available on this device", not "try again"
                // (retrying can't help; the locale still won't support
                // on-device recognition).
                onDeviceUnavailable = true
            } catch {
                failureDetail = error.localizedDescription
            }
            // The memo is transient — drop it whether or not
            // recognition succeeded.
            try? FileManager.default.removeItem(at: url)
            // `handleViewDisappearing()` cancels this task when the
            // composer goes away mid-transcription; honor that by
            // dropping the result instead of surfacing a stale notice
            // or draft text for a screen nobody's looking at, while
            // still resetting phase so a later reappearance doesn't
            // find the controller stuck in `.transcribing` forever.
            guard !Task.isCancelled else {
                self?.phase = .idle
                return
            }
            self?.transcriptionFinished(
                text: text,
                failureDetail: failureDetail,
                onDeviceUnavailable: onDeviceUnavailable
            )
        }
    }

    /// The finger dragged past the cancel radius. Discards the take
    /// without transcribing.
    public func holdCancelled() {
        guard phase == .recording, let recorder = activeRecorder else { return }
        activeRecorder = nil
        activeFileURL = nil
        recorder.cancel()
        phase = .idle
        showNotice(.cancelled)
    }

    /// A live recording or in-flight transcription is about to be
    /// orphaned — the owning view is disappearing (tab switch away
    /// from Chat) or the app is backgrounding. Recording keeps the mic
    /// hot with nobody watching the status strip, so treat it exactly
    /// like a user-initiated cancel; an in-flight transcription can't
    /// be stopped mid-flight (SFSpeechRecognizer has no cancel-and-
    /// discard hook exposed through `SpeechTranscribing`) but marking
    /// the task cancelled means its eventual result is dropped instead
    /// of surfacing a notice or draft text nobody asked for anymore.
    public func handleViewDisappearing() {
        switch phase {
        case .recording:
            holdCancelled()
        case .transcribing:
            transcriptionTask?.cancel()
        case .idle:
            break
        }
    }

    /// Audio-session interruption arriving mid-take (phone call, Siri,
    /// another app). `began == true` discards the in-flight recording
    /// the same way a drag-away cancel would; `began == false` (the
    /// interruption ending) is deliberately a no-op — the hold gesture
    /// that started the take is long gone, so auto-resuming would
    /// record into a take nothing is driving anymore. Internal (not
    /// private) so tests can drive it without a real AVAudioSession
    /// notification.
    func handleAudioSessionInterruption(began: Bool) {
        guard began, phase == .recording, let recorder = activeRecorder else { return }
        activeRecorder = nil
        activeFileURL = nil
        recorder.cancel()
        phase = .idle
        showNotice(.interrupted)
    }

    // MARK: - Internals

    /// Races `transcriber.transcribe(fileAt:)` against `timeout`. The
    /// timeout side winning cancels the transcription child task — for
    /// `OnDeviceSpeechTranscriber` that resolves its own
    /// `withTaskCancellationHandler` and unblocks immediately instead
    /// of leaving the take (and `phase`) stuck forever — and this then
    /// throws, so `holdReleased()`'s existing generic `catch` surfaces
    /// `.transcriptionFailed` and phase still settles back to `.idle`.
    /// A mock whose `transcribe` doesn't itself react to cancellation
    /// (e.g. one that never returns at all) would still hang this race
    /// — the timeout only protects against a *cancellable* operation
    /// that's simply slow or stuck waiting on a callback, which is
    /// exactly `OnDeviceSpeechTranscriber`'s failure mode.
    private static func transcribe(
        with transcriber: any SpeechTranscribing,
        url: URL,
        timeout: Duration
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await transcriber.transcribe(fileAt: url)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DictationError(reason: .transcriptionTimedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw DictationError(reason: .transcriptionTimedOut)
            }
            return result
        }
    }

    private func startRecording() {
        // Privacy contract: never record audio this app can't transcribe
        // on-device. Checked fresh on every hold — on-device language
        // support can change (locale switch, model download/removal)
        // without an app update.
        guard dictationAvailability.isOnDeviceRecognitionAvailable() else {
            showNotice(.onDeviceUnavailable)
            return
        }
        do {
            let url = makeFileURL()
            let recorder = try recorderFactory.makeRecorder(fileURL: url)
            guard recorder.record() else {
                try? FileManager.default.removeItem(at: url)
                showNotice(.recorderFailed)
                return
            }
            activeFileURL = url
            activeRecorder = recorder
            phase = .recording
        } catch {
            Self.logFailure("recorder failed to start", detail: error.localizedDescription)
            showNotice(.recorderFailed)
        }
    }

    private func transcriptionFinished(text: String?, failureDetail: String?, onDeviceUnavailable: Bool) {
        phase = .idle
        if onDeviceUnavailable {
            showNotice(.onDeviceUnavailable)
            return
        }
        if let failureDetail {
            Self.logFailure("transcription failed", detail: failureDetail)
            showNotice(.transcriptionFailed)
            return
        }
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showNotice(.nothingHeard)
            return
        }
        transcript = TranscriptDelivery(id: nextTranscriptID, text: trimmed)
        nextTranscriptID += 1
    }

    /// Maps a permission state to its notice, or nil when there's
    /// nothing to complain about (granted / still undetermined).
    private static func denialNotice(for permission: PushToTalkPermission) -> PushToTalkNotice? {
        switch permission {
        case .granted, .undetermined:
            return nil
        case .microphoneDenied:
            return .microphonePermissionDenied
        case .speechDenied:
            return .speechPermissionDenied
        case .restricted:
            return .permissionsRestricted
        }
    }

    /// Show `value` and clear it after ``noticeLifetime``. The timer is
    /// keyed by GENERATION, not by the notice's value: deduping by value
    /// made two identical notices in a row share the first one's timer,
    /// so the second was cleared early (the same generation rule
    /// `VoiceLiveSessionModel.showComposerNotice` uses).
    private func showNotice(_ value: PushToTalkNotice) {
        notice = value
        noticeGeneration += 1
        let mine = noticeGeneration
        let lifetime = noticeLifetime
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: lifetime)
            guard let self, self.noticeGeneration == mine else { return }
            self.notice = nil
        }
    }

    #if canImport(os)
    private static func logFailure(_ what: String, detail: String) {
        logger.error("Dictation \(what, privacy: .public): \(detail, privacy: .public)")
    }
    #else
    private static func logFailure(_ what: String, detail: String) {}
    #endif
}
