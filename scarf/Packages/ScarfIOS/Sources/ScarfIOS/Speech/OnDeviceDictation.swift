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
/// the locale, or the recognizer is temporarily unavailable).
public struct DictationError: Error, Sendable {
    public let reason: Reason

    public enum Reason: Sendable {
        case recognizerUnavailable
    }

    public init(reason: Reason) {
        self.reason = reason
    }
}

/// SFSpeechRecognizer wrapper that transcribes a finished memo file,
/// preferring the on-device model whenever the locale supports it.
public struct OnDeviceSpeechTranscriber: SpeechTranscribing {
    public init() {}

    public func transcribe(fileAt url: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw DictationError(reason: .recognizerUnavailable)
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // On-device wherever the locale allows it; locales without an
        // on-device model fall back to Apple's server-assisted path
        // rather than failing the dictation outright.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

        return try await withCheckedThrowingContinuation { continuation in
            let gate = RecognitionContinuationGate(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    gate.resume(throwing: error)
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    gate.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}

/// Resumes a throwing continuation exactly once — the recognizer's
/// result handler can fire again after `isFinal`/error on some OS
/// versions, and a double resume traps.
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
