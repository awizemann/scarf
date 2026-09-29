import Foundation
import ScarfCore
import os

/// Executes a `TemplateInstallPlan`. All writes happen in one pass with
/// early-fail semantics: if any step throws, later steps don't run (but
/// earlier ones aren't reversed — v1 doesn't ship an atomic rollback). The
/// plan has already verified `projectDir` doesn't exist and no conflicting
/// file exists at target paths, so by the time we start writing, the
/// expected-error surface is small (mostly I/O failures).
struct ProjectTemplateInstaller: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "ProjectTemplateInstaller")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    /// Apply the plan. On success, returns the `ProjectEntry` that was added
    /// to the registry so the caller can set `AppCoordinator.selectedProjectName`.
    @discardableResult
    nonisolated func install(plan: TemplateInstallPlan) throws -> ProjectEntry {
        try bootstrapProjectsRoot(plan: plan)
        try preflight(plan: plan)
        try createProjectFiles(plan: plan)
        try createSkillsFiles(plan: plan)
        try appendMemoryIfNeeded(plan: plan)
        // Minted before the cron jobs so each job's name can carry it
        // (`ProjectCronAttribution`): the template tag alone is shared by
        // every project installed from the same template.
        let projectID = UUID()
        let cronJobNames = try createCronJobs(plan: plan, projectID: projectID)
        let entry = try registerProject(plan: plan, projectID: projectID)
        try writeLockFile(plan: plan, cronJobNames: cronJobNames)

        // Write the canonical .scarf/project.json now that all facets exist
        // on disk (manifest, config, cron, and — just above — the lock file),
        // so derive() captures templateLockRef + memoryNamespace too. Reuses
        // the registry entry's minted UUID as the stable id. Non-fatal: a
        // missing record is re-derived by lazy migration; the registry row
        // already drives sidebar visibility.
        do {
            let store = ProjectStore(context: context)
            try store.save(store.derive(from: entry))
        } catch {
            Self.logger.warning("install couldn't write project.json for \(plan.projectRegistryName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // Mirror resolved Keychain secrets into ~/.hermes/.env so the
        // template's cron jobs (and any other agent process Hermes
        // spawns) can use them via $SCARF_<SLUG>_<FIELD>. Hermes
        // reloads .env fresh on every cron tick, so this takes effect
        // without a restart. Failure is non-fatal — the install
        // itself succeeded; the launch-time reconciler retries on
        // next app start.
        do {
            try KeychainEnvMirror(context: context).mirror(project: entry)
        } catch {
            Self.logger.warning("install couldn't mirror secrets to ~/.hermes/.env: \(error.localizedDescription, privacy: .public)")
        }

        // P4 of the projects-feature fix: refresh the Scarf-managed
        // AGENTS.md block now (on a v0.16+ host, which takes the project
        // context as HERMES_ENVIRONMENT_HINT at chat start instead, `sync`
        // strips any block rather than writing one — #142) so installed-template projects get the
        // platform-reference + project bookkeeping section without
        // having to wait for the user to open a chat. Previously the
        // block was only written at chat-start, so an installed
        // project that the user inspected before chatting had a
        // template-author AGENTS.md with no Scarf context. Non-fatal —
        // a failed refresh just defers the block to chat-start (which
        // already calls refresh).
        do {
            try ProjectAgentContextService(context: context).sync(
                for: entry, capabilities: HermesVersionCache.shared.capabilitiesSync(for: context))
        } catch {
            Self.logger.warning("install couldn't refresh AGENTS.md block: \(error.localizedDescription, privacy: .public)")
        }

        Self.logger.info("installed template \(plan.manifest.id, privacy: .public) v\(plan.manifest.version, privacy: .public) into \(plan.projectDir, privacy: .public)")
        return entry
    }

    // MARK: - Bootstrap

    /// Idempotently `mkdir -p` the parent directory so a fresh remote
    /// host (or a local user with no `~/Projects`) can complete the
    /// first install. Runs *before* preflight — preflight then checks
    /// the project dir itself, which we deliberately don't create
    /// here so the "already exists" collision check still fires for
    /// repeat installs at the same path.
    ///
    /// Safe on both transports: `LocalTransport.createDirectory` uses
    /// `withIntermediateDirectories: true`; `SSHTransport.createDirectory`
    /// runs `mkdir -p`. Idempotent for existing dirs in both cases.
    nonisolated private func bootstrapProjectsRoot(plan: TemplateInstallPlan) throws {
        let parentDir = (plan.projectDir as NSString).deletingLastPathComponent
        guard !parentDir.isEmpty, parentDir != "/" else { return }
        try context.makeTransport().createDirectory(parentDir)
    }

    // MARK: - Preflight

    nonisolated private func preflight(plan: TemplateInstallPlan) throws {
        // Plan was built on a recent snapshot of the filesystem; re-check the
        // invariants at install time so concurrent activity between
        // preview-and-confirm can't slip past us.
        //
        // All existence and read checks for paths that come from
        // `context.paths` go through the transport — not `FileManager` —
        // so this code works identically against a future remote
        // `ServerContext`. See the warning on `ServerContext.readText`:
        // "Foundation file APIs are LOCAL ONLY — using them with a remote
        // path silently returns nil because the remote path doesn't exist
        // on this Mac."
        let transport = context.makeTransport()
        if transport.fileExists(plan.projectDir) {
            throw ProjectTemplateError.projectDirExists(plan.projectDir)
        }
        // A row whose folder is gone passes the check above. Refused here,
        // before anything is written; `registerProjectLocked` re-checks
        // under the registry lock.
        try Self.refuseRegisteredPath(
            plan.projectDir,
            in: ProjectDashboardService(context: context).loadRegistry().projects
        )
        for copy in plan.projectFiles where transport.fileExists(copy.destinationPath) {
            throw ProjectTemplateError.conflictingFile(copy.destinationPath)
        }
        for copy in plan.skillsFiles where transport.fileExists(copy.destinationPath) {
            throw ProjectTemplateError.conflictingFile(copy.destinationPath)
        }
        // Memory appendix collision: re-scan MEMORY.md for an existing block
        // with the same template id so two installs of v1.0.0 can't
        // double-append. A missing MEMORY.md is fine (treated as empty),
        // but any *other* read failure (permissions, bad file type) gets
        // logged + surfaced so we don't silently pretend MEMORY.md is empty
        // and append over a broken file.
        if plan.memoryAppendix != nil {
            // Same guarded read the append itself makes — a file we can't
            // read or can't decode fails preflight rather than being
            // treated as empty (which would clear the collision check AND,
            // before t-05a7c23d, get overwritten wholesale).
            let existing = try Self.memoryText(
                of: Self.inspectMemory(at: plan.memoryPath, transport: transport),
                at: plan.memoryPath
            )
            // Either marker form: a block an older Scarf installed is still
            // this template's block.
            if ProjectTemplateService.memoryBlockMarkers(in: existing, templateId: plan.manifest.id) != nil {
                throw ProjectTemplateError.memoryBlockAlreadyExists(plan.manifest.id)
            }
        }
    }

    // MARK: - Project files

    nonisolated private func createProjectFiles(plan: TemplateInstallPlan) throws {
        let transport = context.makeTransport()
        try transport.createDirectory(plan.projectDir)
        for copy in plan.projectFiles {
            let parent = (copy.destinationPath as NSString).deletingLastPathComponent
            try transport.createDirectory(parent)

            // Empty `sourceRelativePath` is the "synthesized content"
            // sentinel used by `buildPlan` for `.scarf/config.json`.
            // The installer materialises config.json from
            // `plan.configValues` here rather than copying a bundle
            // file that doesn't exist.
            if copy.sourceRelativePath.isEmpty {
                if copy.destinationPath.hasSuffix("/.scarf/config.json") {
                    let data = try encodeConfigFile(plan: plan)
                    // UNGUARDED-WRITE(C): install-time copy from the unpacked template bundle.
                    try transport.unguardedWriteFile(copy.destinationPath, data: data)
                    continue
                }
                throw ProjectTemplateError.requiredFileMissing(
                    "synthesized file with unknown destination: \(copy.destinationPath)"
                )
            }

            let source = plan.unpackedDir + "/" + copy.sourceRelativePath
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            // UNGUARDED-WRITE(C): install-time copy from the unpacked template bundle.
            try transport.unguardedWriteFile(copy.destinationPath, data: data)
        }
    }

    /// Serialise `plan.configValues` into the `<project>/.scarf/config.json`
    /// shape. Secrets appear as `keychainRef` URIs — the raw bytes were
    /// routed into the Keychain by the VM before `install()` was called.
    nonisolated private func encodeConfigFile(plan: TemplateInstallPlan) throws -> Data {
        let file = ProjectConfigFile(
            schemaVersion: 2,
            templateId: plan.manifest.id,
            values: plan.configValues,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    // MARK: - Skills

    nonisolated private func createSkillsFiles(plan: TemplateInstallPlan) throws {
        guard let namespaceDir = plan.skillsNamespaceDir else { return }
        let transport = context.makeTransport()
        try transport.createDirectory(namespaceDir)
        for copy in plan.skillsFiles {
            let source = plan.unpackedDir + "/" + copy.sourceRelativePath
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            let parent = (copy.destinationPath as NSString).deletingLastPathComponent
            try transport.createDirectory(parent)
            // UNGUARDED-WRITE(C): install-time copy of a template skill file from the unpacked bundle.
            try transport.unguardedWriteFile(copy.destinationPath, data: data)
        }
    }

    // MARK: - Memory

    /// Append the template's memory block to MEMORY.md.
    ///
    /// **Guarded (t-05a7c23d, the DI-C2 class).** This is a whole-file
    /// read-modify-write of the user's own long-lived prose, and it opened
    /// with `(try? readFile).flatMap { String(data:encoding:.utf8) } ?? ""`
    /// — which turned BOTH a dropped SSH round-trip and a single non-UTF-8
    /// byte into an empty document, then published `"" + appendix` over the
    /// file. A template install would silently replace MEMORY.md with its
    /// own appendix. Same treatment W1 gave `ProjectContextBlock.writeBlock`:
    /// stat-confirmed proof of damage, a refusal on undecodable bytes, and
    /// a one-deep `MEMORY.md.bak` of whatever is replaced.
    ///
    /// SERIALIZED (GW-F3 / DI H4). `MEMORY.md` has three writers — this
    /// appendix, the uninstaller's strip, and the memory editor's save — and
    /// an append computed against bytes the editor is replacing publishes
    /// the user's previous draft back over their save. The read and the
    /// publish are one hold of `MEMORY.md`'s write lock, taken through
    /// `GuardedTextFile` so it is the same lock file the other two use.
    /// (The read itself stays on `inspectMemory`, which preflight shares.)
    nonisolated private func appendMemoryIfNeeded(plan: TemplateInstallPlan) throws {
        guard let appendix = plan.memoryAppendix else { return }
        let transport = context.makeTransport()
        try GuardedTextFile(context: context, label: "MEMORY.md")
            .withLock(plan.memoryPath) {
                let inspection = Self.inspectMemory(at: plan.memoryPath, transport: transport)
                let existing = try Self.memoryText(of: inspection, at: plan.memoryPath)
                let combined = ProjectTemplateService.appendingMemoryEntry(appendix, to: existing)
                guard let data = combined.data(using: .utf8) else {
                    throw ProjectTemplateError.requiredFileMissing("memory/append.md (non-UTF8)")
                }
                try GuardedJSONStore(transport: transport, label: "MEMORY.md")
                    .write(data, to: plan.memoryPath, after: inspection)
            }
    }

    /// One guarded read of MEMORY.md, shared by preflight and the append.
    nonisolated static func inspectMemory(
        at path: String, transport: any ServerTransport
    ) -> GuardedJSONStore.Inspection {
        // The house cap (32 MB), matching `ProjectTemplateUninstaller`'s
        // read of the SAME file and `ProjectContextBlock.maxAgentsBytes`.
        // It was `Int.max` on the grounds that MEMORY.md is the user's prose
        // rather than an index we decode — but that argues for a GENEROUS
        // bound, not for none, and `Int.max` additionally SKIPS the
        // stat-first probe, so an agent-writable file of any size was held
        // whole before anyone could object (GW-F5 / SEC F3).
        var inspection = GuardedJSONStore(transport: transport, label: "MEMORY.md")
            .inspect(path, maxBytes: GuardedTextFile.defaultMaxBytes)
        // An empty MEMORY.md is a normal file with nothing to lose.
        if case .unreadable = inspection.state, inspection.bytes?.isEmpty == true {
            inspection = GuardedJSONStore.Inspection(state: .absent, bytes: nil)
        }
        return inspection
    }

    nonisolated static func memoryText(
        of inspection: GuardedJSONStore.Inspection, at path: String
    ) throws -> String {
        switch inspection.state {
        case .absent:
            return ""
        case .unreadable(let damaged):
            throw ProjectTemplateError.memoryFileUnreadable(damaged)
        case .quarantined:
            throw ProjectTemplateError.memoryFileUnreadable(path)
        case .present:
            guard let text = String(data: inspection.bytes ?? Data(), encoding: .utf8) else {
                throw ProjectTemplateError.memoryFileNotText(path)
            }
            return text
        }
    }

    // MARK: - Cron

    /// Create each cron job via `hermes cron create`, paused. On v0.21.1+
    /// that is one write (`--paused`); older hosts create enabled and are
    /// paused immediately afterwards. Returns the list of resolved job
    /// names, which is what the lock file records — we don't know the job
    /// ids without parsing the create output, but the name is enough to
    /// find + remove them later. Each name carries the new project's tag
    /// after the template tag, which also makes it unique to this install.
    /// A cron job's skill references, pointed at where this install puts
    /// the skills the bundle ships.
    ///
    /// Bundled skills land at `skills/templates/<slug>/<name>/`
    /// (``ProjectTemplateService``), but a job's reference was the author's
    /// own id — `creative/pixel-art` for a categorized skill, which is what
    /// Scarf's cron editor stores. Hermes resolves a reference as a direct
    /// path under the skills dir or as a directory/frontmatter name equal to
    /// the WHOLE string (`tools/skills_tool.py:345-361` @ v2026.9.24), so
    /// `creative/pixel-art` never found `templates/<slug>/pixel-art` and every
    /// run went ahead without the skill ("could not be found",
    /// `cron/scheduler_prompt.py:190-198`). A bare `pixel-art` would resolve
    /// by directory name, but Hermes refuses a name two skills share
    /// (`_collect_skill_candidates`), so the exact path is used.
    ///
    /// A bare name the bundle ships (what a current export writes) is always
    /// rewritten. A `category/name` whose name the bundle ships — what an
    /// older export wrote — is rewritten only when it does not resolve on
    /// this host (`resolves`, a direct `<skills>/<ref>/SKILL.md`): a current
    /// export keeps a reference to a hub or Hermes-bundled skill as it is,
    /// and when that skill merely shares its name with one the bundle ships,
    /// it exists here and must keep pointing at itself. Every other
    /// reference is kept.
    nonisolated static func installedSkillRefs(
        _ refs: [String], bundled: [String], slug: String, resolves: (String) -> Bool = { _ in false }
    ) -> [String] {
        let shipped = Set(bundled)
        return refs.map { ref in
            let leaf = ref.split(separator: "/").last.map(String.init) ?? ref
            guard shipped.contains(leaf) else { return ref }
            if ref.contains("/"), resolves(ref) { return ref }
            return "templates/\(slug)/\(leaf)"
        }
    }

    nonisolated private func createCronJobs(
        plan: TemplateInstallPlan, projectID: UUID
    ) throws -> [String] {
        guard !plan.cronJobs.isEmpty else { return [] }

        var createdNames: [String] = []
        let transport = context.makeTransport()
        let skillsDir = context.paths.skillsDir

        // Probe the install host once: `--deliver all` is a v0.14+ value, and
        // forwarding it to an older host makes `hermes cron create` argparse-
        // fail → the throw below aborts the WHOLE template install. Gate it on
        // the host's capability (failed probe → .empty → conservative: drop).
        // A specific platform (`discord`, …) is baseline and always forwarded.
        // Shared with the window's capability store via `HermesVersionCache`,
        // so this is usually a cache hit rather than a fresh subprocess; a
        // failed probe still yields `.empty` (never a remembered value) —
        // flag gating must not run on an optimistic guess.
        let caps = HermesVersionCache.shared.capabilitiesSync(for: context)
        // Only the create-then-pause fallback needs the "what existed
        // before" snapshot, and taking it costs a `jobs.json` read on the
        // install host. On a `--paused` host there is no second step, so
        // there is nothing to diff against.
        let existingBefore = caps.hasCronCreatePaused
            ? []
            : Set(HermesFileService(context: context).loadCronJobs().map(\.id))

        for job in plan.cronJobs {
            let name = ProjectCronAttribution.templateJobName(
                job.name, templateId: plan.manifest.id, projectID: projectID
            )
            // ONE builder for every cron-create argv (M3): the capability
            // gates and the `--` end-of-options marker live in
            // `FleetApplyPlan.cronCreateArgs`, not in each call site.
            // Substitute template-author tokens with install-time values
            // first: Hermes doesn't set a CWD for cron runs, so any relative
            // path in the prompt would resolve against the agent's own dir.
            let (args, droppedDeliverAll) = FleetApplyPlan.cronCreateArgs(
                name: name,
                deliver: job.deliver,
                repeatCount: job.repeatCount,
                skills: Self.installedSkillRefs(
                    job.skills ?? [], bundled: plan.manifest.contents.skills ?? [], slug: plan.manifest.slug,
                    resolves: { transport.fileExists(skillsDir + "/" + $0 + "/SKILL.md") }),
                schedule: job.schedule,
                prompt: job.prompt.flatMap { $0.isEmpty ? nil : Self.substituteCronTokens($0, plan: plan) },
                caps: caps,
                // v0.21.1: created disabled in ONE write instead of the
                // create-then-`cron pause` two-step below, which leaves a
                // real window where an installed template's job can fire.
                paused: true
            )
            if droppedDeliverAll {
                Self.logger.warning("template cron '\(job.name, privacy: .public)': dropping --deliver \(job.deliver ?? "", privacy: .public) — install host predates v0.14 deliver=all; job created with default delivery")
            }

            let (output, exit) = context.runHermes(args)
            guard exit == 0 else {
                throw ProjectTemplateError.cronCreateFailed(job: job.name, output: output)
            }
            createdNames.append(name)
        }

        // Diff the current job set against the snapshot we took before
        // creating — anything new belongs to this install and gets paused.
        // We pause by id (not name) because `cron pause` takes an id.
        guard !caps.hasCronCreatePaused else { return createdNames }
        let currentJobs = HermesFileService(context: context).loadCronJobs()
        let newJobs = currentJobs.filter { !existingBefore.contains($0.id) && createdNames.contains($0.name) }
        for job in newJobs {
            let (_, exit) = context.runHermes(["cron", "pause", job.id])
            if exit != 0 {
                Self.logger.warning("couldn't pause newly-created cron job \(job.id, privacy: .public) — leaving enabled")
            }
        }

        return createdNames
    }

    // MARK: - Registry

    /// Append this install's row to `projects.json`.
    ///
    /// A read-modify-write, so it takes the cross-process lock around the
    /// WHOLE of it (t-07e909e0 / DI-H5) rather than leaving the load and
    /// the save on either side of a window a concurrent `project_register`
    /// can land in — which would append this row onto a list that no longer
    /// has the agent's, and publish the agent's row away. The load moves
    /// INSIDE the lock for the same reason, and its fingerprint travels to
    /// the save as `expecting:` so the remote case (where the lock is only
    /// a local stand-in) refuses instead of clobbering. Synchronous
    /// throughout: the lock's reentrancy is thread-local and must not span
    /// a suspension.
    nonisolated private func registerProject(
        plan: TemplateInstallPlan, projectID: UUID
    ) throws -> ProjectEntry {
        let service = ProjectDashboardService(context: context)
        guard let lock = RegistryWriteLock(context: context) else {
            return try registerProjectLocked(plan: plan, projectID: projectID, service: service)
        }
        return try lock.withLock(path: context.paths.projectsRegistry) {
            try registerProjectLocked(plan: plan, projectID: projectID, service: service)
        }
    }

    nonisolated private func registerProjectLocked(
        plan: TemplateInstallPlan, projectID: UUID, service: ProjectDashboardService
    ) throws -> ProjectEntry {
        let loaded = service.loadRegistryDetailed()
        var registry = loaded.registry
        // Mint the stable UUID at install time (parity with the scaffolder),
        // so the project is first-class from its first byte rather than
        // waiting on lazy migration — fleet/portfolio only groups projects
        // whose id somebody actually asserted. The canonical `project.json`
        // is written after the lock file lands (see install()).
        try Self.refuseRegisteredPath(plan.projectDir, in: registry.projects)
        let entry = ProjectEntry(name: plan.projectRegistryName, path: plan.projectDir, uuid: projectID)
        registry.projects.append(entry)
        // Must throw on failure — silent failure here used to make the
        // installer return a valid entry while the registry on disk
        // never got updated, producing the "install completed but the
        // project doesn't show up in the sidebar" bug. If the registry
        // write fails, the whole install is surfaced as failed so the
        // user can see + address the underlying problem.
        try service.saveRegistry(registry, expecting: loaded.contentFingerprint)
        return entry
    }

    /// Throw when a registry row already claims `path`, compared
    /// normalized — the rule `project_register` and `ProjectStore` hold.
    nonisolated static func refuseRegisteredPath(_ path: String, in projects: [ProjectEntry]) throws {
        let normalized = ProjectIdentity.normalizedPath(path)
        if let existing = projects.first(where: { ProjectIdentity.normalizedPath($0.path) == normalized }) {
            throw ProjectTemplateError.projectPathRegistered(path: path, name: existing.name)
        }
    }

    // MARK: - Token substitution (install-time placeholder resolution)

    /// Supported placeholders for template-author prompts. Keep the set
    /// intentionally small — every token here becomes a load-bearing
    /// part of the template format that we can't rename without
    /// breaking existing bundles.
    ///
    /// - `{{PROJECT_DIR}}`: absolute path of the newly-created project
    ///   directory. Required for cron prompts because Hermes doesn't
    ///   establish a CWD when firing cron jobs; relative paths would
    ///   resolve against whatever dir Hermes happens to be in.
    ///
    /// - `{{TEMPLATE_ID}}`: the `owner/name` id from the manifest.
    ///   Less load-bearing; occasionally useful for tagging or
    ///   delivery targets that reference the template.
    ///
    /// - `{{TEMPLATE_SLUG}}`: the sanitised slug the installer used
    ///   for the skills namespace and project dir name.
    nonisolated static func substituteCronTokens(
        _ prompt: String,
        plan: TemplateInstallPlan
    ) -> String {
        var out = prompt
        out = out.replacingOccurrences(of: "{{PROJECT_DIR}}", with: plan.projectDir)
        out = out.replacingOccurrences(of: "{{TEMPLATE_ID}}", with: plan.manifest.id)
        out = out.replacingOccurrences(of: "{{TEMPLATE_SLUG}}", with: plan.manifest.slug)
        return out
    }

    // MARK: - Lock file

    nonisolated private func writeLockFile(
        plan: TemplateInstallPlan,
        cronJobNames: [String]
    ) throws {
        // Every value that ended up as a keychainRef in config.json gets
        // tracked in the lock so the uninstaller can SecItemDelete each
        // entry. Field keys are recorded separately for informational
        // display in the uninstall preview sheet.
        let keychainItems: [String]? = {
            let refs = plan.configValues.compactMap { (_, value) -> String? in
                if case .keychainRef(let uri) = value { return uri } else { return nil }
            }
            return refs.isEmpty ? nil : refs.sorted()
        }()
        let configFields: [String]? = {
            guard let schema = plan.configSchema, !schema.isEmpty else { return nil }
            return schema.fields.map(\.key)
        }()
        // Slash command file paths, RELATIVE to the project root, so the
        // uninstaller can remove only what the template installed (not
        // user-authored slash commands the user added later in the
        // same dir). Source-relative-path identifies bundle slash commands
        // because they live under `slash-commands/` in the unpacked tree.
        let slashCommandFiles: [String]? = {
            let names = plan.manifest.contents.slashCommands ?? []
            guard !names.isEmpty else { return nil }
            return names.sorted().map { ".scarf/slash-commands/\($0).md" }
        }()

        let lock = TemplateLock(
            templateId: plan.manifest.id,
            templateVersion: plan.manifest.version,
            templateName: plan.manifest.name,
            installedAt: ISO8601DateFormatter().string(from: Date()),
            projectFiles: plan.projectFiles.map(\.destinationPath),
            skillsNamespaceDir: plan.skillsNamespaceDir,
            skillsFiles: plan.skillsFiles.map(\.destinationPath),
            cronJobNames: cronJobNames,
            memoryBlockId: plan.memoryAppendix == nil ? nil : plan.manifest.id,
            configKeychainItems: keychainItems,
            configFields: configFields,
            slashCommandFiles: slashCommandFiles
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(lock)
        let path = plan.projectDir + "/.scarf/template.lock.json"
        // UNGUARDED-WRITE(C): install-time lock file, composed entirely from the install plan.
        try context.makeTransport().unguardedWriteFile(path, data: data)
    }
}
