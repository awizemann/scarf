import AVFoundation
import Foundation
import Speech
import os

// The listening half of the chained voice path (P7a). Chained is a CLIENT
// loop — STT, a normal Hermes turn, then TTS — so Scarf owns the microphone
// itself instead of handing it to a vendor's full-duplex model. Design A of
// `documents/plans/2026-09-19-voice-p7-free-voice-path.md`: the transcript is
// produced ON THIS DEVICE, so audio never leaves it and no consent recipient
// is declared (``VoiceDataConsent``).

/// What a ``VoiceListener`` reports while it listens.
public enum VoiceListenerEvent: Sendable, Equatable {
    /// The recognizer's current, still-changing hypothesis for the utterance
    /// in progress. Captions only — never submitted.
    case partial(String)
    /// A finished utterance: the hypothesis stopped changing for the
    /// listener's silence window. This is what reaches Hermes.
    case utterance(String)
    /// Microphone input level, 0…1, for a level meter.
    case level(Double)
    /// Voice energy started after quiet. The engine uses it for barge-in
    /// (stop speaking) BEFORE the words are known, because waiting for a
    /// transcript would let the reply talk over the user for a second.
    case speechStarted
    /// Terminal: the listener stopped and will emit nothing more.
    case failed(VoiceListenerError)
}

/// Why listening could not start, or stopped.
///
/// Structured, not text: ScarfCore has no string catalog, so the apps
/// localize one sentence per case (``VoiceSessionFailure`` carries them into
/// the engine's terminal phase).
public enum VoiceListenerError: Error, Sendable, Equatable {
    /// No `SFSpeechRecognizer` for this locale, or it is not available now.
    case recognizerUnavailable
    /// The recognizer exists but cannot transcribe on-device for this
    /// locale/device. A HARD STOP: the chained path promises on-device
    /// transcription, so it never silently falls back to Apple's servers.
    case onDeviceRecognitionUnsupported
    /// Speech recognition was denied (or restricted) by the user or the OS.
    case speechRecognitionDenied
    /// The microphone was denied by the user or the OS.
    case microphoneDenied
    /// The audio engine or its input node could not start.
    case audioEngineFailed(detail: String)
    /// The recognition task itself reported an error mid-stream.
    case recognitionFailed(detail: String)

    /// English diagnostic token, never UI copy.
    public var englishDescription: String {
        switch self {
        case .recognizerUnavailable: return "Speech recognition is unavailable."
        case .onDeviceRecognitionUnsupported: return "On-device speech recognition is not supported for this language."
        case .speechRecognitionDenied: return "Scarf can't use speech recognition."
        case .microphoneDenied: return "Scarf can't use the microphone."
        case .audioEngineFailed(let detail): return "Couldn't start audio input: \(detail)"
        case .recognitionFailed(let detail): return "Speech recognition stopped: \(detail)"
        }
    }
}

/// A continuous listener that turns microphone audio into utterances.
///
/// One `start()` per session: the returned stream lives until ``stop()``, a
/// ``VoiceListenerEvent/failed(_:)`` event, or the listener is dropped.
/// Conformers keep listening across utterances (the engine needs the mic open
/// while the reply is spoken, for barge-in) — ``setPaused(_:)`` is the mute.
@MainActor
public protocol VoiceListener: AnyObject {
    /// Open the microphone and begin recognizing. Throws a
    /// ``VoiceListenerError`` when it cannot start at all; a failure that
    /// happens later arrives as ``VoiceListenerEvent/failed(_:)``.
    func start() throws -> AsyncStream<VoiceListenerEvent>
    /// Stop and release the microphone. Finishes the stream. Idempotent.
    func stop()
    /// Mute: keep the session and the audio graph, drop the audio.
    /// Paused listeners emit no partials, utterances or speech onsets, and
    /// report level 0.
    func setPaused(_ paused: Bool)
}

// MARK: - End-of-utterance

/// The pure end-of-utterance rule, split out so it is testable without a
/// microphone.
///
/// Apple's streaming recognizer does not tell us when the user stopped
/// talking — it keeps refining one hypothesis. The rule that works (and the
/// one Hermes's own clients use in spirit, via `voice.silence_duration`) is:
/// the hypothesis stopped CHANGING for ``silence`` seconds and is not empty.
/// Tracking text change rather than audio level means a long pause mid-
/// thought while the recognizer is still revising does not cut the user off.
public struct VoiceUtteranceDetector: Sendable, Equatable {
    /// 1.2 s of stillness. Long enough to survive a mid-sentence breath,
    /// short enough that the reply does not feel late.
    public static let defaultSilence: TimeInterval = 1.2

    /// Seconds of an unchanging hypothesis that end the utterance.
    public var silence: TimeInterval
    /// The hypothesis as last seen.
    public private(set) var text: String = ""
    /// When ``text`` last changed.
    public private(set) var lastChangeAt: Date?

    public init(silence: TimeInterval = defaultSilence) {
        self.silence = silence
    }

    /// Record a new hypothesis. Returns true when it actually changed.
    @discardableResult
    public mutating func note(partial: String, at now: Date) -> Bool {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != text else {
            if lastChangeAt == nil, !trimmed.isEmpty { lastChangeAt = now }
            return false
        }
        text = trimmed
        lastChangeAt = now
        return true
    }

    /// The finished utterance, if the hypothesis has been still long enough.
    /// Returns `nil` while the user is (probably) still talking, and RESETS
    /// once it returns text, so the next utterance starts clean.
    public mutating func settled(at now: Date) -> String? {
        guard !text.isEmpty, let lastChangeAt, now.timeIntervalSince(lastChangeAt) >= silence else { return nil }
        return take()
    }

    /// Force the utterance out (the recognizer declared the result final).
    public mutating func take() -> String? {
        guard !text.isEmpty else { return nil }
        let finished = text
        reset()
        return finished
    }

    public mutating func reset() {
        text = ""
        lastChangeAt = nil
    }
}

/// Input-level maths, split out so the meter is testable without hardware.
public enum VoiceAudioLevel {
    /// Everything at or below this many dBFS reads as silence.
    public static let floorDB: Double = -50

    /// Root-mean-square of one buffer of mono float samples, mapped to 0…1
    /// on a dB scale (a linear RMS meter spends almost its whole range on
    /// the top few dB and looks dead for normal speech).
    public static func level(ofSamples samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return level(ofRMS: (sum / Double(samples.count)).squareRoot())
    }

    /// The same mapping, from an already-computed RMS (0…1 linear).
    public static func level(ofRMS rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return min(1, (db - floorDB) / -floorDB)
    }

    /// Voice onset: a level above this counts as "someone started talking"
    /// for barge-in. Above room tone, below normal speech.
    public static let speechOnsetLevel: Double = 0.18
}

// MARK: - Audio session seam

/// The platform audio session, behind a seam the apps can override.
///
/// P7a deliberately keeps this minimal: iOS only, and the REAL session policy
/// (category, options, interruption and route-change handling, deactivating
/// so other apps resume) belongs to P7c, which owns it app-side. macOS has no
/// `AVAudioSession` at all, and the package's tests run there, so every call
/// here is a no-op off iOS.
@MainActor
public protocol VoiceAudioSessionControlling: AnyObject {
    /// Claim the session for simultaneous record + playback.
    func activateForVoiceConversation() throws
    /// Release it.
    func deactivate()
}

/// The default seam: `playAndRecord` on iOS, nothing anywhere else.
@MainActor
public final class DefaultVoiceAudioSession: VoiceAudioSessionControlling {
    public init() {}

    public func activateForVoiceConversation() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // `.voiceChat` asks for the system's echo cancellation, which is the
        // only defence the chained path has against the microphone hearing
        // its own TTS (there is no WebRTC AEC here).
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif
    }

    public func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

// MARK: - Apple on-device listener

/// Streaming on-device speech recognition: `SFSpeechRecognizer` +
/// `SFSpeechAudioBufferRecognitionRequest`, fed by an `AVAudioEngine` input
/// tap that also computes the level meter.
///
/// **Privacy contract.** `requiresOnDeviceRecognition` is always `true`, and
/// a recognizer whose `supportsOnDeviceRecognition` is `false` REFUSES to
/// start (``VoiceListenerError/onDeviceRecognitionUnsupported``). There is no
/// path here that sends audio to Apple's servers — that is the whole reason
/// the chained engine declares no ``VoiceDataRecipient``. The same rule is
/// already enforced for ScarfGo's push-to-talk dictation
/// (`ScarfIOS/Speech/OnDeviceDictation.swift`), which is file-based; this is
/// its streaming sibling.
///
/// **Why the request restarts.** An on-device
/// `SFSpeechAudioBufferRecognitionRequest` is not a forever stream: Apple
/// caps a single recognition at roughly a minute. Each finished utterance
/// therefore ends the current request and starts a fresh one while the audio
/// tap keeps running, so the microphone never closes between turns (which is
/// what makes barge-in possible).
@MainActor
public final class AppleOnDeviceVoiceListener: VoiceListener {

    public struct Configuration: Sendable {
        /// End-of-utterance silence.
        public var silence: TimeInterval = VoiceUtteranceDetector.defaultSilence
        /// How often the silence rule is evaluated and the level published.
        public var tickInterval: Duration = .milliseconds(100)
        /// The recognizer's locale. `nil` uses the user's current one.
        public var locale: Locale?
        public init() {}
    }

    private let configuration: Configuration
    private let session: any VoiceAudioSessionControlling
    private let clock: @MainActor () -> Date
    private static let logger = Logger(subsystem: "com.scarf", category: "LiveVoice")

    private var recognizer: SFSpeechRecognizer?
    /// The request the audio tap feeds. Held in a lock-guarded box because
    /// the tap runs on the audio thread while the main actor swaps it out
    /// between utterances.
    private let requestBox = VoiceRecognitionRequestBox()
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { requestBox.request }
        set { requestBox.request = newValue }
    }
    private var task: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<VoiceListenerEvent>.Continuation?
    private var tickTask: Task<Void, Never>?
    private var detector: VoiceUtteranceDetector
    private var paused = false
    private var running = false
    private var speaking = false
    private var lastLevel: Double = 0
    /// Written by the audio tap (off the main actor), drained by the tick.
    private let levelBox = VoiceInputLevelBox()

    public init(
        configuration: Configuration = Configuration(),
        audioSession: (any VoiceAudioSessionControlling)? = nil,
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.session = audioSession ?? DefaultVoiceAudioSession()
        self.clock = clock
        self.detector = VoiceUtteranceDetector(silence: configuration.silence)
    }

    // MARK: Authorization

    /// Speech-recognition authorization, requesting it when undetermined.
    /// `nil` means authorized. Microphone permission is checked separately
    /// (``microphoneAuthorization()``) because the two are different TCC
    /// entries and the apps want to explain each one.
    public static func speechAuthorization() async -> VoiceListenerError? {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        return status == .authorized ? nil : .speechRecognitionDenied
    }

    /// Microphone authorization, requesting it when undetermined. `nil` means
    /// authorized. `AVCaptureDevice` is used rather than `AVAudioApplication`
    /// because it exists on macOS too, and the chained engine runs on both.
    public static func microphoneAuthorization() async -> VoiceListenerError? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return nil
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio) ? nil : .microphoneDenied
        default: return .microphoneDenied
        }
    }

    /// Both prompts, speech first. `nil` means ready to listen.
    public static func authorize() async -> VoiceListenerError? {
        if let error = await speechAuthorization() { return error }
        return await microphoneAuthorization()
    }

    // MARK: VoiceListener

    public func start() throws -> AsyncStream<VoiceListenerEvent> {
        guard !running else { throw VoiceListenerError.audioEngineFailed(detail: "already listening") }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw VoiceListenerError.speechRecognitionDenied
        }
        let candidate = configuration.locale.map { SFSpeechRecognizer(locale: $0) } ?? SFSpeechRecognizer()
        guard let candidate, candidate.isAvailable else { throw VoiceListenerError.recognizerUnavailable }
        // Privacy contract — never relax this into a server fallback.
        guard candidate.supportsOnDeviceRecognition else { throw VoiceListenerError.onDeviceRecognitionUnsupported }
        recognizer = candidate

        try session.activateForVoiceConversation()
        let audioEngine = AVAudioEngine()
        engine = audioEngine
        running = true

        let (stream, streamContinuation) = AsyncStream<VoiceListenerEvent>.makeStream()
        continuation = streamContinuation

        do {
            try startAudio(audioEngine)
        } catch {
            running = false
            teardown()
            continuation = nil
            throw VoiceListenerError.audioEngineFailed(detail: error.localizedDescription)
        }
        startRecognition()
        startTickLoop()
        return stream
    }

    public func stop() {
        guard running else { return }
        running = false
        teardown()
        continuation?.finish()
        continuation = nil
    }

    public func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        // Drop whatever was half-heard: a muted stretch must not be stitched
        // onto the next utterance.
        detector.reset()
        if paused, lastLevel != 0 {
            lastLevel = 0
            continuation?.yield(.level(0))
        }
        speaking = false
    }

    // MARK: Audio

    private func startAudio(_ audioEngine: AVAudioEngine) throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceListenerError.audioEngineFailed(detail: "no input format")
        }
        let box = levelBox
        let sink = requestBox
        // The tap runs on a REALTIME AUDIO THREAD. It may only touch things
        // that are safe off the main actor: the lock-guarded level box and
        // the lock-guarded current request (`append` is documented as safe
        // from the audio thread). Nothing here may hop to, or assume, the
        // main actor — everything MainActor happens on the tick instead.
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            box.record(buffer: buffer)
            sink.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startRecognition() {
        guard running, let recognizer else { return }
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = true   // privacy contract
        request = newRequest
        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.handle(transcript: transcript, isFinal: isFinal, errorMessage: message)
            }
        }
    }

    private func handle(transcript: String?, isFinal: Bool, errorMessage: String?) {
        guard running else { return }
        if let errorMessage {
            // A request WE finished (an utterance, or a restart) reports an
            // error too; only report one that arrives while a request is live.
            guard request != nil else { return }
            Self.logger.notice("Chained listener recognition error: \(errorMessage, privacy: .public)")
            fail(.recognitionFailed(detail: errorMessage))
            return
        }
        guard let transcript, !paused else { return }
        if detector.note(partial: transcript, at: clock()), !transcript.isEmpty {
            continuation?.yield(.partial(transcript))
        }
        if isFinal, let utterance = detector.take() {
            emit(utterance: utterance)
        }
    }

    /// Finish the utterance, then restart the request: on-device recognition
    /// is capped at about a minute per request, so a session that reused one
    /// would go deaf mid-conversation.
    private func emit(utterance: String) {
        continuation?.yield(.utterance(utterance))
        speaking = false
        restartRecognition()
    }

    private func restartRecognition() {
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        detector.reset()
        startRecognition()
    }

    // MARK: Tick

    private func startTickLoop() {
        tickTask?.cancel()
        let interval = configuration.tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// One pass: publish the level, report a speech onset, and apply the
    /// silence rule. Internal so tests can drive it without a microphone.
    func tick() {
        guard running else { return }
        let level = paused ? 0 : levelBox.take()
        if abs(level - lastLevel) >= 0.02 || (level == 0) != (lastLevel == 0) {
            lastLevel = level
            continuation?.yield(.level(level))
        }
        guard !paused else { return }
        if !speaking, level >= VoiceAudioLevel.speechOnsetLevel {
            speaking = true
            continuation?.yield(.speechStarted)
        } else if speaking, level < VoiceAudioLevel.speechOnsetLevel / 2 {
            speaking = false
        }
        if let utterance = detector.settled(at: clock()) {
            emit(utterance: utterance)
        }
    }

    // MARK: Teardown

    private func fail(_ error: VoiceListenerError) {
        running = false
        teardown()
        continuation?.yield(.failed(error))
        continuation?.finish()
        continuation = nil
    }

    private func teardown() {
        tickTask?.cancel()
        tickTask = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        recognizer = nil
        detector.reset()
        paused = false
        speaking = false
        lastLevel = 0
        session.deactivate()
    }
}

/// The live recognition request, shared between the main actor (which
/// replaces it after every utterance) and the audio tap (which appends to it).
final class VoiceRecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { stored }?.append(buffer)
    }
}

/// The level the audio tap measured, handed across threads under a lock.
/// Peak-holding between ticks: a meter that sampled only the newest buffer
/// would miss the loudest 90 % of a 100 ms window.
final class VoiceInputLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Double = 0

    func record(buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum = 0.0
        for index in 0..<count {
            let sample = Double(channel[index])
            sum += sample * sample
        }
        record(rms: (sum / Double(count)).squareRoot())
    }

    func record(rms: Double) {
        let level = VoiceAudioLevel.level(ofRMS: rms)
        lock.withLock { peak = max(peak, level) }
    }

    /// The peak since the last call, and reset.
    func take() -> Double {
        lock.withLock {
            let value = peak
            peak = 0
            return value
        }
    }
}
