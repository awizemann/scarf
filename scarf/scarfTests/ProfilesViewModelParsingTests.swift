import Foundation
import Testing
import ScarfCore
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
         ◆Production (default) deepseek/deepseek-v4-flash   running      —            —
          Staging Box (gateway) —                            stopped      —            —
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
         ◆My (test) profile (myid) deepseek/deepseek-v4-flash   running      —            —

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
          My (test) profile (myid) grok-4 (beta)                stopped      —            —

        """
        let (profiles, active) = ProfilesViewModel.parseProfileList(output)
        #expect(profiles.map(\.name) == ["myid"])
    }
    // MARK: - Server's active profile on remote (S13-F3)

    /// Remotely every `profile list` is pinned to the window's profile, so
    /// the `◆` marks the viewed profile. The badge must come from the
    /// root's `active_profile` file instead.
    @Test("remote: the active badge comes from active_profile, not the marker")
    func remoteActiveComesFromTheStickyFile() {
        let parsed = [HermesProfile(name: "default", isActive: false, path: ""),
                      HermesProfile(name: "work", isActive: true, path: ""),
                      HermesProfile(name: "coder", isActive: false, path: "")]
        let (profiles, active) = ProfilesViewModel.resolveActive(
            parsed: parsed, markedActive: "work", isRemote: true, hostActiveFile: .contents("coder\n"))
        #expect(active == "coder")
        #expect(profiles.filter(\.isActive).map(\.name) == ["coder"])

        // No file (or an empty one) means default, as it does to Hermes.
        let (noFile, noFileActive) = ProfilesViewModel.resolveActive(
            parsed: parsed, markedActive: "work", isRemote: true, hostActiveFile: .missing)
        #expect(noFileActive == "default")
        #expect(noFile.filter(\.isActive).map(\.name) == ["default"])

        // A failed read badges nothing rather than guessing.
        let (unknown, unknownActive) = ProfilesViewModel.resolveActive(
            parsed: parsed, markedActive: "work", isRemote: true, hostActiveFile: .unreadable)
        #expect(unknownActive == nil)
        #expect(unknown.filter(\.isActive).isEmpty)
    }

    /// The remote read is one `cat`, so "no file" (server on default) and
    /// "couldn't read" stay distinct.
    @Test("remote active_profile read: contents, missing and failure are told apart")
    func hostActiveReadIsClassified() {
        #expect(ProfilesViewModel.classifyHostActiveRead(exitCode: 0, stdout: "coder\n", stderr: "")
                == .contents("coder\n"))
        #expect(ProfilesViewModel.classifyHostActiveRead(
            exitCode: 1, stdout: "", stderr: "cat: /root/.hermes/active_profile: No such file or directory")
                == .missing)
        #expect(ProfilesViewModel.classifyHostActiveRead(exitCode: 255, stdout: "", stderr: "ssh: connect to host box: Connection refused")
                == .unreadable)
        #expect(ProfilesViewModel.classifyHostActiveRead(exitCode: 1, stdout: "", stderr: "cat: active_profile: Permission denied")
                == .unreadable)
    }

    @Test("local: the marker is kept (an unpinned local run marks the sticky profile)")
    func localKeepsTheMarker() {
        let parsed = [HermesProfile(name: "default", isActive: false, path: ""),
                      HermesProfile(name: "work", isActive: true, path: "")]
        let (profiles, active) = ProfilesViewModel.resolveActive(
            parsed: parsed, markedActive: "work", isRemote: false, hostActiveFile: .contents("ignored"))
        #expect(active == "work")
        #expect(profiles == parsed)
    }

    // MARK: - Failed `profile list` (S13-F6)

    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [(String, Int32)]
        init(_ results: [(String, Int32)]) { self.results = results }
        func next() -> (String, Int32) {
            lock.lock(); defer { lock.unlock() }
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("timed out")
    }

    static let table = """

     Profile          Model                        Gateway      Alias        Distribution
     ───────────────    ───────────────────────────    ───────────    ───────────    ────────────────────
     ◆default         —                            stopped      —            —
      coder           —                            stopped      coder        —

    """

    @Test("a failed profile list keeps the last list and reports why, instead of 'No Profiles'")
    @MainActor
    func failedListKeepsPreviousAndReportsError() async {
        let script = Script([(Self.table, 0), ("bash: line 1: hermes: command not found", 127)])
        let vm = ProfilesViewModel(context: .local, cliRunner: { _, _ in script.next() })
        vm.load()
        await Self.settle { !vm.isLoading && vm.profiles.count == 2 }
        #expect(vm.loadError == nil)

        vm.load()
        await Self.settle { !vm.isLoading && vm.loadError != nil }
        #expect(vm.profiles.map(\.name) == ["default", "coder"], "previous list kept")
        #expect(vm.loadError == "Failed: bash: line 1: hermes: command not found")
    }

    @Test("a failed first load leaves an error, not an empty success")
    @MainActor
    func failedFirstLoadIsAnError() async {
        let vm = ProfilesViewModel(context: .local, cliRunner: { _, _ in ("", -1) })
        vm.load()
        await Self.settle { !vm.isLoading && vm.loadError != nil }
        #expect(vm.profiles.isEmpty)
        #expect(vm.loadError == "Failed (no output).")
    }
}
