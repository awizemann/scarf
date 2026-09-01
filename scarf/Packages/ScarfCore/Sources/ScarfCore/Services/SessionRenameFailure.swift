import Foundation

/// Turns a failed `hermes sessions rename` invocation into something a
/// person can act on.
///
/// ## Where the refusal comes from
///
/// It is **not** a CLI-level or ACP-level check. Hermes refuses the
/// rename in the DB layer, inside `SessionDB._set_session_title`
/// (`hermes_state.py` :10199-10215) — the single write path that
/// `sessions rename`, `/title`, the gateway's `session.title` and the
/// REST surface all funnel through. The guard fires when the write is
/// user-sourced, the row's *current* title is exactly
/// `CANONICAL_BOT_CHAT_TITLE` (`"Bot Chat"`, :10066), the row is
/// `hidden`, and the new title differs. It raises a `ValueError`, which
/// `_sessions_rename` (`hermes_cli/console_engine.py` :1497-1517) does
/// not catch — so what reaches Scarf is a non-zero exit plus Hermes'
/// own prose somewhere in the combined output.
///
/// `hidden` is the discriminator on purpose: an ordinary *visible*
/// session a user happens to have named "Bot Chat" renames freely.
/// Scarf therefore cannot predict the refusal from the title alone and
/// must not pre-empt it in the UI — it reacts to the failure instead.
/// That is the whole scope here: a clean error message, not a Bot Mode
/// feature.
public enum SessionRenameFailure {

    /// Fragments of Hermes' refusal text. Matched loosely (and
    /// case-insensitively) rather than byte-pinned to the full
    /// sentence, so a future rewording of the guidance half of the
    /// message does not silently drop Scarf back to the raw dump.
    private static let botChatMarkers = [
        "canonical bot chat",
        "its name is its identity"
    ]

    /// The message Scarf shows when the canonical Bot Chat refuses a
    /// rename. Deliberately Scarf's own phrasing, not a passthrough:
    /// Hermes' text ends with CLI-flavoured advice, and the sheet needs
    /// one short sentence.
    public static let botChatMessage =
        "This is the bot's canonical Bot Chat. Its name is how Hermes finds the "
        + "conversation, so it can't be renamed — create a new bot to start fresh."

    /// Hermes' uniqueness guard (`hermes_state.py` :10250) — session
    /// titles are unique, and a collision is the other rename failure a
    /// user can actually fix.
    private static let duplicateTitleMarker = "is already in use by session"

    public static let duplicateTitleMessage =
        "Another session already uses that title. Pick a different one."

    /// Map a failed rename to a user-presentable message.
    ///
    /// - Parameter output: the CLI's combined stdout+stderr, exactly as
    ///   `ServerContext.runHermes` returns it.
    /// - Returns: a friendly sentence for the two failures Hermes names,
    ///   otherwise the last non-empty output line (Hermes' own error,
    ///   which is usually more specific than anything Scarf could
    ///   invent), or a generic fallback when the command said nothing
    ///   at all.
    public static func message(for output: String) -> String {
        let lowered = output.lowercased()
        if botChatMarkers.contains(where: { lowered.contains($0) }) {
            return botChatMessage
        }
        if lowered.contains(duplicateTitleMarker) {
            return duplicateTitleMessage
        }
        let lastLine = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        if let lastLine, !lastLine.isEmpty {
            // Strip the CLI's own "Error: " lead-in so the sheet does
            // not read "Error: Error: …" next to its label.
            if lastLine.lowercased().hasPrefix("error: ") {
                return String(lastLine.dropFirst("Error: ".count))
            }
            return lastLine
        }
        return "Rename failed. Hermes did not report a reason."
    }
}
