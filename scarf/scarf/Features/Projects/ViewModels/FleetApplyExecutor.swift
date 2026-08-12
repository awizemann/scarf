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
        let message: String
        var id: String { field.rawValue }
        nonisolated enum Status: Sendable { case applied, skipped, failed }
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
    nonisolated func execute(_ plan: FleetApplyPlan, source: ScarfProject) -> [TargetResult] {
        // Read the source host's project cron jobs once, only if some
        // target actually applies cron.
        let appliesCron = plan.targets.contains { t in
            t.actions.contains { $0.field == .cron && $0.disposition.isApply }
        }
        var sourceCronJobs: [HermesCronJob] = []
        if appliesCron, let srcCtx = context(for: plan.sourceServerId) {
            let tag = "[proj:\(plan.projectID.uuidString)]"
            sourceCronJobs = HermesFileService(context: srcCtx).loadCronJobs().filter {
                $0.name.hasPrefix(tag)
            }
        }

        return plan.targets.map { target in
            execute(target: target, plan: plan, source: source, sourceCronJobs: sourceCronJobs)
        }
    }

    private nonisolated func execute(
        target: FleetApplyPlan.Target,
        plan: FleetApplyPlan,
        source: ScarfProject,
        sourceCronJobs: [HermesCronJob]
    ) -> TargetResult {
        guard let ctx = context(for: target.serverId) else {
            // Host is in a record's binding but no longer registered here.
            let fields = target.actions.map {
                FieldResult(field: $0.field, status: .failed, message: "server not registered on this Mac")
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
                    fieldResults.append(FieldResult(field: .modelPreset, status: .applied, message: "bound model preset"))
                } catch {
                    fieldResults.append(FieldResult(field: .modelPreset, status: .failed, message: error.localizedDescription))
                }
            case .board:
                do {
                    try KanbanTenantResolver(context: ctx).setTenant(source.board ?? "", for: entry)
                    fieldResults.append(FieldResult(field: .board, status: .applied, message: "set board \(source.board ?? "")"))
                } catch {
                    fieldResults.append(FieldResult(field: .board, status: .failed, message: error.localizedDescription))
                }
            case .cron:
                fieldResults.append(
                    applyCron(sourceJobs: sourceCronJobs, to: ctx, sourceRoot: plan.sourceRootPath, targetRoot: target.rootPath)
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
        targetRoot: String
    ) -> FieldResult {
        guard !sourceJobs.isEmpty else {
            return FieldResult(field: .cron, status: .skipped, message: "source has no project cron jobs")
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
        var createdNames: [String] = []

        for job in sourceJobs {
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
            guard let scheduleArg = Self.scheduleArg(job.schedule) else {
                failed += 1
                continue
            }
            let (args, droppedDeliverAll) = FleetApplyPlan.cronCreateArgs(
                copying: job,
                schedule: scheduleArg,
                caps: caps,
                sourceRoot: sourceRoot,
                targetRoot: targetRoot
            )

            let (_, exit) = ctx.runHermes(args)
            if exit == 0 {
                created += 1
                createdNames.append(job.name)
                if droppedDeliverAll { deliverAllDowngrades += 1 }
            } else {
                failed += 1
            }
        }

        // Created jobs land enabled — pause them (mirror the installer) so
        // a fleet push never silently arms autonomous cron on a remote.
        // Count how many we actually managed to pause; an unpaused created
        // job is the one outcome the user must SEE (it's live on a remote),
        // so it goes in the result message, not just a log line.
        var paused = 0
        if !createdNames.isEmpty {
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
                ? "\(created) created (paused)"
                : "\(created) created, \(unpaused) could NOT be paused — verify on host")
        }
        if skipped > 0 { parts.append("\(skipped) already present") }
        if scriptOnlySkipped > 0 { parts.append("\(scriptOnlySkipped) script-only skipped") }
        if failed > 0 { parts.append("\(failed) failed") }
        // A deliver=all downgrade is a created-but-degraded job (runs with
        // Hermes's default delivery, not fan-out) — the user must SEE it,
        // same rationale as the unpaused-job note above.
        if deliverAllDowngrades > 0 {
            parts.append("\(deliverAllDowngrades) w/o deliver=all (host < v0.14)")
        }
        // `.failed` only when nothing landed; a created-but-unpaused job
        // still applied (its live state is surfaced in the message above).
        let status: FieldResult.Status = (created == 0 && failed > 0) ? .failed : .applied
        return FieldResult(field: .cron, status: status, message: parts.isEmpty ? "no changes" : parts.joined(separator: ", "))
    }

    /// The positional schedule arg `hermes cron create` expects — prefer
    /// the cron expression, fall back to the run-at timestamp, then the
    /// human display. `nil` when the schedule carries none (can't recreate).
    private nonisolated static func scheduleArg(_ schedule: CronSchedule) -> String? {
        if let e = schedule.expression, !e.isEmpty { return e }
        if let r = schedule.runAt, !r.isEmpty { return r }
        if let d = schedule.display, !d.isEmpty { return d }
        return nil
    }

    private nonisolated func context(for serverId: String) -> ServerContext? {
        contexts.first { $0.id.uuidString == serverId }
    }
}
