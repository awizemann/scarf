import Testing
import Foundation
@testable import ScarfCore

/// Blind re-audit B08 (Hermes v0.21.5): plugin update, cron mutation
/// verdicts, skill config keys and the plugin tool-override badge.
@Suite("Blind re-audit B08")
struct BlindReauditB08Tests {

    // MARK: - S10-F1: catalog plugin update

    /// `cmd_update_catalog` prints `✓ Plugin <name> updated to <sha8>.` or
    /// `✓ Plugin <name> is already at catalog pin <sha8>.` and exits 0
    /// (`hermes_cli/plugins_cmd_catalog.py:405-406` @ v2026.9.24).
    @Test func catalogUpdateLinesAreSuccess() {
        let updated = """
        Checking catalog pin for weather...
        ✓ Plugin weather updated to 1a2b3c4d.
        Installing Python dependencies...
        """
        #expect(HermesPluginsUpdateVerdict.judge(output: updated, exitCode: 0).succeeded)
        let pinned = "Checking catalog pin for weather...\n✓ Plugin weather is already at catalog pin 1a2b3c4d.\n"
        #expect(HermesPluginsUpdateVerdict.judge(output: pinned, exitCode: 0).succeeded)
        // The git-pull shapes still pass.
        #expect(HermesPluginsUpdateVerdict.judge(output: "✓ Plugin weather updated.\n", exitCode: 0).succeeded)
    }

    @Test func catalogUpdateRefusalsStayFailures() {
        // Consent refused after a re-pin: failure wins over the ✓ line.
        let ungranted = """
        ✓ Plugin weather updated to 1a2b3c4d.
          Non-interactive session: capabilities NOT granted (fail closed).
        """
        #expect(!HermesPluginsUpdateVerdict.judge(output: ungranted, exitCode: 0).succeeded)
        // A widening the non-TTY run would not apply exits 1 through `_fail`.
        let notApplied = """
          Non-interactive session: update NOT applied (fail closed).
        Update of weather not applied: consent required
        """
        #expect(!HermesPluginsUpdateVerdict.judge(output: notApplied, exitCode: 1).succeeded)
        // A git-pull body line that happens to end the same way is not ours.
        #expect(!HermesPluginsUpdateVerdict.judge(output: "docs: plugin updated to 1a2b3c4d.\n", exitCode: 0).succeeded)
        // No sha: not the catalog shape.
        #expect(!HermesPluginsUpdateVerdict.judge(output: "✓ Plugin weather updated to latest.\n", exitCode: 0).succeeded)
    }

    // MARK: - S15 handoff: cron mutations that exit 0 on failure

    /// Up to v2026.8.31 `cmd_cron` dropped the handler's return code, so
    /// these lines came with exit 0 (`hermes_cli/main.py:5626-5630` @
    /// v2026.8.31).
    @Test func cronExitZeroRefusalsAreRecognised() {
        #expect(HermesCronMutationVerdict.exitZeroRefusal(
            output: "Failed to pause job: Job with ID or name 'x' not found.\n")
            == "Failed to pause job: Job with ID or name 'x' not found.")
        #expect(HermesCronMutationVerdict.exitZeroRefusal(
            output: "\u{1B}[31mFailed to resume job: Cannot resume: one-shot time …\u{1B}[0m\n") != nil)
        #expect(HermesCronMutationVerdict.exitZeroRefusal(output: "Job not found: abc\n") != nil)
        #expect(HermesCronMutationVerdict.exitZeroRefusal(output: "Failed to re-arm job: nope\n") != nil)
        // Success output carries none of them.
        #expect(HermesCronMutationVerdict.exitZeroRefusal(output: "Paused job: Nightly (abc)\n") == nil)
        #expect(HermesCronMutationVerdict.exitZeroRefusal(
            output: "Resumed job: Nightly (abc)\n  Next run: 2026-09-28T09:00:00\n") == nil)
    }

    @MainActor
    @Test func iOSCronVerdictReadsTheRefusalAtExitZero() {
        switch IOSCronViewModel.classify(exitCode: 0, output: "Failed to pause job: gone\n", verb: "pause") {
        case .refused(let message): #expect(message == "Failed to pause job: gone")
        default: Issue.record("an exit-0 refusal read as success")
        }
        switch IOSCronViewModel.classify(exitCode: 0, output: "Paused job: N (j1)\n", verb: "pause") {
        case .succeeded: break
        default: Issue.record("a real pause did not read as success")
        }
        switch IOSCronViewModel.classify(exitCode: 1, output: "Failed to pause job: gone\n", verb: "pause") {
        case .refused(let message): #expect(message == "Failed to pause job: gone")
        default: Issue.record("an exit-1 refusal did not read as refused")
        }
        switch IOSCronViewModel.classify(exitCode: 127, output: "sh: hermes: command not found", verb: "pause") {
        case .unavailable: break
        default: Issue.record("a missing binary must fall back to the JSON write")
        }
    }

    // MARK: - S10-F3: skill config keys, scanned and checked

    private static func scratchHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b08-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func put(_ relative: String, in home: URL, _ text: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// The scanner reads `metadata.hermes.config` and `metadata.hermes.
    /// related_skills` from SKILL.md, and ignores `skill.yaml`; the missing
    /// check looks at `skills.config.<key>` the way `get_missing_skill_config_vars`
    /// does.
    @Test func scannedConfigKeysDriveTheMissingCheck() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.put("skills/research/notes/SKILL.md", in: home, """
        ---
        name: notes
        description: Notes
        metadata:
          hermes:
            related_skills: [arxiv, pdf]
            config:
              - key: notes.dir
                description: Where notes live
                default: "~/notes"
              - key: notes.format
                description: Output format
        ---
        # notes
        """)
        try Self.put("skills/research/notes/skill.yaml", in: home, "required_config:\n  - legacy_key\n")
        let ctx = ServerContext.local(home: home)
        let skill = try #require(
            SkillsScanner.scan(context: ctx, transport: LocalTransport())
                .flatMap(\.skills).first { $0.name == "notes" })
        #expect(skill.requiredConfig == ["notes.dir", "notes.format"])
        #expect(skill.relatedSkills == ["arxiv", "pdf"])

        let config = """
        skills:
          config:
            notes:
              dir: ~/Documents/notes
              format: ""
        """
        #expect(SkillsViewModel.computeMissingConfig(for: skill, yaml: config) == ["notes.format"])
        // The key's text appearing elsewhere is not a value (the old check
        // passed on any substring match).
        #expect(SkillsViewModel.computeMissingConfig(
            for: skill, yaml: "# notes.dir notes.format\nmodel: x\n") == ["notes.dir", "notes.format"])
        #expect(SkillsViewModel.computeMissingConfig(for: skill, yaml: nil) == ["notes.dir", "notes.format"])
    }

    // MARK: - S10-F3: tool-override badge from capabilities

    @Test func toolOverrideComesFromTheCapabilitiesList() throws {
        let home = try Self.scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = ServerContext.local(home: home)
        try Self.put("a/plugin.yaml", in: home, "name: a\ncapabilities:\n  - tools.override\n  - llm.model_override\n")
        try Self.put("b/plugin.yaml", in: home, "name: b\ncapabilities: [\"tools.override\"]\n")
        try Self.put("c/plugin.yaml", in: home, "name: c\ntool_override: true\n")
        try Self.put("d/plugin.json", in: home, #"{"name": "d", "capabilities": ["tools.override"]}"#)
        try Self.put("e/plugin.json", in: home, #"{"name": "e", "tool_override": true}"#)
        func badge(_ dir: String) -> Bool {
            HermesPluginDirectoryScanner.readManifest(path: home.path + "/" + dir, context: ctx).toolOverride
        }
        #expect(badge("a"))
        #expect(badge("b"))
        #expect(!badge("c"), "no Hermes version reads a manifest tool_override key")
        #expect(badge("d"))
        #expect(!badge("e"))
    }
}
