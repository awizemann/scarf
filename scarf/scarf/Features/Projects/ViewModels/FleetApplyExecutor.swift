import Foundation
import ScarfCore
import os

/// Executes a `FleetApplyPlan` — the I/O side of apply-to-fleet
/// (config-as-policy, Phase-1 item #4). Pure planning lives in ScarfCore
/// (`FleetApplyPlan`); this Mac-target service performs the writes by
/// **reusing the existing per-project writers** so there's one code path
/// for "set this project's model / board" whether it's the model-preset
/// sheet or a fleet push:
///
/// - **Model preset** → `ProjectModelPresetBinding.bind` (manifest
///   `modelPresetID`; overwrite-safe, reversible re-bind).
/// - **Board** → `KanbanTenantResolver.setTenant` (manifest `kanbanTenant`;
///   only for targets the plan marked `apply`, i.e. no existing tenant —
///   additive, never orphans tasks).
/// - **Cron** → recreate the source's `[proj:<id>]` jobs on the target via
///   `hermes cron create`, with prompts path-rewritten source→target root
///   (`FleetApplyPlan.rewriteCronPrompt`), created-then-paused like the
///   template installer. Idempotent: jobs whose name already exists on the
///   target are skipped.
///
/// After writing a target's manifest/cron, the target's
/// `.scarf/project.json` record is re-derived + saved so the Fleet panel
/// reflects the new config without a manual reload.
///
/// **NON-FATAL**: every write is isolated; one failing field or one
/// unreachable host never aborts the rest. Each target gets a
/// `TargetResult` with per-field status. Runs blocking CLI + SFTP — call
/// off the main actor.
struct FleetApplyExecutor: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "FleetApplyExecutor")

    /// Every registered server, so a plan's `serverId` strings resolve to
    /// real `ServerContext`s (`ServerRegistry.allContexts`).
    let contexts: [ServerContext]

    nonisolated init(contexts: [ServerContext]) {
        self.contexts = contexts
    }

    // MARK: - Results

    nonisolated struct FieldResult: Sendable, Identifiable {
        let field: FleetApplyField
        let status: Status
        /// User-facing, and therefore ALREADY LOCALIZED — every producer below
        /// builds it with `String(localized:)`. The result sheet renders it
        /// verbatim; a plain literal here was English on screen.
        let message: String
        /// Raw CLI/transport diagnostics for a failure — the `hermes` stderr
        /// (combined output) of the first failing call. Surfaced verbatim in
        /// the result sheet: "1 failed" alone tells the user nothing they can
        /// act on, and the reason (bad schedule, missing binary, dead SSH
        /// channel) only ever exists in that output.
        let detail: String?
        var id: String { field.rawValue }
        nonisolated enum Status: Sendable, Equatable { case applied, skipped, failed }

        init(field: FleetApplyField, status: Status, message: String, detail: String? = nil) {
            self.field = field
            self.status = status
            self.message = message
            self.detail = detail
        }
    }

    nonisolated struct TargetResult: Sendable, Identifiable {
        let serverId: String
        let serverDisplayName: String?
        let fields: [FieldResult]
        var id: String { serverId }

        var hadFailure: Bool { fields.contains { $0.status == .failed } }
        var appliedCount: Int { fields.filter { $0.status == .applied }.count }
        var displayName: String {
            if let n = serverDisplayName, !n.isEmpty { return n }
            if serverId == ServerContext.local.id.uuidString { return "Local" }
            return String(serverId.prefix(8))
        }
    }

    // MARK: - Execute

    /// Apply `plan` (built from `source`'s config) to its targets.
    /// `source` supplies the values to push (model preset id, board slug)
    /// and is the host whose `[proj:]` cron jobs are copied.
    ///
    /// `sourceCronJobs` is the **already-partitioned copy set** (
    /// `FleetApplyPlan.copyableCronJobs(...).copyable`) the caller previewed;
    /// passing it in — rather than re-reading and re-filtering here — is what
    /// makes the preview and the execution provably the same job set. `nil`
    /// falls back to reading the source host directly through the same
    /// partitioner.
    ///
    /// `isCancelled` is polled between targets and between cron creates so a
    /// long fleet push can be stopped; already-written targets keep their
    /// results and the rest come back explicitly `.skipped` "cancelled".
    /// `onProgress(completed, total)` fires on each target as it finishes, in
    /// completion order. Added because a fleet push against several remote
    /// hosts is a minutes-long operation that previously reported nothing at
    /// all between "applying" and "done" — the user could not tell a slow
    /// push from a wedged one, which is exactly when they reach for Cancel.
    nonisolated func execute(
        _ plan: FleetApplyPlan,
        source: ScarfProject,
        sourceCronJobs: [HermesCronJob]? = nil,
        isCancelled: @Sendable @escaping () -> Bool = { false },
        onProgress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> [TargetResult] {
        // Read the source host's project cron jobs once, only if some
        // target actually applies cron.
        let appliesCron = plan.targets.contains { t in
            t.actions.contains { $0.field == .cron && $0.disposition.isApply }
        }
        var cronJobs: [HermesCronJob] = sourceCronJobs ?? []
        if sourceCronJobs == nil, appliesCron, let srcCtx = context(for: plan.sourceServerId) {
            cronJobs = FleetApplyPlan.copyableCronJobs(
                from: HermesFileService(context: srcCtx).loadCronJobs(),
                projectID: plan.projectID
            ).copyable
        }

        // CONCURRENT across targets. Each target is a different host with its
        // own manifest and its own cron list — no target reads anything
        // another writes — so the serial loop this replaced simply paid every
        // host's SSH latency end to end, one after another. Bounded at
        // `maxConcurrentHosts`: a fleet is a handful of machines, and an
        // unbounded group would open an SSH channel to every one of them at
        // once.
        //
        // Cancellation keeps its honesty (F5): a target that has NOT started
        // when cancel lands reports "cancelled before apply", and one already
        // in flight runs to completion and reports what it actually did.
        // Results are re-sorted into PLAN ORDER, not completion order, so the
        // result sheet reads the same way the preview did.
        let total = plan.targets.count
        let indexed = Array(plan.targets.enumerated())
        let completed = ProgressCounter()

        var byIndex: [Int: TargetResult] = [:]
        await withTaskGroup(of: (Int, TargetResult).self) { group in
            var next = 0
            func addTask(_ item: (offset: Int, element: FleetApplyPlan.Target)) {
                group.addTask {
                    let target = item.element
                    let result: TargetResult
                    if isCancelled() {
                        result = TargetResult(
                            serverId: target.serverId,
                            serverDisplayName: target.serverDisplayName,
                            fields: target.actions.map {
                                FieldResult(field: $0.field, status: .skipped, message: String(localized: "cancelled before apply"))
                            }
                        )
                    } else {
                        result = self.execute(
                            target: target, plan: plan, source: source,
                            sourceCronJobs: cronJobs, isCancelled: isCancelled
                        )
                    }
                    onProgress(await completed.increment(), total)
                    return (item.offset, result)
                }
            }
            while next < indexed.count, next < Self.maxConcurrentHosts {
                addTask(indexed[next]); next += 1
            }
            while let (offset, result) = await group.next() {
                byIndex[offset] = result
                if next < indexed.count { addTask(indexed[next]); next += 1 }
            }
        }
        return (0..<total).compactMap { byIndex[$0] }
    }

    /// How many hosts a fleet push writes to at once.
    nonisolated static let maxConcurrentHosts = 4

    private nonisolated func execute(
        target: FleetApplyPlan.Target,
        plan: FleetApplyPlan,
        source: ScarfProject,
        sourceCronJobs: [HermesCronJob],
        isCancelled: @Sendable () -> Bool
    ) -> TargetResult {
        guard let ctx = context(for: target.serverId) else {
            // Host is in a record's binding but no longer registered here.
            let fields = target.actions.map {
                FieldResult(field: $0.field, status: .failed, message: String(localized: "server not registered on this Mac"))
            }
            return TargetResult(serverId: target.serverId, serverDisplayName: target.serverDisplayName, fields: fields)
        }

        // The writers key on path; name is cosmetic. uuid pins the stable
        // id so the re-derive below preserves it.
        let entry = ProjectEntry(name: source.name, path: target.rootPath, uuid: plan.projectID)
        var fieldResults: [FieldResult] = []

        for action in target.actions {
            guard action.disposition.isApply else {
                fieldResults.append(FieldResult(field: action.field, status: .skipped, message: action.disposition.detail))
                continue
            }
            switch action.field {
            case .modelPreset:
                do {
                    try ProjectModelPresetBinding(context: ctx).bind(presetID: source.modelPresetId, to: entry)
                    fieldResults.append(FieldResult(field: .modelPreset, status: .applied, message: String(localized: "bound model preset")))
                } catch {
                    fieldResults.append(FieldResult(field: .modelPreset, status: .failed, message: String(localized: "couldn’t bind model preset"), detail: error.localizedDescription))
                }
            case .board:
                do {
                    try KanbanTenantResolver(context: ctx).setTenant(source.board ?? "", for: entry)
                    fieldResults.append(FieldResult(field: .board, status: .applied, message: String(localized: "set board \(source.board ?? "")")))
                } catch {
                    fieldResults.append(FieldResult(field: .board, status: .failed, message: String(localized: "couldn’t set board"), detail: error.localizedDescription))
                }
            case .cron:
                fieldResults.append(
                    applyCron(
                        sourceJobs: sourceCronJobs,
                        to: ctx,
                        sourceRoot: plan.sourceRootPath,
                        targetRoot: target.rootPath,
                        isCancelled: isCancelled
                    )
                )
            }
        }

        // Refresh the target's canonical record so the Fleet panel shows
        // the new config on next gather. Best-effort, non-fatal.
        let store = ProjectStore(context: ctx)
        do {
            try store.save(store.derive(from: entry))
        } catch {
            Self.logger.warning("couldn't refresh project.json for \(target.serverId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        return TargetResult(serverId: target.serverId, serverDisplayName: target.serverDisplayName, fields: fieldResults)
    }

    // MARK: - Cron

    private nonisolated func applyCron(
        sourceJobs: [HermesCronJob],
        to ctx: ServerContext,
        sourceRoot: String,
        targetRoot: String,
        isCancelled: @Sendable () -> Bool
    ) -> FieldResult {
        guard !sourceJobs.isEmpty else {
            return FieldResult(field: .cron, status: .skipped, message: String(localized: "source has no copyable project cron jobs"))
        }
        let fileService = HermesFileService(context: ctx)
        let before = fileService.loadCronJobs()
        let existingNames = Set(before.map(\.name))
        let beforeIDs = Set(before.map(\.id))

        // Probe the TARGET host's Hermes version ONCE so we forward only the
        // cron flags it understands (mixed-version fleets): a pre-v0.14 host
        // rejects `--deliver all`, a pre-v0.12 host rejects `--workdir`. A
        // failed/unparseable probe yields `.empty` → conservative (drop the
        // version-gated flags rather than risk an argparse error that fails
        // the whole `cron create`). FleetApplyPlan.cronCreateArgs owns the
        // per-flag gating + source→target path rewriting.
        // Cached per *connection* (see `HermesVersionCache.key(for:)`), so a
        // fleet of mixed-version hosts still gets each host's own answer.
        let caps = HermesVersionCache.shared.capabilitiesSync(for: ctx)

        var created = 0, skipped = 0, failed = 0, deliverAllDowngrades = 0, scriptOnlySkipped = 0
        var monitorSkipped = 0, continuityDowngrades = 0, crossJobContextDowngrades = 0
        var preRunScriptDowngrades = 0
        var modelPinDowngrades = 0
        var cancelledRemaining = 0
        var createdNames: [String] = []
        // First failing `cron create`'s combined stdout+stderr — the only
        // place the actual reason exists. Kept verbatim for the result sheet.
        var firstFailureDetail: String?

        for job in sourceJobs {
            if isCancelled() {
                cancelledRemaining += 1
                continue
            }
            // Idempotent/additive: skip if a job with this name (carrying
            // the same [proj:<id>] tag) already exists on the target, OR we
            // already created it earlier in this same pass — two source
            // jobs can share a name, and creating both would double-up.
            if existingNames.contains(job.name) || createdNames.contains(job.name) {
                skipped += 1
                continue
            }
            // Script-only watchdog jobs (`no_agent`) can't be faithfully
            // copied: their behavior is a pre-run script that lives as a FILE
            // PATH on the SOURCE host (`pre_run_script`), and fleet-apply
            // doesn't replicate that file to the target. Forwarding `--script`
            // would dangle, and dropping it leaves an empty-prompt no-op — so
            // we skip and SURFACE it rather than report a do-nothing job as
            // "created". Full script-replicating copy is tracked separately.
            // (Agent jobs that merely also carry a pre-run script are still
            // copied — they keep their working prompt.)
            if job.noAgent == true {
                scriptOnlySkipped += 1
                continue
            }
            // Round-4 decision 8: a MONITOR job is skipped and surfaced for
            // the same reason. Its behaviour is "run the agent only when this
            // source's output CHANGED" — `--monitor-script` is a path on the
            // SOURCE host that fleet-apply does not replicate, `--monitor-url`
            // carries hash state (`monitor_state`) that does not travel
            // (`hermes_cli/subcommands/cron.py:51-62` @ `v2026.9.7`).
            // `cronCreateArgs` forwards neither, so a copy used to become an
            // ordinary agent job that ran, and billed, on every single tick
            // under a green "created". Decline it and say so instead.
            if FleetApplyPlan.shouldSkipMonitorJob(job) {
                monitorSkipped += 1
                continue
            }
            // `sourceJobs` is already the partitioned copy set, so a nil here
            // can only mean the caller handed us an unpartitioned list — count
            // it as a failure WITH a reason rather than a bare tally.
            guard let scheduleArg = CronScheduleArgument.resolve(job.schedule) else {
                failed += 1
                if firstFailureDetail == nil {
                    firstFailureDetail = "\(job.name): schedule has no cron expression, interval, or run-at to recreate from"
                }
                continue
            }
            let (args, droppedDeliverAll) = FleetApplyPlan.cronCreateArgs(
                copying: job,
                schedule: scheduleArg,
                caps: caps,
                sourceRoot: sourceRoot,
                targetRoot: targetRoot,
                paused: true
            )

            let (output, exit) = ctx.runHermes(args)
            if exit == 0 {
                created += 1
                createdNames.append(job.name)
                if droppedDeliverAll { deliverAllDowngrades += 1 }
                // `--continuity` is a downgrade, not a refusal: it is stored
                // as `"self"` in `context_from`
                // (`tools/cronjob_job_args.py:313-321` @ `v2026.9.7`), so the
                // copy just starts its own run history — which is what the
                // FIRST run of a continuity job does anyway
                // (`subcommands/cron.py:76-84`). Counted on the SUCCESS arm
                // with the deliver downgrade: a job that never landed was not
                // degraded, it failed, and reporting both would double-count
                // the same job in two different notes.
                if job.hasRunToRunContinuity { continuityDowngrades += 1 }
                // A `context_from` ref naming ANOTHER job is the second half
                // of the same field and gets the same treatment for a harder
                // reason: there is no `--context-from` option on `cron
                // create`/`edit` at all (`hermes_cli/subcommands/cron.py`
                // exposes only `--continuity`/`--no-continuity`, `:76-84`,
                // `:115-120` @ `v2026.9.7`), so nothing CAN forward it — and
                // `_validate_context_from_refs`
                // (`tools/cronjob_job_args.py:326-337`) would reject the ids
                // anyway, because they name jobs on the SOURCE host. Surface,
                // never forward. Counted on the success arm: the copy landed,
                // it just wakes without the other job's output.
                if !job.crossJobContextRefs.isEmpty { crossJobContextDowngrades += 1 }
                // Round-5 decision 12. A pre-run script on an AGENT job is a
                // downgrade, not a refusal — unlike a `no_agent` job, where
                // the script IS the job and the copy would be an empty no-op
                // (`scriptOnly`, declined above). Here the copy keeps its
                // prompt and runs; it just wakes without the script's stdout
                // injected. `cron create` would ACCEPT `--script` (it takes
                // that flag and validates nothing at create time —
                // `hermes_cli/subcommands/cron.py:41-46`, `hermes_cli/cron.py:540`,
                // `:453-465` @ `v2026.9.7`), which is exactly why forwarding
                // it is the wrong answer: the path names a file under the
                // SOURCE host's `~/.hermes/scripts/` and the green "created"
                // would hide a job that injects nothing. Replicating the
                // script file is `t-848d3adc`. Counted on the success arm,
                // same rule as the two notes above.
                if job.hasPreRunScript { preRunScriptDowngrades += 1 }
                // Round-6 decision 8, the P50 shape exactly. `cron create`
                // WOULD take `--model` / `--provider` / `--reasoning-effort`
                // (`hermes_cli/subcommands/cron.py:66-77` @ `v2026.9.7`) —
                // an accepted flag whose value names something only the
                // SOURCE host has, so forwarding it lands a green "created"
                // job that fails at first run against a model the target has
                // no provider or credential for. Dropped, and counted on the
                // success arm with its three siblings: the copy runs, it just
                // runs on the target's own default model.
                if job.hasModelPin { modelPinDowngrades += 1 }
            } else {
                failed += 1
                if firstFailureDetail == nil {
                    firstFailureDetail = Self.diagnostic(jobName: job.name, exit: exit, output: output)
                }
                Self.logger.warning("cron create failed for \(job.name, privacy: .public) exit=\(exit, privacy: .public)")
            }
        }

        // Created jobs land enabled — pause them (mirror the installer) so
        // a fleet push never silently arms autonomous cron on a remote.
        // Count how many we actually managed to pause; an unpaused created
        // job is the one outcome the user must SEE (it's live on a remote),
        // so it goes in the result message, not just a log line.
        // v0.21.1 hosts got `--paused` in the create argv above, so the job
        // was never armed for even one tick — nothing left to pause, and the
        // whole create-then-pause race is gone. Older hosts still need the
        // second write.
        var paused = caps.hasCronCreatePaused ? created : 0
        if !createdNames.isEmpty, !caps.hasCronCreatePaused {
            let newlyCreated = fileService.loadCronJobs().filter {
                !beforeIDs.contains($0.id) && createdNames.contains($0.name)
            }
            for j in newlyCreated {
                let (_, exit) = ctx.runHermes(["cron", "pause", j.id])
                if exit == 0 {
                    paused += 1
                } else {
                    Self.logger.warning("couldn't pause fleet-created cron job \(j.id, privacy: .public) — leaving enabled")
                }
            }
        }

        var parts: [String] = []
        if created > 0 {
            let unpaused = created - paused
            parts.append(unpaused == 0
                ? String(localized: "\(created) created (paused)")
                : String(localized: "\(created) created, \(unpaused) could NOT be paused — verify on host"))
        }
        if skipped > 0 { parts.append(String(localized: "\(skipped) already present")) }
        if scriptOnlySkipped > 0 { parts.append(String(localized: "\(scriptOnlySkipped) script-only skipped")) }
        if monitorSkipped > 0 { parts.append(String(localized: "\(monitorSkipped) monitor skipped — source doesn't travel")) }
        if failed > 0 { parts.append(String(localized: "\(failed) failed")) }
        if cancelledRemaining > 0 { parts.append(String(localized: "\(cancelledRemaining) cancelled")) }
        // A deliver=all downgrade is a created-but-degraded job (runs with
        // Hermes's default delivery, not fan-out) — the user must SEE it,
        // same rationale as the unpaused-job note above.
        if deliverAllDowngrades > 0 {
            parts.append(String(localized: "\(deliverAllDowngrades) w/o deliver=all (host < v0.14)"))
        }
        // A copied continuity job DID land; it just starts its own run
        // history. Same created-but-degraded rule as the deliver note.
        if continuityDowngrades > 0 {
            parts.append(String(localized: "\(continuityDowngrades) w/o run-to-run continuity"))
        }
        if crossJobContextDowngrades > 0 {
            parts.append(String(localized: "\(crossJobContextDowngrades) w/o cross-job context (no CLI flag to copy it)"))
        }
        if preRunScriptDowngrades > 0 {
            parts.append(String(localized: "\(preRunScriptDowngrades) w/o their pre-run script (the file stays on this host)"))
        }
        if modelPinDowngrades > 0 {
            parts.append(String(localized: "\(modelPinDowngrades) w/o their model pin (the target host's default model runs them)"))
        }
        let status = Self.cronFieldStatus(
            created: created, failed: failed,
            scriptOnlySkipped: scriptOnlySkipped + monitorSkipped,
            cancelledRemaining: cancelledRemaining)
        return FieldResult(
            field: .cron,
            status: status,
            message: parts.isEmpty ? String(localized: "no changes") : parts.joined(separator: ", "),
            detail: firstFailureDetail
        )
    }

    /// Verdict for the cron field from what the pass actually wrote.
    ///
    /// - `.failed` whenever a `cron create` errored. A partly-failed pass is
    ///   NOT `.applied`: the field message carries "N created, M failed", but
    ///   the status is what `TargetResult.appliedCount` counts and what the
    ///   row badge shows, and telling the user a field applied while some of
    ///   its jobs never landed is the same lie the `scriptOnlySkipped` case
    ///   used to tell. A created-but-unpaused job is a different matter — it
    ///   DID land, and its live state is surfaced in the message.
    /// - `.skipped` when nothing was created, nothing failed, and the pass
    ///   either skipped jobs Scarf declines to copy — script-only
    ///   (`no_agent`) or monitor (`monitor_script`/`monitor_url`), which the
    ///   caller sums into `scriptOnlySkipped` because the verdict is the same
    ///   for both — or was
    ///   CANCELLED before it wrote anything. Both are real outcomes where not
    ///   one job was written; cancellation already reports `.skipped`
    ///   "cancelled before apply" when it lands between targets, and a cancel
    ///   between cron creates must not read differently.
    /// - `.applied` otherwise, INCLUDING the all-already-present case: a
    ///   target that already has every job is genuinely in the desired state,
    ///   which is not the same as a job Scarf declined to copy.
    nonisolated static func cronFieldStatus(
        created: Int, failed: Int, scriptOnlySkipped: Int, cancelledRemaining: Int = 0
    ) -> FieldResult.Status {
        if failed > 0 { return .failed }
        if created == 0 && (scriptOnlySkipped > 0 || cancelledRemaining > 0) { return .skipped }
        return .applied
    }

    /// Humanize a failed `hermes` invocation for the result sheet: the job
    /// it was for, the exit code, and the tail of the combined stdout+stderr
    /// (`ServerContext.runHermes` concatenates them). Trimmed to a few lines
    /// so a stack trace can't blow out the sheet.
    private nonisolated static func diagnostic(jobName: String, exit: Int32, output: String) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(4).joined(separator: "\n")
        let head = "\(jobName): hermes cron create exited \(exit)"
        return tail.isEmpty ? "\(head) with no output" : "\(head)\n\(tail)"
    }

    private nonisolated func context(for serverId: String) -> ServerContext? {
        contexts.first { $0.id.uuidString == serverId }
    }
}

/// Completion tally for `FleetApplyExecutor.execute`'s progress callback.
/// An actor rather than a lock because the group's children report from
/// arbitrary threads and the count must be monotonic for the UI to read.
private actor ProgressCounter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
