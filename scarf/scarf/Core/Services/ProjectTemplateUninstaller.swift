import Foundation
import ScarfCore
import os

/// Reverses the work of `ProjectTemplateInstaller`, driven by the
/// `<project>/.scarf/template.lock.json` the installer dropped. Symmetric
/// with the installer: `loadUninstallPlan(for:)` builds a plan the preview
/// sheet can display honestly; `uninstall(plan:)` executes it. No hidden
/// side effects — every path the uninstaller touches is in the plan.
///
/// **User-added files are preserved.** The lock records exactly what the
/// installer wrote; any file the user created in the project dir after
/// install (e.g. a `sites.txt` or `status-log.md` authored by the agent
/// on first run) is listed as an "extra entry" in the plan and left on
/// disk. If the project dir ends up empty after removing lock-tracked
/// files, the dir itself is removed; otherwise the dir (with user content)
/// stays.
struct ProjectTemplateUninstaller: Sendable {
    private nonisolated static let logger = Logger(subsystem: "com.scarf", category: "ProjectTemplateUninstaller")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Detection

    /// Is the given project installed from a template that we can
    /// uninstall cleanly? Cheap — just a file-existence check on the lock
    /// path.
    nonisolated func isTemplateInstalled(project: ProjectEntry) -> Bool {
        context.makeTransport().fileExists(lockPath(for: project))
    }

    // MARK: - Planning

    /// Read the lock file, walk the filesystem + cron list, and produce a
    /// plan listing every op the uninstaller will perform. Does not
    /// modify anything.
    nonisolated func loadUninstallPlan(for project: ProjectEntry) throws -> TemplateUninstallPlan {
        let transport = context.makeTransport()
        let path = lockPath(for: project)
        guard transport.fileExists(path) else {
            throw ProjectTemplateError.lockFileMissing(path)
        }
        let lockData: Data
        do {
            lockData = try transport.readFile(path)
        } catch {
            throw ProjectTemplateError.lockFileParseFailed(error.localizedDescription)
        }
        let lock: TemplateLock
        do {
            lock = try JSONDecoder().decode(TemplateLock.self, from: lockData)
        } catch {
            throw ProjectTemplateError.lockFileParseFailed(error.localizedDescription)
        }

        // Partition tracked project files into present vs. already-gone.
        // The lock file itself is always in `projectFiles` — the installer
        // doesn't explicitly record it, but the preview sheet and the
        // execute step must remove it.
        //
        // The lock is AGENT-WRITABLE, so every path in it is untrusted
        // input, not a record of what the installer did: an edited
        // `project_files` entry naming `/Users/me/Documents` would
        // otherwise be deleted on one user click. Re-derive containment
        // here against the project root — and again at time-of-use in
        // `uninstall(plan:)`, because this plan can sit on screen while
        // the agent rewrites the lock underneath it.
        let guardian = PathGuard(isRemote: transport.isRemote)
        var lockTrackedFiles = lock.projectFiles
        lockTrackedFiles.append(path)
        var toRemove: [String] = []
        var alreadyGone: [String] = []
        var refused: [String] = []
        for file in lockTrackedFiles {
            guard guardian.admits(file, under: project.path) else {
                Self.logger.error(
                    "lock lists \(file, privacy: .public) which is not inside \(project.path, privacy: .public); refusing to delete it"
                )
                refused.append(file)
                continue
            }
            if transport.fileExists(file) {
                toRemove.append(file)
            } else {
                alreadyGone.append(file)
            }
        }

        // Same treatment for the skills namespace dir: it must live under
        // `<hermes>/skills/templates/` (where `ProjectTemplateService`
        // puts it) and nowhere else — this one is deleted RECURSIVELY, so
        // a lock pointing it at `~` is the worst case in the file.
        var skillsDir: String? = nil
        if let claimed = lock.skillsNamespaceDir {
            if guardian.admits(claimed, under: Self.skillsTemplatesRoot(context: context)) {
                skillsDir = claimed
            } else {
                Self.logger.error(
                    "lock lists skills namespace dir \(claimed, privacy: .public) outside the template skills root; refusing to delete it"
                )
                refused.append(claimed)
            }
        }

        // Scan the project dir for entries that AREN'T in the lock — these
        // are user-added and we preserve them. An empty project dir (after
        // removing lock-tracked files) gets removed too.
        let trackedSet = Set(lockTrackedFiles)
        let extras = try enumerateProjectDirExtras(
            projectDir: project.path,
            trackedPaths: trackedSet,
            transport: transport
        )
        let projectDirBecomesEmpty = extras.isEmpty

        // Resolve cron job ids by matching lock names against the live
        // list. Names that no longer exist go into the already-gone bucket
        // — the user likely removed them by hand.
        let currentJobs = HermesFileService(context: context).loadCronJobs()
        var cronToRemove: [(id: String, name: String)] = []
        var cronGone: [String] = []
        for name in lock.cronJobNames {
            if let match = currentJobs.first(where: { $0.name == name }) {
                cronToRemove.append((id: match.id, name: match.name))
            } else {
                cronGone.append(name)
            }
        }

        // Memory block detection. The installer wraps its appendix between
        // `<!-- scarf-template:<id>:begin -->` / `:end -->` markers; look
        // for the begin marker in the current MEMORY.md. If it's missing
        // (never installed, or removed by hand) we simply skip the memory
        // strip step.
        let memoryPath = context.paths.memoryMD
        var memoryBlockPresent = false
        if lock.memoryBlockId != nil {
            if transport.fileExists(memoryPath),
               let data = try? transport.readFile(memoryPath),
               let text = String(data: data, encoding: .utf8) {
                let beginMarker = ProjectTemplateService.memoryBlockBeginMarker(
                    templateId: lock.memoryBlockId!
                )
                memoryBlockPresent = text.contains(beginMarker)
            }
        }

        // Keychain items: same shape of untrust. Admit only URIs in
        // Scarf's own service namespace that are BOUND to this project's
        // path — a lock naming another project's (or another app's) item
        // must not reach `SecItemDelete`.
        var keychainToDelete: [TemplateKeychainRef] = []
        for uri in lock.configKeychainItems ?? [] {
            guard let ref = TemplateKeychainRef.parse(uri),
                  ref.belongs(toProjectPath: project.path) else {
                Self.logger.error(
                    "lock lists keychain uri \(uri, privacy: .public) that isn't this project's; refusing to delete it"
                )
                refused.append(uri)
                continue
            }
            keychainToDelete.append(ref)
        }

        return TemplateUninstallPlan(
            lock: lock,
            project: project,
            projectFilesToRemove: toRemove,
            projectFilesAlreadyGone: alreadyGone,
            extraProjectEntries: extras,
            projectDirBecomesEmpty: projectDirBecomesEmpty,
            refusedEntries: refused,
            keychainItemsToDelete: keychainToDelete,
            skillsNamespaceDir: skillsDir,
            cronJobsToRemove: cronToRemove,
            cronJobsAlreadyGone: cronGone,
            memoryBlockPresent: memoryBlockPresent,
            memoryPath: memoryPath
        )
    }

    // MARK: - Execution

    /// Execute the plan. Non-atomic: steps run in order, and if any step
    /// throws, later steps don't run. v1 doesn't ship rollback — the lock
    /// file itself is only removed at the very end, so a mid-flight
    /// failure leaves enough breadcrumbs for the user to retry or finish
    /// by hand.
    nonisolated func uninstall(plan: TemplateUninstallPlan) throws {
        let transport = context.makeTransport()
        // Time-of-use re-derivation. The plan was built from the lock,
        // and the lock is agent-writable: between planning and the user's
        // click, both the file and the filesystem can change (a tracked
        // path can become a symlink). Every deletion below re-checks
        // containment through this guard rather than trusting the plan it
        // was handed.
        let guardian = PathGuard(isRemote: transport.isRemote)

        // 0. Strip the project's block from ~/.hermes/.env BEFORE we
        // delete project files — KeychainEnvMirror.unmirror reads the
        // cached manifest at <project>/.scarf/manifest.json to recover
        // the slug. After step 1 deletes that file the slug is only
        // recoverable by name, which is fine but more brittle. Run
        // first while the cached manifest is still around. Failure is
        // non-fatal: a stale block in .env is benign (env vars
        // referencing a deleted project just sit there) and a fresh
        // install at the same slug will overwrite it.
        do {
            try KeychainEnvMirror(context: context).unmirror(project: plan.project)
        } catch {
            Self.logger.warning("uninstall couldn't strip secrets block from ~/.hermes/.env: \(error.localizedDescription, privacy: .public)")
        }

        // 1. Project files (tracked only — user additions untouched).
        for file in plan.projectFilesToRemove {
            guard guardian.admits(file, under: plan.project.path) else {
                Self.logger.error(
                    "skipping \(file, privacy: .public): no longer contained by \(plan.project.path, privacy: .public)"
                )
                continue
            }
            do {
                try transport.removeFile(file)
            } catch {
                Self.logger.warning("couldn't remove project file \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // keep going — partial cleanup is better than bailing and
                // leaving orphan skills/cron state
            }
        }
        // 1a. Scarf's own record. Not lock-tracked (the installer doesn't
        // write it) and not the user's, but its presence is what makes the
        // doctor call this folder an unlisted project — see
        // `scarfOwnedFiles`. Guarded like every other deletion here.
        for file in Self.scarfOwnedFiles(in: plan.project.path + "/.scarf")
        where guardian.admits(file, under: plan.project.path) && transport.fileExists(file) {
            do {
                try transport.removeFile(file)
            } catch {
                Self.logger.warning("couldn't remove \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // The `.scarf/` directory itself, when nothing is left in it. Same
        // confirm-then-remove discipline as the project dir below: local
        // `removeFile` is recursive, so "I think it's empty" is not enough.
        if transport.fileExists(plan.project.path + "/.scarf") {
            removeProjectDirIfEmpty(plan.project.path + "/.scarf", transport: transport)
        }
        if plan.projectDirBecomesEmpty, transport.fileExists(plan.project.path) {
            removeProjectDirIfEmpty(plan.project.path, transport: transport)
        }

        // 2. Skills namespace dir (always removed wholesale — it's
        // isolated, never mixed with user skills).
        if let skillsDir = plan.skillsNamespaceDir,
           guardian.admits(skillsDir, under: Self.skillsTemplatesRoot(context: context)),
           transport.fileExists(skillsDir) {
            try removeRecursively(
                skillsDir,
                root: Self.skillsTemplatesRoot(context: context),
                guardian: guardian,
                transport: transport
            )
        }

        // 3. Cron jobs via CLI — `hermes cron remove <id>`. A non-zero
        // exit gets logged but doesn't abort the uninstall; leaving a
        // stray cron job is better than leaving it AND the skills/memory
        // state that was supposed to pair with it.
        for job in plan.cronJobsToRemove {
            let (output, exit) = context.runHermes(["cron", "remove", job.id])
            if exit != 0 {
                Self.logger.warning("failed to remove cron job \(job.id, privacy: .public) \(job.name, privacy: .public): \(output, privacy: .public)")
            }
        }

        // 4. Memory block — strip the bracketed block in place. Safe
        // when the block is absent; we already decided presence in the
        // plan and only come here when `memoryBlockPresent` was true
        // AND the plan recorded a memoryBlockId.
        if plan.memoryBlockPresent, let blockId = plan.lock.memoryBlockId {
            try stripMemoryBlock(blockId: blockId, memoryPath: plan.memoryPath, transport: transport)
        }

        // 4a. Config Keychain items — remove every secret the template's
        // install step stashed in the login Keychain. Items that were
        // already deleted (e.g. user cleaned them with Keychain Access)
        // hit the `errSecItemNotFound` no-op path inside the wrapper, so
        // a stale lock doesn't abort the rest of the uninstall.
        //
        // The plan already filtered these to Scarf's own service
        // namespace, bound to this project's path hash; re-check the
        // binding here so a plan built elsewhere can't widen the blast
        // radius of `SecItemDelete` (which is reachable for ANY item this
        // app can see).
        let keychain = ProjectConfigKeychain()
        for ref in plan.keychainItemsToDelete {
            guard ref.belongs(toProjectPath: plan.project.path) else {
                Self.logger.error("refusing to delete keychain item \(ref.uri, privacy: .public) — not this project's")
                continue
            }
            do {
                try keychain.delete(ref: ref)
            } catch {
                Self.logger.warning("couldn't delete keychain item \(ref.uri, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 5. Projects registry — remove the entry by UUID when the row
        // carries one (the stable key: survives a rename AND a path
        // change), falling back to a normalized path compare for
        // pre-Phase-1 rows that have no UUID yet. Raw string equality
        // alone is too brittle — the same project dir can be spelled
        // `/tmp/x` or `/private/tmp/x`, with or without a trailing
        // slash, so both sides go through `Self.normalizedPath`.
        let dashboardService = ProjectDashboardService(context: context)
        let loaded = dashboardService.loadRegistryDetailed()
        // A LOSSY load cannot support either conclusion: the row may be in
        // the part we couldn't read, so "nothing matched" is not a fact.
        // Fail loudly — a silent success here is the "sheet says
        // uninstalled, sidebar still shows it" bug. (`saveRegistry` would
        // refuse the write anyway; this reports it as the uninstall's own
        // failure instead of as a write error, and skips the pointless
        // attempt.)
        if let loss = loaded.loss {
            Self.logger.error(
                "uninstall couldn't read the projects registry: \(loss.message, privacy: .public)"
            )
            throw ProjectTemplateError.registryUpdateFailed(loss.message)
        }
        var registry = loaded.registry
        let rowsBefore = registry.projects.count
        registry.projects.removeAll { Self.matches($0, project: plan.project) }
        // Mirrors `ProjectsViewModel.removeProject`'s presence check, and
        // for the same reason: the `allowEmpty: true` below deliberately
        // bypasses the empty-overwrite guard, so a removal that removed
        // NOTHING would write the list it just loaded — and if that list
        // came back empty (a load that failed for any reason), this
        // blanked the registry while reporting a clean uninstall. Removing
        // nothing means the row is already gone: the rest of the uninstall
        // succeeded, so this is a no-op, not a failure.
        if registry.projects.count < rowsBefore {
            // A failed registry write is NOT cosmetic: the row survives,
            // the sidebar keeps showing a project whose files are gone, and
            // the success screen would claim a clean removal. Surface it
            // the way every other hard failure in this method surfaces —
            // by throwing — so `TemplateUninstallerViewModel` lands on
            // `.failed` and the user sees why. Everything destructive has
            // already run at this point, so a retry is safe: the plan's
            // remaining steps are all no-ops on second pass.
            do {
                // Deliberate removal — uninstalling the only project must
                // still be able to leave the registry empty.
                try dashboardService.saveRegistry(registry, allowEmpty: true)
            } catch {
                Self.logger.error("uninstall couldn't rewrite projects registry: \(error.localizedDescription, privacy: .public)")
                throw ProjectTemplateError.registryUpdateFailed(error.localizedDescription)
            }
        } else {
            // Nothing matched: the row is already gone (or was never
            // there). Writing anyway is the whole hazard described above,
            // and there is nothing left to remove — a no-op, not a failure.
            Self.logger.info(
                "uninstall: no registry row matched \(plan.project.path, privacy: .public); leaving projects.json untouched"
            )
        }

        // 6. The state that lives outside the registry — mini-app permission
        // grants (which a re-used folder would otherwise inherit, ids being
        // derived from (host, path)) and the Scarf-managed AGENTS.md block
        // (which goes on describing the uninstalled template to every agent
        // that opens the folder). Shared with the sidebar's own removal so
        // the two paths cannot drift; best-effort by construction.
        ProjectLifecycleService(context: context).cleanUpAfterRemoval(of: plan.project)

        Self.logger.info("uninstalled template \(plan.lock.templateId, privacy: .public) from \(plan.project.path, privacy: .public)")
    }

    // MARK: - Helpers

    /// Remove the project directory — but only after CONFIRMING, at time of
    /// use, that it holds nothing.
    ///
    /// Two failures met here, one on each transport:
    ///
    /// - **Locally**, `LocalTransport.removeFile` is `FileManager.removeItem`,
    ///   which is RECURSIVE. `projectDirBecomesEmpty` was computed at plan
    ///   time, from a scan that skipped `.scarf/` entirely; anything written
    ///   into the folder between the plan and the click was invisible to it
    ///   too. So a stale "empty" was a recursive delete of a folder that
    ///   wasn't. The plan's flag is now a precondition, not a permission:
    ///   the directory is listed again here and left alone unless it is
    ///   actually empty.
    /// - **Remotely**, `removeFile` is `rm -f`, which refuses a directory.
    ///   The old code caught that, logged a warning nobody sees, and
    ///   continued to delete the registry row — leaving a GHOST: a folder
    ///   still holding `.scarf/project.json` with no row pointing at it,
    ///   which the Project Doctor then reports as an orphan and offers to
    ///   ADOPT. Accepting re-registers the project the user just
    ///   uninstalled, with its original uuid, which re-attaches its cron
    ///   jobs. An uninstall that half-happens must SAY so; `rmdir` is the
    ///   verb that actually removes an empty directory, and a directory that
    ///   survives both attempts is reported.
    ///
    /// Never throws: the destructive work is done by the time we get here
    /// and the registry row still has to come out. The residue is logged and
    /// left, which is the honest outcome — files the user can see and delete
    /// beat a silent partial success.
    nonisolated private func removeProjectDirIfEmpty(
        _ path: String,
        transport: any ServerTransport
    ) {
        guard let remaining = try? transport.listDirectory(path) else {
            Self.logger.warning(
                "couldn't list \(path, privacy: .public) to confirm it is empty; leaving it in place"
            )
            return
        }
        guard remaining.isEmpty else {
            Self.logger.warning(
                "leaving \(path, privacy: .public) in place — it still holds \(remaining.count) entries the uninstall did not track"
            )
            return
        }
        do {
            try transport.removeFile(path)
        } catch {
            // `rm -f` on a directory. Retry with the verb that means it.
            if transport.isRemote {
                let rmdir = try? transport.runProcess(
                    executable: "/bin/sh",
                    args: ["-c", "rmdir -- \"$0\"", path],
                    stdin: nil,
                    timeout: 20
                )
                if rmdir?.exitCode == 0 { return }
            }
            Self.logger.warning(
                "couldn't remove empty project dir \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Does this registry row denote the project the plan is removing?
    /// UUID first (stable across renames and moves), path second for
    /// rows minted before `ProjectEntry.uuid` existed. Never falls back
    /// to name — the user can rename a project in the sidebar, and two
    /// projects can share a name.
    nonisolated static func matches(_ entry: ProjectEntry, project: ProjectEntry) -> Bool {
        if let target = project.uuid, let candidate = entry.uuid,
           candidate == target {
            return true
        }
        // Path fallback runs even when both uuids are present but differ:
        // a row re-minted with a fresh uuid for the same directory must
        // still be removed, or the uninstall leaves it behind.
        return normalizedPath(entry.path) == normalizedPath(project.path)
    }

    /// Canonical spelling of a filesystem path for comparison purposes:
    /// symlinks resolved (`/tmp` → `/private/tmp`), `.`/`..` collapsed,
    /// trailing slash dropped. Matches how `ProjectTemplateService`
    /// compares extracted paths against their base dir. Applied to BOTH
    /// sides of every compare — never one.
    nonisolated static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated private func lockPath(for project: ProjectEntry) -> String {
        project.path + "/.scarf/template.lock.json"
    }

    /// Walk the project dir and return the absolute paths of every entry
    /// not in `trackedPaths`. `.scarf/` (and its remaining contents after
    /// the lock is recorded) is filtered out because the installer owns
    /// that directory entirely — if the user dropped a file into it,
    /// that's on them, but the common case is that `.scarf/` only holds
    /// our dashboard.json + template.lock.json.
    nonisolated private func enumerateProjectDirExtras(
        projectDir: String,
        trackedPaths: Set<String>,
        transport: any ServerTransport
    ) throws -> [String] {
        guard transport.fileExists(projectDir) else { return [] }
        var extras: [String] = []
        let entries: [String]
        do {
            entries = try transport.listDirectory(projectDir)
        } catch {
            return []
        }
        for entry in entries {
            let full = projectDir + "/" + entry
            if entry == ".scarf" {
                // NOT skipped wholesale any more. The old version assumed
                // `.scarf/` holds only what the installer put there, and
                // the assumption stopped being true the moment `.scarf/`
                // became the project's home: `project.json` (the canonical
                // record), `slash-commands/`, `miniapps/`, `config.json`,
                // `dashboard.json` edits the agent made after install —
                // none of it in the lock. Treating the directory as
                // "nothing of the user's" made `projectDirBecomesEmpty`
                // true with all of that still inside, and the removal
                // below is a RECURSIVE delete on every local transport.
                // The project's own record and every command the user
                // wrote went with the template.
                extras.append(contentsOf: untrackedEntries(
                    in: full, trackedPaths: trackedPaths.union(Self.scarfOwnedFiles(in: full)),
                    transport: transport
                ))
                continue
            }
            if trackedPaths.contains(full) { continue }
            extras.append(full)
        }
        return extras
    }

    /// Absolute paths inside `dir` (one level, non-recursive) that the lock
    /// does not track. An unreadable directory returns nothing — the caller
    /// treats "no extras" as "safe to remove", so this must be reached only
    /// for a directory we could actually list. `listDirectory` failing on a
    /// present `.scarf/` therefore reports the directory ITSELF as an extra:
    /// unknown contents are user content until proven otherwise.
    /// The files in `<project>/.scarf/` that belong to SCARF rather than to
    /// the user or the template: the canonical project record and its
    /// rolling backup.
    ///
    /// They are neither "user content to preserve" nor lock-tracked, and
    /// leaving them was what manufactured the ghost. `project.json` is the
    /// file that makes a folder LOOK like a registered project — it is what
    /// `ProjectDoctorService.orphanFindings` keys on — so a folder that
    /// keeps it after its registry row is deleted comes back as an orphan
    /// the doctor offers to adopt, re-registering the project the user just
    /// uninstalled under its original uuid, with its `[proj:<uuid>]` cron
    /// tags intact. The record's whole meaning is "this folder is a
    /// registered project"; an uninstall must take it with the row.
    nonisolated static func scarfOwnedFiles(in scarfDir: String) -> Set<String> {
        [scarfDir + "/project.json", scarfDir + "/project.json.bak"]
    }

    nonisolated private func untrackedEntries(
        in dir: String,
        trackedPaths: Set<String>,
        transport: any ServerTransport
    ) -> [String] {
        guard transport.fileExists(dir) else { return [] }
        guard let names = try? transport.listDirectory(dir) else { return [dir] }
        return names
            .map { dir + "/" + $0 }
            .filter { !trackedPaths.contains($0) }
    }

    /// Where a template's skills namespace dir is allowed to live —
    /// mirrors `ProjectTemplateService`'s `skillsDir + "/templates/" + slug`.
    /// The lock records the full path; this is the root we re-validate it
    /// against instead of believing it.
    nonisolated static func skillsTemplatesRoot(context: ServerContext) -> String {
        context.paths.skillsDir + "/templates"
    }

    /// Recursively delete a directory via the transport. The transport's
    /// `removeFile` works on files and on empty directories; we walk
    /// children first, then remove the now-empty parent.
    ///
    /// **Symlink-safe.** A symlinked child is UNLINKED, never descended
    /// into: `stat`/`listDirectory` follow links, so the old version
    /// would happily enumerate and delete whatever a
    /// `<namespace>/x -> ~/Documents` link pointed at. Every child is also
    /// re-checked for containment under `root`, so a link that survives
    /// detection still can't take the walk outside the guarded tree.
    /// Returns `false` when something under `path` was deliberately left
    /// alone, so the caller knows not to try (and fail) to remove a
    /// directory that isn't empty. A skipped entry must not turn into a
    /// thrown error: steps 3-5 of the uninstall (cron, memory, registry)
    /// still need to run.
    @discardableResult
    nonisolated private func removeRecursively(
        _ path: String,
        root: String,
        guardian: PathGuard,
        transport: any ServerTransport
    ) throws -> Bool {
        guard guardian.admits(path, under: root) else {
            Self.logger.error("skipping \(path, privacy: .public): escapes \(root, privacy: .public)")
            return false
        }
        guard transport.fileExists(path) || guardian.isSymlink(path) else { return true }
        // A symlink (including a dangling one) is removed as a link.
        if guardian.isSymlink(path) {
            try transport.removeFile(path)
            return true
        }
        if transport.stat(path)?.isDirectory != true {
            try transport.removeFile(path)
            return true
        }
        let entries = (try? transport.listDirectory(path)) ?? []
        var complete = true
        for entry in entries {
            let removed = try removeRecursively(
                path + "/" + entry,
                root: root,
                guardian: guardian,
                transport: transport
            )
            complete = complete && removed
        }
        guard complete else {
            Self.logger.warning("leaving \(path, privacy: .public) in place — it still holds entries we refused to delete")
            return false
        }
        try transport.removeFile(path)
        return true
    }

    // MARK: - Containment guard

    /// Re-derives "may this path be deleted?" from the filesystem at the
    /// moment of use, instead of from the agent-writable lock that named
    /// it. Two independent conditions, both required:
    ///
    /// 1. **Lexical.** The candidate is absolute, standardizes (no `.` /
    ///    `..` left) to something strictly BELOW `root`, and root itself
    ///    is never a target.
    /// 2. **Physical (local only).** The candidate's parent chain, walked
    ///    with symlinks resolved, still lands exactly where the lexical
    ///    path says it should. Any symlinked component between `root` and
    ///    the candidate makes the two disagree, and the path is refused —
    ///    which is what stops `<project>/data -> /Users/me/Documents`
    ///    from turning a project-scoped delete into a home-directory one.
    ///
    /// Remote transports get the lexical half only: there is no realpath
    /// primitive on `ServerTransport`, and resolving locally would answer
    /// questions about the WRONG filesystem. That is strictly better than
    /// the previous "no check at all", and remote template installs don't
    /// exist yet (`ProjectTemplateInstaller` is local-only today).
    nonisolated struct PathGuard: Sendable {
        let isRemote: Bool

        nonisolated func admits(_ candidate: String, under root: String) -> Bool {
            guard candidate.hasPrefix("/"), root.hasPrefix("/") else { return false }
            let rootStd = Self.standardized(root)
            // A root of `/` would make containment vacuous — every
            // absolute path is "inside" it. A project registered at the
            // filesystem root has nothing legitimate to uninstall anyway.
            guard rootStd != "/" else { return false }
            let pathStd = Self.standardized(candidate)
            guard pathStd.hasPrefix(rootStd + "/") else { return false }
            let relative = String(pathStd.dropFirst(rootStd.count + 1))
            let components = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  !components.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." })
            else { return false }
            if isRemote { return true }
            // Physical check: resolve the root once, then require the
            // candidate's PARENT to resolve to exactly root-resolved +
            // the lexical parent components. (The candidate itself may be
            // a symlink — that's legal, we just unlink it rather than
            // follow it; see `removeRecursively`.)
            let rootReal = Self.physicalPath(rootStd)
            let parentComponents = components.dropLast().map(String.init)
            let expectedParent = ([rootReal] + parentComponents).joined(separator: "/")
            let actualParent = Self.physicalPath(
                ([rootStd] + parentComponents).joined(separator: "/")
            )
            return actualParent == expectedParent
        }

        /// Is `path` itself a symbolic link? Local only — `lstat` has no
        /// transport primitive, and a remote answer derived from the local
        /// filesystem would be a lie. Remote callers therefore keep the
        /// containment guarantee but not the link guarantee.
        nonisolated func isSymlink(_ path: String) -> Bool {
            guard !isRemote else { return false }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                return false
            }
            return (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
        }

        nonisolated static func standardized(_ path: String) -> String {
            var out = URL(fileURLWithPath: path).standardizedFileURL.path
            while out.count > 1, out.hasSuffix("/") { out.removeLast() }
            return out
        }

        nonisolated static func resolved(_ path: String) -> String {
            var out = URL(fileURLWithPath: path)
                .standardizedFileURL.resolvingSymlinksInPath().path
            while out.count > 1, out.hasSuffix("/") { out.removeLast() }
            return out
        }

        /// Canonical on-disk spelling, tolerant of a path that doesn't
        /// exist (yet / any more). `resolvingSymlinksInPath` gives up
        /// entirely on a path whose leaf is missing — it returns the input
        /// unresolved — which would make the comparison above depend on
        /// whether a file happened to be there. So: resolve the deepest
        /// EXISTING ancestor and re-attach the missing tail verbatim.
        nonisolated static func physicalPath(_ path: String) -> String {
            let std = standardized(path)
            var components = std.split(separator: "/").map(String.init)
            var tail: [String] = []
            while !components.isEmpty {
                let candidate = "/" + components.joined(separator: "/")
                if exists(candidate) {
                    return ([resolved(candidate)] + tail).joined(separator: "/")
                }
                tail.insert(components.removeLast(), at: 0)
            }
            return std
        }

        /// `lstat`-flavored existence: true for a dangling symlink too,
        /// where `FileManager.fileExists` (which follows) says false.
        nonisolated static func exists(_ path: String) -> Bool {
            (try? FileManager.default.attributesOfItem(atPath: path)) != nil
        }
    }

    /// Remove the `<!-- scarf-template:<id>:begin --> … :end -->` block
    /// from MEMORY.md, preserving everything else. A missing end marker
    /// is logged but doesn't fail — we strip from the begin marker to
    /// EOF in that case, on the theory that a broken template block is
    /// worse than a slightly aggressive strip.
    nonisolated private func stripMemoryBlock(
        blockId: String,
        memoryPath: String,
        transport: any ServerTransport
    ) throws {
        let beginMarker = ProjectTemplateService.memoryBlockBeginMarker(templateId: blockId)
        let endMarker = ProjectTemplateService.memoryBlockEndMarker(templateId: blockId)

        let data = try transport.readFile(memoryPath)
        guard let text = String(data: data, encoding: .utf8) else { return }
        guard let beginRange = text.range(of: beginMarker) else { return }

        let stripRange: Range<String.Index>
        if let endRange = text.range(of: endMarker, range: beginRange.upperBound..<text.endIndex) {
            // Include the end marker and one trailing newline if present.
            var upper = endRange.upperBound
            if upper < text.endIndex, text[upper] == "\n" {
                upper = text.index(after: upper)
            }
            stripRange = beginRange.lowerBound..<upper
        } else {
            Self.logger.warning("memory block for \(blockId, privacy: .public) has begin marker but no end marker; stripping to EOF")
            stripRange = beginRange.lowerBound..<text.endIndex
        }

        // Also consume one leading blank line that the installer inserts
        // before the begin marker, so repeated install/uninstall cycles
        // don't accumulate blank lines at the insertion site.
        var lower = stripRange.lowerBound
        if lower > text.startIndex {
            let prev = text.index(before: lower)
            if text[prev] == "\n", prev > text.startIndex {
                let prevPrev = text.index(before: prev)
                if text[prevPrev] == "\n" {
                    lower = prev
                }
            }
        }
        let updated = text.replacingCharacters(in: lower..<stripRange.upperBound, with: "")
        guard let outData = updated.data(using: .utf8) else { return }
        try transport.writeFile(memoryPath, data: outData)
    }
}
