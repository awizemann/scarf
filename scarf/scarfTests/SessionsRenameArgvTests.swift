import Testing
import Foundation
@testable import scarf

/// `hermes sessions rename` argv contract (whole-surface audit, P14).
///
/// Hermes declares the title as `nargs="+"`
/// (`hermes_cli/subcommands/sessions.py:210-213` at tag v2026.9.7):
///
/// ```python
/// sessions_rename = sessions_subparsers.add_parser(
///     "rename", help="Set or change a session's title")
/// sessions_rename.add_argument("session_id", help="Session ID to rename")
/// sessions_rename.add_argument("title", nargs="+", help="New title for the session")
/// ```
///
/// Without a `--` separator, argparse treats a title that opens with a dash
/// as an option and exits 2 — the user's rename silently fails with a
/// parser error instead of landing. `_cmd_rename` then re-joins the list
/// with a single space (`hermes_cli/sessions_cmd.py:681`), so the title must
/// stay ONE argv element or its internal spacing collapses.
@Suite struct SessionsRenameArgvTests {

    @Test func renameArgvPutsSeparatorBeforePositionals() {
        #expect(SessionsViewModel.renameArgv(sessionId: "sess-1", title: "Quarterly plan")
                == ["sessions", "rename", "--", "sess-1", "Quarterly plan"])
    }

    @Test func renameArgvSurvivesADashLeadingTitle() {
        // The whole point of `--`. Pre-fix argv was
        // ["sessions", "rename", "sess-1", "--json is broken"], which
        // argparse rejects before `_cmd_rename` ever runs.
        let argv = SessionsViewModel.renameArgv(sessionId: "sess-1", title: "--json is broken")
        #expect(argv == ["sessions", "rename", "--", "sess-1", "--json is broken"])
        // The separator must precede the session id, not sit between the
        // two positionals: everything after `--` is positional, so one
        // separator covers both.
        #expect(argv.firstIndex(of: "--") == 2)
    }

    @Test func renameArgvKeepsTheTitleAsOneElement() {
        // Hermes joins `args.title` with single spaces. Splitting here
        // would turn "Ship  v2" into "Ship v2".
        let argv = SessionsViewModel.renameArgv(sessionId: "s", title: "Ship  v2 now")
        #expect(argv.count == 5)
        #expect(argv.last == "Ship  v2 now")
    }
}
