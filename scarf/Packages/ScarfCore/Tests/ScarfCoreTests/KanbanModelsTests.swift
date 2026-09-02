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
        #expect(task.idempotencyKey == "abc")
        #expect(task.maxRuntimeSeconds == 1800)
        #expect(task.currentRunId == 1)
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

    @Test func decodeV016GoalModeFields() throws {
        // v0.16 `list --json` / `show --json` expose goal_mode + the
        // optional goal_max_turns turn budget for Ralph-style goal loops.
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
        #expect(task.goalMode == true)
        #expect(task.goalMaxTurns == 5)
    }

    @Test func decodeV016GoalModeFieldsAbsentBecomesNil() throws {
        // A row missing the v0.16 goal fields (pre-v0.16 host, or a
        // one-shot task) decodes with both nil — pins the tolerant-decode
        // contract so a v0.15 user upgrading Scarf doesn't break the board.
        let json = """
        {"id": "t_legacy16", "title": "no v0.16 fields", "status": "ready"}
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.goalMode == nil)
        #expect(task.goalMaxTurns == nil)
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
        #expect(argv.contains("--body"))
        #expect(argv.contains("--assignee"))
        #expect(argv.contains("--parent"))
        #expect(argv.contains("--workspace"))
        #expect(argv.contains("dir:/tmp/proj"))
        #expect(argv.contains("--tenant"))
        #expect(argv.contains("scarf:demo"))
        #expect(argv.contains("--priority"))
        #expect(argv.contains("75"))
        #expect(argv.contains("--triage"))
        #expect(argv.contains("--idempotency-key"))
        #expect(argv.contains("--max-runtime"))
        #expect(argv.contains("--created-by"))
        #expect(argv.contains("--skill"))
        #expect(argv.last == "Translate doc") // positional title is last
        #expect(argv.contains("--json"))
    }

    @Test func createRequestArgvOmitsAbsent() {
        let req = KanbanCreateRequest(title: "minimal")
        let argv = req.argv()
        #expect(argv.contains("--json"))
        #expect(argv.last == "minimal")
        #expect(!argv.contains("--body"))
        #expect(!argv.contains("--assignee"))
        #expect(!argv.contains("--triage"))
        // v0.15 `--branch` is absent by default.
        #expect(!argv.contains("--branch"))
    }

    @Test func createRequestArgvIncludesBranch() {
        // v0.15 worktree tasks carry a `--branch <name>` flag.
        let req = KanbanCreateRequest(
            title: "worktree task",
            workspace: .worktreePath("/tmp/wt"),
            branch: "feat/x"
        )
        let argv = req.argv()
        #expect(argv.contains("--branch"))
        if let i = argv.firstIndex(of: "--branch") {
            #expect(argv[argv.index(after: i)] == "feat/x")
        } else {
            Issue.record("expected --branch in argv: \(argv)")
        }
        // `worktree:<path>` workspace spec round-trips.
        #expect(argv.contains("worktree:/tmp/wt"))
    }

    // MARK: - KanbanListFilter argv

    @Test func listFilterEmptyOnlyJSON() {
        let argv = KanbanListFilter.all.argv()
        #expect(argv == ["--json"])
    }

    @Test func listFilterStatusFlag() {
        let argv = KanbanListFilter(status: .running).argv()
        #expect(argv.contains("--status"))
        #expect(argv.contains("running"))
    }

    @Test func listFilterTenantPasses() {
        let argv = KanbanListFilter(tenant: "scarf:demo").argv()
        #expect(argv.contains("--tenant"))
        #expect(argv.contains("scarf:demo"))
    }

    @Test func listFilterArchivedAndMine() {
        let argv = KanbanListFilter(includeArchived: true, mineOnly: true).argv()
        #expect(argv.contains("--mine"))
        #expect(argv.contains("--archived"))
    }

    @Test func listFilterSessionPasses() {
        let argv = KanbanListFilter(session: "acp-sess-123").argv()
        #expect(argv.contains("--session"))
        #expect(argv.contains("acp-sess-123"))
        // The empty default filter never emits `--session`.
        #expect(!KanbanListFilter.all.argv().contains("--session"))
    }

    @Test func listFilterEmptySessionDropped() {
        // Empty string is treated as "no session" (mirrors the
        // non-empty guard on `--session`), so it isn't emitted.
        let argv = KanbanListFilter(session: "").argv()
        #expect(!argv.contains("--session"))
    }

    @Test func listFilterSessionAndsWithTenant() {
        let argv = KanbanListFilter(tenant: "scarf:demo", session: "acp-x").argv()
        #expect(argv.contains("--tenant"))
        #expect(argv.contains("scarf:demo"))
        #expect(argv.contains("--session"))
        #expect(argv.contains("acp-x"))
    }

    @Test func listFilterSortPasses() {
        // v0.15 `--sort` is passed through verbatim (not enforced).
        let argv = KanbanListFilter(sort: "priority-desc").argv()
        #expect(argv.contains("--sort"))
        #expect(argv.contains("priority-desc"))
        // The two appear adjacently in flag/value order.
        if let i = argv.firstIndex(of: "--sort") {
            #expect(argv[argv.index(after: i)] == "priority-desc")
        } else {
            Issue.record("expected --sort in argv: \(argv)")
        }
        // The empty default filter never emits `--sort`.
        #expect(!KanbanListFilter.all.argv().contains("--sort"))
    }

    // MARK: - Transition planning

    @Test func planUpNextToRunningDispatches() throws {
        // `dispatch`, not `claim`. See KanbanTransitionStep doc for the
        // rationale — claim doesn't spawn a worker; the dispatcher does.
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .upNext, to: .running)
        )
        #expect(plan.steps == [.dispatch])
    }

    @Test func planRunningToBlockedRequiresReason() throws {
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .running, to: .blocked)
        )
        #expect(plan.requiresBlockReason)
    }

    @Test func planBlockedToRunningChainsTwoVerbs() throws {
        let plan = try KanbanService.plan(
            for: KanbanTransition(from: .blocked, to: .running)
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
                for: KanbanTransition(from: .done, to: .upNext)
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
                for: KanbanTransition(from: .triage, to: .upNext)
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
            for: KanbanTransition(from: .running, to: .running)
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
        let json = """
        {
          "id": "t_v013",
          "title": "v0.13 task",
          "status": "blocked",
          "max_retries": 5,
          "auto_blocked_reason": "worker exited without `kanban complete`",
          "hallucination_gate_status": "pending",
          "diagnostics": [
            {"kind": "worker_exit_no_complete", "message": "exit code 0 with no complete call", "detected_at": 1778160614},
            {"kind": "darwin_zombie_detected", "detected_at": "2026-05-09T12:00:00Z"}
          ]
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.maxRetries == 5)
        #expect(task.autoBlockedReason?.contains("kanban complete") == true)
        #expect(task.hallucinationGateStatus == "pending")
        #expect(task.diagnostics.count == 2)
        #expect(task.diagnostics.first?.kind == "worker_exit_no_complete")
        #expect(task.diagnostics.last?.detectedAt?.contains("2026") == true)
    }

    @Test func decodeV012TaskHasNoNewFields() throws {
        // The most damaging failure mode is a v0.12 user upgrading Scarf
        // and having the board stop loading because a v0.13-only field
        // is required. Pin the contract.
        let json = """
        {"id": "t_legacy", "title": "v0.12 task", "status": "ready"}
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.maxRetries == nil)
        #expect(task.autoBlockedReason == nil)
        #expect(task.hallucinationGateStatus == nil)
        #expect(task.diagnostics.isEmpty)
    }

    @Test func decodeMalformedDiagnosticTolerated() throws {
        // If Hermes emits a malformed diagnostics value, the rest of the
        // task should still decode. We use try? on the diagnostics decode
        // so a single bad entry doesn't reject the whole row.
        let json = """
        {
          "id": "t_x",
          "title": "x",
          "status": "ready",
          "diagnostics": "not-an-array"
        }
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.id == "t_x")
        // Diagnostics field couldn't decode — treat as empty.
        #expect(task.diagnostics.isEmpty)
    }

    @Test func hallucinationGateMirrorMapsKnownValues() {
        #expect(KanbanHallucinationGate.from("pending") == .pending)
        #expect(KanbanHallucinationGate.from("verified") == .verified)
        #expect(KanbanHallucinationGate.from("REJECTED") == .rejected)  // case-insensitive
        #expect(KanbanHallucinationGate.from(nil) == nil)
        #expect(KanbanHallucinationGate.from("") == nil)
        // Unknown wire values fall through to nil so the banner stays
        // hidden; future Hermes versions can add `quarantined` etc.
        // without a Scarf release.
        #expect(KanbanHallucinationGate.from("quarantined") == nil)
    }

    @Test func diagnosticKindMirrorMapsKnownValues() {
        #expect(KanbanDiagnosticKind.from("heartbeat_stalled") == .heartbeatStalled)
        #expect(KanbanDiagnosticKind.from("DARWIN_ZOMBIE_DETECTED") == .darwinZombieDetected)
        // Unknown kinds fall through to .unknown so views can render
        // the raw string verbatim.
        #expect(KanbanDiagnosticKind.from("future_kind_v014") == .unknown)
    }

    @Test func diagnosticSeverityMapping() {
        #expect(KanbanDiagnosticKind.retryCapHit.severity == .danger)
        #expect(KanbanDiagnosticKind.darwinZombieDetected.severity == .danger)
        #expect(KanbanDiagnosticKind.heartbeatStalled.severity == .warning)
        #expect(KanbanDiagnosticKind.workerExitNoComplete.severity == .warning)
        #expect(KanbanDiagnosticKind.unknown.severity == .neutral)
    }

    @Test func createRequestArgvIncludesMaxRetries() {
        let req = KanbanCreateRequest(title: "t", maxRetries: 5)
        let argv = req.argv()
        #expect(argv.contains("--max-retries"))
        #expect(argv.contains("5"))
    }

    @Test func createRequestArgvOmitsMaxRetriesWhenAbsent() {
        let req = KanbanCreateRequest(title: "t")
        let argv = req.argv()
        #expect(!argv.contains("--max-retries"))
    }

    @Test func decodeRunWithDiagnostics() throws {
        let json = """
        {
          "id": 1,
          "task_id": "t_x",
          "status": "failed",
          "started_at": 1778160000,
          "ended_at": 1778160300,
          "outcome": "crashed",
          "error": "OOM",
          "diagnostics": [
            {"kind": "retry_cap_hit", "message": "3/3 retries exhausted"}
          ],
          "failure_count": 3
        }
        """
        let run = try JSONDecoder().decode(HermesKanbanRun.self, from: Data(json.utf8))
        #expect(run.diagnostics.count == 1)
        #expect(run.diagnostics.first?.kind == "retry_cap_hit")
        #expect(run.failureCount == 3)
    }

    @Test func decodeRunWithoutDiagnostics() throws {
        // v0.12 run row — no diagnostics, no failure_count, must still
        // decode cleanly.
        let json = """
        {"id": 1, "task_id": "t_x", "status": "running", "started_at": 1778160000}
        """
        let run = try JSONDecoder().decode(HermesKanbanRun.self, from: Data(json.utf8))
        #expect(run.diagnostics.isEmpty)
        #expect(run.failureCount == nil)
    }

    @Test func taskDetailMergesEnvelopeAndTaskDiagnostics() throws {
        // Hermes's wire shape may put diagnostics on the task envelope OR
        // on the inner task. `allDiagnostics` dedupes by (kind, detected_at)
        // so a server emitting both sides doesn't surface dupes.
        let json = """
        {
          "task": {
            "id": "t_y",
            "title": "y",
            "status": "blocked",
            "diagnostics": [
              {"kind": "heartbeat_stalled", "detected_at": "2026-05-09T12:00:00Z"}
            ]
          },
          "comments": [],
          "events": [],
          "diagnostics": [
            {"kind": "heartbeat_stalled", "detected_at": "2026-05-09T12:00:00Z"},
            {"kind": "retry_cap_hit"}
          ]
        }
        """
        let detail = try JSONDecoder().decode(HermesKanbanTaskDetail.self, from: Data(json.utf8))
        let merged = detail.allDiagnostics
        #expect(merged.count == 2)
        #expect(merged.contains(where: { $0.kind == "heartbeat_stalled" }))
        #expect(merged.contains(where: { $0.kind == "retry_cap_hit" }))
    }

    @Test func taskDetailWithoutEnvelopeDiagnosticsDecodes() throws {
        // Pre-v0.13 task detail — no envelope diagnostics. Must decode.
        let json = """
        {
          "task": {"id": "t_z", "title": "z", "status": "ready"},
          "comments": [],
          "events": []
        }
        """
        let detail = try JSONDecoder().decode(HermesKanbanTaskDetail.self, from: Data(json.utf8))
        #expect(detail.envelopeDiagnostics == nil)
        #expect(detail.allDiagnostics.isEmpty)
    }

    @Test func diagnosticDecodesUnixTimestamp() throws {
        let json = """
        {"kind": "spawn_failure", "detected_at": 1778160614}
        """
        let diag = try JSONDecoder().decode(HermesKanbanDiagnostic.self, from: Data(json.utf8))
        #expect(diag.kind == "spawn_failure")
        // Decoder normalizes Unix int → ISO-8601 string.
        #expect(diag.detectedAt?.contains("2026") == true)
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
