import Testing
import Foundation
@testable import ScarfCore

/// P42b · the reviewer's re-audit of P42's seven commits.
///
/// Every floor here was re-walked by OPENING the file at each `v2026.*` tag,
/// not by grepping a filename — which is exactly the mistake P42 made when it
/// dated `provider_override` from the file MOVE.
@Suite struct HermesKanbanProviderFloorP42bTests {

    /// The first tag whose `list --json` EMITS `provider_override`.
    ///
    /// `hermes_cli/kanban.py::_task_to_dict` gains
    /// `"provider_override": t.provider_override` at `v2026.7.30:80`
    /// (`pyproject.toml` = `0.19.1`), and `cmd_list` prints
    /// `[_task_to_dict(t) for t in tasks]` at `:1594` of the same blob, so
    /// storing and emitting begin together.
    @Test func theFloorIsTheFirstTagThatEmitsTheKey() {
        #expect(HermesCapabilities.parse("Hermes Agent v0.19.1 (2026.7.30)").hasKanbanProviderOverride)
    }

    /// The tag BELOW the floor: `v2026.7.20` (`pyproject.toml` = `0.19.0`)
    /// has no occurrence of `provider_override` in `hermes_cli/kanban.py` at
    /// all. This is the assertion P42 got wrong — it named `v2026.8.31`,
    /// which HAS the key (`:80`).
    @Test func theTagBelowTheFloorIsRefused() {
        #expect(!HermesCapabilities.parse("Hermes Agent v0.19.0 (2026.7.20)").hasKanbanProviderOverride)
    }

    /// The two tags P42's doc claimed were below the floor both have the key
    /// in `_task_to_dict` (`v2026.8.31:80`, `v2026.9.7` via
    /// `kanban_output.py::_TASK_DICT_FIELDS`). A regression to `isV0211OrLater`
    /// would leave the chip dark on a host that emits the field.
    @Test func everyTagAboveTheFloorKeepsTheChip() {
        #expect(HermesCapabilities.parse("Hermes Agent v0.20.0 (2026.8.3)").hasKanbanProviderOverride)
        #expect(HermesCapabilities.parse("Hermes Agent v0.21.0 (2026.8.31)").hasKanbanProviderOverride)
        #expect(HermesCapabilities.parse("Hermes Agent v0.21.1 (2026.9.7)").hasKanbanProviderOverride)
    }

    /// An unreadable version probe answers `.empty`, i.e. below every floor,
    /// i.e. no chip — the C1 direction. And `project_id` has NO flag: it is
    /// decode-only, `decodeIfPresent`, and gates nothing, so a pre-v0.18 row
    /// gives `nil`, the same answer an unlinked task gives.
    @Test func anUnknownHostGetsNoChipAndProjectIDNeedsNoFlag() throws {
        #expect(!HermesCapabilities.empty.hasKanbanProviderOverride)
        let json = #"{"id":"t_1","title":"T","status":"todo"}"#
        let bare = try JSONDecoder().decode(HermesKanbanTask.self, from: Data(json.utf8))
        #expect(bare.projectId == nil)
        #expect(bare.providerOverride == nil)
    }
}

/// P42b · the MED — Duplicate seeded a one-shot time Hermes will never run.
@Suite struct CronDuplicateSeedP42bTests {

    static func oneShot(runAt: String?, state: String = "completed") -> HermesCronJob {
        HermesCronJob(
            id: "job_1", name: "nightly", prompt: "go", skills: nil, model: nil,
            schedule: CronSchedule(kind: "once", runAt: runAt, display: "once at 2020-01-01 09:00"),
            enabled: false, state: state
        )
    }

    /// The Mac's form seed. A spent one-shot's time is dropped: `cron create`
    /// refuses it at `_next_run_or_reject_past_oneshot`
    /// (`cron/jobs.py:1758` → `:1663-1666` @ `v2026.9.7`), so pre-filling it
    /// built an argv guaranteed to exit 1 under a hint that already said
    /// "with a new time".
    @Test func aSpentOneShotSeedsAnEmptySchedule() {
        #expect(Self.oneShot(runAt: "2020-01-01T09:00:00Z").duplicateSeedSchedule().isEmpty)
    }

    /// A one-shot still in the future keeps its time — the copy is legal, and
    /// blanking it would make the user retype a time that works.
    @Test func aFutureOneShotKeepsItsTime() {
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        #expect(Self.oneShot(runAt: future).duplicateSeedSchedule() == future)
    }

    /// Recurring kinds are untouched: nothing about a cron expression goes
    /// stale, and `editValue` is still the seed.
    @Test func aRecurringJobIsUnaffected() {
        let job = HermesCronJob(
            id: "job_2", name: "n", prompt: "go", skills: nil, model: nil,
            schedule: CronSchedule(kind: "cron", expression: "0 9 * * 1-5"),
            enabled: true, state: "scheduled")
        #expect(job.duplicateSeedSchedule() == "0 9 * * 1-5")
    }

    /// iOS's duplicate is a RECORD, not a form seed, and iOS writes
    /// `jobs.json` directly — so the dead time has to be dropped from the
    /// record itself or the copy is "scheduled" forever
    /// (`cron/scheduler_provider.py:274-279` @ `v2026.9.7` refuses to
    /// resurrect it). `display` goes with it: it is the label OF that time.
    @Test func theIOSDuplicateRecordDropsASpentOneShotTime() {
        let copy = Self.oneShot(runAt: "2020-01-01T09:00:00Z").duplicatedAsNewJob(id: "job_new", existingNames: [])
        #expect(copy.schedule.kind == "once")
        #expect(copy.schedule.runAt == nil)
        #expect(copy.schedule.display == nil)
        // Still a fresh record in every other respect.
        #expect(copy.id == "job_new")
        #expect(!copy.isTerminal)
    }

    /// …and a future one-shot's record duplicate keeps its time, so the
    /// blanking is the exception rather than the rule.
    @Test func theIOSDuplicateKeepsAFutureOneShotTime() {
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        let copy = Self.oneShot(runAt: future, state: "scheduled").duplicatedAsNewJob(id: "job_new", existingNames: [])
        #expect(copy.schedule.runAt == future)
    }
}

/// P42b · the two LOWs on what a copy admits it drops.
@Suite struct CronCopyGapsP42bTests {

    static func job(workdir: String? = nil, noAgent: Bool? = nil, model: String? = nil,
                    contextFrom: [String]? = nil, extra: [String: JSONValue] = [:]) -> HermesCronJob {
        HermesCronJob(
            id: "job_1", name: "n", prompt: "go", skills: nil, model: model,
            schedule: CronSchedule(kind: "cron", expression: "0 9 * * *"),
            enabled: true, state: "scheduled",
            workdir: workdir, contextFrom: contextFrom, noAgent: noAgent, extra: extra)
    }

    static let modern = HermesCapabilities.parse("Hermes Agent v0.21.1 (2026.9.7)")
    static let ancient = HermesCapabilities.parse("Hermes Agent v0.11.0 (2026.3.12)")

    /// The gaps list was RECORD-shaped: it named only what the form has no
    /// widget for. But both call sites blank `workdir`/`noAgent`/
    /// `failureDeliver` below their floors (v0.12 / v0.13 / v0.21.1) before
    /// calling `createJob`, and the list said nothing — so a `--workdir` job
    /// duplicated onto a pre-v0.12 host reported a faithful copy.
    @Test func aBelowFloorHostNamesTheFieldsItWillDrop() {
        let job = Self.job(workdir: "/w", noAgent: true,
                           extra: ["failure_deliver": .string("discord:ops")])
        let dropped = job.settingsACreateFormCannotCarry(caps: Self.ancient)
        #expect(dropped.contains { $0.contains("/w") })
        #expect(dropped.contains { $0.contains("no-agent") })
        #expect(dropped.contains { $0.contains("discord:ops") })
    }

    /// On a host that HAS all three, the form carries them and the list must
    /// stay silent — naming a loss that isn't one is the same lie inverted.
    @Test func aModernHostNamesNoneOfThem() {
        let job = Self.job(workdir: "/w", noAgent: true,
                           extra: ["failure_deliver": .string("discord:ops")])
        #expect(job.settingsACreateFormCannotCarry(caps: Self.modern).isEmpty)
    }

    /// The record-shaped half is unchanged by the capability argument.
    @Test func theRecordShapedGapsStillShowOnAModernHost() {
        let job = Self.job(model: "kimi-k2",
                           extra: ["monitor_script": .string("/s/check.sh")])
        let dropped = job.settingsACreateFormCannotCarry(caps: Self.modern)
        #expect(dropped.contains { $0.contains("kimi-k2") })
        #expect(dropped.contains { $0.contains("/s/check.sh") })
    }

    /// `context_from` refs naming OTHER jobs are the half the fleet copier
    /// counted as nothing: the executor only ever looked at
    /// `hasRunToRunContinuity`, which is the `"self"` half. There is no
    /// `--context-from` on `cron create`/`edit` at `v2026.9.7`
    /// (`hermes_cli/subcommands/cron.py:76-84`, `:115-120` expose only
    /// `--continuity`/`--no-continuity`), and
    /// `_validate_context_from_refs` (`tools/cronjob_job_args.py:326-337`)
    /// would reject a source-host id on the target anyway — so it is
    /// surfaced, never forwarded.
    @Test func crossJobContextRefsAreSeparableFromContinuity() {
        let both = Self.job(contextFrom: ["self", "job_9"])
        #expect(both.hasRunToRunContinuity)
        #expect(both.crossJobContextRefs == ["job_9"])

        let selfOnly = Self.job(contextFrom: ["SELF "])
        #expect(selfOnly.hasRunToRunContinuity)
        #expect(selfOnly.crossJobContextRefs.isEmpty)

        // The job's OWN id is the resolved spelling of "self", not a peer.
        let resolved = Self.job(contextFrom: ["job_1"])
        #expect(resolved.hasRunToRunContinuity)
        #expect(resolved.crossJobContextRefs.isEmpty)

        let crossOnly = Self.job(contextFrom: ["job_9", "  "])
        #expect(!crossOnly.hasRunToRunContinuity)
        #expect(crossOnly.crossJobContextRefs == ["job_9"])

        #expect(Self.job().crossJobContextRefs.isEmpty)
    }
}
