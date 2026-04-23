import Foundation
import os

/// Executes a `TemplateInstallPlan`. All writes happen in one pass with
/// early-fail semantics: if any step throws, later steps don't run (but
/// earlier ones aren't reversed — v1 doesn't ship an atomic rollback). The
/// plan has already verified `projectDir` doesn't exist and no conflicting
/// file exists at target paths, so by the time we start writing, the
/// expected-error surface is small (mostly I/O failures).
struct ProjectTemplateInstaller: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectTemplateInstaller")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    /// Apply the plan. On success, returns the `ProjectEntry` that was added
    /// to the registry so the caller can set `AppCoordinator.selectedProjectName`.
    @discardableResult
    nonisolated func install(plan: TemplateInstallPlan) throws -> ProjectEntry {
        try preflight(plan: plan)
        try createProjectFiles(plan: plan)
        try createSkillsFiles(plan: plan)
        try appendMemoryIfNeeded(plan: plan)
        let cronJobNames = try createCronJobs(plan: plan)
        let entry = try registerProject(plan: plan)
        try writeLockFile(plan: plan, cronJobNames: cronJobNames)
        Self.logger.info("installed template \(plan.manifest.id, privacy: .public) v\(plan.manifest.version, privacy: .public) into \(plan.projectDir, privacy: .public)")
        return entry
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
            let existing: String
            if transport.fileExists(plan.memoryPath) {
                do {
                    let data = try transport.readFile(plan.memoryPath)
                    existing = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    Self.logger.error("failed to read MEMORY.md at \(plan.memoryPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    throw error
                }
            } else {
                existing = ""
            }
            let marker = ProjectTemplateService.memoryBlockBeginMarker(templateId: plan.manifest.id)
            if existing.contains(marker) {
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
                    try transport.writeFile(copy.destinationPath, data: data)
                    continue
                }
                throw ProjectTemplateError.requiredFileMissing(
                    "synthesized file with unknown destination: \(copy.destinationPath)"
                )
            }

            let source = plan.unpackedDir + "/" + copy.sourceRelativePath
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            try transport.writeFile(copy.destinationPath, data: data)
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
            try transport.writeFile(copy.destinationPath, data: data)
        }
    }

    // MARK: - Memory

    nonisolated private func appendMemoryIfNeeded(plan: TemplateInstallPlan) throws {
        guard let appendix = plan.memoryAppendix else { return }
        let transport = context.makeTransport()
        let existing = (try? transport.readFile(plan.memoryPath)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let combined = existing + appendix
        guard let data = combined.data(using: .utf8) else {
            throw ProjectTemplateError.requiredFileMissing("memory/append.md (non-UTF8)")
        }
        let parent = (plan.memoryPath as NSString).deletingLastPathComponent
        try transport.createDirectory(parent)
        try transport.writeFile(plan.memoryPath, data: data)
    }

    // MARK: - Cron

    /// Create each cron job via `hermes cron create`, then immediately pause
    /// it (Hermes creates jobs enabled). Returns the list of resolved job
    /// names, which is what the lock file records — we don't know the job
    /// ids without parsing the create output, but the name is enough to
    /// find + remove them later.
    nonisolated private func createCronJobs(plan: TemplateInstallPlan) throws -> [String] {
        guard !plan.cronJobs.isEmpty else { return [] }

        let existingBefore = Set(HermesFileService(context: context).loadCronJobs().map(\.id))
        var createdNames: [String] = []

        for job in plan.cronJobs {
            var args = ["cron", "create", "--name", job.name]
            if let deliver = job.deliver, !deliver.isEmpty { args += ["--deliver", deliver] }
            if let repeatCount = job.repeatCount { args += ["--repeat", String(repeatCount)] }
            for skill in job.skills ?? [] where !skill.isEmpty {
                args += ["--skill", skill]
            }
            args.append(job.schedule)
            if let prompt = job.prompt, !prompt.isEmpty {
                args.append(prompt)
            }

            let (output, exit) = context.runHermes(args)
            guard exit == 0 else {
                throw ProjectTemplateError.cronCreateFailed(job: job.name, output: output)
            }
            createdNames.append(job.name)
        }

        // Diff the current job set against the snapshot we took before
        // creating — anything new belongs to this install and gets paused.
        // We pause by id (not name) because `cron pause` takes an id.
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

    nonisolated private func registerProject(plan: TemplateInstallPlan) throws -> ProjectEntry {
        let service = ProjectDashboardService(context: context)
        var registry = service.loadRegistry()
        let entry = ProjectEntry(name: plan.projectRegistryName, path: plan.projectDir)
        registry.projects.append(entry)
        // Must throw on failure — silent failure here used to make the
        // installer return a valid entry while the registry on disk
        // never got updated, producing the "install completed but the
        // project doesn't show up in the sidebar" bug. If the registry
        // write fails, the whole install is surfaced as failed so the
        // user can see + address the underlying problem.
        try service.saveRegistry(registry)
        return entry
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
            configFields: configFields
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(lock)
        let path = plan.projectDir + "/.scarf/template.lock.json"
        try context.makeTransport().writeFile(path, data: data)
    }
}
