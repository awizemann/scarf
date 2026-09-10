import Testing
import Foundation
@testable import ScarfCore

/// Whole-surface audit P18 — incomplete-fix residue from P9–P17, the
/// ScarfCore half.
@Suite struct HermesP18RemediationTests {

    // MARK: - `oneShotIsUnresumable` refused a resume Hermes accepts

    /// `resume_job` (`cron/jobs.py:1986-2003`, v2026.9.7) computes the next
    /// run with `compute_next_run(job["schedule"])` — `last_run_at` left at
    /// its `None` default (:1096), so `_recoverable_oneshot_run_at`'s
    /// "already run, never eligible again" arm (:841-846) NEVER fires on the
    /// resume path. Scarf refused on `lastRunAt` alone.
    ///
    /// Reachable: `rearm_oneshot` (:2036-2055) re-arms a spent one-shot to a
    /// new future time and clears `repeat.completed`, the run claim and the
    /// fire claim — but NOT `last_run_at`. Pause that re-armed job and try to
    /// re-enable it and Scarf refused a resume the host performs.
    @Test func aReArmedOneShotWithAFutureDeadlineResumes() {
        let now = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
        let job = Self.oneShot(
            runAt: "2026-09-07T18:00:00+00:00",
            lastRunAt: "2026-09-01T09:00:00+00:00",
            state: "paused")
        #expect(job.oneShotIsUnresumable(now: now) == false)
    }

    /// What Hermes DOES refuse is re-activating a terminal record —
    /// `_reject_terminal_activation` (:1865-1878, armed from `update_job`
    /// :1941/:1965) — and that is where a genuinely spent one-shot ends up:
    /// `_advance_after_run` calls `_complete_job_record` for every
    /// `kind == "once"` with no next run. So the guard did not get weaker.
    @Test func aCompletedOneShotIsStillRefused() {
        let now = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
        #expect(Self.oneShot(runAt: "2026-09-07T18:00:00+00:00",
                             lastRunAt: "2026-09-07T09:00:00+00:00",
                             state: "completed")
            .oneShotIsUnresumable(now: now) == true)
        #expect(Self.oneShot(runAt: "2026-09-07T18:00:00+00:00",
                             lastRunAt: nil, state: "error")
            .oneShotIsUnresumable(now: now) == true)
    }

    /// …and the past-deadline arm P15 got right is untouched: a re-armed
    /// job whose new deadline has since passed is still refused, terminal
    /// or not.
    @Test func aPastDeadlineIsStillRefusedRegardlessOfLastRun() {
        let now = ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z")!
        #expect(Self.oneShot(runAt: "2026-09-07T11:00:00+00:00",
                             lastRunAt: "2026-09-01T09:00:00+00:00",
                             state: "paused")
            .oneShotIsUnresumable(now: now) == true)
    }

    private static func oneShot(runAt: String, lastRunAt: String?, state: String) -> HermesCronJob {
        let last = lastRunAt.map { "\"last_run_at\": \"\($0)\"," } ?? ""
        let json = """
        {"id": "j1", "name": "one shot", "prompt": "go", "enabled": false,
         "state": "\(state)", \(last)
         "schedule": {"kind": "once", "run_at": "\(runAt)"}}
        """
        return try! JSONDecoder().decode(HermesCronJob.self, from: Data(json.utf8))
    }

    // MARK: - The literal `== "true"` readers P17's own comment denied

    /// `checkpoints.enabled` is an absence SENTINEL: v0.21 flipped the
    /// server-side default true→false, so `nil` has to mean "absent" and be
    /// resolved against the host. Its reader still compared the literal
    /// `"true"` — 78 lines under a header comment asserting no such reader
    /// remained — so `checkpoints.enabled: yes` (which PyYAML hands Hermes
    /// as `True`) read as OFF, and a trailing comment defeated it entirely.
    @Test func checkpointsEnabledReadsEveryBooleanSpellingHermesReads() {
        for spelling in ["true", "yes", "on", "1", "True", "YES"] {
            let cfg = HermesConfig(yaml: "checkpoints:\n  enabled: \(spelling)\n")
            #expect(cfg.checkpoints.enabled == true, "\(spelling) should read as on")
        }
        for spelling in ["false", "no", "off", "0", "False"] {
            let cfg = HermesConfig(yaml: "checkpoints:\n  enabled: \(spelling)\n")
            #expect(cfg.checkpoints.enabled == false, "\(spelling) should read as off")
        }
        // A trailing comment is legal YAML and is not part of the value.
        #expect(HermesConfig(yaml: "checkpoints:\n  enabled: yes  # keep snapshots\n")
            .checkpoints.enabled == true)
    }

    /// The sentinel itself: absent, and unrecognised, both stay `nil` so the
    /// display layer resolves against the host's capabilities.
    @Test func checkpointsEnabledKeepsItsAbsenceSentinel() {
        #expect(HermesConfig(yaml: "agent:\n  model: x\n").checkpoints.enabled == nil)
        #expect(HermesConfig(yaml: "checkpoints:\n  enabled: maybe\n").checkpoints.enabled == nil)
    }

    /// The other survivor. Hermes coerces `multiplex_profiles` with
    /// `_coerce_bool(value, False)` (`gateway/config.py:733` → `_bool_token`
    /// :29-32 over `_TRUTHY_STRINGS`/`_FALSY_STRINGS` :25-26), so `yes` /
    /// `on` / `1` are ON. Scarf's `== "true"` read every one of them as OFF
    /// and rendered the profile-routes editor for a host that was in fact
    /// multiplexing.
    @Test func multiplexProfilesReadsTheBoolishSet() {
        for spelling in ["true", "yes", "on", "1", "TRUE"] {
            let snap = ProfileRoutesYAML.parse("multiplex_profiles: \(spelling)\n")
            #expect(snap.multiplexProfiles == true, "\(spelling) should read as on")
        }
        for spelling in ["false", "no", "off", "0"] {
            let snap = ProfileRoutesYAML.parse("multiplex_profiles: \(spelling)\n")
            #expect(snap.multiplexProfiles == false, "\(spelling) should read as off")
        }
        // Absent → the dataclass default `False` (`gateway/config.py:561`);
        // so does an unrecognised token, which `_coerce_bool` falls back on.
        #expect(ProfileRoutesYAML.parse("gateway:\n  host: 1.2.3.4\n").multiplexProfiles == false)
        #expect(ProfileRoutesYAML.parse("multiplex_profiles: maybe\n").multiplexProfiles == false)
        // Nested form, same vocabulary — and the top-level form still wins.
        #expect(ProfileRoutesYAML.parse("gateway:\n  multiplex_profiles: on\n").multiplexProfiles == true)
        #expect(ProfileRoutesYAML.parse(
            "multiplex_profiles: off\ngateway:\n  multiplex_profiles: yes\n"
        ).multiplexProfiles == false)
    }

    // MARK: - Dead wire keys (the sweep P14 left half-finished)

    /// Every kanban task dict Hermes emits is `_TASK_DICT_FIELDS`
    /// (`hermes_cli/kanban_output.py:18-24`, v2026.9.7) via the single
    /// serialiser `_task_to_dict` (:85-88), shared by `create --json`,
    /// `list --json` and `show --json`. `idempotency_key`,
    /// `last_heartbeat_at`, `max_runtime_seconds` and `current_run_id` are
    /// kanban DB columns that have never been in it at any tag.
    ///
    /// This is a DRIFT ALARM as much as a regression test: the fixture is
    /// the emitted field set. If a future Hermes starts emitting one of the
    /// deleted keys, the model has to grow it back deliberately — a
    /// decodeIfPresent that is always nil is indistinguishable from "the
    /// host didn't report it".
    @Test func aKanbanTaskDecodesTheEmittedFieldsAndIgnoresTheRest() throws {
        let json = """
        {"id": "t1", "title": "Ship it", "body": null, "assignee": "worker",
         "status": "running", "priority": 2, "tenant": "scarf",
         "workspace_kind": "worktree", "workspace_path": "/tmp/w",
         "branch_name": "feat/x", "project_id": "p1", "created_by": "alan",
         "created_at": 1757246400, "started_at": null, "completed_at": null,
         "result": null, "skills": ["research"], "max_retries": 3,
         "model_override": null, "provider_override": null, "session_id": "s1",
         "workflow_template_id": null, "current_step_key": null,
         "completion_contract": null, "last_failure_error": null,
         "idempotency_key": "ignored", "max_runtime_seconds": 1800,
         "last_heartbeat_at": 1757246400, "current_run_id": 7}
        """
        let task = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(task.id == "t1")
        #expect(task.skills == ["research"])
        #expect(task.maxRetries == 3)
        #expect(task.sessionId == "s1")
        // Unknown keys are tolerated, not modelled: a Codable synthesised
        // over the remaining CodingKeys ignores them, and the round trip
        // below proves Scarf never writes them back either.
        let round = try JSONEncoder().encode(task)
        let text = String(data: round, encoding: .utf8) ?? ""
        for dead in ["idempotency_key", "max_runtime_seconds", "last_heartbeat_at", "current_run_id"] {
            #expect(!text.contains(dead), "\(dead) must not be re-emitted")
        }
    }

    /// Same for runs: `_SHOW_RUN_FIELDS` / `_RUNS_RUN_FIELDS`
    /// (`kanban_output.py:25-32`) are the only two run shapes, and neither
    /// carries `task_id`, `claim_lock`, `claim_expires`,
    /// `max_runtime_seconds`, `last_heartbeat_at` or `failure_count`.
    @Test func aKanbanRunDecodesTheEmittedFieldsAndIgnoresTheRest() throws {
        let json = """
        {"id": 9, "profile": "worker-a", "step_key": "build", "status": "done",
         "outcome": "completed", "summary": "ok", "error": null,
         "metadata": {"k": 1}, "worker_pid": 4242,
         "started_at": 1757246400, "ended_at": 1757250000,
         "task_id": "t1", "claim_lock": "host:1", "claim_expires": 5,
         "max_runtime_seconds": 900, "last_heartbeat_at": 1757246400,
         "failure_count": 3}
        """
        let run = try JSONDecoder().decode(HermesKanbanRun.self, from: Data(json.utf8))
        #expect(run.id == 9)
        #expect(run.profile == "worker-a")
        #expect(run.stepKey == "build")
        #expect(run.outcome == "completed")
        #expect(run.workerPid == 4242)
        #expect(run.endedAt != nil)
        let text = String(data: try JSONEncoder().encode(run), encoding: .utf8) ?? ""
        for dead in ["task_id", "claim_lock", "claim_expires",
                     "max_runtime_seconds", "last_heartbeat_at", "failure_count"] {
            #expect(!text.contains(dead), "\(dead) must not be re-emitted")
        }
    }

    /// `kanban show --json`'s envelope is exactly task / latest_summary /
    /// parents / children / comments / events / runs (`kanban.py:492-498`).
    /// `parent_results` exists only as `kanban_db.parent_results` (:4060),
    /// feeding the worker's CONTEXT text (`_ctx_parent_results` :3692) —
    /// never an envelope.
    @Test func aKanbanTaskDetailDecodesTheRealEnvelope() throws {
        let json = """
        {"task": {"id": "t1", "title": "Ship it", "status": "running", "skills": []},
         "latest_summary": "wip",
         "parents": ["t0"], "children": [],
         "comments": [], "events": [],
         "parent_results": {"t0": "leftover"}}
        """
        let detail = try JSONDecoder().decode(HermesKanbanTaskDetail.self, from: Data(json.utf8))
        #expect(detail.task.id == "t1")
        #expect(detail.comments.isEmpty)
        let text = String(data: try JSONEncoder().encode(detail), encoding: .utf8) ?? ""
        #expect(!text.contains("parent_results"))
    }
}
