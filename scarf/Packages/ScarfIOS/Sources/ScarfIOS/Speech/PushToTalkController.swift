import Foundation
import Observation
#if canImport(os)
import os
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
    case recorderFailed
    case transcriptionFailed
    case nothingHeard
    case cancelled
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
    private let makeFileURL: @Sendable () -> URL

    private var activeRecorder: (any AudioMemoRecording)?
    private var activeFileURL: URL?
    private var transcriptionTask: Task<Void, Never>?
    private var nextTranscriptID = 0

    /// Auto-clear window for `notice` — mirrors `RichChatViewModel`'s
    /// transient-hint lifetime so both strips behave the same.
    private static let noticeLifetimeNanoseconds: UInt64 = 4_000_000_000

    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf.ios", category: "PushToTalk")
    #endif

    /// Production wiring: real permission prompts, AVAudioRecorder
    /// memos into the app's tmp directory, on-device SFSpeechRecognizer.
    public init() {
        self.permissions = PushToTalkPermissionClient()
        self.recorderFactory = AVAudioMemoRecorderFactory()
        self.transcriber = OnDeviceSpeechTranscriber()
        self.makeFileURL = { Self.defaultMemoURL() }
    }

    /// Test seam — every collaborator injected.
    public init(
        permissions: any PushToTalkPermissionChecking,
        recorderFactory: any AudioMemoRecorderFactory,
        transcriber: any SpeechTranscribing,
        makeFileURL: @escaping @Sendable () -> URL
    ) {
        self.permissions = permissions
        self.recorderFactory = recorderFactory
        self.transcriber = transcriber
        self.makeFileURL = makeFileURL
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
        transcriptionTask = Task { [weak self, transcriber] in
            // `any Error` isn't Sendable under strict concurrency — carry
            // the detail back as a String instead (same pattern the iOS
            // attachment ingestion uses).
            var text: String?
            var failureDetail: String?
            do {
                text = try await transcriber.transcribe(fileAt: url)
            } catch {
                failureDetail = error.localizedDescription
            }
            // The memo is transient — drop it whether or not
            // recognition succeeded.
            try? FileManager.default.removeItem(at: url)
            self?.transcriptionFinished(text: text, failureDetail: failureDetail)
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

    // MARK: - Internals

    private func startRecording() {
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

    private func transcriptionFinished(text: String?, failureDetail: String?) {
        phase = .idle
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

    private func showNotice(_ value: PushToTalkNotice) {
        notice = value
        let snapshot = value
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.noticeLifetimeNanoseconds)
            if self?.notice == snapshot {
                self?.notice = nil
            }
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
