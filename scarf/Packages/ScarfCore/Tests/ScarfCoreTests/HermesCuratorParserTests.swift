import Testing
import Foundation
@testable import ScarfCore

@Suite struct HermesCuratorParserTests {

    /// Real `hermes curator status` output captured from a v0.12.0
    /// install with no curator runs yet. Locks in the empty-state
    /// happy path so a Hermes layout tweak surfaces here before
    /// CuratorView starts rendering "—" placeholders silently.
    private static let realFreshOutput = """
    curator: ENABLED
      runs:           0
      last run:       never
      last summary:   (none)
      interval:       every 7d
      stale after:    30d unused
      archive after:  90d unused

    agent-created skills: 18 total
      active     18
      stale      0
      archived   0

    least recently active (top 5):
      Scarf Dashboard Chart Widget Parse Error Fix  activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      Scarf Project Registry Format Fix         activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      clip                                      activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      find-nearby                               activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      gguf-quantization                         activity=  0  use=  0  view=  0  patches=  0  last_activity=never

    least active (top 5):
      Scarf Dashboard Chart Widget Parse Error Fix  activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      Scarf Project Registry Format Fix         activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      clip                                      activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      find-nearby                               activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      gguf-quantization                         activity=  0  use=  0  view=  0  patches=  0  last_activity=never
    """

    @Test func parseRealFreshOutput() {
        let s = HermesCuratorStatusParser.parse(text: Self.realFreshOutput)
        #expect(s.state == .enabled)
        #expect(s.runCount == 0)
        #expect(s.lastRunISO == nil)
        #expect(s.lastSummary == nil)
        #expect(s.intervalLabel == "every 7d")
        #expect(s.staleAfterLabel == "30d unused")
        #expect(s.archiveAfterLabel == "90d unused")
        #expect(s.totalSkills == 18)
        #expect(s.activeSkills == 18)
        #expect(s.staleSkills == 0)
        #expect(s.archivedSkills == 0)
        #expect(s.pinnedNames.isEmpty)
        #expect(s.leastRecentlyActive.count == 5)
        #expect(s.leastActive.count == 5)
        #expect(s.mostActive.isEmpty)
        let firstRow = s.leastRecentlyActive.first
        #expect(firstRow?.name == "Scarf Dashboard Chart Widget Parse Error Fix")
        #expect(firstRow?.activityCount == 0)
        #expect(firstRow?.lastActivityLabel == "never")
        // Pre-0.20 output carries no provenance split or unmanaged block.
        #expect(s.agentCreatedSkills == nil)
        #expect(s.bundledSkills == nil)
        #expect(s.unmanagedCount == nil)
    }

    // MARK: - v0.20 status format (WS-B2)

    /// Real `hermes curator status` output captured live from a v0.20.0
    /// install (2026-08-03). The header renamed `agent-created skills:`
    /// → `curator-managed skills: N total  (agent-created=X  bundled=Y)`
    /// and a new `unmanaged (…)` summary block sits between `pinned` and
    /// the top-5 lists.
    private static let realV020Output = """
    curator: ENABLED
      runs:           8
      last run:       6d ago
      last summary:   auto: 11 marked stale; llm: skipped (consolidation off)
      last report:    /Users/awizemann/.hermes/logs/curator/20260728-072206
      interval:       every 7d
      stale after:    30d unused
      archive after:  90d unused
      consolidate:    off (prune-only; LLM merge pass opt-in)

    curator-managed skills: 18 total  (agent-created=0  bundled=18)
      active     8
      stale      10
      archived   0

    unmanaged (no provenance marker): 50 total
      pre-dates marker    41
      foreground-created  9
      never auto-staled or archived — `hermes curator adopt <name>` hands one over

    least recently active (top 5):
      computer-use                              activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      docx                                      activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      evaluating-llms-harness                   activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      grounded-citations                        activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      inspecting-hermes-desktop-dom             activity=  0  use=  0  view=  0  patches=  0  last_activity=never

    least active (top 5):
      computer-use                              activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      docx                                      activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      evaluating-llms-harness                   activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      grounded-citations                        activity=  0  use=  0  view=  0  patches=  0  last_activity=never
      inspecting-hermes-desktop-dom             activity=  0  use=  0  view=  0  patches=  0  last_activity=never
    """

    @Test func parseRealV020Output() {
        let s = HermesCuratorStatusParser.parse(text: Self.realV020Output)
        #expect(s.state == .enabled)
        #expect(s.runCount == 8)
        #expect(s.lastSummary == "auto: 11 marked stale; llm: skipped (consolidation off)")
        #expect(s.lastReportPath == "/Users/awizemann/.hermes/logs/curator/20260728-072206")
        #expect(s.totalSkills == 18)
        #expect(s.activeSkills == 8)
        #expect(s.staleSkills == 10)
        #expect(s.archivedSkills == 0)
        #expect(s.agentCreatedSkills == 0)
        #expect(s.bundledSkills == 18)
        #expect(s.unmanagedCount == 50)
        #expect(s.pinnedNames.isEmpty)
        #expect(s.leastRecentlyActive.count == 5)
        #expect(s.leastActive.count == 5)
        #expect(s.leastRecentlyActive.first?.name == "computer-use")
    }

    /// v0.20 empty sentinel: `no curator-managed skills` (pre-0.20 said
    /// `no agent-created skills`), followed by the unmanaged block when
    /// unmanaged skills exist.
    @Test func parseV020EmptySentinel() {
        let text = """
        curator: ENABLED
          runs:           0
          last run:       never
          last summary:   (none)
          interval:       every 7d
          stale after:    30d unused
          archive after:  90d unused
          consolidate:    off (prune-only; LLM merge pass opt-in)

        no curator-managed skills

        unmanaged (no provenance marker): 7 total
          pre-dates marker    5
          foreground-created  2
          never auto-staled or archived — `hermes curator adopt <name>` hands one over
        """
        let s = HermesCuratorStatusParser.parse(text: text)
        #expect(s.state == .enabled)
        #expect(s.totalSkills == 0)
        #expect(s.agentCreatedSkills == nil)
        #expect(s.bundledSkills == nil)
        #expect(s.unmanagedCount == 7)
        #expect(s.leastRecentlyActive.isEmpty)
    }

    /// v0.20 nonzero provenance split parses both counters.
    @Test func parseV020ProvenanceSplit() {
        let text = "curator-managed skills: 25 total  (agent-created=7  bundled=18)"
        let s = HermesCuratorStatusParser.parse(text: text)
        #expect(s.totalSkills == 25)
        #expect(s.agentCreatedSkills == 7)
        #expect(s.bundledSkills == 18)
    }

    // MARK: - v0.20 list-unmanaged (WS-B2)

    /// Rows verified against live `hermes curator list-unmanaged` output
    /// on v0.20.0 — header line, indented rows with both marker
    /// variants, multi-word names, and the trailing adopt hint.
    @Test func listUnmanagedParsesRealShape() {
        let out = """
        unmanaged skills (4):
          CDO Contact Research Automation              activity=   0  last_activity=never           (no marker)
          godmode                                      activity=   0  last_activity=never           (created_by:null)
          jupyter-live-kernel                          activity=   4  last_activity=41d ago         (created_by:null)
          scarf-template-author                        activity=  22  last_activity=36d ago         (created_by:null)

        adopt one with `hermes curator adopt <name>`, or all with `hermes curator adopt --all-unmanaged`
        """
        let rows = CuratorService.parseListUnmanaged(out)
        #expect(rows.count == 4)
        #expect(rows[0].name == "CDO Contact Research Automation")
        #expect(rows[0].activityCount == 0)
        #expect(rows[0].lastActivityLabel == "never")
        #expect(rows[0].markerLabel == "no marker")
        #expect(rows[1].name == "godmode")
        #expect(rows[1].markerLabel == "created_by:null")
        #expect(rows[2].activityCount == 4)
        #expect(rows[2].lastActivityLabel == "41d ago")
        #expect(rows[3].activityCount == 22)
    }

    /// Empty / sentinel stdout folds to `[]` without throwing.
    @Test func listUnmanagedEmptyStaysSafe() {
        #expect(CuratorService.parseListUnmanaged("").isEmpty)
        #expect(CuratorService.parseListUnmanaged("no unmanaged skills\n").isEmpty)
    }

    @Test func parsedPausedState() {
        let text = """
        curator: PAUSED
          runs:           5
          last run:       2026-04-29T03:10:00Z
          last summary:   pruned 2 skills, consolidated 1
          interval:       every 7d
          stale after:    30d unused
          archive after:  90d unused

        agent-created skills: 12 total
          active     8
          stale      3
          archived   1

        pinned (2): kanban-orchestrator, scarf-template-author
        """
        let s = HermesCuratorStatusParser.parse(text: text)
        #expect(s.state == .paused)
        #expect(s.runCount == 5)
        #expect(s.lastRunISO == "2026-04-29T03:10:00Z")
        #expect(s.lastSummary == "pruned 2 skills, consolidated 1")
        #expect(s.totalSkills == 12)
        #expect(s.activeSkills == 8)
        #expect(s.staleSkills == 3)
        #expect(s.archivedSkills == 1)
        #expect(s.pinnedNames == ["kanban-orchestrator", "scarf-template-author"])
    }

    @Test func stateFileOverridesTextSummary() {
        // The state file is authoritative for last_run_at /
        // last_run_summary / last_report_path because it carries full
        // ISO timestamps the text output may have rounded. Verify that
        // a state file with richer values overrides parsed text.
        let text = """
        curator: ENABLED
          runs:           1
          last run:       2026-04-30T11:00:00Z
          last summary:   short
          interval:       every 7d
          stale after:    30d unused
          archive after:  90d unused

        agent-created skills: 3 total
          active     3
          stale      0
          archived   0
        """
        let stateJSON: [String: Any] = [
            "run_count": 4,
            "last_run_at": "2026-04-30T18:42:13.001Z",
            "last_run_summary": "richer summary from state file",
            "last_report_path": "/Users/u/.hermes/logs/curator/20260430-184213"
        ]
        let data = try! JSONSerialization.data(withJSONObject: stateJSON)
        let s = HermesCuratorStatusParser.parse(text: text, stateFileJSON: data)
        #expect(s.runCount == 4)
        #expect(s.lastRunISO == "2026-04-30T18:42:13.001Z")
        #expect(s.lastSummary == "richer summary from state file")
        #expect(s.lastReportPath == "/Users/u/.hermes/logs/curator/20260430-184213")
    }

    @Test func parsedDisabledStatus() {
        let s = HermesCuratorStatusParser.parse(text: "curator: DISABLED\n  runs:           0\n")
        #expect(s.state == .disabled)
    }

    @Test func parsedEmptyOutputStaysSafe() {
        let s = HermesCuratorStatusParser.parse(text: "")
        #expect(s.state == .unknown)
        #expect(s.totalSkills == 0)
        #expect(s.leastRecentlyActive.isEmpty)
    }

    @Test func skillRowParserHandlesMultiWordNames() {
        // Names with spaces are common (Scarf Dashboard Chart Widget…)
        // The parser slices at the first `activity=` so names can be
        // arbitrary length without breaking the counter columns.
        let row = "  Some Long Skill Name v2  activity= 12  use= 4  view= 6  patches= 2  last_activity=2026-04-25"
        let s = HermesCuratorStatusParser.parse(text: """
        least recently active (top 5):
        \(row)
        """)
        let parsed = s.leastRecentlyActive.first
        #expect(parsed?.name == "Some Long Skill Name v2")
        #expect(parsed?.activityCount == 12)
        #expect(parsed?.useCount == 4)
        #expect(parsed?.viewCount == 6)
        #expect(parsed?.patchCount == 2)
        #expect(parsed?.lastActivityLabel == "2026-04-25")
    }

    // MARK: - v0.13 list-archived / prune fixtures (WS-4)

    /// Empty JSON array → `[]`. Locks in the happy-path no-archives shape.
    @Test func listArchivedEmpty() throws {
        let result = try CuratorService.parseListArchived(stdout: "[]")
        #expect(result.isEmpty)
    }

    /// Three archives with full optional fields. Asserts each
    /// optional value decodes through `decodeIfPresent` and that
    /// the computed labels resolve.
    @Test func listArchivedThreeSkills() throws {
        let json = """
        [
          {
            "name": "legacy-helper",
            "category": "templates",
            "archived_at": "2026-04-22T03:14:09Z",
            "reason": "stale: 91d unused",
            "size_bytes": 4521,
            "path": "/Users/u/.hermes/skills/.archived/legacy-helper"
          },
          {
            "name": "old-translator",
            "category": "user",
            "archived_at": "2026-04-23T10:00:00Z",
            "reason": "consolidated with translator",
            "size_bytes": 8192
          },
          {
            "name": "minimal"
          }
        ]
        """
        let result = try CuratorService.parseListArchived(stdout: json)
        #expect(result.count == 3)
        #expect(result[0].name == "legacy-helper")
        #expect(result[0].category == "templates")
        #expect(result[0].reason == "stale: 91d unused")
        #expect(result[0].sizeBytes == 4521)
        #expect(result[0].archivedAtLabel == "2026-04-22")
        #expect(result[0].path == "/Users/u/.hermes/skills/.archived/legacy-helper")

        // Tolerant: only `name` set on the third row.
        #expect(result[2].name == "minimal")
        #expect(result[2].category == nil)
        #expect(result[2].reason == nil)
        #expect(result[2].archivedAtLabel == "—")
        #expect(result[2].sizeLabel == "—")
    }

    /// `{"archived": [...]}` envelope is also accepted.
    @Test func listArchivedEnvelope() throws {
        let json = """
        {"archived": [
          {"name": "envelope-skill", "size_bytes": 1024}
        ]}
        """
        let result = try CuratorService.parseListArchived(stdout: json)
        #expect(result.count == 1)
        #expect(result[0].name == "envelope-skill")
    }

    /// Text fallback when `--json` isn't supported. Each row carries
    /// the name in column 1 plus k=v chips for the optional fields.
    @Test func listArchivedTextFallback() {
        let text = """
          legacy-helper      archived=2026-04-22 size=4521 reason=stale
          old-translator     archived=2026-04-23 size=8192
          minimal-row
        """
        let result = CuratorService.parseListArchivedText(text)
        #expect(result.count == 3)
        #expect(result[0].name == "legacy-helper")
        #expect(result[0].archivedAt == "2026-04-22")
        #expect(result[0].sizeBytes == 4521)
        #expect(result[0].reason == "stale")
        #expect(result[2].name == "minimal-row")
        #expect(result[2].sizeBytes == nil)
    }

    /// Empty-state sentinel folds to `[]` (parallel to KanbanService's
    /// `"no matching tasks"` handling).
    @Test func listArchivedNoArchivedSentinel() throws {
        let result = try CuratorService.parseListArchived(stdout: "no archived skills\n")
        #expect(result.isEmpty)
    }

    /// Whitespace-only stdout also folds to empty.
    @Test func listArchivedWhitespaceFoldsToEmpty() throws {
        let result = try CuratorService.parseListArchived(stdout: "   \n\n")
        #expect(result.isEmpty)
    }

    /// Decode failure (clearly non-JSON, non-text) throws. We accept
    /// JSON, the envelope, the empty sentinel, or text rows; anything
    /// else surfaces as a `CuratorError.decoding`.
    @Test func listArchivedNonsenseThrows() throws {
        do {
            _ = try CuratorService.parseListArchived(stdout: "{garbage")
            Issue.record("expected decoding throw")
        } catch let error as CuratorError {
            if case .decoding = error {
                // expected
            } else {
                Issue.record("unexpected error \(error)")
            }
        }
    }

    /// Prune dry-run text → idle candidates parsed from the indented rows;
    /// the column-0 header + "(dry run …)" footer are ignored.
    @Test func prunePreviewParsesIdleRows() {
        let out = """
        curator: 3 skill(s) idle >= 90d:
          old-helper                               idle 412d
          scratch-pad                              idle 120d
          one-off-script                           idle 95d

        (dry run — no changes made)
        """
        let summary = CuratorService.parsePrune(out, days: 90)
        #expect(summary.count == 3)
        #expect(summary.days == 90)
        #expect(summary.candidates.first?.name == "old-helper")
        #expect(summary.candidates.first?.idleDays == 412)
        #expect(summary.candidates.last?.name == "one-off-script")
    }

    /// "nothing to prune" (column-0, no indented rows) → empty summary.
    @Test func pruneNothingToPruneIsEmpty() {
        let out = "curator: nothing to prune (no unpinned skills idle >= 90d)"
        let summary = CuratorService.parsePrune(out, days: 90)
        #expect(summary.count == 0)
        #expect(summary.candidates.isEmpty)
        #expect(summary.days == 90)
    }

    /// Live (-y) run prints the same rows plus a column-0 "archived N/M"
    /// footer — the footer is ignored, the candidate rows still parse.
    @Test func pruneLiveRunOutputParsesCandidates() {
        let out = """
        curator: 2 skill(s) idle >= 60d:
          alpha                                    idle 200d
          beta                                     idle 61d

        curator: archived 2/2
        """
        let summary = CuratorService.parsePrune(out, days: 60)
        #expect(summary.count == 2)
        #expect(summary.candidates.map(\.name) == ["alpha", "beta"])
        #expect(summary.candidates.last?.idleDays == 61)
    }

    /// A skill name containing "idle" still parses (we split on the last
    /// " idle " token, so the trailing idle suffix wins).
    @Test func pruneToleratesIdleInName() {
        let out = "  go-idle-watcher                          idle 300d"
        let summary = CuratorService.parsePrune(out, days: 90)
        #expect(summary.candidates.first?.name == "go-idle-watcher")
        #expect(summary.candidates.first?.idleDays == 300)
    }

    /// CRLF line endings (defensive — Hermes prints LF today) still parse:
    /// the trailing CR must not defeat the `idle <N>d` suffix match.
    @Test func pruneToleratesCRLF() {
        let out = "curator: 1 skill(s) idle >= 90d:\r\n  crlf-skill                               idle 150d\r\n"
        let summary = CuratorService.parsePrune(out, days: 90)
        #expect(summary.count == 1)
        #expect(summary.candidates.first?.name == "crlf-skill")
        #expect(summary.candidates.first?.idleDays == 150)
    }

    /// Empty / whitespace stdout → zero summary (no throw).
    @Test func pruneEmptyStaysSafe() {
        let summary = CuratorService.parsePrune("   \n", days: 90)
        #expect(summary.count == 0)
    }

    /// Verify the size label uses the byte formatter (not raw bytes).
    @Test func archivedSkillSizeLabelFormats() {
        let big = HermesCuratorArchivedSkill(name: "x", sizeBytes: 1_500_000)
        // ByteCountFormatter produces a localized label; just verify
        // it's non-empty and not raw "1500000".
        #expect(!big.sizeLabel.isEmpty)
        #expect(big.sizeLabel != "1500000")
    }

    // MARK: - Ledger (v0.20.4, hermes_cli/curator.py:539 `_cmd_ledger`)

    /// Verbatim fixed-width table shape, one plain row + one `absorbed
    /// into` row + one `rollback of` row, plus the trailing hint line —
    /// all reproduced from Python's `f"{...:<14} {...:<12} {...:<8}
    /// {...:<12} {...}"` format so column offsets match exactly.
    @Test func ledgerParsesPopulatedTableWithSuffixArrows() {
        let out = """
        id             when         actor    action       skill
        ab12cd34ef56   2026-08-18   curator  archive      old-helper
        cd34ef56ab12   2026-08-17   agent    absorb       scratch-pad  → absorbed into 'notes'
        ef56ab12cd34   2026-08-16   user     rollback     old-helper  → rollback of ab12cd34ef56

        Roll back a single mutation with `hermes curator rollback <id>`; whole-tree snapshots remain available via `hermes curator rollback --list`.
        """
        let rows = CuratorService.parseLedger(out)
        #expect(rows.count == 3)

        #expect(rows[0].entryID == "ab12cd34ef56")
        #expect(rows[0].whenLabel == "2026-08-18")
        #expect(rows[0].actor == "curator")
        #expect(rows[0].action == "archive")
        #expect(rows[0].skill == "old-helper")
        #expect(rows[0].absorbedInto == nil)
        #expect(rows[0].rollbackTarget == nil)

        #expect(rows[1].entryID == "cd34ef56ab12")
        #expect(rows[1].actor == "agent")
        #expect(rows[1].action == "absorb")
        #expect(rows[1].skill == "scratch-pad")
        #expect(rows[1].absorbedInto == "notes")
        #expect(rows[1].rollbackTarget == nil)

        #expect(rows[2].entryID == "ef56ab12cd34")
        #expect(rows[2].actor == "user")
        #expect(rows[2].action == "rollback")
        #expect(rows[2].skill == "old-helper")
        #expect(rows[2].absorbedInto == nil)
        #expect(rows[2].rollbackTarget == "ab12cd34ef56")
    }

    /// Empty-state sentinel folds to `[]`, not a parse error.
    @Test func ledgerEmptyStateIsEmpty() {
        let out = "curator: ledger is empty (or skills.ledger is disabled)."
        let rows = CuratorService.parseLedger(out)
        #expect(rows.isEmpty)
    }

    // MARK: - Purge (v0.20.4, hermes_cli/curator.py:570 `_cmd_purge`)

    /// Disabled sentinel (`curator.archive_ttl_days` is 0, no `--days`
    /// override) is recognized so the service can surface it via
    /// `disabledReason` instead of throwing.
    @Test func purgeDisabledMessageIsRecognized() {
        let out = "curator: purge disabled (curator.archive_ttl_days is 0). Set the config key or pass --days N to purge archives older than N days."
        let disabled = CuratorService.parsePurgeDisabled(out)
        #expect(disabled == out)
    }

    @Test func purgeNonDisabledOutputIsNotFlagged() {
        let out = "Archived skills older than 90d:\n  old-helper\n(dry run — nothing deleted)"
        #expect(CuratorService.parsePurgeDisabled(out) == nil)
    }

    /// Dry-run preview: candidate rows + the trailing "(dry run …)" line,
    /// which must not be mistaken for a candidate.
    @Test func purgeDryRunOutputParsesCandidates() {
        let out = """
        Archived skills older than 90d:
          old-helper
          scratch-pad
        (dry run — nothing deleted)
        """
        let summary = CuratorService.parsePurge(out, days: 90)
        #expect(summary.count == 2)
        #expect(summary.candidates.map(\.name) == ["old-helper", "scratch-pad"])
        #expect(summary.days == 90)
        #expect(summary.purgedCount == nil)
    }

    /// Confirmed live run: same candidate rows, but the footer is
    /// `curator: purged N archived skill(s). Ledger entries recorded.`
    /// instead of the dry-run sentinel — `purgedCount` must reflect it.
    @Test func purgeConfirmedRunOutputParsesPurgedCount() {
        let out = """
        Archived skills older than 90d:
          old-helper
          scratch-pad
        curator: purged 2 archived skill(s). Ledger entries recorded.
        """
        let summary = CuratorService.parsePurge(out, days: 90)
        #expect(summary.count == 2)
        #expect(summary.purgedCount == 2)
        #expect(summary.days == 90)
    }

    /// No-candidates sentinel → empty summary, effective days parsed from
    /// the message even when the caller didn't pass an explicit override.
    @Test func purgeNoCandidatesParsesEffectiveDays() {
        let out = "curator: no archived skills older than 45d."
        let summary = CuratorService.parsePurge(out, days: nil)
        #expect(summary.count == 0)
        #expect(summary.purgedCount == nil)
    }

    // MARK: - Rollback (v0.20.4, hermes_cli/curator.py:660 `_cmd_rollback`, entry_id form)

    /// Successful single-mutation rollback: header block fields + the
    /// trailing `curator: <message>` success line.
    @Test func rollbackEntrySuccessParsesFields() {
        let out = """
        Rollback target: ledger entry ab12cd34ef56
          action: archive
          skill:  old-helper
          actor:  curator
          when:   2026-08-18T10:00:00Z
          files:  3
        curator: restored 3 file(s) from ledger entry ab12cd34ef56
        """
        let result = CuratorService.parseRollbackEntry(out, entryID: "ab12cd34ef56")
        #expect(result != nil)
        #expect(result?.succeeded == true)
        #expect(result?.action == "archive")
        #expect(result?.skill == "old-helper")
        #expect(result?.actor == "curator")
        #expect(result?.filesTouched == 3)
        #expect(result?.message == "restored 3 file(s) from ledger entry ab12cd34ef56")
    }

    /// Unknown entry id → failure result, not a thrown decode error.
    @Test func rollbackEntryUnknownIDParsesAsFailure() {
        let out = "curator: no ledger entry 'bogus-id'. See `hermes curator ledger` for entry ids, or use `--id <snapshot>` for whole-tree snapshot rollback."
        let result = CuratorService.parseRollbackEntry(out, entryID: "bogus-id")
        #expect(result != nil)
        #expect(result?.succeeded == false)
        #expect(result?.message?.contains("no ledger entry 'bogus-id'") == true)
    }

    /// Rollback-mechanism failure (target found, restore itself failed).
    @Test func rollbackEntryMechanismFailureParsesAsFailure() {
        let out = """
        Rollback target: ledger entry ab12cd34ef56
          action: archive
          skill:  old-helper
          actor:  curator
          when:   2026-08-18T10:00:00Z
          files:  3
        curator: rollback failed — blob missing for old-helper/SKILL.md
        """
        let result = CuratorService.parseRollbackEntry(out, entryID: "ab12cd34ef56")
        #expect(result != nil)
        #expect(result?.succeeded == false)
        #expect(result?.message == "blob missing for old-helper/SKILL.md")
    }

    /// Output with no recognizable `curator:` line at all (genuine
    /// transport failure) must return `nil` so the caller falls back to
    /// throwing via `ensureSuccess`, not a fabricated result.
    @Test func rollbackEntryUnrecognizedOutputReturnsNil() {
        let result = CuratorService.parseRollbackEntry("", entryID: "ab12cd34ef56")
        #expect(result == nil)
    }
}
