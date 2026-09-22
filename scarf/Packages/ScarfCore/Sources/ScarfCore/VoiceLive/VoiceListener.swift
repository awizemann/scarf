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
    /// Tell the listener the assistant's reply is playing out loud.
    ///
    /// THE LISTENER OWNS THE BARGE-IN GRACE AND THE ECHO RULES; the engine
    /// only says when playback starts and stops. While playback is active the
    /// listener raises its onset trigger, ignores onsets for a short grace,
    /// and refuses to emit any hypothesis that began during playback (that
    /// text is the reply bleeding back through the microphone, not the user).
    func setPlaybackActive(_ active: Bool)
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

    /// Below this level the microphone counts as quiet for end-of-utterance.
    /// 0.2 on the 0…1 meter is about -40 dBFS. Measured 2026-09-22 with the
    /// voice-processing input chain on (its gain control lifts a silent room
    /// to 0.10-0.13, and the cancelled residue of the reply sits at
    /// 0.06-0.16): both read as quiet here, while speech reads 0.45 and up.
    public static let defaultSilenceLevel: Double = 0.2

    /// Seconds of an unchanging hypothesis that end the utterance.
    public var silence: TimeInterval
    /// The level at or above which the microphone is NOT quiet.
    public var silenceLevel: Double
    /// The hypothesis as last seen.
    public private(set) var text: String = ""
    /// When ``text`` last changed.
    public private(set) var lastChangeAt: Date?
    /// When the microphone was last at or above ``silenceLevel``. `nil` means
    /// no level has been reported at all (the pure-text callers, and the
    /// tests that drive only hypotheses), which leaves the audio gate open.
    public private(set) var lastLoudAt: Date?

    public init(silence: TimeInterval = defaultSilence, silenceLevel: Double = defaultSilenceLevel) {
        self.silence = silence
        self.silenceLevel = silenceLevel
    }

    /// Record the current microphone level. The end-of-utterance rule needs
    /// it because text stillness alone cuts a thinking pause off: the
    /// recognizer stops revising while the user is still making sound.
    public mutating func note(level: Double, at now: Date) {
        if level >= silenceLevel { lastLoudAt = now }
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
        guard !text.isEmpty, let lastChangeAt else { return nil }
        let still = now.timeIntervalSince(lastChangeAt)
        guard still >= silence else { return nil }
        // …and the microphone has actually been quiet for the same window.
        // The audio gate can only DELAY the utterance, never hold it forever:
        // a room whose noise floor sits above `silenceLevel` (a fan, a busy
        // café) would otherwise make the session deaf. Past `maxAudioHold`
        // of stillness the text rule alone decides.
        if let lastLoudAt, now.timeIntervalSince(lastLoudAt) < silence, still < maxAudioHold { return nil }
        return take()
    }

    /// The longest the audio gate may hold a still hypothesis: twice the
    /// silence window, so end-of-utterance is never later than 2.4 s.
    public var maxAudioHold: TimeInterval { silence * 2 }

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
        lastLoudAt = nil
    }
}

/// The pure barge-in rule, split out for the same reason: testable without a
/// microphone.
///
/// A SINGLE loud tick is not speech. A door, a keyboard, or one syllable of
/// the app's own reply leaking back through the speaker all produce one tick
/// over the trigger, and the old single-tick rule cut every reply off about a
/// second in. Real speech holds the meter up: requiring the level to sit at
/// or above the trigger for ``requiredTicks`` CONSECUTIVE ticks (3 × 100 ms =
/// 300 ms, the same window the Hermes desktop's `voice-barge-in.ts` uses)
/// keeps transients out while still reacting within a third of a second.
public struct VoiceSpeechOnsetDetector: Sendable, Equatable {
    /// 300 ms at the listener's 100 ms tick.
    public static let defaultRequiredTicks = 3

    /// Consecutive ticks at or above the trigger that confirm an onset.
    public var requiredTicks: Int
    /// How many consecutive ticks have been at or above the trigger.
    public private(set) var run = 0
    /// Whether an onset is currently held (it is released by quiet).
    public private(set) var isSpeaking = false

    public init(requiredTicks: Int = defaultRequiredTicks) {
        self.requiredTicks = requiredTicks
    }

    /// Record one tick's level. Returns `true` on the single tick where the
    /// onset is confirmed, and never again until the level drops back to
    /// quiet — the caller uses that edge to fire `.speechStarted`.
    @discardableResult
    public mutating func note(level: Double, trigger: Double) -> Bool {
        guard level >= trigger else {
            run = 0
            // Release on clear quiet, not on the first dip: a syllable gap
            // inside one sentence must not re-arm the onset.
            if isSpeaking, level < trigger / 2 { isSpeaking = false }
            return false
        }
        run += 1
        guard !isSpeaking, run >= requiredTicks else { return false }
        isSpeaking = true
        return true
    }

    public mutating func reset() {
        run = 0
        isSpeaking = false
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

    /// Voice onset: a level at or above this, held for
    /// ``VoiceSpeechOnsetDetector/requiredTicks``, counts as "someone started
    /// talking". 0.25 is about -37.5 dBFS: above the voice-processing chain's
    /// resting floor (0.10-0.13 measured), well below speech (0.45 and up).
    public static let speechOnsetLevel: Double = 0.25

    /// The same rule WHILE THE ASSISTANT IS SPEAKING. Even with voice
    /// processing on, the cancelled reply leaves a residue at the microphone
    /// (0.06-0.16 measured, one 0.36 transient at onset that the grace
    /// covers) — so a barge-in has to clear a higher bar, sustained. 0.35 is
    /// about -32.5 dBFS: above the residue, still comfortably under someone
    /// talking to their laptop (0.45 and up).
    public static let bargeInOnsetLevel: Double = 0.35

    /// How long after playback starts onsets are ignored entirely. The
    /// speaker's first syllable arrives before the echo canceller has
    /// converged, so the first half second is never a barge-in. This is the
    /// ONE grace in the system: the engine does not keep a second one.
    public static let bargeInGrace: TimeInterval = 0.5
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

// MARK: - Recognition seam

/// One streaming recognition request: what the audio tap feeds and the
/// listener ends. A seam, so the listener's decisions can be driven in a test
/// without the Speech framework (and without a microphone).
protocol VoiceRecognitionRequesting: AnyObject {
    var shouldReportPartialResults: Bool { get set }
    var requiresOnDeviceRecognition: Bool { get set }
    /// Safe from the realtime audio thread.
    func appendAudio(_ buffer: AVAudioPCMBuffer)
    func finishAudio()
}

extension SFSpeechAudioBufferRecognitionRequest: VoiceRecognitionRequesting {
    func appendAudio(_ buffer: AVAudioPCMBuffer) { append(buffer) }
    func finishAudio() { endAudio() }
}

/// A recognition task in flight.
protocol VoiceRecognitionTasking: AnyObject {
    func cancelRecognition()
}

extension SFSpeechRecognitionTask: VoiceRecognitionTasking {
    func cancelRecognition() { cancel() }
}

/// What one recognition callback carries, flattened so no Speech type has to
/// cross the seam (or a concurrency boundary).
struct VoiceRecognitionEvent: Sendable, Equatable {
    var transcript: String?
    var isFinal: Bool = false
    var errorMessage: String?
}

/// The recognizer itself, behind a seam.
@MainActor
protocol VoiceRecognizing: AnyObject {
    var isRecognizerAvailable: Bool { get }
    var supportsOnDeviceRecognition: Bool { get }
    func makeRequest() -> any VoiceRecognitionRequesting
    /// Start recognizing `request`. The handler may be called from any thread.
    func startTask(
        with request: any VoiceRecognitionRequesting,
        handler: @escaping @Sendable (VoiceRecognitionEvent) -> Void
    ) -> (any VoiceRecognitionTasking)?
}

/// The production recognizer: `SFSpeechRecognizer`.
@MainActor
final class SpeechFrameworkRecognizer: VoiceRecognizing {
    private let recognizer: SFSpeechRecognizer

    init(_ recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }

    var isRecognizerAvailable: Bool { recognizer.isAvailable }
    var supportsOnDeviceRecognition: Bool { recognizer.supportsOnDeviceRecognition }

    func makeRequest() -> any VoiceRecognitionRequesting {
        SFSpeechAudioBufferRecognitionRequest()
    }

    func startTask(
        with request: any VoiceRecognitionRequesting,
        handler: @escaping @Sendable (VoiceRecognitionEvent) -> Void
    ) -> (any VoiceRecognitionTasking)? {
        guard let request = request as? SFSpeechAudioBufferRecognitionRequest else { return nil }
        return recognizer.recognitionTask(with: request) { result, error in
            handler(VoiceRecognitionEvent(
                transcript: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal ?? false,
                errorMessage: error?.localizedDescription))
        }
    }
}

/// The microphone tap, behind a seam for the same reason.
@MainActor
protocol VoiceAudioTapping: AnyObject {
    /// Begin tapping. `onBuffer` is called on a REALTIME AUDIO THREAD.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// The production tap: `AVAudioEngine`'s input node.
@MainActor
final class AVAudioEngineTap: VoiceAudioTapping {
    private var engine: AVAudioEngine?
    private static let logger = Logger(subsystem: "com.scarf", category: "LiveVoice")

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        // The OS's voice-processing input chain: echo cancellation against
        // everything the Mac is playing (measured 2026-09-22 with `say`
        // through the built-in speaker: the reply at the mic drops from
        // 0.45-0.61 on the meter, indistinguishable from a person, to
        // 0.06-0.16). Without it no threshold can tell the reply from the
        // user and the conversation feeds on itself. Two side effects are
        // handled below: the input format becomes MULTI-CHANNEL (10 on Apple
        // silicon; channel 0 is the processed voice), and by default the OS
        // ducks other audio -- which here would duck the reply itself.
        do {
            try input.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, iOS 17.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        } catch {
            // Not fatal: an unprocessed tap still transcribes, and the
            // listener's raised playback trigger is the second line of defence.
            Self.logger.notice("Voice processing unavailable on the input node: \(error.localizedDescription, privacy: .public)")
        }
        // Read AFTER enabling voice processing: it changes the format.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceListenerError.audioEngineFailed(detail: "no input format")
        }
        // The tap runs on a REALTIME AUDIO THREAD. It may only touch things
        // that are safe off the main actor: the lock-guarded level box and
        // the lock-guarded current request (`append` is documented as safe
        // from the audio thread). Nothing here may hop to, or assume, the
        // main actor -- everything MainActor happens on the tick instead.
        if format.channelCount == 1 {
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in onBuffer(buffer) }
        } else {
            // The speech request does not transcribe a multi-channel buffer
            // (it silently produces nothing), so channel 0 is copied into a
            // mono buffer of the same sample rate. One memcpy per 1,024
            // frames -- cheap enough for the realtime thread.
            guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false) else {
                throw VoiceListenerError.audioEngineFailed(detail: "no mono format")
            }
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                guard let monoBuffer = Self.channelZero(of: buffer, as: mono) else { return }
                onBuffer(monoBuffer)
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        engine = audioEngine
    }

    /// Channel 0 of `buffer` as a fresh mono buffer in `mono`. Realtime-safe
    /// apart from the allocation, which the tap accepts (the buffer size is
    /// small and the alternative -- a shared scratch buffer -- races the
    /// recognizer, which keeps the buffer it was handed).
    nonisolated static func channelZero(of buffer: AVAudioPCMBuffer, as mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0, let source = buffer.floatChannelData?[0],
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames),
              let target = out.floatChannelData?[0] else { return nil }
        target.update(from: source, count: Int(frames))
        out.frameLength = frames
        return out
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
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
/// path here that sends audio to Apple's servers -- that is the whole reason
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
///
/// **Generations.** Every request carries a monotonic generation, captured by
/// the callback that belongs to it. A request we finished ourselves reports
/// its cancellation asynchronously, after a fresh request is already
/// installed, so a callback is trusted only while its generation is the
/// current one -- otherwise a routine restart looks like a mid-stream failure
/// and kills the session after nearly every utterance.
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
    private let makeRecognizer: @MainActor (Locale?) -> (any VoiceRecognizing)?
    private let makeAudioTap: @MainActor () -> any VoiceAudioTapping
    private let isSpeechAuthorized: @MainActor () -> Bool
    private static let logger = Logger(subsystem: "com.scarf", category: "LiveVoice")

    private var recognizer: (any VoiceRecognizing)?
    /// The request the audio tap feeds. Held in a lock-guarded box because
    /// the tap runs on the audio thread while the main actor swaps it out
    /// between utterances -- and because the box, not the tap, is where mute
    /// is enforced.
    private let requestBox = VoiceRecognitionRequestBox()
    private var request: (any VoiceRecognitionRequesting)? {
        get { requestBox.request }
        set { requestBox.request = newValue }
    }
    /// Monotonic, bumped by every ``startRecognition()``. A callback whose
    /// generation is stale is ignored entirely.
    private(set) var requestGeneration = 0
    private var task: (any VoiceRecognitionTasking)?
    private var audioTap: (any VoiceAudioTapping)?
    private var continuation: AsyncStream<VoiceListenerEvent>.Continuation?
    private var tickTask: Task<Void, Never>?
    private var detector: VoiceUtteranceDetector
    private var paused = false
    private var running = false
    private var onset = VoiceSpeechOnsetDetector()
    /// Whether the assistant's reply is playing right now, and since when.
    private var playbackActive = false
    private var playbackStartedAt: Date?
    /// Set once a sustained onset was confirmed DURING playback: from there
    /// on the user really is talking over the reply, so what the recognizer
    /// hears is theirs and is kept.
    private var confirmedBargeIn = false
    /// Set when the recognizer produced text during playback that was NOT
    /// preceded by a confirmed onset — the reply bleeding into the
    /// microphone. It is never emitted. Diagnostic only: the request is
    /// restarted at the end of every un-barged playback regardless.
    private var sawPlaybackBleed = false
    private var lastLevel: Double = 0

    /// The reply is playing (or has stopped). See ``VoiceListener/setPlaybackActive(_:)``.
    private var isBleeding: Bool { playbackActive && !confirmedBargeIn }
    /// Written by the audio tap (off the main actor), drained by the tick.
    private let levelBox = VoiceInputLevelBox()

    public convenience init(
        configuration: Configuration = Configuration(),
        audioSession: (any VoiceAudioSessionControlling)? = nil,
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.init(
            configuration: configuration,
            audioSession: audioSession,
            clock: clock,
            makeRecognizer: { locale in
                let speech = locale.map { SFSpeechRecognizer(locale: $0) } ?? SFSpeechRecognizer()
                return speech.map(SpeechFrameworkRecognizer.init)
            },
            makeAudioTap: { AVAudioEngineTap() },
            isSpeechAuthorized: { SFSpeechRecognizer.authorizationStatus() == .authorized })
    }

    /// The seamed initializer: the tests drive the recognizer and the tap.
    init(
        configuration: Configuration = Configuration(),
        audioSession: (any VoiceAudioSessionControlling)? = nil,
        clock: @escaping @MainActor () -> Date = { Date() },
        makeRecognizer: @escaping @MainActor (Locale?) -> (any VoiceRecognizing)?,
        makeAudioTap: @escaping @MainActor () -> any VoiceAudioTapping,
        isSpeechAuthorized: @escaping @MainActor () -> Bool
    ) {
        self.configuration = configuration
        self.session = audioSession ?? DefaultVoiceAudioSession()
        self.clock = clock
        self.makeRecognizer = makeRecognizer
        self.makeAudioTap = makeAudioTap
        self.isSpeechAuthorized = isSpeechAuthorized
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

    /// Open the microphone and begin recognizing.
    ///
    /// **Callers must run ``authorize()`` first** (both apps do). `start()`
    /// only CHECKS the decision already made -- it throws
    /// ``VoiceListenerError/speechRecognitionDenied`` when speech recognition
    /// is not authorized yet and never prompts, because a TCC prompt inside a
    /// synchronous start would block opening the audio graph.
    public func start() throws -> AsyncStream<VoiceListenerEvent> {
        guard !running else { throw VoiceListenerError.audioEngineFailed(detail: "already listening") }
        guard isSpeechAuthorized() else { throw VoiceListenerError.speechRecognitionDenied }
        let candidate = makeRecognizer(configuration.locale)
        guard let candidate, candidate.isRecognizerAvailable else { throw VoiceListenerError.recognizerUnavailable }
        // Privacy contract -- never relax this into a server fallback.
        guard candidate.supportsOnDeviceRecognition else { throw VoiceListenerError.onDeviceRecognitionUnsupported }
        recognizer = candidate

        try session.activateForVoiceConversation()
        let tap = makeAudioTap()
        audioTap = tap
        running = true

        let (stream, streamContinuation) = AsyncStream<VoiceListenerEvent>.makeStream()
        continuation = streamContinuation

        do {
            let levels = levelBox
            let sink = requestBox
            try tap.start { buffer in
                levels.record(buffer: buffer)
                sink.append(buffer)
            }
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
        // Mute is a real mute: the box drops the tap's buffers while paused,
        // so no hypothesis accumulates behind the mute waiting to be
        // submitted to Hermes the moment the user unmutes.
        requestBox.isPaused = paused
        // Drop whatever was half-heard: a muted stretch must not be stitched
        // onto the next utterance.
        detector.reset()
        if paused {
            if lastLevel != 0 {
                lastLevel = 0
                continuation?.yield(.level(0))
            }
        } else {
            // The recognizer kept its own partial hypothesis across the mute;
            // a fresh request (and generation) is the only way to clear it.
            restartRecognition()
        }
        onset.reset()
        sawPlaybackBleed = false
        confirmedBargeIn = false
    }

    public func setPlaybackActive(_ active: Bool) {
        guard running, playbackActive != active else { return }
        playbackActive = active
        onset.reset()
        if active {
            playbackStartedAt = clock()
            confirmedBargeIn = false
            sawPlaybackBleed = false
        } else {
            playbackStartedAt = nil
            // Whatever the recognizer heard of the reply itself must not be
            // stitched onto the user's next sentence. The restart is
            // unconditional (not only when bleed TEXT was seen): recognition
            // lags the audio by a few hundred milliseconds, so the reply's
            // last word can arrive as a transcript AFTER playback ends, on a
            // request that would otherwise still be trusted. A confirmed
            // barge-in is the one exception -- that request holds the user's
            // own words.
            if !confirmedBargeIn { restartRecognition() }
            sawPlaybackBleed = false
            confirmedBargeIn = false
        }
    }

    // MARK: Recognition

    private func startRecognition() {
        guard running, let recognizer else { return }
        requestGeneration += 1
        let generation = requestGeneration
        let newRequest = recognizer.makeRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = true   // privacy contract
        request = newRequest
        task = recognizer.startTask(with: newRequest) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event, generation: generation)
            }
        }
    }

    /// Route one recognition callback. Internal so tests can drive it.
    func handle(_ event: VoiceRecognitionEvent, generation: Int) {
        // A callback from a request we already replaced is not news: its
        // cancellation error is our own doing, and its last result belongs to
        // an utterance that has already been emitted.
        guard running, generation == requestGeneration else { return }
        if let errorMessage = event.errorMessage {
            guard request != nil else { return }
            Self.logger.notice("Chained listener recognition error: \(errorMessage, privacy: .public)")
            fail(.recognitionFailed(detail: errorMessage))
            return
        }
        guard let transcript = event.transcript, !paused else { return }
        // Text heard while the reply plays, with no confirmed barge-in behind
        // it, is the reply itself. Do not caption it, do not let it reach the
        // detector, and remember to clear the recognizer when playback ends.
        if isBleeding {
            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sawPlaybackBleed = true }
            return
        }
        if detector.note(partial: transcript, at: clock()), !transcript.isEmpty {
            continuation?.yield(.partial(transcript))
        }
        if event.isFinal, let utterance = detector.take() {
            emit(utterance: utterance)
        }
    }

    /// Finish the utterance, then restart the request: on-device recognition
    /// is capped at about a minute per request, so a session that reused one
    /// would go deaf mid-conversation.
    private func emit(utterance: String) {
        continuation?.yield(.utterance(utterance))
        onset.reset()
        restartRecognition()
    }

    private func restartRecognition() {
        request?.finishAudio()
        request = nil
        task?.cancelRecognition()
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
        let now = clock()
        // One trigger while idle, a higher one while the reply plays, and no
        // onset at all inside the grace right after playback starts.
        let trigger = playbackActive ? VoiceAudioLevel.bargeInOnsetLevel : VoiceAudioLevel.speechOnsetLevel
        let inGrace = playbackActive
            && (playbackStartedAt.map { now.timeIntervalSince($0) < VoiceAudioLevel.bargeInGrace } ?? false)
        if inGrace {
            onset.reset()
        } else if onset.note(level: level, trigger: trigger) {
            if playbackActive {
                // A real barge-in. Restart recognition first: the request has
                // been swallowing the reply's own words, and none of them may
                // end up prefixed onto what the user is about to say.
                confirmedBargeIn = true
                sawPlaybackBleed = false
                restartRecognition()
            }
            continuation?.yield(.speechStarted)
        }
        detector.note(level: level, at: now)
        if let utterance = detector.settled(at: now) {
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
        request?.finishAudio()
        request = nil
        requestBox.isPaused = false
        task?.cancelRecognition()
        task = nil
        audioTap?.stop()
        audioTap = nil
        recognizer = nil
        detector.reset()
        paused = false
        onset.reset()
        playbackActive = false
        playbackStartedAt = nil
        confirmedBargeIn = false
        sawPlaybackBleed = false
        lastLevel = 0
        session.deactivate()
    }
}

/// The live recognition request, shared between the main actor (which
/// replaces it after every utterance) and the audio tap (which appends to it).
/// The mute lives here too: a paused box drops the tap's buffers on the floor,
/// so muted audio never reaches the recognizer at all.
final class VoiceRecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any VoiceRecognitionRequesting)?
    private var paused = false

    var request: (any VoiceRecognitionRequesting)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var isPaused: Bool {
        get { lock.withLock { paused } }
        set { lock.withLock { paused = newValue } }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { paused ? nil : stored }?.appendAudio(buffer)
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
