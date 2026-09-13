import Foundation

/// A config field that "apply to fleet" can push from a source project's
/// host onto other hosts (Phase-1 item #4, config-as-policy).
///
/// Only **host-portable** config is here. Model preset and board are pure
/// references (a preset UUID, a tenant slug) with no embedded paths, so
/// they copy cleanly. Cron is host-COUPLED — its prompts embed the
/// source host's absolute project path — so cron apply rewrites those
/// paths to the target's root (`FleetApplyPlan.rewriteCronPrompt`). Tool/
/// skill scoping is deferred upstream (hermes-agent#45958) and so is not
/// a field here.
public enum FleetApplyField: String, Sendable, CaseIterable {
    case modelPreset
    case board
    case cron

    public var label: String {
        switch self {
        case .modelPreset: return "Model preset"
        case .board:       return "Board"
        case .cron:        return "Cron jobs"
        }
    }
}

/// A computed, previewable plan for applying a source project's config to
/// a set of target hosts. **Pure** — built from records only, no I/O. The
/// Mac-target `FleetApplyExecutor` consumes it and performs the writes,
/// reporting actual results back; this type is the intent + the preview.
///
/// Each target carries a per-field `Disposition` (`apply` with a summary,
/// or `skip` with a reason) so the user sees exactly what will change —
/// and what *won't*, like a board kept to protect its existing tasks —
/// before committing.
public struct FleetApplyPlan: Sendable, Equatable {

    /// The stable id being applied across the fleet.
    public let projectID: UUID
    /// `ServerContext.id.uuidString` of the source (the host whose config
    /// is being pushed).
    public let sourceServerId: String
    /// The source host's project root — the path that cron-prompt
    /// rewriting replaces with each target's root.
    public let sourceRootPath: String
    public var targets: [Target]

    public init(projectID: UUID, sourceServerId: String, sourceRootPath: String, targets: [Target]) {
        self.projectID = projectID
        self.sourceServerId = sourceServerId
        self.sourceRootPath = sourceRootPath
        self.targets = targets
    }

    public struct Target: Sendable, Equatable, Identifiable {
        public let serverId: String
        public let serverDisplayName: String?
        /// The target host's own project root — where cron prompts get
        /// rewritten to, and the path the manifest writers address.
        public let rootPath: String
        public var actions: [Action]

        public init(serverId: String, serverDisplayName: String?, rootPath: String, actions: [Action]) {
            self.serverId = serverId
            self.serverDisplayName = serverDisplayName
            self.rootPath = rootPath
            self.actions = actions
        }

        public var id: String { serverId }

        /// True when at least one field will actually be written.
        public var willChange: Bool { actions.contains { $0.disposition.isApply } }
    }

    public struct Action: Sendable, Equatable {
        public let field: FleetApplyField
        public let disposition: Disposition

        public init(field: FleetApplyField, disposition: Disposition) {
            self.field = field
            self.disposition = disposition
        }
    }

    public enum Disposition: Sendable, Equatable {
        /// Will write; payload is a short human summary ("set board scarf:x").
        case apply(String)
        /// Won't write; payload is the reason ("already matches",
        /// "target already has a board").
        case skip(String)

        public var isApply: Bool { if case .apply = self { return true }; return false }

        public var detail: String {
            switch self {
            case .apply(let s): return s
            case .skip(let s):  return s
            }
        }
    }

    /// Targets that will actually change at least one field.
    public var effectiveTargets: [Target] { targets.filter(\.willChange) }

    // MARK: - Planning (pure)

    /// Which fields the SOURCE actually carries a value for — the only
    /// fields it makes sense to offer in the UI. You can't push a model
    /// preset you don't have, a board you haven't minted, or cron jobs
    /// that don't exist.
    public static func applicableFields(source: ScarfProject) -> Set<FleetApplyField> {
        var fields: Set<FleetApplyField> = []
        if let p = source.modelPresetId, !p.isEmpty { fields.insert(.modelPreset) }
        if let b = source.board, !b.isEmpty { fields.insert(.board) }
        if !source.cronJobIds.isEmpty { fields.insert(.cron) }
        return fields
    }

    /// Build the plan: for each target, decide each chosen field's
    /// disposition. Pure — decides from the records alone. (The executor
    /// does the finer-grained per-cron-job idempotency at write time; the
    /// plan's cron line is the intent.)
    ///
    /// `presetHosts` is the set of `serverId`s on which the SOURCE's model
    /// preset UUID actually resolves to a preset (see `Disposition` below);
    /// `nil` means the caller couldn't probe and availability is treated as
    /// unknown-but-present. `copyableCronCount` is the count from
    /// `copyableCronJobs` — the SAME set the executor iterates — so the
    /// preview can never advertise jobs the executor won't touch; `nil`
    /// falls back to the record's coarse `cronJobIds` count.
    public static func make(
        source: FleetMaterialization,
        targets: [FleetMaterialization],
        fields: Set<FleetApplyField>,
        presetHosts: Set<String>? = nil,
        copyableCronCount: Int? = nil
    ) -> FleetApplyPlan {
        let src = source.project
        let planTargets: [Target] = targets.map { t in
            // Stable field order via allCases.
            let actions: [Action] = FleetApplyField.allCases
                .filter { fields.contains($0) }
                .map {
                    Action(
                        field: $0,
                        disposition: disposition(
                            $0,
                            source: src,
                            target: t.project,
                            targetServerId: t.serverId,
                            presetHosts: presetHosts,
                            copyableCronCount: copyableCronCount
                        )
                    )
                }
            return Target(
                serverId: t.serverId,
                serverDisplayName: t.serverDisplayName,
                rootPath: t.project.rootPath,
                actions: actions
            )
        }
        return FleetApplyPlan(
            projectID: src.id,
            sourceServerId: source.serverId,
            sourceRootPath: src.rootPath,
            targets: planTargets
        )
    }

    /// Decide one field's disposition for one target. The board rule is
    /// **additive**: a target that already has a (non-matching) tenant is
    /// kept as-is — overwriting would orphan its existing board tasks.
    /// Model is overwrite-safe (reversible re-bind). Cron is recreate-on-
    /// target (the executor skips by name for idempotency).
    ///
    /// **Model presets are per-host records, not portable values.** A
    /// `modelPresetId` is a UUID minted into THIS host's
    /// `~/.hermes/scarf/model_presets.json` (`ModelPresetService`); the same
    /// UUID means nothing on another host's store. Pushing it would bind the
    /// target project to a preset that doesn't exist there — a dangling
    /// reference that reads as "configured" in every UI and silently resolves
    /// to the global default at run time. So the preset is applied ONLY to
    /// hosts whose store actually holds that id (`presetHosts`), and every
    /// other host gets an explicit, explained `.skip` — never a silent drop
    /// and never a silent "success".
    static func disposition(
        _ field: FleetApplyField,
        source: ScarfProject,
        target: ScarfProject,
        targetServerId: String,
        presetHosts: Set<String>? = nil,
        copyableCronCount: Int? = nil
    ) -> Disposition {
        switch field {
        case .modelPreset:
            guard let preset = source.modelPresetId, !preset.isEmpty else {
                return .skip("source has no model preset bound")
            }
            if target.modelPresetId == preset { return .skip("already matches") }
            if let presetHosts, !presetHosts.contains(targetServerId) {
                return .skip("preset \(String(preset.prefix(8))) doesn't exist on this host "
                    + "(model presets are per-host) — create it there, then apply")
            }
            return .apply("set model preset")

        case .board:
            guard let board = source.board, !board.isEmpty else {
                return .skip("source has no board")
            }
            if let tb = target.board, !tb.isEmpty {
                return tb == board
                    ? .skip("already matches")
                    : .skip("target already has a board (kept to protect its tasks)")
            }
            return .apply("set board \(board)")

        case .cron:
            // The count MUST come from the same `copyableCronJobs` set the
            // executor iterates; `cronJobIds` is the record's broader
            // attribution (it also indexes legacy `[tmpl:<id>]` jobs, which
            // fleet-apply does not copy), so previewing from it describes
            // jobs the executor will never touch.
            let count = copyableCronCount ?? source.cronJobIds.count
            guard count > 0 else { return .skip("source has no copyable project cron jobs") }
            return .apply("recreate up to \(count) cron job\(count == 1 ? "" : "s")")
        }
    }

    // MARK: - Cron copy set (single source of truth)

    /// The `[proj:<id>]` name tag a project's cron jobs carry. Both the
    /// preview and the executor derive the copy set from this one function.
    public static func projectCronTag(_ projectID: UUID) -> String {
        "[proj:\(projectID.uuidString)]"
    }

    /// Which of a host's cron jobs fleet-apply can actually recreate
    /// elsewhere, plus the reasons the rest were left out.
    ///
    /// **This is the single source of truth for "which jobs".** The plan
    /// preview counts `copyable` and the executor iterates `copyable`, so the
    /// number the user approves is the number the executor acts on.
    public struct CronCopySet: Sendable, Equatable {
        /// Jobs that will be recreated on each target, in source order.
        public var copyable: [HermesCronJob]
        /// Script-only (`no_agent`) jobs — their behavior is a `script` FILE
        /// on the source host that fleet-apply doesn't replicate.
        public var scriptOnly: [HermesCronJob]
        /// Monitor jobs (`monitor_script` / `monitor_url`) — round-4
        /// decision 8. Their behaviour is "run the agent only when this
        /// source's output CHANGED", and the source is a script path on the
        /// source host that fleet-apply does not replicate, or a URL whose
        /// hash state (`monitor_state`) does not travel. Recreating one
        /// without its source yields an agent job that runs on every tick, so
        /// it is declined and surfaced exactly as `scriptOnly` is, rather
        /// than copied degraded under a green "created".
        public var monitor: [HermesCronJob]
        /// Jobs whose schedule carries no field we can rebuild a `cron
        /// create` argument from.
        public var unsupportedSchedule: [HermesCronJob]

        /// Every job the pass will NOT create, with the two reasons kept
        /// separate for copy but summed where the verdict is the same.
        public var declined: [HermesCronJob] { scriptOnly + monitor }

        public init(
            copyable: [HermesCronJob] = [],
            scriptOnly: [HermesCronJob] = [],
            monitor: [HermesCronJob] = [],
            unsupportedSchedule: [HermesCronJob] = []
        ) {
            self.copyable = copyable
            self.scriptOnly = scriptOnly
            self.monitor = monitor
            self.unsupportedSchedule = unsupportedSchedule
        }
    }

    /// Partition `jobs` (a host's full `jobs.json`) into the fleet-copy set
    /// for `projectID`. Pure.
    public static func copyableCronJobs(from jobs: [HermesCronJob], projectID: UUID) -> CronCopySet {
        let tag = projectCronTag(projectID)
        var set = CronCopySet()
        for job in jobs where job.name.hasPrefix(tag) {
            if job.noAgent == true {
                set.scriptOnly.append(job)
            } else if shouldSkipMonitorJob(job) {
                set.monitor.append(job)
            } else if CronScheduleArgument.resolve(job.schedule) == nil {
                set.unsupportedSchedule.append(job)
            } else {
                set.copyable.append(job)
            }
        }
        return set
    }

    // MARK: - Cron prompt path rewriting (pure)

    /// Rewrite occurrences of the source host's project root in a cron
    /// prompt to the target host's root. The same logical project lives
    /// at different absolute paths per host, and Hermes runs cron jobs
    /// with no CWD — so a fully-qualified prompt copied verbatim would
    /// point at the *source* host's filesystem. This swaps the root.
    ///
    /// **Boundary-aware (conservative).** The root is only replaced when
    /// the character after the match is a path boundary — `/`, whitespace,
    /// a quote, or end-of-string — so a root that's a *prefix* of an
    /// unrelated path (`/work/proj` vs `/work/proj2`) is left intact, and
    /// unrelated text is never corrupted. It can under-replace on exotic
    /// punctuation (`…/proj.`), but the bias is deliberate: never mangle a
    /// prompt, even at the cost of missing a rare boundary.
    public static func rewriteCronPrompt(_ prompt: String, sourceRoot: String, targetRoot: String) -> String {
        let s = normalizeRoot(sourceRoot)
        let t = normalizeRoot(targetRoot)
        guard !s.isEmpty, s != t else { return prompt }

        var result = ""
        var searchStart = prompt.startIndex
        while let range = prompt.range(of: s, range: searchStart..<prompt.endIndex) {
            result += prompt[searchStart..<range.lowerBound]
            let isBoundary: Bool
            if range.upperBound == prompt.endIndex {
                isBoundary = true
            } else {
                let next = prompt[range.upperBound]
                isBoundary = next == "/" || next == " " || next == "\t"
                    || next == "\n" || next == "\"" || next == "'"
            }
            // On a real boundary, swap in the target root; otherwise
            // re-emit the *matched* slice (not the normalized source) so a
            // canonical-but-not-byte-identical match is preserved verbatim.
            result += isBoundary ? t : String(prompt[range])
            searchStart = range.upperBound
        }
        result += prompt[searchStart..<prompt.endIndex]
        return result
    }

    /// Strip trailing slashes (keep a lone "/") and surrounding
    /// whitespace so the prefix match is path-clean.
    private static func normalizeRoot(_ path: String) -> String {
        var s = path.trimmingCharacters(in: .whitespaces)
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Build the `hermes cron create` argv for copying `job` from the source
    /// host to a target host, forwarding only the flags that target's `caps`
    /// understand and rewriting project paths source→target.
    ///
    /// **Capability gating (mixed-version fleets).** `--deliver all` is a
    /// v0.14+ value (`caps.hasCronDeliverAll`): on an older target argparse
    /// rejects it and the whole `cron create` fails, so we DROP `--deliver`
    /// (the job is still created, falling back to Hermes's default delivery)
    /// and report it via the returned `droppedDeliverAll` so the caller can
    /// surface the downgrade. The match is exact — `"all"` is Hermes's single
    /// v0.14 fan-out sentinel; a specific platform (`discord`, `discord:chan`,
    /// `telegram:chat`) is baseline and always forwarded unchanged. `--workdir`
    /// is a v0.12+ flag (`caps.hasCronWorkdir`); it's path-rewritten
    /// source→target like the prompt, and omitted on a pre-v0.12 target (which
    /// also matches the pre-existing behavior of dropping workdir entirely).
    ///
    /// Pass `.empty` caps to be conservative (drop the version-gated flags) —
    /// e.g. when the target's `hermes --version` probe failed.
    ///
    /// **`repeat` IS forwarded** (round-6 decision 7). The claim above that
    /// it is "not modeled on `HermesCronJob`" stopped being true at P38,
    /// which added `repeatSpec` — the note outlived the code it described,
    /// and a bounded source job (`repeat.times = 3`) was copied UNBOUNDED,
    /// running forever on every target. `--repeat` takes no capability gate:
    /// `cron_create.add_argument("--repeat", type=int, …)` is present at
    /// every tag Scarf supports — `hermes_cli/subcommands/cron.py:38` @
    /// `v2026.9.7` and `hermes_cli/main.py:3936` @ `v2026.3.30` (0.6.0, the
    /// charter's minimum) — and first appears at `v2026.3.17` (0.3.0), below
    /// the floor. An older target therefore renders it IDENTICALLY: the flag
    /// parses, `normalize_repeat_value` coerces it (`cron/jobs.py:591`), and
    /// the copy is bounded exactly as the source is. `repeat.completed` is
    /// deliberately NOT carried — a fresh job has run zero times, and
    /// `create_job` stamps `{"times": repeat, "completed": 0}` regardless
    /// (`cron/jobs.py:1779`).
    ///
    /// NOT forwarded, each with a concrete reason (all dropped today too):
    /// - `context_from` — YAML-only; Hermes exposes no `--context-from` CLI flag.
    /// - `pre_run_script` / `no_agent` — `pre_run_script` is a FILE PATH on the
    ///   source host that fleet-apply does not replicate to the target, so
    ///   forwarding `--script` would dangle. `no_agent` (script-only) jobs are
    ///   therefore skipped + surfaced by the caller, not built here. A
    ///   script-replicating copy is tracked separately.
    /// - `model` / `provider` / `reasoning_effort` — the inference PIN. Not
    ///   forwarded because the source's model reference may not be configured
    ///   on the target at all (`cron create --model` would land a job that
    ///   errors at first run), and `_compute_provider_model_snapshots`
    ///   (`cron/jobs.py:1599-1620` @ `v2026.9.7`) resolves the unpinned axes
    ///   against the TARGET's own config, which is the honest answer for a
    ///   copy. Round-6 decision 8 makes it a DOWNGRADE NOTE rather than a
    ///   silence, in the P50 `pre_run_script` shape: `HermesCronJob.hasModelPin`
    ///   is the predicate, `FleetApplyViewModel.caveats` the preview seam and
    ///   `FleetApplyExecutor`'s `modelPinDowngrades` the report seam.
    /// - `silent` — JSON-only field; `cron create` has no flag for it.
    /// - `monitor_script` / `monitor_url` / `--continuity` — NOT dropped
    ///   silently any more. A monitor job's whole behaviour is "run the agent
    ///   only when this source's output changed" (`hermes cron create
    ///   --monitor-script`, `hermes_cli/subcommands/cron.py:51-62` @
    ///   `v2026.9.7`); the source is a script path on the SOURCE host that
    ///   fleet-apply does not replicate, or a URL whose hash state
    ///   (`monitor_state`) does not travel. Re-creating one without its
    ///   source produces an ordinary agent job that runs — and bills — on
    ///   every tick. Round-4 decision 8: the caller SKIPS these and surfaces
    ///   them exactly as it surfaces `no_agent` jobs, so the pass never
    ///   reports a silently-degraded job as "created". `shouldSkipMonitorJob`
    ///   is the predicate; the counting lives in `FleetApplyExecutor`.
    /// `schedule` is a STRUCTURED `CronScheduleArgument` (cron expression /
    /// interval minutes / one-shot timestamp), not a free-text string — see
    /// that type for why the job's human `display` is never round-tripped.
    /// Whether a fleet copy must decline this record rather than degrade it.
    ///
    /// A monitor job (`monitor_script` / `monitor_url`) is the shape: its
    /// source does not travel, and the copy would run the agent every tick
    /// instead of only on a change. `--continuity` is NOT on its own a reason
    /// to skip — it is stored as `"self"` in `context_from`
    /// (`tools/cronjob_job_args.py:313-321` @ `v2026.9.7`), the copy simply
    /// starts its own history, and the first run of a continuity job is
    /// unchanged by design (`hermes_cli/subcommands/cron.py:76-84`). It is
    /// reported as a downgrade note, not a refusal.
    public static func shouldSkipMonitorJob(_ job: HermesCronJob) -> Bool {
        job.isMonitorJob
    }

    public static func cronCreateArgs(
        copying job: HermesCronJob,
        schedule: CronScheduleArgument,
        caps: HermesCapabilities,
        sourceRoot: String,
        targetRoot: String,
        paused: Bool = false
    ) -> (args: [String], droppedDeliverAll: Bool) {
        let (args, droppedDeliverAll) = cronCreateArgs(
            name: job.name,
            deliver: job.deliver,
            failureDeliver: job.failureDeliver,
            // Round-6 decision 7. `nil` means "run forever" on both sides —
            // `repeatSpec.times` is `nil` for an unbounded job and
            // `create_job` stores `{"times": None, …}` for a missing
            // `--repeat` (`cron/jobs.py:1779`) — so an unbounded source
            // still emits no flag and nothing changes for it.
            repeatCount: job.repeatSpec.times,
            skills: job.skills ?? [],
            workdir: job.workdir.map { rewriteCronPrompt($0, sourceRoot: sourceRoot, targetRoot: targetRoot) },
            schedule: schedule.argumentValue,
            prompt: rewriteCronPrompt(job.prompt, sourceRoot: sourceRoot, targetRoot: targetRoot),
            caps: caps,
            paused: paused
        )
        return (args, droppedDeliverAll)
    }

    /// The ONE `hermes cron create` argv builder. Every caller that creates
    /// a cron job goes through this — the fleet copier above and the
    /// project-template installer — so the capability gates (`--deliver`
    /// grammar, `--failure-deliver`, `--paused`, `--workdir`) and the `--`
    /// end-of-options marker are decided in one place instead of being
    /// re-derived, differently, per call site.
    ///
    /// `droppedDeliverAll` reports that a `--deliver` value the target host
    /// cannot parse was omitted; the job is still created and still
    /// delivers, so the caller surfaces it as a note, not a failure.
    public static func cronCreateArgs(
        name: String,
        deliver: String?,
        failureDeliver: String? = nil,
        repeatCount: Int? = nil,
        skills: [String] = [],
        workdir: String? = nil,
        schedule: String,
        prompt: String?,
        caps: HermesCapabilities,
        paused: Bool = false
    ) -> (args: [String], droppedDeliverAll: Bool) {
        var args = ["cron", "create", HermesCLIOption.joined("--name", name)]
        var droppedDeliverAll = false

        if let deliver, !deliver.isEmpty {
            if caps.supportsCronDeliver(deliver) {
                args.append(HermesCLIOption.joined("--deliver", deliver))
            } else {
                droppedDeliverAll = true
            }
        }
        // v0.21.1 `--failure-deliver`. Two gates, both required: the FLAG is
        // unknown to older argparse (`hasCronFailureDeliver`), and its VALUE
        // shares `--deliver`'s grammar, so a `bot-chat`/`all` target that the
        // target host can't parse must be dropped exactly as the deliver lane
        // drops it. A dropped failure lane is not `droppedDeliverAll` — the
        // copy still delivers, failures just follow `deliver` as they did
        // before the feature existed.
        if caps.hasCronFailureDeliver,
           let failureDeliver, !failureDeliver.isEmpty,
           caps.supportsCronDeliver(failureDeliver) {
            args.append(HermesCLIOption.joined("--failure-deliver", failureDeliver))
        }
        if let repeatCount { args.append(HermesCLIOption.joined("--repeat", String(repeatCount))) }
        // v0.21.1 `--paused`: create disabled in ONE write. Callers that pass
        // `true` keep a create-then-`cron pause` fallback for older hosts —
        // the flag itself is fatal to argparse there.
        if paused, caps.hasCronCreatePaused { args.append("--paused") }
        for skill in skills where !skill.isEmpty { args.append(HermesCLIOption.joined("--skill", skill)) }
        if let workdir, !workdir.isEmpty, caps.hasCronWorkdir {
            args.append(HermesCLIOption.joined("--workdir", workdir))
        }
        // `--` ends the options: the positionals below are user text, and a
        // prompt or schedule beginning with `-` would otherwise be read as
        // an unknown flag (argparse exit 2, aborting the whole apply).
        args.append("--")
        args.append(schedule)
        if let prompt, !prompt.isEmpty { args.append(prompt) }
        return (args, droppedDeliverAll)
    }
}
