import Foundation
import AVFoundation
import os
import Observation

/// Per-message text-to-speech for assistant chat replies (issue #66).
/// Uses `AVSpeechSynthesizer` with the system voice — no Hermes
/// dependency, works offline, picks up the user's macOS Spoken Content
/// voice selection automatically.
///
/// One synthesizer is shared across the app so starting a second
/// message's playback automatically interrupts the first. The
/// per-message speaker button reads `playingMessageId` to render
/// play vs. stop state.
///
/// The full Hermes-provider TTS pipeline (Edge / ElevenLabs / OpenAI
/// / NeuTTS / Piper from Settings → Voice) is deferred to a follow-up
/// — wiring per-provider audio fetching, caching, and interruption
/// is a much bigger surface than what's needed to give users a
/// listen-while-doing-other-work affordance today.
@MainActor
@Observable
final class MessageSpeechService: NSObject {
    static let shared = MessageSpeechService()

    /// The message id currently being spoken, or `nil` when idle.
    /// Bubbles read this to flip their speaker icon to a stop glyph.
    private(set) var playingMessageId: Int?

    private let synthesizer = AVSpeechSynthesizer()
    private let logger = Logger(subsystem: "com.scarf", category: "MessageSpeech")

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Speak `content`. If a different message is currently playing,
    /// interrupt it. If the same message is currently playing, this
    /// stops playback (toggle behavior).
    func toggle(messageId: Int, content: String) {
        if playingMessageId == messageId {
            stop()
            return
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let cleaned = Self.strippedForSpeech(content)
        guard !cleaned.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: cleaned)
        // AVSpeechUtterance honors the user's Spoken Content default
        // voice when `voice` is `nil`, which is the right behavior:
        // users who configured a specific macOS voice get it
        // automatically.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        playingMessageId = messageId
        synthesizer.speak(utterance)
    }

    /// Stop any in-progress speech and clear `playingMessageId`.
    func stop() {
        guard playingMessageId != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
        playingMessageId = nil
    }

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
        if let regex = try? NSRegularExpression(
            pattern: #"\[([^\]]+)\]\([^)]+\)"#,
            options: []
        ) {
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
