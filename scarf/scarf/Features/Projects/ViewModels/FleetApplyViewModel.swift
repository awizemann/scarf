import Foundation
import ScarfCore

/// Drives the `FleetApplySheet` — the user's pick of which config fields
/// to push and which hosts to push them to, the live plan preview, and
/// the off-main execution.
///
/// The plan is **recomputed purely** from the current selections
/// (`FleetApplyPlan.make`) so the preview always matches what Apply will
/// do. Execution runs `FleetApplyExecutor` in a detached task and lands
/// per-target results.
@Observable
@MainActor
final class FleetApplyViewModel {

    /// The current host's materialization — the config being pushed.
    let source: FleetMaterialization
    /// Candidate target hosts (every other host the project is on).
    let candidates: [FleetMaterialization]
    /// All registered servers, for the executor's serverId → context map.
    let contexts: [ServerContext]
    /// Fields the source actually carries — the only ones offered.
    let applicableFields: Set<FleetApplyField>

    var selectedTargetIds: Set<String>
    var selectedFields: Set<FleetApplyField>
    var phase: Phase = .configuring

    /// Server ids whose `~/.hermes/scarf/model_presets.json` actually holds
    /// the SOURCE's bound preset UUID. Model presets are per-host records, so
    /// pushing this host's UUID to a host that doesn't have it would write a
    /// dangling binding; the plan turns "not in this set" into an explained
    /// skip (`FleetApplyPlan.disposition`). `nil` until `prepare()` has run —
    /// which is also the "couldn't probe" value, deliberately permissive so a
    /// probe failure never silently blocks a legitimate apply.
    private(set) var presetHosts: Set<String>?

    /// The source host's fleet-copyable cron jobs — the SAME set the executor
    /// iterates (`FleetApplyPlan.copyableCronJobs`), loaded once here so the
    /// preview count and the execution can't diverge.
    private(set) var cronCopySet: FleetApplyPlan.CronCopySet?

    private(set) var isPreparing = false
    /// (completed, total) while a push is running, else nil. A fleet apply is
    /// a minutes-long operation against remote machines; before this the
    /// sheet showed nothing between "applying" and "done", so a slow push and
    /// a wedged one looked identical.
    private(set) var applyProgress: (done: Int, total: Int)?

    /// Live apply task, so the user can cancel a long fleet push.
    @ObservationIgnored private var applyTask: Task<[FleetApplyExecutor.TargetResult], Never>?
    private(set) var didCancel = false

    enum Phase {
        case configuring
        case applying
        case done([FleetApplyExecutor.TargetResult])
    }

    /// Whether an apply is in flight — drives the sheet's disabled state
    /// without an `Equatable` conformance on `Phase` (whose `.done`
    /// associated value isn't meaningfully comparable).
    var isApplying: Bool {
        if case .applying = phase { return true }
        return false
    }

    init(source: FleetMaterialization, candidates: [FleetMaterialization], contexts: [ServerContext]) {
        self.source = source
        self.candidates = candidates
        self.contexts = contexts
        let applicable = FleetApplyPlan.applicableFields(source: source.project)
        self.applicableFields = applicable
        self.selectedFields = applicable                       // default: everything pushable
        self.selectedTargetIds = Set(candidates.map(\.serverId))  // default: every host
    }

    var selectedTargets: [FleetMaterialization] {
        candidates.filter { selectedTargetIds.contains($0.serverId) }
    }

    /// The live plan for the current selections — also the preview source.
    var plan: FleetApplyPlan {
        FleetApplyPlan.make(
            source: source,
            targets: selectedTargets,
            fields: selectedFields,
            presetHosts: presetHosts,
            copyableCronCount: cronCopySet?.copyable.count
        )
    }

    /// Load the two facts the pure plan can't compute: which hosts hold the
    /// source's model preset, and which of the source's cron jobs are
    /// actually copyable. Off-main (disk + SFTP). Idempotent-ish — the sheet
    /// calls it once from `.task`.
    func prepare() async {
        guard !isPreparing, presetHosts == nil, cronCopySet == nil else { return }
        isPreparing = true
        defer { isPreparing = false }

        let projectID = source.project.id
        let sourceServerId = source.serverId
        let presetID = source.project.modelPresetId.flatMap(UUID.init(uuidString:))
        let hostIds = ([source.serverId] + candidates.map(\.serverId))
        let contexts = self.contexts

        let loaded = await Task.detached(priority: .userInitiated) {
            () -> (Set<String>?, FleetApplyPlan.CronCopySet) in
            var hosts: Set<String>?
            if let presetID {
                var found: Set<String> = []
                for id in hostIds {
                    guard let ctx = contexts.first(where: { $0.id.uuidString == id }) else { continue }
                    if ModelPresetStoreReader(context: ctx).contains(presetID) {
                        found.insert(id)
                    }
                }
                hosts = found
            }
            var copySet = FleetApplyPlan.CronCopySet()
            if let srcCtx = contexts.first(where: { $0.id.uuidString == sourceServerId }) {
                copySet = FleetApplyPlan.copyableCronJobs(
                    from: HermesFileService(context: srcCtx).loadCronJobs(),
                    projectID: projectID
                )
            }
            return (hosts, copySet)
        }.value

        presetHosts = loaded.0
        cronCopySet = loaded.1
    }

    /// Fields the source carries a value for, narrowed by what's actually
    /// copyable once `prepare()` has run: a project whose only cron jobs are
    /// script-only has nothing to push.
    var offeredFields: Set<FleetApplyField> {
        guard let cronCopySet else { return applicableFields }
        return cronCopySet.copyable.isEmpty ? applicableFields.subtracting([.cron]) : applicableFields
    }

    /// Why fields were dropped from the offer / will be skipped — shown in
    /// the sheet so a smaller-than-expected push is never silent.
    var caveats: [String] {
        var out: [String] = []
        if let cronCopySet {
            if !cronCopySet.scriptOnly.isEmpty {
                out.append("\(cronCopySet.scriptOnly.count) script-only cron job\(cronCopySet.scriptOnly.count == 1 ? "" : "s") can't be copied (their script file lives on this host only).")
            }
            // Round-4 decision 8. Same caveat shape as `scriptOnly`: the
            // monitor SOURCE doesn't travel (a `--monitor-script` path is on
            // this host only; a `--monitor-url`'s hash state is per-host), so
            // a copy would run the agent on every tick instead of only on a
            // change.
            if !cronCopySet.monitor.isEmpty {
                out.append("\(cronCopySet.monitor.count) monitor cron job\(cronCopySet.monitor.count == 1 ? "" : "s") can't be copied (the monitored script or URL state lives on this host only).")
            }
            // A DOWNGRADE, not a skip — these jobs are still copied. There
            // is no `--context-from` on `cron create`/`edit` at `v2026.9.7`
            // (only `--continuity`/`--no-continuity`,
            // `hermes_cli/subcommands/cron.py:76-84`, `:115-120`), and
            // `_validate_context_from_refs`
            // (`tools/cronjob_job_args.py:326-337`) rejects a ref naming a
            // job the TARGET profile doesn't have — which every source-host
            // id is. Say so here rather than let the copy wake up context-less
            // under a green "created".
            let crossJobContext = cronCopySet.copyable.filter { !$0.crossJobContextRefs.isEmpty }
            if !crossJobContext.isEmpty {
                out.append("\(crossJobContext.count) cron job\(crossJobContext.count == 1 ? "" : "s") read another job's output; that link can't be copied (no CLI flag sets it, and the job ids are this host's).")
            }
            // Round-5 decision 12 — a DOWNGRADE at the same seam, for the
            // same reason as the cross-job note above: the job is still
            // copied. `cron create` does take `--script`
            // (`hermes_cli/subcommands/cron.py:41-46` @ `v2026.9.7`) and
            // validates nothing at create time (`hermes_cli/cron.py:540`;
            // the only existence check is `cron doctor`'s
            // `_script_health_issue`, `:453-465`), so forwarding the path
            // would land a green "created" job pointing at a file only THIS
            // host has. Replicating the file is `t-848d3adc`; until then,
            // say so here.
            let preRunScript = cronCopySet.copyable.filter(\.hasPreRunScript)
            if !preRunScript.isEmpty {
                out.append("\(preRunScript.count) cron job\(preRunScript.count == 1 ? "" : "s") run a pre-run script whose output is injected into the prompt; the script file stays on this host, so the copy runs without it.")
            }
            // Round-6 decision 8 — the same DOWNGRADE shape as the pre-run
            // script note above, for the same kind of reason. `cron create`
            // would ACCEPT `--model` / `--provider` / `--reasoning-effort`
            // (`hermes_cli/subcommands/cron.py:66-77` @ `v2026.9.7`), and
            // that is precisely why forwarding them is wrong: a model id is
            // resolved against the TARGET's provider config and credential
            // pools, so a pin the target has never heard of lands green and
            // fails on its first run. Dropping it lets the target resolve its
            // own default (`_compute_provider_model_snapshots`,
            // `cron/jobs.py:1599-1620`) — a defensible outcome, but a silent
            // change of which model runs the job, and whose bill.
            let modelPinned = cronCopySet.copyable.filter(\.hasModelPin)
            if !modelPinned.isEmpty {
                out.append("\(modelPinned.count) cron job\(modelPinned.count == 1 ? "" : "s") pin their own model, provider or reasoning effort; those pins are this host's, so the copy follows the target host's defaults.")
            }
            if !cronCopySet.unsupportedSchedule.isEmpty {
                out.append("\(cronCopySet.unsupportedSchedule.count) cron job\(cronCopySet.unsupportedSchedule.count == 1 ? "" : "s") have a schedule that can't be recreated from the CLI.")
            }
        }
        if let presetHosts, let presetID = source.project.modelPresetId, !presetID.isEmpty {
            let missing = candidates.filter { !presetHosts.contains($0.serverId) }
            if !missing.isEmpty {
                out.append("Model presets are per-host: \(missing.count) host\(missing.count == 1 ? " doesn't" : "s don't") have preset \(String(presetID.prefix(8))), so it will be skipped there.")
            }
        }
        return out
    }

    /// Apply is enabled only when at least one selected host will actually
    /// change at least one field (a selection that's entirely no-ops is
    /// pointless).
    var canApply: Bool {
        guard !selectedFields.isEmpty, !selectedTargetIds.isEmpty else { return false }
        return !plan.effectiveTargets.isEmpty
    }

    func isFieldSelected(_ field: FleetApplyField) -> Bool { selectedFields.contains(field) }

    func toggleField(_ field: FleetApplyField, _ on: Bool) {
        if on { selectedFields.insert(field) } else { selectedFields.remove(field) }
    }

    func isTargetSelected(_ serverId: String) -> Bool { selectedTargetIds.contains(serverId) }

    func toggleTarget(_ serverId: String, _ on: Bool) {
        if on { selectedTargetIds.insert(serverId) } else { selectedTargetIds.remove(serverId) }
    }

    func apply() async {
        guard canApply else { return }
        phase = .applying
        didCancel = false
        let plan = self.plan
        let sourceProject = source.project
        let contexts = self.contexts
        // The copy set the user just previewed is handed to the executor, so
        // it acts on exactly the jobs the plan described.
        let cronJobs = cronCopySet?.copyable
        // A DETACHED task doesn't inherit cancellation from its parent, so
        // the handle is retained and cancelled explicitly by `cancel()`;
        // `Task.isCancelled` inside the body then reads THIS task's flag.
        // `plan.targets.count`, NOT `effectiveTargets`: the executor reports
        // progress over every target it walks, including the ones whose
        // actions are all no-ops, so a denominator taken from the smaller set
        // would let the counter run past its own total.
        applyProgress = (0, plan.targets.count)
        let task = Task.detached(priority: .userInitiated) { [weak self] () -> [FleetApplyExecutor.TargetResult] in
            // Bound to a local `let` BEFORE the `onProgress` closure is formed.
            // Binding it *inside* that closure (the shape this file carried
            // until the Release ratchet caught it) does not help: the closure
            // runs concurrently and the reference it captures is still the
            // outer weak `self` binding, which Swift 6 treats as a captured
            // var (SendableClosureCaptures). Capturing `owner` instead gives
            // the closure an immutable value of its own.
            let owner = self
            return await FleetApplyExecutor(contexts: contexts).execute(
                plan,
                source: sourceProject,
                sourceCronJobs: cronJobs,
                isCancelled: { Task.isCancelled },
                onProgress: { done, total in
                    // Hops to the MainActor arrive in arbitrary order, so the
                    // counter is clamped monotonic — a progress bar that goes
                    // backwards reads as a bug in the push itself.
                    Task { @MainActor [owner] in
                        guard let owner else { return }
                        let previous = owner.applyProgress?.done ?? 0
                        owner.applyProgress = (max(previous, done), total)
                    }
                }
            )
        }
        applyTask = task
        let results = await task.value
        applyTask = nil
        applyProgress = nil
        phase = .done(results)
    }

    /// Stop a fleet push in progress. Hosts already written keep their
    /// results; the remainder come back explicitly "cancelled" — a fleet
    /// apply touches remote machines, so an abandoned run must still report
    /// exactly how far it got.
    func cancel() {
        guard isApplying else { return }
        didCancel = true
        applyTask?.cancel()
    }

    // MARK: - Result summary (honest about partial failure)

    /// Fleet-level outcome. A push that failed on ANY host is NOT a success:
    /// the per-host rows used to be the only signal, under an unconditional
    /// "Applied to N hosts" heading, so a fleet that half-failed still read
    /// as green.
    enum Outcome {
        case allApplied
        case partialFailure(failed: Int, total: Int)
        case allFailed(total: Int)
        case nothingApplied
    }

    static func outcome(for results: [FleetApplyExecutor.TargetResult]) -> Outcome {
        guard !results.isEmpty else { return .nothingApplied }
        let failed = results.filter(\.hadFailure).count
        if failed == results.count { return .allFailed(total: results.count) }
        if failed > 0 { return .partialFailure(failed: failed, total: results.count) }
        return results.contains { $0.appliedCount > 0 } ? .allApplied : .nothingApplied
    }
}
