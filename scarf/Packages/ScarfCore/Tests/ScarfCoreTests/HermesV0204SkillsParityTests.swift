import Testing
import Foundation
@testable import ScarfCore

/// Hermes v0.20.4 parity, Phase 4 — Skills.
///
/// (a) `skills update` no longer overwrites locally-edited skills: it
/// prints per-skill `Skipping:` notices, a tally that EXCLUDES them, and
/// a trailing "kept your local edits" summary. Fixtures below are the
/// verbatim plain-text output of `do_update`
/// (`hermes_cli/skills_hub.py`) with Rich markup stripped, as Scarf sees
/// it over a non-TTY pipe.
///
/// (b) Repo-local project skills load from `./.hermes/skills` /
/// `./.agents/skills` in checkouts listed under
/// `skills.trusted_project_dirs` in `config.yaml`.
@Suite("Hermes v0.20.4 parity — Skills")
struct HermesV0204SkillsParityTests {

    // MARK: - (a) Update report parsing

    /// Two updated, one skipped for local edits.
    private static let mixedRun = """
    Updating: 1password
    Updating: gmail
    Skipping: reddit — you have local edits (update would overwrite them).
    Updated 2 skill(s).

    1 skill(s) kept your local edits: reddit.
    Overwrite with: hermes skills update <name> --force

    """

    @Test func parsesSkippedSkillsAndAccurateCount() {
        let report = HermesSkillsHubParser.parseUpdateReport(Self.mixedRun)
        #expect(report.updatedCount == 2)
        #expect(report.skipped == ["reddit"])
    }

    @Test func mergesMultipleSkipsWithoutDuplicatingTheSummaryNames() {
        let output = """
        Updating: gmail
        Skipping: reddit — you have local edits (update would overwrite them).
        Skipping: slack-digest — you have local edits (update would overwrite them).
        Updated 1 skill(s).

        2 skill(s) kept your local edits: reddit, slack-digest.
        Overwrite with: hermes skills update <name> --force
        """
        let report = HermesSkillsHubParser.parseUpdateReport(output)
        #expect(report.updatedCount == 1)
        #expect(report.skipped == ["reddit", "slack-digest"])
    }

    /// Every skill was updated: no `Skipping:` line, no summary. Byte
    /// identical to the pre-v0.20.4 shape.
    @Test func zeroSkipsReportsNoLocalEdits() {
        let output = """
        Updating: 1password
        Updating: gmail
        Updated 2 skill(s).

        """
        let report = HermesSkillsHubParser.parseUpdateReport(output)
        #expect(report.updatedCount == 2)
        #expect(report.skipped.isEmpty)
    }

    /// A pre-v0.20.4 host prints the tally over ALL entries and has no
    /// skip concept at all — the parser must return an empty skip list so
    /// the Updates tab renders exactly as it did before.
    @Test func pre0204OutputYieldsNoSkips() {
        let output = """
        Updating: reddit
        Updated 1 skill(s).

        """
        let report = HermesSkillsHubParser.parseUpdateReport(output)
        #expect(report.updatedCount == 1)
        #expect(report.skipped.isEmpty)
    }

    @Test func noUpdatesAvailableIsZeroAndEmpty() {
        let report = HermesSkillsHubParser.parseUpdateReport("No updates available.\n")
        #expect(report.updatedCount == 0)
        #expect(report.skipped.isEmpty)
    }

    /// The sync path's unrelated `Skipping entry with no identifier:`
    /// line must not be mistaken for a local-edit skip.
    @Test func unrelatedSkippingLineIsIgnored() {
        let output = """
        Skipping entry with no identifier: reddit
        Updated 0 skill(s).
        """
        let report = HermesSkillsHubParser.parseUpdateReport(output)
        #expect(report.skipped.isEmpty)
    }

    /// Rich soft-wraps at 80 columns when stdout isn't a TTY. The name
    /// always precedes the wrap point on a `Skipping:` line, so the skip
    /// still parses.
    @Test func wrappedSkipNoticeStillYieldsTheName() {
        let output = """
        Skipping: a-very-long-skill-name-here — you have local edits (update would
        overwrite them).
        Updated 0 skill(s).
        """
        let report = HermesSkillsHubParser.parseUpdateReport(output)
        #expect(report.skipped == ["a-very-long-skill-name-here"])
    }

    // MARK: - (a) --force is single-skill only

    @Test func forceArgsTargetExactlyOneNamedSkill() {
        #expect(SkillsViewModel.forceUpdateArgs("reddit") == ["skills", "update", "reddit", "--force"])
    }

    /// The bulk path must NEVER carry `--force`: it would overwrite every
    /// locally-edited skill at once.
    @Test func updateAllNeverForces() {
        #expect(SkillsViewModel.updateAllArgs == ["skills", "update"])
        #expect(!SkillsViewModel.updateAllArgs.contains("--force"))
    }

    // MARK: - (b) Project skills + trust

    @Test func trustArgsUsePathExplicitly() {
        #expect(ProjectSkillsScanner.trustArgs("/repos/app", trusted: true)
            == ["skills", "trust", "/repos/app"])
        #expect(ProjectSkillsScanner.trustArgs("/repos/app", trusted: false)
            == ["skills", "untrust", "/repos/app"])
    }

    @Test func projectSkillSubdirsMatchHermes() {
        #expect(ProjectSkillsScanner.subdirectories == [".hermes/skills", ".agents/skills"])
    }

    @Test func parsesBlockFormTrustedProjectDirs() {
        let yaml = """
        skills:
          disabled:
          - noisy
          trusted_project_dirs:
          - /Users/me/repos/app
          - /Users/me/repos/other
        model: opus
        """
        #expect(ProjectSkillsScanner.parseTrustedProjectDirs(yaml)
            == ["/Users/me/repos/app", "/Users/me/repos/other"])
    }

    @Test func parsesInlineFormTrustedProjectDirs() {
        let yaml = """
        skills:
          trusted_project_dirs: ["/a/b", "/c/d"]
        """
        #expect(ProjectSkillsScanner.parseTrustedProjectDirs(yaml) == ["/a/b", "/c/d"])
    }

    /// Pre-v0.20.4 config has no such key — nothing is trusted, and the
    /// panel that consumes this is capability-gated anyway.
    @Test func absentKeyYieldsNoTrustedDirs() {
        let yaml = """
        skills:
          disabled:
          - noisy
        """
        #expect(ProjectSkillsScanner.parseTrustedProjectDirs(yaml).isEmpty)
    }

    @Test func trailingSlashesDoNotBreakTrustMatching() {
        #expect(ProjectSkillsScanner.normalizedRoot("/repos/app/") == "/repos/app")
        #expect(ProjectSkillsScanner.normalizedRoot("/repos/app") == "/repos/app")
        #expect(ProjectSkillsScanner.normalizedRoot("/") == "/")
    }

    // MARK: - (b) Scanner over a real directory tree

    @Test func scansFlatAndNestedProjectSkills() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("scarf-project-skills-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        // .hermes/skills/writer/SKILL.md  (flat)
        // .hermes/skills/ops/deploy/SKILL.md  (category-nested)
        // .agents/skills/reviewer/SKILL.md
        // .hermes/skills/not-a-skill/  (no SKILL.md → ignored)
        for path in [
            ".hermes/skills/writer",
            ".hermes/skills/ops/deploy",
            ".agents/skills/reviewer",
            ".hermes/skills/not-a-skill"
        ] {
            try fm.createDirectory(
                at: root.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }
        for path in [
            ".hermes/skills/writer/SKILL.md",
            ".hermes/skills/ops/deploy/SKILL.md",
            ".agents/skills/reviewer/SKILL.md"
        ] {
            try "# skill".write(
                to: root.appendingPathComponent(path),
                atomically: true,
                encoding: .utf8
            )
        }

        let context = ServerContext.local
        let snapshot = ProjectSkillsScanner.scan(
            projectRoot: root.path,
            context: context,
            transport: context.makeTransport()
        )

        #expect(snapshot.skills.map(\.name) == ["deploy", "writer", "reviewer"])
        #expect(snapshot.skills.filter { $0.source == ".agents/skills" }.map(\.name) == ["reviewer"])
        #expect(!snapshot.skills.contains { $0.name == "not-a-skill" })
    }

    @Test func scanOfARepoWithoutProjectSkillsIsEmpty() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("scarf-empty-project-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let context = ServerContext.local
        let snapshot = ProjectSkillsScanner.scan(
            projectRoot: root.path,
            context: context,
            transport: context.makeTransport()
        )
        #expect(snapshot.skills.isEmpty)
        #expect(!snapshot.hasUntrustedSkills)
    }
}
