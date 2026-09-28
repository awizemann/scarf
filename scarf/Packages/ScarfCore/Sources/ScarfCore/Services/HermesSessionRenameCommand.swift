import Foundation

/// argv for `hermes sessions rename`, shared by the Mac (Sessions pane,
/// chat sidebar, `/new <name>`) and ScarfGo (`/new <name>`).
///
/// The `--` separator is REQUIRED: `title` is `nargs="+"` on Hermes's
/// parser (`hermes_cli/subcommands/sessions.py:252-256` @ v2026.9.24), so
/// a title that begins with a dash ("-- draft", "-v2 notes") would be read
/// as an option and argparse would exit 2. Everything after `--` is
/// positional. The title stays ONE argv element — Hermes re-joins the list
/// with a single space, so splitting it would collapse internal spacing.
public enum HermesSessionRenameCommand {
    public static func argv(sessionId: String, title: String) -> [String] {
        ["sessions", "rename", "--", sessionId, title]
    }
}
