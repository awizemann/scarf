import Foundation

/// Hermes's per-turn note for a delegation from a live spoken conversation,
/// vendored because ACP has no voice-live surface to ask Hermes for it.
///
/// Source: `VOICE_LIVE_TURN_NOTE` and `voice_live_turn_note(context)` at
/// `tools/voice_live.py:73-90` @ v2026.9.14. In Hermes's own clients
/// (tui_gateway, `prompt.submit {surface: "voice-live"}`,
/// `tui_gateway/methods_prompt.py:541, 582-588`) the note is prepended to
/// the MODEL input only. Scarf gets the same effect over ACP by sending it
/// as an embedded-resource context note (``ACPContextNote``).
///
/// **Refresh this text in every Hermes release audit** — a contract test
/// pins it byte-for-byte to the tag.
public enum VoiceLiveTurnNote {
    /// `VOICE_LIVE_TURN_NOTE` — `tools/voice_live.py:73-81` @ v2026.9.14.
    public static let note =
        "[Note: this message is a delegation from a live spoken conversation. The text is a voice "
        + "transcript (it may contain mis-hearings, hesitations and later corrections; use the latest "
        + "intent). Your reply will be spoken aloud by a voice model that paraphrases it: answer in plain "
        + "conversational sentences, keep it short (a few sentences unless the user asked for detail), no "
        + "markdown, no lists, no code blocks, no URLs read out character by character. Do the work with "
        + "your tools as usual; only the final facts need to be spoken. Do not claim an action succeeded "
        + "before it actually did.]"

    /// The embedded resource's URI. Hermes shows its last path segment in
    /// the "[Attached file: voice-live-turn-note]" header of the model input.
    public static let uri = "scarf://voice-live/voice-live-turn-note"

    /// `voice_live_turn_note(context)` — `tools/voice_live.py:84-90`.
    public static func text(context: String) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return note }
        return "\(note)\n[Recent spoken conversation, newest last:\n\(trimmed)]"
    }

    /// The note (with the recent spoken exchange) as ACP context.
    public static func contextNote(context: String) -> ACPContextNote {
        ACPContextNote(uri: uri, text: text(context: context))
    }
}
