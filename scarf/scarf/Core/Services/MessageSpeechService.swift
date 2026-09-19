import Foundation
import AVFoundation
import os
import Observation
import ScarfCore

/// Per-message text-to-speech for assistant chat replies (issue #66).
///
/// Two playback engines, selected in Settings → Voice ("Playback
/// Engine", `HermesSpeechService.PlaybackEngine.defaultsKey`):
///
///  - **system** (default) — `AVSpeechSynthesizer` with the macOS system
///    voice: no Hermes dependency, works offline, picks up the user's
///    Spoken Content voice selection automatically. This is the original
///    engine, unchanged.
///  - **hermes** — synthesis through the Hermes TTS stack of the server
///    the MESSAGE came from (`ScarfCore.HermesSpeechService` →
///    `text_to_speech_tool`), with the fetched, magic-byte-verified audio
///    (WAV/MP3/FLAC/AIFF) played through `AVAudioEngine`. Only honoured
///    when that window's host has `hasHermesSpeechSynthesis`; otherwise
///    the system voice plays exactly as before. Synthesis can take
///    seconds, so the playback id flips on immediately — the stop button works while
///    synthesis is in flight (stop cancels the task, which terminates the
///    server round trip) — and `loading` exposes the synth-pending state.
///    Any synthesis failure (transport, envelope, path validation,
///    provider mismatch) falls back to the system voice rather than going
///    silent.
///
/// There is NO app-wide "current server": every `toggle` carries the
/// `ServerContext` of the window (or bot conversation) that rendered the
/// message, so one server's message text is never sent to another.
/// One service is shared across the app so starting a second message's
/// playback — in any window — interrupts the first. The per-message
/// speaker button asks `isPlaying(_:)` with its own `PlaybackID`.
@MainActor
@Observable
final class MessageSpeechService: NSObject {
    typealias PlaybackID = HermesSpeechService.PlaybackID
    typealias Engine = HermesSpeechService.PlaybackEngine

    /// COMPILED ONCE — this was rebuilt from its pattern on every spoken
    /// message. `NSRegularExpression` is thread-safe once constructed.
    /// Link syntax: `[text](url)` → `text`.
    private static let markdownLinkRegex = try? NSRegularExpression(
        pattern: #"\[([^\]]+)\]\([^)]+\)"#, options: []
    )

    static let shared = MessageSpeechService()

    /// UserDefaults key shared with the Settings → Voice picker.
    /// "system" (and any unset value) keeps the original behavior.
    static let engineKey = Engine.defaultsKey

    /// The message currently being spoken or synthesized, or `nil` when
    /// idle. Bubbles compare against their own `PlaybackID` to flip the
    /// speaker icon to a stop glyph — including while Hermes synthesis is
    /// still loading.
    private(set) var playing: PlaybackID?

    /// The message with Hermes synthesis in flight (loading state; `nil`
    /// on the system engine, which starts speaking synchronously).
    /// Cleared when audio starts or playback is stopped.
    private(set) var loading: PlaybackID?

    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance the synthesizer is speaking for `playing`. Delegate
    /// callbacks for any OTHER utterance (a stopped predecessor whose
    /// cancel arrives after the next message started) are ignored.
    private var currentUtterance: AVSpeechUtterance?
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var synthesisTask: Task<Void, Never>?
    /// Temp audio files backing the scheduled `AVAudioFile`s. The player
    /// node reads them during playback, so deletion waits for the
    /// completion callbacks (or stop).
    private var pendingTempFiles: [URL] = []
    private var pendingSegments = 0
    /// Bumped on every audio-file start and stop. Segment callbacks carry the
    /// generation they were scheduled under and no-op when it's stale, so
    /// a flushed segment from a stopped playback can never decrement the
    /// next playback's counter.
    private var playbackGeneration = 0
    private let logger = Logger(subsystem: "com.scarf", category: "MessageSpeech")

    private override init() {
        super.init()
        synthesizer.delegate = self
        audioEngine.attach(playerNode)
    }

    /// Whether `id` is playing or synthesizing.
    func isPlaying(_ id: PlaybackID) -> Bool { playing == id }

    /// Speak `content` from the message `id` identifies. If a different
    /// message is currently playing, interrupt it. If the same message is
    /// currently playing or loading, this stops playback (toggle).
    ///
    /// - Parameter capabilities: the capability snapshot of the window
    ///   that rendered the message — decides whether the "hermes"
    ///   preference is honoured for THIS server.
    func toggle(_ id: PlaybackID, content: String, capabilities: HermesCapabilities) {
        if playing == id {
            stop()
            return
        }
        stop()
        let cleaned = Self.strippedForSpeech(content)
        guard !cleaned.isEmpty else { return }
        let preference = UserDefaults.standard.string(forKey: Self.engineKey)
        switch Engine.resolve(preference: preference, capabilities: capabilities) {
        case .system:
            speakWithSystemVoice(cleaned, id: id)
        case .hermes:
            speakWithHermes(cleaned, id: id)
        }
    }

    /// Stop any in-progress speech — synthesis, system voice, or audio-file
    /// playback — and clear the observable state.
    func stop() {
        guard playing != nil || loading != nil else { return }
        synthesisTask?.cancel()
        synthesisTask = nil
        loading = nil
        currentUtterance = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        stopFilePlayback()
        playing = nil
    }

    private func speakWithSystemVoice(_ text: String, id: PlaybackID) {
        playing = id
        let utterance = AVSpeechUtterance(string: text)
        // AVSpeechUtterance honors the user's Spoken Content default
        // voice when `voice` is `nil`, which is the right behavior:
        // users who configured a specific macOS voice get it
        // automatically.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    // MARK: - Hermes engine

    private func speakWithHermes(_ text: String, id: PlaybackID) {
        // The id flips before synthesis starts: the stop control is live
        // during the (potentially seconds-long) synthesis.
        playing = id
        loading = id
        // The message's own server — never any other.
        let service = HermesSpeechService(context: id.server)
        synthesisTask = Task { [weak self] in
            do {
                // `HermesSpeechService` is an actor: config read, the
                // server round trip, and file I/O all run off the main
                // actor. Only the playback hand-off below comes back.
                let audio = try await service.synthesize(text: text)
                let files = try await Self.writeTempFiles(audio.chunks, format: audio.format, id: id)
                guard let self, !Task.isCancelled, self.playing == id else {
                    files.forEach { try? FileManager.default.removeItem(at: $0) }
                    return
                }
                try self.playAudioFiles(files)
            } catch is CancellationError {
                // stop() already reset the observable state.
            } catch {
                guard let self, !Task.isCancelled, self.playing == id else { return }
                let summary = Self.logSummary(for: error)
                self.logger.warning(
                    "Hermes TTS failed (\(summary.publicSummary, privacy: .public)): \(summary.privateDetail, privacy: .private) — falling back to system voice"
                )
                self.loading = nil
                self.speakWithSystemVoice(text, id: id)
            }
        }
    }

    /// Split a TTS failure into the half that may be logged publicly and
    /// the half that may not (charter C9).
    ///
    /// `SpeechError.synthesisFailed` carries a verbatim tail of the host's
    /// stdout/stderr, and a provider that echoes its key back in an error
    /// message puts that key in there — so only the CASE NAME is public and
    /// the payload goes out with `privacy: .private`, redacted in the
    /// device log unless someone is attached with a debugger.
    nonisolated static func logSummary(for error: Error) -> (publicSummary: String, privateDetail: String) {
        switch error {
        case let speech as HermesSpeechService.SpeechError:
            switch speech {
            case .synthesisFailed(let detail): return ("synthesisFailed", detail)
            case .providerMismatch(let format): return ("providerMismatch", format)
            case .emptyAudio: return ("emptyAudio", "")
            case .unexpectedOutputPath(let path): return ("unexpectedOutputPath", path)
            case .transportFailed(let detail): return ("transportFailed", detail)
            }
        default:
            // An error from somewhere else: its TYPE is safe to name, its
            // description is not (it may wrap a command line or a response
            // body).
            return (String(describing: type(of: error)), String(describing: error))
        }
    }

    #if DEBUG
    /// Test seams for the temp-file bookkeeping: the scheduling path and
    /// the files it still owns, so a test can prove that audio Core Audio
    /// refuses leaves nothing behind in $TMPDIR.
    func playAudioFilesForTesting(_ urls: [URL]) throws { try playAudioFiles(urls) }
    var pendingTempFileURLs: [URL] { pendingTempFiles }
    #endif

    /// Write verified audio chunks to local temp files, off the main actor.
    /// The extension matches the sniffed container so Core Audio decodes
    /// it with the right parser.
    /// Named `scarf-play-…`, apart from the synthesis script's own
    /// `scarf-tts-<uid>/` directory (which, for the local server, lives in
    /// this same `$TMPDIR` and is swept by the script).
    private nonisolated static func writeTempFiles(_ chunks: [Data], format: HermesSpeechService.AudioFormat, id: PlaybackID) async throws -> [URL] {
        try await Task.detached(priority: .userInitiated) {
            var urls: [URL] = []
            do {
                for (index, chunk) in chunks.enumerated() {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("scarf-play-\(id.messageId)-\(index)-\(UUID().uuidString).\(format.rawValue)")
                    try chunk.write(to: url, options: .atomic)
                    urls.append(url)
                }
            } catch {
                urls.forEach { try? FileManager.default.removeItem(at: $0) }
                throw error
            }
            return urls
        }.value
    }

    /// Schedule the temp audio files back-to-back on the shared player
    /// node. The completion callback of the final segment clears
    /// `playing`; stop() bumps the generation so flushed callbacks no-op.
    private func playAudioFiles(_ urls: [URL]) throws {
        loading = nil
        guard !urls.isEmpty else {
            playing = nil
            return
        }
        // Open every file BEFORE registering it: `AVAudioFile(forReading:)`
        // throws on audio Core Audio can't parse, and the caller's catch
        // falls back to the system voice without stopping playback — so
        // anything registered here would sit in `$TMPDIR` until some later
        // playback happened to flush the list.
        let files: [AVAudioFile]
        do {
            files = try urls.map { try AVAudioFile(forReading: $0) }
        } catch {
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        pendingTempFiles.append(contentsOf: urls)
        playbackGeneration += 1
        let generation = playbackGeneration
        pendingSegments = files.count
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: files[0].processingFormat)
        for (file, url) in zip(files, urls) {
            playerNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.segmentFinished(tempURL: url, generation: generation)
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        playerNode.play()
    }

    /// Per-segment completion (any thread): delete the temp file, then
    /// hop to the main actor for the shared counter.
    nonisolated private func segmentFinished(tempURL: URL, generation: Int) {
        try? FileManager.default.removeItem(at: tempURL)
        Task { @MainActor [weak self] in
            guard let self, generation == self.playbackGeneration else { return }
            self.pendingTempFiles.removeAll { $0 == tempURL }
            self.pendingSegments -= 1
            if self.pendingSegments == 0 {
                self.finishFilePlayback()
            }
        }
    }

    private func finishFilePlayback() {
        playerNode.stop()
        audioEngine.stop()
        pendingTempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        pendingTempFiles = []
        if playing != nil {
            playing = nil
        }
    }

    private func stopFilePlayback() {
        // Invalidate every scheduled segment's callback first, then flush.
        playbackGeneration += 1
        playerNode.stop()
        audioEngine.stop()
        pendingTempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        pendingTempFiles = []
        pendingSegments = 0
    }

    /// A system-voice utterance ended (finished or cancelled). Only the
    /// CURRENT utterance clears the playing state.
    private func utteranceEnded(_ utterance: ObjectIdentifier) {
        guard let current = currentUtterance, ObjectIdentifier(current) == utterance else { return }
        currentUtterance = nil
        playing = nil
    }

    // MARK: - Text cleanup

    /// Strip markdown control characters before speech so the user
    /// doesn't hear "asterisk asterisk bold". Code fences and inline
    /// code are spoken verbatim minus the backticks. Keeps URLs
    /// readable but drops square-bracket link wrappers.
    static func strippedForSpeech(_ raw: String) -> String {
        var out = raw
        // Fenced code blocks → keep contents
        out = out.replacingOccurrences(of: "```", with: "")
        // Inline code → drop backticks
        out = out.replacingOccurrences(of: "`", with: "")
        // Bold/italic markers
        out = out.replacingOccurrences(of: "**", with: "")
        out = out.replacingOccurrences(of: "__", with: "")
        // Link syntax: [text](url) → text
        if let regex = Self.markdownLinkRegex {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(
                in: out,
                options: [],
                range: range,
                withTemplate: "$1"
            )
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension MessageSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let token = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.utteranceEnded(token)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let token = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.utteranceEnded(token)
        }
    }
}
