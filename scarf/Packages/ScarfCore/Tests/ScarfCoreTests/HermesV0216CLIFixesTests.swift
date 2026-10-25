import Foundation
import Testing
@testable import ScarfCore

/// S7 (Hermes v0.21.6 … v0.22.5 parity) — small CLI and data fixes. Each
/// fixture is the text the tagged Hermes source prints, cited per test, so
/// reverting the matching fix fails it.
@Suite struct HermesV0216CLIFixesTests {
    static let v0215 = HermesCapabilities.parseLine("Hermes Agent v0.21.5 (2026.9.24)")
    static let v0216 = HermesCapabilities.parseLine("Hermes Agent v0.21.6 (2026.9.24)")

    // MARK: - import: v0.21.6 partial restore exits 1

    /// `run_import` on a restore with skipped files (`hermes_cli/backup.py:811`,
    /// `:819-825`, `:907-910` @ v0.22.5), exit 1.
    static let importPartial = """
        Backup contains 812 files
        Target: ~/.hermes

        Checking archive integrity ...

        Importing 812 files ...

        Import incomplete: 809 files restored in 4.1s
          Target: ~/.hermes

          Warnings (3 files skipped):
            sessions/a.json: Permission denied
            sessions/b.json: Permission denied
            sessions/c.json: Permission denied

        Import incomplete: 3 file(s) were not restored (see Warnings above). Fix the cause and re-run the import.
        """

    @Test func partialImportIsAPartialSuccessOnV0216() throws {
        let outcome = HermesImportVerdict.judge(output: Self.importPartial, exitCode: 1, capabilities: Self.v0216)
        #expect(outcome.succeeded)
        #expect(outcome.detail == "Import incomplete: 809 files restored in 4.1s")
        let warning = try #require(outcome.warning)
        #expect(warning.hasPrefix(HermesImportVerdict.skippedNote))
        #expect(warning.contains("3 file(s) were not restored"))
    }

    @Test func partialImportShrinkNoteRidesAlong() throws {
        let output = Self.importPartial + """

              ⚠ Session data replaced by older backup contents:
                state.db: 12 session(s) / 340 message(s) -> 0 / 0
            """
        let warning = try #require(
            HermesImportVerdict.judge(output: output, exitCode: 1, capabilities: Self.v0216).warning)
        #expect(warning.contains(HermesImportVerdict.sessionsShrankNote))
        #expect(warning.contains(HermesImportVerdict.skippedNote))
    }

    /// C1: below the floor an exit 1 stays a plain failure.
    @Test func exitOneStaysAFailureBelowV0216() {
        for caps in [Self.v0215, HermesCapabilities.empty] {
            let outcome = HermesImportVerdict.judge(output: Self.importPartial, exitCode: 1, capabilities: caps)
            #expect(!outcome.succeeded)
        }
    }

    /// `Import refused; no files restored: {exc}` then `sys.exit(1)`
    /// (`backup.py:805-806` @ v0.22.5) — a failure, quoting its reason.
    @Test func importRefusedIsAFailureWithItsReason() {
        let output = """
            Backup contains 812 files
            Target: ~/.hermes

            Checking archive integrity ...

            Importing 812 files ...

            Import refused; no files restored: gateway pid 4242 owns this home
            """
        let outcome = HermesImportVerdict.judge(output: output, exitCode: 1, capabilities: Self.v0216)
        #expect(!outcome.succeeded)
        #expect(outcome.detail == "Import refused; no files restored: gateway pid 4242 owns this home")
    }

    /// The damaged-archive arm returns 1 too (`backup.py:787-793`) with no
    /// `Import incomplete:` — nothing was restored, so it is a failure.
    @Test func damagedArchiveIsNotAPartialSuccess() {
        let output = """
            Checking archive integrity ...
            Error: backup archive is damaged (1 member(s) fail to decompress or fail their CRC); nothing was restored:
              state.db
            """
        #expect(!HermesImportVerdict.judge(output: output, exitCode: 1, capabilities: Self.v0216).succeeded)
    }

    // MARK: - cron duplicate: v0.21.6 `interpreter`

    static func scriptJob() throws -> HermesCronJob {
        let json = """
            {"id": "j1", "name": "Report", "prompt": "", "enabled": true, "state": "scheduled",
             "schedule": {"kind": "cron", "expr": "0 9 * * *", "display": "0 9 * * *"},
             "script": "report.py", "interpreter": "~/venvs/report/bin/python"}
            """
        return try JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    @Test func duplicateCarriesInterpreterOnV0216() throws {
        let job = try Self.scriptJob()
        #expect(job.interpreter == "~/venvs/report/bin/python")
        let copy = job.duplicatedAsNewJob(id: "j2", existingNames: ["Report"], capabilities: Self.v0216)
        #expect(copy.extra["interpreter"] == .string("~/venvs/report/bin/python"))
    }

    /// C1: v0.21.5's allowlist (no `interpreter` there) is unchanged.
    @Test func v0215AllowlistUnchanged() throws {
        let copy = try Self.scriptJob().duplicatedAsNewJob(
            id: "j2", existingNames: ["Report"], capabilities: Self.v0215)
        #expect(copy.extra["interpreter"] == nil)
    }

    // MARK: - kanban diagnostics: missing kinds

    @Test func runningWithOpenParentsAndStaleRunningAreKnownKinds() {
        // `kanban_diagnostics.py:581` @ v2026.9.24 / `:793` @ v0.22.5.
        #expect(KanbanDiagnosticKind.from("running_with_open_parents") == .runningWithOpenParents)
        #expect(KanbanDiagnosticKind.from("stale_running") == .staleRunning)
        #expect(KanbanDiagnosticKind.staleRunning.glyphName != KanbanDiagnosticKind.unknown.glyphName)
        #expect(KanbanDiagnosticKind.from("future_kind_v99") == .unknown)
    }

    @Test func staleRunningWithReclaimActionStillDecodes() throws {
        let json = """
            [{"task_id": "t1", "diagnostics": [{"kind": "stale_running", "severity": "error",
              "title": "Running claim is stale", "detail": "worker gone",
              "actions": [{"kind": "reclaim", "label": "Reclaim the dead claim", "suggested": true, "payload": {}}],
              "first_seen_at": 0, "last_seen_at": 0, "count": 1, "run_id": 7, "data": {}}]}]
            """
        let entries = try HermesKanbanDiagnosticsEntry.decodeList(from: Data(json.utf8))
        #expect(KanbanDiagnosticKind.from(try #require(entries.first?.diagnostics.first).kind) == .staleRunning)
    }

    // MARK: - skills install: v0.21.6 built-in arms

    /// `Restored built-in skill: {name} ({path})` (`skills_hub.py:744` @ v0.22.5).
    @Test func restoredBuiltinIsASuccess() {
        let output = "Restored built-in skill: arxiv (/Users/a/.hermes/skills/research/arxiv)\n"
        #expect(SkillsViewModel.installOutcome(exitCode: 0, output: output).succeeded)
    }

    /// `'{name}' is a built-in skill and is already available{where}.` (`:742`).
    @Test func alreadyAvailableBuiltinIsASuccess() {
        let output = "'arxiv' is a built-in skill and is already available at /Users/a/.hermes/skills/research/arxiv.\n"
        #expect(SkillsViewModel.installOutcome(exitCode: 0, output: output).succeeded)
    }

    /// The present-arm phrase never beats a refusal, and is not read
    /// mid-line (a quoted SKILL.md finding).
    @Test func builtinPhraseDoesNotOverrideARefusal() {
        let refused = """
            'arxiv' is a built-in skill and is already available.
            Installation blocked: scan verdict dangerous
            """
        #expect(!SkillsViewModel.installOutcome(exitCode: 0, output: refused).succeeded)
        let quoted = "  MEDIUM  says 'x' is a built-in skill and is already available\n"
        #expect(!SkillsViewModel.installOutcome(exitCode: 0, output: quoted).succeeded)
    }
}
