import Foundation
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
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectTemplateUninstaller")

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
        var lockTrackedFiles = lock.projectFiles
        lockTrackedFiles.append(path)
        var toRemove: [String] = []
        var alreadyGone: [String] = []
        for file in lockTrackedFiles {
            if transport.fileExists(file) {
                toRemove.append(file)
            } else {
                alreadyGone.append(file)
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

        return TemplateUninstallPlan(
            lock: lock,
            project: project,
            projectFilesToRemove: toRemove,
            projectFilesAlreadyGone: alreadyGone,
            extraProjectEntries: extras,
            projectDirBecomesEmpty: projectDirBecomesEmpty,
            skillsNamespaceDir: lock.skillsNamespaceDir,
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

        // 1. Project files (tracked only — user additions untouched).
        for file in plan.projectFilesToRemove {
            do {
                try transport.removeFile(file)
            } catch {
                Self.logger.warning("couldn't remove project file \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // keep going — partial cleanup is better than bailing and
                // leaving orphan skills/cron state
            }
        }
        if plan.projectDirBecomesEmpty, transport.fileExists(plan.project.path) {
            do {
                try transport.removeFile(plan.project.path)
            } catch {
                Self.logger.warning("couldn't remove empty project dir \(plan.project.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 2. Skills namespace dir (always removed wholesale — it's
        // isolated, never mixed with user skills).
        if let skillsDir = plan.skillsNamespaceDir, transport.fileExists(skillsDir) {
            try removeRecursively(skillsDir, transport: transport)
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

        // 5. Projects registry — remove the entry by path (more stable
        // than name: user may have renamed the project in the UI).
        let dashboardService = ProjectDashboardService(context: context)
        var registry = dashboardService.loadRegistry()
        registry.projects.removeAll { $0.path == plan.project.path }
        dashboardService.saveRegistry(registry)

        Self.logger.info("uninstalled template \(plan.lock.templateId, privacy: .public) from \(plan.project.path, privacy: .public)")
    }

    // MARK: - Helpers

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
            // Skip the .scarf/ dir entirely when deciding "does the
            // project dir have user content?" — the only files we put
            // there (dashboard.json + lock) are tracked already, and
            // if they're still there the overall project is not yet
            // "empty."
            if entry == ".scarf" { continue }
            if trackedPaths.contains(full) { continue }
            extras.append(full)
        }
        return extras
    }

    /// Recursively delete a directory via the transport. The transport's
    /// `removeFile` works on files and on empty directories; we walk
    /// children first, then remove the now-empty parent.
    nonisolated private func removeRecursively(
        _ path: String,
        transport: any ServerTransport
    ) throws {
        guard transport.fileExists(path) else { return }
        if transport.stat(path)?.isDirectory != true {
            try transport.removeFile(path)
            return
        }
        let entries = (try? transport.listDirectory(path)) ?? []
        for entry in entries {
            try removeRecursively(path + "/" + entry, transport: transport)
        }
        try transport.removeFile(path)
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
