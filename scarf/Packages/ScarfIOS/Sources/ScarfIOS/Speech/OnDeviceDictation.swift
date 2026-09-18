import AVFoundation
import Foundation
import Speech

/// Production permission client. Speech first (the prompt most likely
/// to surprise), then microphone — both prompts appear in one hold.
public struct PushToTalkPermissionClient: PushToTalkPermissionChecking {
    public init() {}

    public func authorizationStatus() -> PushToTalkPermission {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            return .undetermined
        case .denied:
            return .speechDenied
        case .restricted:
            return .restricted
        @unknown default:
            return .restricted
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .undetermined:
            return .undetermined
        case .denied:
            return .microphoneDenied
        @unknown default:
            return .restricted
        }
    }

    public func requestAuthorization() async -> PushToTalkPermission {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speech == .authorized else {
            switch speech {
            case .denied:
                return .speechDenied
            case .notDetermined:
                return .undetermined
            default:
                return .restricted
            }
        }
        let microphoneGranted = await AVAudioApplication.requestRecordPermission()
        return microphoneGranted ? .granted : .microphoneDenied
    }
}

/// AVAudioRecorder-backed memo factory. Emits 16 kHz / mono / 16-bit
/// linear PCM — the format the on-device recognizer handles best and
/// small enough (32 KB/s) that a long hold is still a small file.
@MainActor
public struct AVAudioMemoRecorderFactory: AudioMemoRecorderFactory {
    public init() {}

    /// A function (not a `static let`) — a `[String: Any]` constant
    /// isn't concurrency-safe under strict checking, and there's no
    /// reason to keep an instance around anyway.
    public static func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    public func makeRecorder(fileURL: URL) throws -> any AudioMemoRecording {
        Self.activateRecordingSession()
        let recorder = try AVAudioRecorder(url: fileURL, settings: Self.audioSettings())
        // Create the file + allocate the IO buffer now so the first
        // audio samples aren't clipped while setup runs.
        recorder.prepareToRecord()
        return AVAudioMemoRecorder(recorder: recorder)
    }

    /// Claim the shared audio session for recording. `AVAudioSession`
    /// doesn't exist on macOS (where this package's tests run), so the
    /// whole session dance is iOS-only.
    private static func activateRecordingSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker]
        )
        try? session.setActive(true)
        #endif
    }

    fileprivate static func deactivateRecordingSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }
}

/// Thin wrapper adding session teardown (and take deletion on cancel)
/// to the raw `AVAudioRecorder` lifecycle.
@MainActor
private final class AVAudioMemoRecorder: AudioMemoRecording {
    private let recorder: AVAudioRecorder

    init(recorder: AVAudioRecorder) {
        self.recorder = recorder
    }

    func record() -> Bool {
        recorder.record()
    }

    func stop() {
        recorder.stop()
        AVAudioMemoRecorderFactory.deactivateRecordingSession()
    }

    func cancel() {
        recorder.stop()
        _ = recorder.deleteRecording()
        AVAudioMemoRecorderFactory.deactivateRecordingSession()
    }
}

/// Error thrown when recognition can't run at all (no recognizer for
/// the locale, or the recognizer is temporarily unavailable), or when
/// it could only run by breaking the on-device privacy promise.
public struct DictationError: Error, Sendable, Equatable {
    public let reason: Reason

    public enum Reason: Sendable, Equatable {
        case recognizerUnavailable
        /// The recognizer exists but can't transcribe on-device for
        /// this locale/device. `NSSpeechRecognitionUsageDescription`
        /// promises on-device transcription, so this is a hard stop,
        /// never a silent fall back to Apple's servers.
        case onDeviceRecognitionUnsupported
        /// `PushToTalkController` gave up waiting — the recognizer's
        /// completion handler never fired within the bounded window.
        /// See `PushToTalkController.transcribe(with:url:timeout:)`.
        case transcriptionTimedOut
    }

    public init(reason: Reason) {
        self.reason = reason
    }
}

/// Whether on-device speech recognition can run right now, for the
/// user's current locale, on this device. Checked before every hold —
/// Apple ties on-device support to the installed language model, which
/// can change (locale switch, language pack download/removal) without
/// an app update, so this is never cached.
public protocol OnDeviceDictationAvailabilityChecking: Sendable {
    func isOnDeviceRecognitionAvailable() -> Bool
}

/// Production check backed by `SFSpeechRecognizer`.
public struct OnDeviceDictationAvailabilityClient: OnDeviceDictationAvailabilityChecking {
    public init() {}

    public func isOnDeviceRecognitionAvailable() -> Bool {
        guard let recognizer = SFSpeechRecognizer() else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }
}

/// SFSpeechRecognizer wrapper that transcribes a finished memo file.
/// Always requires on-device recognition — `PushToTalkController`
/// checks `OnDeviceDictationAvailabilityChecking` before it ever
/// starts recording, so reaching here with on-device support gone
/// (a race between the pre-flight check and this call, however
/// unlikely) throws rather than silently phoning home.
public struct OnDeviceSpeechTranscriber: SpeechTranscribing {
    public init() {}

    public func transcribe(fileAt url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw DictationError(reason: .recognizerUnavailable)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw DictationError(reason: .onDeviceRecognitionUnsupported)
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // Privacy contract: NSSpeechRecognitionUsageDescription promises
        // transcription "on this device". Never relax this — a locale
        // without on-device support is refused above, not silently
        // routed to Apple's servers.
        request.requiresOnDeviceRecognition = true

        // `recognizer` used to be a bare local and the
        // `SFSpeechRecognitionTask` `recognitionTask(with:)` returns
        // was dropped outright — nothing kept either alive once this
        // function suspended on the continuation below, and there was
        // no handle left to cancel a take whose completion handler
        // never fires. The holder retains both explicitly for the
        // call's duration and gives `withTaskCancellationHandler` a
        // live handle to actually stop the take when the surrounding
        // `Task` is cancelled (e.g. `PushToTalkController
        // .handleViewDisappearing()`, or the bounded-timeout race in
        // `PushToTalkController.transcribe`) — and, since
        // `SFSpeechRecognitionTask.cancel()` is not documented to
        // guarantee its completion handler still fires, `onCancel`
        // also force-resumes the continuation directly so a cancelled
        // take can never hang forever waiting on a callback that may
        // never arrive.
        let holder = RecognitionTaskHolder(recognizer: recognizer)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = RecognitionContinuationGate(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        gate.resume(throwing: error)
                        return
                    }
                    guard let result else { return }
                    if result.isFinal {
                        gate.resume(returning: result.bestTranscription.formattedString)
                    }
                }
                holder.attach(task: task, gate: gate)
            }
        } onCancel: {
            holder.cancelAndResume()
        }
    }
}

/// Retains the `SFSpeechRecognizer` and its in-flight
/// `SFSpeechRecognitionTask` for the duration of one
/// `transcribe(fileAt:)` call, and gives `withTaskCancellationHandler`'s
/// `onCancel` a way to both stop the task and force-resume the
/// continuation. `attach` and `cancelAndResume` can race (`onCancel`
/// can fire before `recognitionTask(with:)` even returns its handle) —
/// the lock plus the "already cancelled" check make either ordering
/// safe.
private final class RecognitionTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer
    private var task: SFSpeechRecognitionTask?
    private var gate: RecognitionContinuationGate?
    private var isCancelled = false

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    func attach(task: SFSpeechRecognitionTask, gate: RecognitionContinuationGate) {
        lock.lock()
        let alreadyCancelled = isCancelled
        if !alreadyCancelled {
            self.task = task
            self.gate = gate
        }
        lock.unlock()
        if alreadyCancelled {
            task.cancel()
            gate.resume(throwing: CancellationError())
        }
    }

    func cancelAndResume() {
        lock.lock()
        let task = self.task
        let gate = self.gate
        isCancelled = true
        lock.unlock()
        task?.cancel()
        gate?.resume(throwing: CancellationError())
    }
}

/// Resumes a throwing continuation exactly once — the recognizer's
/// result handler can fire again after `isFinal`/error on some OS
/// versions, cancellation can race a late result, and a double resume
/// traps.
private final class RecognitionContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: String) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
