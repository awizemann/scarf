import Testing
@testable import scarf

/// Coverage for `ProfilesViewModel.parseProfileList` across both the
/// pre-0.20.5 bare-name table format and the 0.20.5+ format that renders
/// `format_profile_label(name, display_name)` — `"display_name (name)"` —
/// in the Profile column. See hermes_cli/profiles.py `format_profile_label`.
@Suite("ProfilesViewModel.parseProfileList")
struct ProfilesViewModelParsingTests {

    @Test("bare-name format (pre-0.20.5 / no display names set)")
    func bareNameFormat() {
        let output = """

         Profile          Model                        Gateway      Alias        Distribution
         ───────────────    ───────────────────────────    ───────────    ───────────    ────────────────────
         ◆default         deepseek/deepseek-v4-flash   running      —            —
          gateway         —                            stopped      —            —
          scarfbox-smoke  deepseek/deepseek-v4-pro     stopped      —            —

        """
        let (profiles, active) = ProfilesViewModel.parseProfileList(output)
        #expect(profiles.map(\.name) == ["default", "gateway", "scarfbox-smoke"])
        #expect(active == "default")
        #expect(profiles.first(where: { $0.name == "default" })?.isActive == true)
        #expect(profiles.first(where: { $0.name == "gateway" })?.isActive == false)
    }

    @Test("suffixed format (0.20.5+ display_name set, differs from name)")
    func suffixedFormatWithDisplayName() {
        let output = """

         Profile                    Model                        Gateway      Alias        Distribution
         ───────────────────────    ───────────────────────────    ───────────    ───────────    ────────────────────
         ◆Production (default)    deepseek/deepseek-v4-flash   running      —            —
          Staging Box (gateway)   —                            stopped      —            —
          scarfbox-smoke          deepseek/deepseek-v4-pro     stopped      —            —

        """
        let (profiles, active) = ProfilesViewModel.parseProfileList(output)
        // The argv-bound name must be the canonical id — the parenthesized
        // token — never the leading display-name words, even when the
        // display name itself contains spaces.
        #expect(profiles.map(\.name) == ["default", "gateway", "scarfbox-smoke"])
        #expect(active == "default")
        #expect(profiles.first(where: { $0.name == "default" })?.isActive == true)
    }

    @Test("suffix absent when display_name equals canonical name")
    func suffixOmittedWhenDisplayNameMatchesName() {
        // format_profile_label falls back to the bare id when display_name
        // is unset or equals the canonical name — byte-for-byte the
        // pre-feature rendering. No parens should appear in that row.
        let output = """

         Profile          Model    Gateway      Alias        Distribution
         ───────────────    ────    ───────────    ───────────    ────────────────────
         ◆default         —        running      —            —

        """
        let (profiles, active) = ProfilesViewModel.parseProfileList(output)
        #expect(profiles.map(\.name) == ["default"])
        #expect(active == "default")
    }

    @Test("asterisk active marker still recognized")
    func asteriskActiveMarker() {
        let output = """

         Profile      Model    Gateway      Alias        Distribution
         ───────────    ────    ───────────    ───────────    ────────────────────
         *work (dev)   —        running      —            —

        """
        let (profiles, active) = ProfilesViewModel.parseProfileList(output)
        #expect(profiles.map(\.name) == ["dev"])
        #expect(active == "dev")
    }

    @Test("display name containing an id-shaped paren does not shadow the real id")
    func displayNameContainingIdShapedParen() {
        // Display names are free-form text and may themselves contain a
        // substring that looks like a parenthesized profile id, e.g.
        // "My (test) profile". Per the format_profile_label grammar
        // (display + " (" + id + ")"), the canonical id is always the
        // *last* paren group on the line — parsing must not grab "test".
        let output = """

         Profile                             Model                        Gateway      Alias        Distribution
         ────────────────────────────────    ───────────────────────────    ───────────    ───────────    ────────────────────
         ◆My (test) profile (myid)         deepseek/deepseek-v4-flash   running      —            —

        """
        let (profiles, active) = ProfilesViewModel.parseProfileList(output)
        #expect(profiles.map(\.name) == ["myid"])
        #expect(active == "myid")
    }

    @Test("id-shaped paren in the Model column does not shadow a bare Profile label")
    func idShapedParenInModelColumnWithBareProfile() {
        // The row format is `f"{marker}{name:<15} {model:<28} {gw:<12}
        // {alias:<12} {dist}"` (main.py) — the Model field renders
        // `model.default` verbatim, so a model id like "gpt-4o (preview)"
        // puts an id-shaped paren group *after* the Profile field. Parsing
        // must stay scoped to field 0 and not pick up "preview".
        let output = """

         Profile          Model                        Gateway      Alias        Distribution
         ───────────────    ───────────────────────────    ───────────    ───────────    ────────────────────
         ◆default         gpt-4o (preview)             running      —            —

        """
        let (profiles, active) = ProfilesViewModel.parseProfileList(output)
        #expect(profiles.map(\.name) == ["default"])
        #expect(active == "default")
    }

    @Test("id-shaped parens in both the display name and the Model column resolve to field 0's id")
    func idShapedParensInDisplayNameAndModelColumn() {
        let output = """

         Profile                             Model                        Gateway      Alias        Distribution
         ────────────────────────────────    ───────────────────────────    ───────────    ───────────    ────────────────────
          My (test) profile (myid)         grok-4 (beta)                stopped      —            —

        """
        let (profiles, active) = ProfilesViewModel.parseProfileList(output)
        #expect(profiles.map(\.name) == ["myid"])
    }
}
