import Testing
import Foundation
@testable import ScarfCore

/// Pure-logic tests for the v2.7.5 Kanban model layer. The actor-based
/// `KanbanService` is exercised separately under integration tests
/// since it spawns `hermes kanban …` subprocesses; this suite covers
/// the wire-shape contracts and the synchronous transition planner.
@Suite struct KanbanModelsTests {

    // MARK: - HermesKanbanTask decoding

    @Test func decodeListRow() throws {
        let json = """
        {
          "id": "t_9f2a",
          "title": "Investigate flaky test",
          "body": "Repro on CI but not local.",
          "assignee": "researcher",
          "status": "running",
          "priority": 50,
          "tenant": "scarf:demo",
          "workspace_kind": "scratch",
          "workspace_path": "/Users/alan/.hermes/kanban/workspaces/t_9f2a",
          "created_by": "user",
          "created_at": "2026-05-06T12:00:00Z",
          "started_at": "2026-05-06T12:01:00Z",
          "skills": ["debugging"],
          "idempotency_key": "abc",
          "last_heartbeat_at": "2026-05-06T12:05:00Z",
          "max_runtime_seconds": 1800,
          "current_run_id": 1
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.id == "t_9f2a")
        #expect(task.assignee == "researcher")
        #expect(task.status == "running")
        #expect(task.tenant == "scarf:demo")
        #expect(task.workspaceKind == "scratch")
        #expect(task.skills == ["debugging"])
        // P18: `idempotency_key` / `max_runtime_seconds` / `current_run_id`
        // are kanban DB columns no tagged release has ever emitted
        // (`_TASK_DICT_FIELDS`, `hermes_cli/kanban_output.py:18-24`), so
        // they are no longer modelled. The fixture still carries them —
        // an unknown key must be TOLERATED, not fatal.
        // A row without `session_id` (pre-v0.15 host, or a CLI/dashboard
        // -created task) decodes with `sessionId == nil` — pins the
        // tolerant-decode contract.
        #expect(task.sessionId == nil)
    }

    @Test func decodeV015TaskFields() throws {
        // v0.15 `list --json` exposes branch_name / workflow_template_id /
        // current_step_key; model_override comes from `show --json` but is
        // still decoded tolerantly.
        let json = """
        {
          "id": "t_v015",
          "title": "worktree task",
          "status": "running",
          "branch_name": "feat/x",
          "workflow_template_id": "wf_translate",
          "current_step_key": "draft",
          "model_override": "claude-opus-4.7"
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.branchName == "feat/x")
        #expect(task.workflowTemplateId == "wf_translate")
        #expect(task.currentStepKey == "draft")
        #expect(task.modelOverride == "claude-opus-4.7")
    }

    @Test func decodeV015TaskFieldsAbsentBecomesNil() throws {
        // A row missing the v0.15 fields (pre-v0.15 host, or a list row
        // that doesn't carry model_override) decodes with all nil —
        // pins the tolerant-decode contract.
        let json = """
        {"id": "t_legacy15", "title": "no v0.15 fields", "status": "ready"}
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.branchName == nil)
        #expect(task.workflowTemplateId == nil)
        #expect(task.currentStepKey == nil)
        #expect(task.modelOverride == nil)
    }

    @Test func goalModeIsNeverOnTheWire() throws {
        // Drift alarm. `goal_mode` / `goal_max_turns` are REAL columns on
        // Hermes's `tasks` table (`hermes_cli/kanban_db.py:922-925`,
        // v2026.9.7) but are NOT in `_TASK_DICT_FIELDS`
        // (`hermes_cli/kanban_output.py:18-24`), so no `--json` surface has
        // ever emitted them and Scarf's goal badge could never render.
        // The decode paths are gone; a row carrying the keys must still
        // decode (forward compat), it just carries nothing extra.
        let json = """
        {
          "id": "t_v016",
          "title": "goal-mode task",
          "status": "running",
          "goal_mode": true,
          "goal_max_turns": 5
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.id == "t_v016")
        #expect(task.status == "running")
    }

    @Test func decodeSessionId() throws {
        // v0.15 stamps the originating ACP session id on tasks created
        // inside an agent loop; `hermes kanban list --json` exposes it.
        let json = """
        {
          "id": "t_abc",
          "title": "Created by a chat",
          "status": "running",
          "session_id": "acp-sess-123"
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.sessionId == "acp-sess-123")
    }

    // MARK: - LocalTransport subprocess environment

    @Test func decodeUnixIntegerTimestamps() throws {
        // Real `hermes kanban create --json` output uses Unix integer
        // seconds for created_at / started_at — its SQLite columns are
        // INTEGER. The decoder must normalize them into ISO-8601 strings
        // so downstream code works with one type.
        let json = """
        {
          "id": "t_2a0be199",
          "title": "smoke",
          "status": "ready",
          "priority": 50,
          "created_at": 1778160614,
          "started_at": null,
          "skills": []
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.id == "t_2a0be199")
        // Should have been converted from Unix int to an ISO-8601 string
        // — exact format is platform-stable.
        #expect(task.createdAt?.contains("2026") == true)
        #expect(task.startedAt == nil)
    }

    @Test func decodeMissingOptionalsBecomesNil() throws {
        // Hermes emits a minimal task object when many fields are
        // absent; the decoder must tolerate it.
        let json = """
        { "id": "t_x", "title": "ok", "status": "todo" }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.id == "t_x")
        #expect(task.assignee == nil)
        #expect(task.priority == nil)
        #expect(task.tenant == nil)
        #expect(task.skills.isEmpty)
    }

    // MARK: - Status / column projection

    @Test func statusToColumnMapping() {
        #expect(KanbanStatus.from("triage").boardColumn == .triage)
        #expect(KanbanStatus.from("todo").boardColumn == .upNext)
        #expect(KanbanStatus.from("ready").boardColumn == .upNext)
        #expect(KanbanStatus.from("running").boardColumn == .running)
        #expect(KanbanStatus.from("blocked").boardColumn == .blocked)
        #expect(KanbanStatus.from("done").boardColumn == .done)
        #expect(KanbanStatus.from("archived").boardColumn == .archived)
        #expect(KanbanStatus.from("WHATEVER").boardColumn == .upNext) // unknown → upNext
    }

    @Test func statusV015NewCases() {
        // v0.15 VALID_STATUSES adds `scheduled` and `review`.
        #expect(KanbanStatus.from("scheduled") == .scheduled)
        #expect(KanbanStatus.from("review") == .review)
        // Case-insensitive, mirroring `from(_:)`.
        #expect(KanbanStatus.from("SCHEDULED") == .scheduled)
    }

    // MARK: - KanbanCreateRequest argv assembly

    @Test func createRequestArgvIncludesAllFields() {
        let req = KanbanCreateRequest(
            title: "Translate doc",
            body: "Spanish, please",
            assignee: "researcher",
            parentIds: ["t_parent"],
            workspace: .directory("/tmp/proj"),
            tenant: "scarf:demo",
            priority: 75,
            triage: true,
            idempotencyKey: "key-1",
            maxRuntimeSeconds: 1800,
            createdBy: "alan",
            skills: ["translation", "github-code-review"]
        )
        let argv = req.argv()
        #expect(HermesCLIOption.contains("--body", in: argv))
        #expect(HermesCLIOption.contains("--assignee", in: argv))
        #expect(HermesCLIOption.contains("--parent", in: argv))
        #expect(HermesCLIOption.contains("--workspace", in: argv))
        #expect(HermesCLIOption.value(of: "--workspace", in: argv) == "dir:/tmp/proj")
        #expect(HermesCLIOption.value(of: "--tenant", in: argv) == "scarf:demo")
        #expect(HermesCLIOption.value(of: "--priority", in: argv) == "75")
        #expect(argv.contains("--triage"))
        #expect(HermesCLIOption.contains("--idempotency-key", in: argv))
        #expect(HermesCLIOption.contains("--max-runtime", in: argv))
        #expect(HermesCLIOption.contains("--created-by", in: argv))
        #expect(HermesCLIOption.contains("--skill", in: argv))
        #expect(argv.last == "Translate doc") // positional title is last
        #expect(argv.contains("--json"))
    }

    @Test func createRequestArgvOmitsAbsent() {
        let req = KanbanCreateRequest(title: "minimal")
        let argv = req.argv()
        #expect(argv.contains("--json"))
        #expect(argv.last == "minimal")
        #expect(!HermesCLIOption.contains("--body", in: argv))
        #expect(!HermesCLIOption.contains("--assignee", in: argv))
        #expect(!argv.contains("--triage"))
        // `--branch` is gone entirely (P56).
        #expect(!HermesCLIOption.contains("--branch", in: argv))
    }

    /// P56. `--branch` was emitted UNGATED and first exists at `v2026.5.28`
    /// (0.15.0) — absent from `hermes_cli/kanban.py` at `v2026.5.16`
    /// (0.14.0), where argparse would have exited 2 on the whole create. No
    /// production caller ever set it, so the parameter was deleted rather
    /// than gated. This is the alarm on that: a `--branch` back in the argv
    /// means the flag returned without its capability floor.
    @Test func createRequestArgvNeverCarriesBranch() {
        let req = KanbanCreateRequest(
            title: "worktree task",
            workspace: .worktreePath("/tmp/wt")
        )
        let argv = req.argv()
        #expect(!HermesCLIOption.contains("--branch", in: argv))
        // `worktree:<path>` workspace spec still round-trips.
        #expect(HermesCLIOption.value(of: "--workspace", in: argv) == "worktree:/tmp/wt")
    }

    @Test func createRequestArgvIncludesCompletionContract() {
        // v0.21.1 `--completion-contract` (hermes_cli/kanban_parser.py:189).
        let req = KanbanCreateRequest(title: "gated", completionContract: "nousresearch/hermes")
        let argv = req.argv()
        #expect(HermesCLIOption.value(of: "--completion-contract", in: argv) == "nousresearch/hermes")
        // Still behind `--` so the title stays a positional.
        #expect(argv.last == "gated")
        // Absent (and empty) means "send no flag" — Hermes keeps its own
        // local-only default rather than Scarf asserting it.
        #expect(!HermesCLIOption.contains("--completion-contract", in: KanbanCreateRequest(title: "x").argv()))
        #expect(!HermesCLIOption.contains("--completion-contract",
                                          in: KanbanCreateRequest(title: "x", completionContract: "").argv()))
    }

    @Test func taskDecodesV0211FieldsAndToleratesTheirAbsence() {
        // v0.21.1 adds `completion_contract` + `last_failure_error` to the
        // `list --json` task dict (hermes_cli/kanban_output.py:18-24). A
        // pre-v0.21.1 row carries neither key and must still decode.
        let withFields = Data("""
        {"id": "t1", "title": "gated", "status": "blocked",
         "completion_contract": "nousresearch/hermes",
         "last_failure_error": "worker exited (code 1) before completing"}
        """.utf8)
        let a = try! JSONDecoder().decode(HermesKanbanTask.self, from: withFields)
        #expect(a.completionContract == "nousresearch/hermes")
        #expect(a.lastFailureError == "worker exited (code 1) before completing")

        let legacy = Data("""
        {"id": "t2", "title": "old", "status": "todo"}
        """.utf8)
        let b = try! JSONDecoder().decode(HermesKanbanTask.self, from: legacy)
        #expect(b.completionContract == nil)
        #expect(b.lastFailureError == nil)
        // And a null (Hermes clears the column on a successful run).
        let cleared = Data("""
        {"id": "t3", "title": "ok", "status": "done",
         "completion_contract": null, "last_failure_error": null}
        """.utf8)
        let c = try! JSONDecoder().decode(HermesKanbanTask.self, from: cleared)
        #expect(c.lastFailureError == nil)
    }

    // MARK: - KanbanListFilter argv

    @Test func listFilterEmptyOnlyJSON() {
        let argv = KanbanListFilter.all.argv()
        #expect(argv == ["--json"])
    }

    @Test func listFilterStatusFlag() {
        let argv = KanbanListFilter(status: .running).argv()
        #expect(HermesCLIOption.value(of: "--status", in: argv) == "running")
    }

    @Test func listFilterTenantPasses() {
        let argv = KanbanListFilter(tenant: "scarf:demo").argv()
        #expect(HermesCLIOption.value(of: "--tenant", in: argv) == "scarf:demo")
    }

    @Test func listFilterArchivedAndMine() {
        let argv = KanbanListFilter(includeArchived: true, mineOnly: true).argv()
        #expect(argv.contains("--mine"))
        #expect(argv.contains("--archived"))
    }

    @Test func listFilterSessionPasses() {
        let argv = KanbanListFilter(session: "acp-sess-123").argv()
        #expect(HermesCLIOption.value(of: "--session", in: argv) == "acp-sess-123")
        // The empty default filter never emits `--session`.
        #expect(!HermesCLIOption.contains("--session", in: KanbanListFilter.all.argv()))
    }

    @Test func listFilterEmptySessionDropped() {
        // Empty string is treated as "no session" (mirrors the
        // non-empty guard on `--session`), so it isn't emitted.
        let argv = KanbanListFilter(session: "").argv()
        #expect(!HermesCLIOption.contains("--session", in: argv))
    }

    @Test func listFilterSessionAndsWithTenant() {
        let argv = KanbanListFilter(tenant: "scarf:demo", session: "acp-x").argv()
        #expect(HermesCLIOption.value(of: "--tenant", in: argv) == "scarf:demo")
        #expect(HermesCLIOption.value(of: "--session", in: argv) == "acp-x")
    }

    @Test func listFilterSortPasses() {
        // v0.15 `--sort` is passed through verbatim (not enforced).
        let argv = KanbanListFilter(sort: "priority-desc").argv()
        #expect(HermesCLIOption.value(of: "--sort", in: argv) == "priority-desc")
        // The empty default filter never emits `--sort`.
        #expect(!HermesCLIOption.contains("--sort", in: KanbanListFilter.all.argv()))
    }

    // MARK: - Transition planning

    @Test func planUpNextToRunningDispatches() throws {
        // `dispatch`, not `claim`. See KanbanTransitionStep doc for the
        // rationale — claim doesn't spawn a worker; the dispatcher does.
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .upNext, to: .running),
            caps: .empty
        )
        #expect(plan.steps == [.dispatch])
    }

    @Test func planRunningToBlockedRequiresReason() throws {
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .running, to: .blocked),
            caps: .empty
        )
        #expect(plan.requiresBlockReason)
    }

    @Test func planBlockedToRunningChainsTwoVerbs() throws {
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .blocked, to: .running),
            caps: .empty
        )
        // unblock then dispatch
        #expect(plan.steps.count == 2)
        if case .unblock = plan.steps.first {} else {
            Issue.record("expected first step .unblock, got \(plan.steps)")
        }
        if case .dispatch = plan.steps.last {} else {
            Issue.record("expected last step .dispatch, got \(plan.steps)")
        }
    }

    @Test func planDoneToAnythingForbidden() {
        do {
            _ = try KanbanService.plan(
                for: KanbanTransition(from: .done, to: .upNext),
                caps: .empty
            )
            Issue.record("expected error")
        } catch let err as KanbanError {
            if case .forbiddenTransition = err {
                // ok
            } else {
                Issue.record("wrong error: \(err)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func planTriageToUpNextForbidden() {
        do {
            _ = try KanbanService.plan(
                for: KanbanTransition(from: .triage, to: .upNext),
                caps: .empty
            )
            Issue.record("expected error")
        } catch let err as KanbanError {
            if case .forbiddenTransition = err {
                // ok
            } else {
                Issue.record("wrong error: \(err)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func planNoOpProducesEmptyPlan() throws {
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .running, to: .running),
            caps: .empty
        )
        #expect(plan.steps.isEmpty)
    }

    // MARK: - Stats glance

    @Test func glanceStringJoinsNonEmptyBuckets() {
        let stats = HermesKanbanStats(
            byStatus: ["todo": 12, "running": 3, "blocked": 5, "done": 0]
        )
        #expect(stats.glanceString == "12 todo · 3 running · 5 blocked")
        #expect(stats.activeCount == 12 + 3 + 5)
    }

    @Test func glanceStringEmptyWhenZero() {
        let stats = HermesKanbanStats(byStatus: [:])
        #expect(stats.glanceString.isEmpty)
        #expect(stats.activeCount == 0)
    }

    // MARK: - v0.13 (Hermes 2026.5.7) tolerant decode
    //
    // The contract these tests pin: a v0.13 host's task / run / detail
    // JSON decodes successfully WITH the new fields populated, AND a
    // pre-v0.13 (v0.12) host's task / run / detail JSON decodes
    // successfully WITHOUT the new fields (everything resolves to nil
    // or empty). Drift from this pair = a regression that bites every
    // user not yet on Hermes v0.13.

    @Test func decodeV013TaskFields() throws {
        // `max_retries` is the only one of the "v0.13 reliability" fields
        // that is real on the wire (`_TASK_DICT_FIELDS`,
        // `hermes_cli/kanban_output.py:18-24` at v2026.9.7).
        let json = """
        {
          "id": "t_v013",
          "title": "v0.13 task",
          "status": "blocked",
          "max_retries": 5
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.maxRetries == 5)
    }

    @Test func hallucinationGateFieldsAreNotDecoded() throws {
        // Drift alarm for the surface deleted in the 2026-09 whole-surface
        // audit. `hallucination_gate_status` / `auto_blocked_reason` /
        // a task-level `diagnostics` array are emitted by NO Hermes version
        // (whole-tree `git grep` over every tag through v2026.9.7 returns
        // zero hits for the first two; `_TASK_DICT_FIELDS` has never
        // carried `diagnostics`). A row inventing them must decode without
        // error and without reviving any of it — if a future Hermes DOES
        // start emitting them, this test still passes and the surface is
        // re-derived deliberately, not by accident.
        let json = """
        {
          "id": "t_v013b",
          "title": "invented fields",
          "status": "blocked",
          "auto_blocked_reason": "worker exited without `kanban complete`",
          "hallucination_gate_status": "pending",
          "diagnostics": [{"kind": "worker_exit_no_complete"}]
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.id == "t_v013b")
        #expect(task.status == "blocked")
        // Nothing on the model can carry them any more: the properties are
        // gone, so this compiling at all is half the assertion.
        let encoded = try JSONEncoder().encode(task)
        let round = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!round.contains("hallucination_gate_status"))
        #expect(!round.contains("auto_blocked_reason"))
        #expect(!round.contains("diagnostics"))
    }

    @Test func decodeV012TaskHasNoNewFields() throws {
        // The most damaging failure mode is a v0.12 user upgrading Scarf
        // and having the board stop loading because a newer field is
        // required. Pin the contract.
        let json = """
        {"id": "t_legacy", "title": "v0.12 task", "status": "ready"}
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.maxRetries == nil)
        #expect(task.lastFailureError == nil)
        #expect(task.completionContract == nil)
    }

    @Test func diagnosticKindMirrorMatchesHermesRules() {
        // Mirrors `DIAGNOSTIC_KINDS` (`hermes_cli/kanban_diagnostics.py`,
        // v2026.9.7). The pre-audit mirror listed seven kinds
        // (`heartbeat_stalled`, `retry_cap_hit`, `darwin_zombie_detected`, …)
        // that NO rule in that module has ever emitted.
        #expect(KanbanDiagnosticKind.from("repeated_failures") == .repeatedFailures)
        #expect(KanbanDiagnosticKind.from("REPEATED_CRASHES") == .repeatedCrashes)
        #expect(KanbanDiagnosticKind.from("stranded_in_ready") == .strandedInReady)
        #expect(KanbanDiagnosticKind.from("hallucinated_cards") == .hallucinatedCards)
        // Retired inventions must NOT resolve.
        #expect(KanbanDiagnosticKind.from("heartbeat_stalled") == .unknown)
        #expect(KanbanDiagnosticKind.from("retry_cap_hit") == .unknown)
        #expect(KanbanDiagnosticKind.from("future_kind_v99") == .unknown)
    }

    @Test func diagnosticSeverityComesOffTheWire() {
        #expect(KanbanDiagnosticSeverity.from("critical") == .critical)
        #expect(KanbanDiagnosticSeverity.from("ERROR") == .error)
        #expect(KanbanDiagnosticSeverity.from("warning") == .warning)
        // An unknown tier must never render as the loudest one.
        #expect(KanbanDiagnosticSeverity.from("catastrophic") == .warning)
    }

    @Test func createRequestArgvIncludesMaxRetries() {
        let req = KanbanCreateRequest(title: "t", maxRetries: 5)
        let argv = req.argv()
        #expect(HermesCLIOption.value(of: "--max-retries", in: argv) == "5")
    }

    @Test func createRequestArgvOmitsMaxRetriesWhenAbsent() {
        let req = KanbanCreateRequest(title: "t")
        let argv = req.argv()
        #expect(!HermesCLIOption.contains("--max-retries", in: argv))
    }

    @Test func runRowsCarryNoDiagnostics() throws {
        // Drift alarm: `_SHOW_RUN_FIELDS` / `_RUNS_RUN_FIELDS`
        // (`hermes_cli/kanban_output.py:25-32`, v2026.9.7) have never had a
        // `diagnostics` key. A run row that invents one still decodes.
        let json = """
        {
          "id": 1,
          "task_id": "t_x",
          "status": "failed",
          "started_at": 1778160000,
          "ended_at": 1778160300,
          "outcome": "crashed",
          "error": "OOM",
          "diagnostics": [{"kind": "retry_cap_hit"}],
          "failure_count": 3
        }
        """
        let run = try JSONDecoder().decode(HermesKanbanRun.self, from: Data(json.utf8))
        #expect(run.id == 1)
        #expect(run.outcome == "crashed")
        let round = String(data: try JSONEncoder().encode(run), encoding: .utf8) ?? ""
        #expect(!round.contains("diagnostics"))
        // P18: `failure_count` joins `diagnostics` — neither
        // `_SHOW_RUN_FIELDS` nor `_RUNS_RUN_FIELDS` (:25-32) has ever
        // carried it, so it is decoded by nobody and re-emitted by nobody.
        #expect(!round.contains("failure_count"))
    }

    @Test func decodeMinimalRun() throws {
        let json = """
        {"id": 1, "task_id": "t_x", "status": "running", "started_at": 1778160000}
        """
        let run = try JSONDecoder().decode(HermesKanbanRun.self, from: Data(json.utf8))
        #expect(run.id == 1)
        #expect(run.status == "running")
    }

    @Test func taskDetailEnvelopeHasNoDiagnostics() throws {
        // `_cmd_show`'s envelope (`hermes_cli/kanban.py:493-498`, v2026.9.7)
        // is task / latest_summary / parents / children / comments / events /
        // runs — never `diagnostics`. An envelope that invents one must
        // still decode, and must not resurrect the field.
        let json = """
        {
          "task": {"id": "t_y", "title": "y", "status": "blocked"},
          "comments": [],
          "events": [],
          "diagnostics": [{"kind": "repeated_failures"}]
        }
        """
        let detail = try JSONDecoder().decode(HermesKanbanTaskDetail.self, from: Data(json.utf8))
        #expect(detail.task.id == "t_y")
        #expect(detail.comments.isEmpty)
    }

    // MARK: - `kanban diagnostics --json` (the real diagnostics surface)

    @Test func decodeDiagnosticsEnvelopeVerbatimFixture() throws {
        // Verbatim shape of `hermes kanban diagnostics --json`
        // (`hermes_cli/kanban.py:678-681` composing
        // `Diagnostic.to_dict()` = `dataclasses.asdict` of
        // `kanban_diagnostics.py:48-64`, v2026.9.7). Timestamps are Unix
        // integer seconds; `actions` / `data` are present and deliberately
        // not decoded.
        let json = """
        [
          {
            "task_id": "t_abc123",
            "title": "Ship the parser",
            "status": "blocked",
            "assignee": "worker-1",
            "diagnostics": [
              {
                "kind": "repeated_failures",
                "severity": "critical",
                "title": "Agent failed x3: ModuleNotFoundError: no module named 'foo'",
                "detail": "This task has failed 3 times in a row (most recent: failed).",
                "actions": [
                  {"kind": "reclaim", "label": "Reclaim task", "payload": {}, "suggested": true}
                ],
                "first_seen_at": 1778160614,
                "last_seen_at": 1778160614,
                "count": 3,
                "run_id": null,
                "data": {"consecutive_failures": 3}
              },
              {
                "kind": "stranded_in_ready",
                "severity": "warning",
                "title": "Ready for 2h with no worker",
                "detail": "No profile has claimed this task.",
                "actions": [],
                "first_seen_at": 0,
                "last_seen_at": 1778160000,
                "count": 1,
                "run_id": 7,
                "data": {}
              }
            ]
          }
        ]
        """
        let entries = try JSONDecoder().decode([HermesKanbanDiagnosticsEntry].self, from: Data(json.utf8))
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.taskId == "t_abc123")
        #expect(entry.diagnostics.count == 2)

        let first = try #require(entry.diagnostics.first)
        #expect(first.kind == "repeated_failures")
        #expect(first.severity == "critical")
        #expect(first.count == 3)
        #expect(first.runId == nil)
        #expect(first.displayLabel.hasPrefix("Agent failed x3"))
        // Unix seconds normalize to ISO-8601 like every other Kanban model.
        #expect(first.lastSeenAt?.contains("2026") == true)

        let second = try #require(entry.diagnostics.last)
        #expect(second.runId == 7)
        // `first_seen_at: 0` means "unset" — never render 1970.
        #expect(second.firstSeenAt == nil)
    }

    @Test func diagnosticFallsBackToKindWhenTitleEmpty() throws {
        let json = """
        {"kind": "block_unblock_cycling", "severity": "warning", "title": "", "detail": "", "count": 1}
        """
        let diag = try JSONDecoder().decode(HermesKanbanDiagnostic.self, from: Data(json.utf8))
        #expect(diag.displayLabel == "block_unblock_cycling")
    }

    @Test func emptyDiagnosticsBoardDecodesToNoEntries() throws {
        // A healthy board prints `[]` — must not be read as an error.
        let entries = try JSONDecoder().decode([HermesKanbanDiagnosticsEntry].self, from: Data("[]".utf8))
        #expect(entries.isEmpty)
    }

    @Test func diagnosticsArgvFleetAndTaskScoped() {
        // `hermes_cli/kanban_parser.py:251-256` (v2026.9.7): the subcommand
        // takes `--json`, an optional `--task <id>`, and `--severity`.
        // `--board` stays a GLOBAL flag right after `kanban`.
        #expect(KanbanService.diagnosticsArgv() == ["kanban", "diagnostics", "--json"])
        // P42: every option value Scarf composes is the single-token
        // `--flag=value` form, so a task id or board slug beginning with a
        // dash cannot be read as an option string (argparse exit 2).
        #expect(KanbanService.diagnosticsArgv(taskId: "t_1")
                == ["kanban", "diagnostics", "--json", "--task=t_1"])
        #expect(KanbanService.diagnosticsArgv(board: "ops", taskId: "t_1")
                == ["kanban", "--board=ops", "diagnostics", "--json", "--task=t_1"])
        // Empty task id must not emit a bare `--task`.
        #expect(KanbanService.diagnosticsArgv(taskId: "") == ["kanban", "diagnostics", "--json"])
    }

    // MARK: - Failure limit

    @Test func hermesDefaultFailureLimitMatchesDispatcher() {
        // `DEFAULT_FAILURE_LIMIT = 2` (`hermes_cli/kanban_db_dispatch.py:33`,
        // v2026.9.7). The create sheet used to claim "Defaults to 3".
        #expect(KanbanCreateRequest.hermesDefaultFailureLimit == 2)
    }

}

/// `LocalTransport.subprocessEnvironment` tests, isolated into their own
/// `.serialized` suite (t-aud31). Both mutate the process-global
/// `LocalTransport.environmentEnricher`; run in parallel (the default), one
/// test's enricher clobbered the other's mid-assertion — the
/// `ANTHROPIC_API_KEY → nil` flake. `.serialized` runs them one at a time, and
/// each still save/restores the global via `defer`. Mirrors how
/// `M5FeatureVMTests` serializes the `ServerContext.sshTransportFactory` global.
/// (These were previously mislocated in `KanbanModelsTests`.)
@Suite(.serialized) struct LocalTransportEnvTests {

    @Test func localTransportSubprocessEnvIncludesExecutableDir() {
        // GUI-launched Scarf would otherwise hand subprocesses
        // `/usr/bin:/bin:/usr/sbin:/sbin`, which doesn't include
        // `~/.local/bin` — so when Hermes's kanban dispatcher
        // spawns a worker by bare name, it fails with
        // `executable not found on PATH` and the run records
        // `outcome=spawn_failed`. Unblock by always making sure
        // the directory of the executable we're launching is on
        // PATH for the child.
        let previous = LocalTransport.environmentEnricher
        defer { LocalTransport.environmentEnricher = previous }
        LocalTransport.environmentEnricher = nil

        let env = LocalTransport.subprocessEnvironment(
            forExecutable: "/Users/alanwizemann/.local/bin/hermes"
        )
        let path = env["PATH"] ?? ""
        #expect(path.contains("/Users/alanwizemann/.local/bin"))
    }

    @Test func localTransportSubprocessEnvLetsEnricherWinPATH() {
        let previous = LocalTransport.environmentEnricher
        defer { LocalTransport.environmentEnricher = previous }
        LocalTransport.environmentEnricher = {
            // Simulate a login-shell probe returning a fuller PATH +
            // some credential env. The enricher's PATH must override
            // the GUI-process PATH.
            return [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/Users/me/.local/bin",
                "ANTHROPIC_API_KEY": "sk-test-fake"
            ]
        }
        let env = LocalTransport.subprocessEnvironment(
            forExecutable: "/usr/local/bin/hermes"
        )
        // Enricher's PATH wins (PATH is the whole point of running it).
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        // Credential env is forwarded (process env didn't have it).
        #expect(env["ANTHROPIC_API_KEY"] == "sk-test-fake")
    }
}
