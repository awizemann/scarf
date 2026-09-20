import AVFoundation
import Foundation
import os

// The speaking half of the chained voice path (P7a). Three conformers, which
// are exactly the two legs of design A/C in
// `documents/plans/2026-09-19-voice-p7-free-voice-path.md` plus the fallback
// that joins them:
//
// - ``SystemVoiceSpeaker``  — `AVSpeechSynthesizer`, zero host setup.
// - ``HermesVoiceSpeaker``  — the host's own `tts.*` provider through
//   ``HermesSpeechService`` (free on a keyless host: edge, piper, kittentts,
//   neutts), played back locally from the verified bytes it returns.
// - ``FallbackVoiceSpeaker`` — Hermes, dropping to the system voice for any
//   chunk the host could not synthesize, with a one-time notice.

/// Something that speaks one piece of text at a time.
///
/// ``speak(_:)`` returns when playback FINISHES or ``stop()`` cuts it short —
/// it never throws `CancellationError` for a stop, because a barge-in is a
/// normal outcome, not an error. It throws only when the text could not be
/// spoken at all, which is what ``FallbackVoiceSpeaker`` catches.
@MainActor
public protocol VoiceSpeaker: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String) async throws
    /// Stop now. Any in-flight ``speak(_:)`` returns promptly. Idempotent.
    func stop()
}

/// Playing already-fetched audio bytes, behind a seam so the engine and its
/// tests never need audio hardware.
@MainActor
public protocol AudioBytesPlaying: AnyObject {
    /// Play `chunks` back to back, in order. Returns when the last one ends
    /// or ``stop()`` is called.
    func play(_ chunks: [Data]) async throws
    func stop()
    var isPlaying: Bool { get }
}

// MARK: - System voice

/// `AVSpeechSynthesizer`. The always-available leg: no Hermes version floor,
/// no host packages, no network, and nothing leaves the device.
@MainActor
public final class SystemVoiceSpeaker: NSObject, VoiceSpeaker {

    public private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    /// The voice identifier to use, or `nil` for the system default.
    private let voiceIdentifier: String?
    private let rate: Float
    /// Resumed exactly once, by whichever of finish / cancel / stop wins.
    private var pending: CheckedContinuation<Void, Never>?

    public init(voiceIdentifier: String? = nil, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = rate
        if let voiceIdentifier { utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) }
        isSpeaking = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pending = continuation
            synthesizer.speak(utterance)
        }
        isSpeaking = false
    }

    public func stop() {
        guard isSpeaking || pending != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
        // `stopSpeaking` posts didCancel asynchronously and, for an utterance
        // that never started, may post nothing at all — resume here so a
        // barge-in can never leave the engine awaiting a callback.
        finishPending()
    }

    private func finishPending() {
        guard let continuation = pending else { return }
        pending = nil
        isSpeaking = false
        continuation.resume()
    }
}

extension SystemVoiceSpeaker: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishPending() }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishPending() }
    }
}

// MARK: - Hermes voice

/// The host's own TTS stack: ``HermesSpeechService`` synthesizes through
/// Hermes's `tts.*` provider and returns magic-byte-verified audio, which is
/// then played locally. The service already caches (``HermesTTSCache``), so a
/// repeated sentence costs no round trip.
///
/// Requires `HermesCapabilities.hasHermesSpeechSynthesis` (v0.20.1+) —
/// checked by ``VoiceLiveReadiness``, not here.
@MainActor
public final class HermesVoiceSpeaker: VoiceSpeaker {

    public private(set) var isSpeaking = false

    private let service: HermesSpeechService
    private let player: any AudioBytesPlaying
    private var synthesis: Task<HermesSpeechService.Audio, Error>?

    public init(service: HermesSpeechService, player: (any AudioBytesPlaying)? = nil) {
        self.service = service
        self.player = player ?? AVAudioBytesPlayer()
    }

    /// Convenience for the apps: one server's Hermes stack.
    public convenience init(context: ServerContext, player: (any AudioBytesPlaying)? = nil) {
        self.init(service: HermesSpeechService(context: context), player: player)
    }

    public func speak(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSpeaking = true
        defer { isSpeaking = false }
        let work = Task { try await service.synthesize(text: trimmed) }
        synthesis = work
        let audio: HermesSpeechService.Audio
        do {
            audio = try await work.value
        } catch is CancellationError {
            return          // a stop during synthesis is not a failure
        } catch {
            synthesis = nil
            throw error     // a real host failure: the fallback speaker catches it
        }
        synthesis = nil
        guard !Task.isCancelled else { return }
        try await player.play(audio.chunks)
    }

    public func stop() {
        // Cancelling the synthesis also terminates the in-flight host script
        // (`SSHScriptRunner`), so a barge-in does not leave a remote `hermes`
        // running for a sentence nobody will hear.
        synthesis?.cancel()
        synthesis = nil
        player.stop()
        isSpeaking = false
    }
}

/// `AVAudioPlayer` over in-memory bytes. `HermesSpeechService` has already
/// verified the container from its magic bytes, so the data is playable or
/// the service refused it.
@MainActor
public final class AVAudioBytesPlayer: NSObject, AudioBytesPlaying {

    public private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var pending: CheckedContinuation<Void, Never>?
    private var stopped = false

    public override init() { super.init() }

    public func play(_ chunks: [Data]) async throws {
        stopped = false
        isPlaying = true
        defer { isPlaying = false }
        for chunk in chunks {
            if stopped { return }
            let audioPlayer = try AVAudioPlayer(data: chunk)
            audioPlayer.delegate = self
            player = audioPlayer
            guard audioPlayer.play() else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pending = continuation
            }
            player = nil
            if stopped { return }
        }
    }

    public func stop() {
        stopped = true
        player?.stop()
        player = nil
        finishPending()
        isPlaying = false
    }

    private func finishPending() {
        guard let continuation = pending else { return }
        pending = nil
        continuation.resume()
    }
}

extension AVAudioBytesPlayer: AVAudioPlayerDelegate {
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finishPending() }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.finishPending() }
    }
}

// MARK: - Fallback

/// Try `primary`; if it throws for a chunk, speak that chunk with `fallback`
/// and tell the engine ONCE.
///
/// Per-chunk, not per-session: a host that fails one sentence (a provider
/// package missing, a dropped SSH connection) may well answer the next, and
/// the conversation must not go silent either way. The notice fires once so
/// the banner says "using the system voice" a single time instead of after
/// every sentence.
@MainActor
public final class FallbackVoiceSpeaker: VoiceSpeaker {

    public var isSpeaking: Bool { primary.isSpeaking || fallback.isSpeaking }
    /// True once any chunk has fallen back in this session.
    public private(set) var didFallBack = false

    private let primary: any VoiceSpeaker
    private let fallback: any VoiceSpeaker
    private let onFirstFallback: (@MainActor () -> Void)?
    /// Set by ``stop()``, cleared by the next ``speak(_:)``. A barge-in can
    /// race the primary speaker into reporting a plain (non-cancellation)
    /// error for the chunk it was told to abandon; without this flag the
    /// fallback would then speak that whole chunk over the silence the user
    /// just asked for.
    private var stopped = false
    private static let logger = Logger(subsystem: "com.scarf", category: "LiveVoice")

    /// - Parameter onFirstFallback: called on the main actor the first time a
    ///   chunk falls back, for a one-time notice.
    public init(
        primary: any VoiceSpeaker,
        fallback: any VoiceSpeaker,
        onFirstFallback: (@MainActor () -> Void)? = nil
    ) {
        self.primary = primary
        self.fallback = fallback
        self.onFirstFallback = onFirstFallback
    }

    public func speak(_ text: String) async throws {
        stopped = false
        do {
            try await primary.speak(text)
        } catch {
            // A stop while the primary was speaking: the chunk was abandoned
            // on purpose, so it must not come back out of the system voice.
            guard !stopped else { return }
            // The host's wording can echo config and paths: log it redacted,
            // never surface it (the apps show one localized sentence).
            Self.logger.notice("Chained TTS fell back to the system voice: \(VoiceLiveHostExchange.redact(error.localizedDescription), privacy: .public)")
            if !didFallBack {
                didFallBack = true
                onFirstFallback?()
            }
            try await fallback.speak(text)
        }
    }

    public func stop() {
        stopped = true
        primary.stop()
        fallback.stop()
    }
}
