import Testing
@testable import ScarfCore

/// W6: the "Bot Chat" rename refusal.
///
/// Hermes raises this from the DB write path
/// (`SessionDB._set_session_title`, `hermes_state.py` :10199-10215), not
/// from the CLI or ACP — so the only thing Scarf sees is a non-zero exit
/// plus prose in the combined output. These tests pin the mapping from
/// that prose to a message worth showing.
@Suite struct SessionRenameFailureTests {

    /// The literal Hermes emits today, reproduced from the source.
    private let hermesBotChatError = """
        Traceback (most recent call last):
          File "/opt/hermes/hermes_cli/console_engine.py", line 1512, in _run
            if not db.set_session_title(resolved_session_id, title):
        ValueError: This is the bot's canonical Bot Chat — its name is its identity, \
        and renaming it would orphan the conversation. To start fresh, create a new bot instead.
        """

    @Test func botChatRefusalMapsToFriendlyMessage() {
        #expect(SessionRenameFailure.message(for: hermesBotChatError)
            == SessionRenameFailure.botChatMessage)
    }

    /// Matching is loose on purpose: a reworded second half must not
    /// drop the user back to a raw traceback.
    @Test func botChatRefusalMatchesOnEitherMarkerAlone() {
        #expect(SessionRenameFailure.message(for: "Error: this is the CANONICAL BOT CHAT, sorry")
            == SessionRenameFailure.botChatMessage)
        #expect(SessionRenameFailure.message(for: "ValueError: its name is its identity here")
            == SessionRenameFailure.botChatMessage)
    }

    @Test func duplicateTitleMapsToItsOwnMessage() {
        let output = "ValueError: Title 'Work' is already in use by session abc123"
        #expect(SessionRenameFailure.message(for: output)
            == SessionRenameFailure.duplicateTitleMessage)
    }

    /// Anything else falls back to Hermes' own last word, which is
    /// nearly always more specific than a Scarf-invented sentence.
    @Test func unknownFailureSurfacesLastNonEmptyLine() {
        let output = "some noise\n\nError: Session 'zzz' not found.\n\n"
        #expect(SessionRenameFailure.message(for: output) == "Session 'zzz' not found.")
    }

    @Test func silentFailureGetsGenericMessage() {
        #expect(SessionRenameFailure.message(for: "   \n\n  ")
            == "Rename failed. Hermes did not report a reason.")
        #expect(SessionRenameFailure.message(for: "")
            == "Rename failed. Hermes did not report a reason.")
    }

    /// The Bot Chat message must not be a passthrough of Hermes' text —
    /// it ends in CLI-flavoured advice and the sheet wants one sentence.
    @Test func botChatMessageIsScarfPhrasingNotAPassthrough() {
        #expect(!SessionRenameFailure.botChatMessage.contains("Traceback"))
        #expect(SessionRenameFailure.botChatMessage.contains("Bot Chat"))
        #expect(SessionRenameFailure.botChatMessage.count < 200)
    }
}
