import Foundation
import AVFoundation
import os
import Observation
import ScarfCore

/// Per-message text-to-speech for assistant chat replies (issue #66).
///
/// Two playback engines, selected in Settings → Voice ("Playback
/// Engine", `scarf.speech.playbackEngine`):
///
///  - **system** (default) — `AVSpeechSynthesizer` with the macOS system
///    voice: no Hermes dependency, works offline, picks up the user's
///    Spoken Content voice selection automatically. This is the original
///    engine, unchanged.
///  - **hermes** — synthesis through the connected server's Hermes TTS
///    stack (`ScarfCore.HermesSpeechService`: the kokoro venv directly
///    for `tts.provider: kokoro`, `text_to_speech_tool` for the other
///    providers), with the fetched, magic-byte-verified WAV played
///    through `AVAudioEngine`. Kokoro cold start is seconds (torch
///    load), so `playingMessageId` flips on immediately — the stop
///    button works while synthesis is in flight — and `loadingMessageId`
///    exposes the synth-pending state for the bubble UI. Any synthesis
///    failure (transport, envelope, provider mismatch) falls back to the
///    system voice rather than going silent.
///
/// One service is shared across the app so starting a second message's
/// playback automatically interrupts the first. The per-message speaker
/// button reads `playingMessageId` to render play vs. stop state.
@MainActor
@Observable
final class MessageSpeechService: NSObject {
    /// COMPILED ONCE — this was rebuilt from its pattern on every spoken
    /// message. `NSRegularExpression` is thread-safe once constructed.
    /// Link syntax: `[text](url)` → `text`.
    private static let markdownLinkRegex = try? NSRegularExpression(
        pattern: #"\[([^\]]+)\]\([^)]+\)"#, options: []
    )

    static let shared = MessageSpeechService()

    /// UserDefaults key shared with the Settings → Voice picker.
    /// "system" (and any unset value) keeps the original behavior.
    static let engineKey = "scarf.speech.playbackEngine"

    /// The message id currently being spoken or synthesized, or `nil`
    /// when idle. Bubbles read this to flip their speaker icon to a
    /// stop glyph — including while Hermes synthesis is still loading.
    private(set) var playingMessageId: Int?

    /// The message id with Hermes synthesis in flight (loading state for
    /// the bubble UI; `nil` on the system engine, which starts speaking
    /// synchronously). Cleared when audio starts or playback is stopped.
    private(set) var loadingMessageId: Int?

    /// The server whose Hermes stack synthesizes (engine "hermes" only).
    /// Pushed by the per-window root as windows appear; multi-window
    /// setups resolve to the most recently appeared window — the last
    /// writer wins. `nil` synthesizes against the local install.
    var serverContext: ServerContext?

    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var synthesisTask: Task<Void, Never>?
    /// Temp WAV files backing the scheduled `AVAudioFile`s. The player
    /// node reads them during playback, so deletion waits for the
    /// completion callbacks.
    private var pendingTempFiles: [URL] = []
    private var pendingSegments = 0
    private var isStoppingPlayback = false
    private let logger = Logger(subsystem: "com.scarf", category: "MessageSpeech")

    private override init() {
        super.init()
        synthesizer.delegate = self
        audioEngine.attach(playerNode)
    }

    /// Currently selected playback engine, from the shared default.
    var engine: Engine {
        UserDefaults.standard.string(forKey: Self.engineKey).flatMap(Engine.init(rawValue:)) ?? .system
    }

    enum Engine: String {
        case system
        case hermes
    }

    /// Speak `content`. If a different message is currently playing,
    /// interrupt it. If the same message is currently playing or loading,
    /// this stops playback (toggle behavior).
    func toggle(messageId: Int, content: String) {
        if playingMessageId == messageId {
            stop()
            return
        }
        stop()
        let cleaned = Self.strippedForSpeech(content)
        guard !cleaned.isEmpty else { return }
        switch engine {
        case .system:
            speakWithSystemVoice(cleaned, messageId: messageId)
        case .hermes:
            speakWithHermes(cleaned, messageId: messageId)
        }
    }

    /// Stop any in-progress speech — synthesis, system voice, or WAV
    /// playback — and clear the observable state.
    func stop() {
        guard playingMessageId != nil || loadingMessageId != nil else { return }
        synthesisTask?.cancel()
        synthesisTask = nil
        loadingMessageId = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        stopWAVPlayback()
        playingMessageId = nil
    }

    private func speakWithSystemVoice(_ text: String, messageId: Int) {
        playingMessageId = messageId
        let utterance = AVSpeechUtterance(string: text)
        // AVSpeechUtterance honors the user's Spoken Content default
        // voice when `voice` is `nil`, which is the right behavior:
        // users who configured a specific macOS voice get it
        // automatically.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    // MARK: - Hermes engine

    private func speakWithHermes(_ text: String, messageId: Int) {
        // The id flips before synthesis starts: the stop control is live
        // during the (potentially seconds-long) kokoro cold start.
        playingMessageId = messageId
        loadingMessageId = messageId
        let context = serverContext ?? .local
        synthesisTask = Task { [weak self] in
            let service = HermesSpeechService(context: context)
            do {
                let audio = try await service.synthesize(text: text)
                guard let self, !Task.isCancelled else { return }
                try self.playWAVChunks(audio.chunks, messageId: messageId)
            } catch is CancellationError {
                // stop() already reset the observable state.
            } catch {
                guard let self else { return }
                self.logger.warning(
                    "Hermes TTS failed (\(String(describing: error), privacy: .public)) — falling back to system voice"
                )
                guard self.playingMessageId == messageId else { return }
                self.loadingMessageId = nil
                self.speakWithSystemVoice(text, messageId: messageId)
            }
        }
    }

    /// Write the fetched WAV chunks to temp files and schedule them
    /// back-to-back on the shared player node. The completion callback
    /// of the final segment clears `playingMessageId`; stop() flushes
    /// pending segments through the same callbacks with the stop flag
    /// set, so both endings converge on the same cleanup.
    private func playWAVChunks(_ chunks: [Data], messageId: Int) throws {
        guard !chunks.isEmpty else {
            playingMessageId = nil
            return
        }
        var files: [AVAudioFile] = []
        var tempURLs: [URL] = []
        for (index, chunk) in chunks.enumerated() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("scarf-tts-\(messageId)-\(index)-\(UUID().uuidString).wav")
            try chunk.write(to: url, options: .atomic)
            tempURLs.append(url)
            files.append(try AVAudioFile(forReading: url))
        }
        pendingTempFiles.append(contentsOf: tempURLs)
        pendingSegments = files.count
        isStoppingPlayback = false
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: files[0].processingFormat)
        for (file, url) in zip(files, tempURLs) {
            playerNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.segmentFinished(tempURL: url)
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
        playerNode.play()
    }

    /// Per-segment completion (any thread): delete the temp file, then
    /// hop to the main actor for the shared counter.
    nonisolated private func segmentFinished(tempURL: URL) {
        try? FileManager.default.removeItem(at: tempURL)
        Task { @MainActor [weak self] in
            guard let self, !self.isStoppingPlayback else { return }
            self.pendingTempFiles.removeAll { $0 == tempURL }
            self.pendingSegments -= 1
            if self.pendingSegments == 0 {
                self.finishWAVPlayback()
            }
        }
    }

    private func finishWAVPlayback() {
        playerNode.stop()
        audioEngine.stop()
        pendingTempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        pendingTempFiles = []
        if playingMessageId != nil {
            playingMessageId = nil
        }
    }

    private func stopWAVPlayback() {
        // Flushes every scheduled segment: their completion callbacks run
        // with the stop flag set and no-op past temp-file deletion.
        isStoppingPlayback = true
        playerNode.stop()
        audioEngine.stop()
        pendingTempFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        pendingTempFiles = []
        pendingSegments = 0
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
        Task { @MainActor in
            self.playingMessageId = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.playingMessageId = nil
        }
    }
}
