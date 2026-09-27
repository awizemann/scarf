import Testing
@testable import ScarfCore

/// `HermesProfileList` — the `hermes profile list` parser shared by the Mac
/// Profiles view and ScarfGo (S13-F4), plus the `active_profile` reader
/// behind the remote "server's active profile" badge (S13-F3).
///
/// The two fixtures are verbatim output of the real Hermes CLI at
/// v2026.9.24 (`.venv/bin/hermes` from the reference checkout), run against
/// a scratch `HOME` holding two display-named profiles — `research`
/// ("Research Bot", uppercase first word) and `helper` ("zeta tool",
/// lowercase first word, the case ScarfGo used to mis-id) — with the sticky
/// `active_profile` set to `research`.
@Suite struct HermesProfileListTests {

    /// `hermes profile list` with no `-p`: Hermes re-homes to the sticky
    /// profile, so `◆` marks `research`.
    static let unpinned = """

         Profile          Model                        Gateway      Alias        Distribution
         ───────────────    ───────────────────────────    ───────────    ───────────    ────────────────────
          default         —                            stopped      —            —
          zeta tool (helper) —                            stopped      helper       —
         ◆Research Bot (research) —                            stopped      research     —

        """

    /// `hermes -p default profile list` against the same home: the marker
    /// follows the PROCESS's home, so it moves to `default` even though the
    /// server's active profile is still `research`.
    static let pinnedDefault = """

         Profile          Model                        Gateway      Alias        Distribution
         ───────────────    ───────────────────────────    ───────────    ───────────    ────────────────────
         ◆default         —                            stopped      —            —
          zeta tool (helper) —                            stopped      helper       —
          Research Bot (research) —                            stopped      research     —

        """

    @Test func displayNamedRowsYieldCanonicalIds() {
        let rows = HermesProfileList.parse(Self.unpinned)
        #expect(rows.map(\.id) == ["default", "helper", "research"])
        #expect(rows.map(\.displayName) == [nil, "zeta tool", "Research Bot"])
    }

    @Test func markerFollowsTheProcessHomeNotTheStickyFile() {
        #expect(HermesProfileList.parse(Self.unpinned).filter(\.isMarked).map(\.id) == ["research"])
        #expect(HermesProfileList.parse(Self.pinnedDefault).filter(\.isMarked).map(\.id) == ["default"])
    }

    @Test func bareIdRowsFromOlderHosts() {
        let output = """

         Profile          Model                        Gateway      Alias
         ───────────────    ───────────────────────────    ───────────    ───────────
         ◆default         gpt-5                        running      —
          coder           —                            stopped      coder

        """
        let rows = HermesProfileList.parse(output)
        #expect(rows.map(\.id) == ["default", "coder"])
        #expect(rows.map(\.displayName) == [nil, nil])
        #expect(rows.first?.isMarked == true)
    }

    /// The parser alone can't tell failure output from a table (a traceback's
    /// "Traceback" is id-shaped), which is why both callers check the exit
    /// code first (S13-F4/F6). What it must not do is invent rows from the
    /// common shell failures.
    @Test func commonFailureOutputYieldsNoRows() {
        #expect(HermesProfileList.parse("sh: hermes: command not found").isEmpty)
        #expect(HermesProfileList.parse("bash: line 1: hermes: command not found").isEmpty)
        #expect(HermesProfileList.parse("").isEmpty)
    }

    @Test func activeProfileFileContents() {
        #expect(HermesProfileList.activeProfile(fromFileContents: "research\n") == "research")
        #expect(HermesProfileList.activeProfile(fromFileContents: "") == "default")
        #expect(HermesProfileList.activeProfile(fromFileContents: nil) == "default")
        #expect(HermesProfileList.activeProfile(fromFileContents: "  \n") == "default")
    }
}
