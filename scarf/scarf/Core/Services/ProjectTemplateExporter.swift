import Foundation
import ScarfCore
import os

/// Builds a `.scarftemplate` bundle from an existing Scarf project plus the
/// caller's selection of skills and cron jobs. Symmetric with the
/// `ProjectTemplateService` + `ProjectTemplateInstaller` pair — the output
/// of this exporter can be fed straight back to `inspect()` + `install()`.
struct ProjectTemplateExporter: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "ProjectTemplateExporter")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    /// Known filenames in the project root that map to specific agents. When
    /// the author opts to include them, each is copied verbatim into
    /// `instructions/` in the bundle.
    nonisolated static let knownInstructionFiles: [String] = [
        "CLAUDE.md",
        "GEMINI.md",
        ".cursorrules",
        ".github/copilot-instructions.md"
    ]

    /// Author-facing description of what `export` will do with the given
    /// selections. Shown in the export sheet so the user knows exactly
    /// what's about to go into the bundle before saving.
    struct ExportPlan: Sendable {
        let templateId: String
        let templateName: String
        let templateVersion: String
        let projectDir: String
        let dashboardPresent: Bool
        let agentsMdPresent: Bool
        let readmePresent: Bool
        let instructionFiles: [String]
        let skillIds: [String]
        let cronJobs: [HermesCronJob]
        let memoryAppendix: String?
        /// Names of slash commands that will be carried into the bundle
        /// (read from `<project>/.scarf/slash-commands/<n>.md`). The
        /// export sheet shows these in the preview so authors can see
        /// what will travel with the bundle.
        let slashCommandNames: [String]
    }

    /// Inputs collected by the export sheet.
    struct ExportInputs: Sendable {
        let project: ProjectEntry
        let templateId: String
        let templateName: String
        let templateVersion: String
        let description: String
        let authorName: String?
        let authorUrl: String?
        let category: String?
        let tags: [String]
        let includeSkillIds: [String]
        let includeCronJobIds: [String]
        /// Raw markdown the author wants appended to installers' MEMORY.md.
        /// `nil` to skip.
        let memoryAppendix: String?
    }

    /// Scan the project dir and report what a fresh export would include
    /// given the caller's inputs. Does not write anything.
    ///
    /// Existence checks go through the context's transport — the project
    /// path comes from the registry on the active server and may be on a
    /// remote filesystem (future remote-install support), where
    /// `FileManager.default.fileExists` would silently return `false`.
    nonisolated func previewPlan(for inputs: ExportInputs) -> ExportPlan {
        let dir = inputs.project.path
        let transport = context.makeTransport()
        let dashboard = transport.fileExists(dir + "/.scarf/dashboard.json")
        let readme = transport.fileExists(dir + "/README.md")
        let agents = transport.fileExists(dir + "/AGENTS.md")
        let instructions = Self.knownInstructionFiles.filter {
            transport.fileExists(dir + "/" + $0)
        }
        let allJobs = HermesFileService(context: context).loadCronJobs()
        let picked = allJobs.filter { inputs.includeCronJobIds.contains($0.id) }
        // Pick up every project-scoped slash command at
        // <project>/.scarf/slash-commands/. The exporter ships them
        // unconditionally — they're tied to the project, not to user
        // identity, and the names go into the manifest's contents claim
        // so installers see them in the preview sheet.
        let slashCommandNames = ProjectSlashCommandService(context: context)
            .loadCommands(at: dir)
            .map(\.name)
            .sorted()
        return ExportPlan(
            templateId: inputs.templateId,
            templateName: inputs.templateName,
            templateVersion: inputs.templateVersion,
            projectDir: dir,
            dashboardPresent: dashboard,
            agentsMdPresent: agents,
            readmePresent: readme,
            instructionFiles: instructions,
            skillIds: inputs.includeSkillIds,
            cronJobs: picked,
            memoryAppendix: inputs.memoryAppendix,
            slashCommandNames: slashCommandNames
        )
    }

    /// Build the bundle and write it to `outputZipPath`. Throws if any
    /// required file is missing or the zip step fails.
    nonisolated func export(
        inputs: ExportInputs,
        outputZipPath: String
    ) throws {
        let stagingDir = NSTemporaryDirectory() + "scarf-template-export-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: stagingDir) }

        let plan = previewPlan(for: inputs)

        guard plan.dashboardPresent else {
            throw ProjectTemplateError.requiredFileMissing("dashboard.json (expected at \(plan.projectDir)/.scarf/dashboard.json)")
        }
        guard plan.readmePresent else {
            throw ProjectTemplateError.requiredFileMissing("README.md (expected at \(plan.projectDir)/README.md)")
        }
        guard plan.agentsMdPresent else {
            throw ProjectTemplateError.requiredFileMissing("AGENTS.md (expected at \(plan.projectDir)/AGENTS.md)")
        }

        // Required files. All source reads go through the context's
        // transport — project paths come from the registry on the active
        // server and may be on a remote filesystem. Destinations are in
        // the local staging dir so Foundation writes are correct.
        let transport = context.makeTransport()
        try copyFromHermes(plan.projectDir + "/.scarf/dashboard.json", to: stagingDir + "/dashboard.json", transport: transport)
        try copyFromHermes(plan.projectDir + "/README.md", to: stagingDir + "/README.md", transport: transport)
        try copyFromHermes(plan.projectDir + "/AGENTS.md", to: stagingDir + "/AGENTS.md", transport: transport)

        // Optional per-agent instruction shims
        for relative in plan.instructionFiles {
            let source = plan.projectDir + "/" + relative
            let destination = stagingDir + "/instructions/" + relative
            try createParent(of: destination)
            try copyFromHermes(source, to: destination, transport: transport)
        }

        // Skills (copied from the global skills dir)
        if !plan.skillIds.isEmpty {
            let skillsRoot = stagingDir + "/skills"
            try FileManager.default.createDirectory(atPath: skillsRoot, withIntermediateDirectories: true)
            let allSkills = HermesFileService(context: context).loadSkills()
                .flatMap(\.skills)
            for skillId in plan.skillIds {
                guard let skill = allSkills.first(where: { $0.id == skillId }) else {
                    throw ProjectTemplateError.requiredFileMissing("skills/" + skillId)
                }
                // The bundle uses a flat `skills/<name>/` layout (no
                // category), matching what the installer expects. If two
                // categories ship skills with the same `name`, the second
                // collides — warn by refusing rather than silently
                // overwriting.
                let targetDir = skillsRoot + "/" + skill.name
                if FileManager.default.fileExists(atPath: targetDir) {
                    throw ProjectTemplateError.conflictingFile(targetDir)
                }
                try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
                for file in skill.files {
                    try copyFromHermes(skill.path + "/" + file, to: targetDir + "/" + file, transport: transport)
                }
            }
        }

        // Cron jobs (stripped to the create-CLI-shaped spec)
        if !plan.cronJobs.isEmpty {
            let specs = plan.cronJobs.map { Self.strip($0) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(specs)
            let cronDir = stagingDir + "/cron"
            try FileManager.default.createDirectory(atPath: cronDir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: cronDir + "/jobs.json"))
        }

        // Memory appendix. A write failure here would silently produce a
        // bundle whose manifest claims `memory.append = true` but ships an
        // empty/missing file — installers would then fail on
        // contentClaimMismatch with no breadcrumb pointing back at the
        // export step. Let the error propagate.
        if let appendix = plan.memoryAppendix, !appendix.isEmpty {
            let memDir = stagingDir + "/memory"
            try FileManager.default.createDirectory(atPath: memDir, withIntermediateDirectories: true)
            guard let data = appendix.data(using: .utf8) else {
                throw ProjectTemplateError.requiredFileMissing("memory/append.md (non-UTF8)")
            }
            try data.write(to: URL(fileURLWithPath: memDir + "/append.md"))
        }

        // Slash commands (manifest schemaVersion 3). Copy each from the
        // project's `.scarf/slash-commands/<name>.md` into the bundle
        // root's `slash-commands/<name>.md`. Read goes through the
        // transport so remote projects work too.
        if !plan.slashCommandNames.isEmpty {
            let slashDir = stagingDir + "/slash-commands"
            try FileManager.default.createDirectory(atPath: slashDir, withIntermediateDirectories: true)
            for name in plan.slashCommandNames {
                let source = plan.projectDir + "/.scarf/slash-commands/" + name + ".md"
                let destination = slashDir + "/" + name + ".md"
                try copyFromHermes(source, to: destination, transport: transport)
            }
        }

        // If the source project was itself installed from a schemaful
        // template, its `.scarf/manifest.json` carries the schema we
        // want to forward to the exported bundle. We carry only the
        // SCHEMA — never user values. Exporting must be safe on a
        // project with live config: the schema is author-supplied
        // metadata; the values in `config.json` are the current user's
        // secrets or personal settings.
        let forwardedSchema: TemplateConfigSchema? = try Self.readCachedSchema(
            from: plan.projectDir
        )

        // Bump schemaVersion based on the most-recent feature carried
        // through:
        //   v3 — bundle ships slashCommands (added v2.5).
        //   v2 — bundle ships a config schema (added v2.3).
        //   v1 — schema-less, byte-compatible with v2.2 catalog validators.
        let schemaVersion: Int = {
            if !plan.slashCommandNames.isEmpty { return 3 }
            if forwardedSchema != nil { return 2 }
            return 1
        }()

        // Manifest — claims exactly what we just wrote
        let manifest = ProjectTemplateManifest(
            schemaVersion: schemaVersion,
            id: inputs.templateId,
            name: inputs.templateName,
            version: inputs.templateVersion,
            minScarfVersion: nil,
            minHermesVersion: nil,
            author: inputs.authorName.map {
                TemplateAuthor(name: $0, url: inputs.authorUrl)
            },
            description: inputs.description,
            category: inputs.category,
            tags: inputs.tags.isEmpty ? nil : inputs.tags,
            icon: nil,
            screenshots: nil,
            contents: TemplateContents(
                dashboard: true,
                agentsMd: true,
                instructions: plan.instructionFiles.isEmpty ? nil : plan.instructionFiles,
                skills: plan.skillIds.isEmpty ? nil : plan.skillIds.compactMap { $0.split(separator: "/").last.map(String.init) },
                cron: plan.cronJobs.isEmpty ? nil : plan.cronJobs.count,
                memory: (inputs.memoryAppendix?.isEmpty == false) ? TemplateMemoryClaim(append: true) : nil,
                config: forwardedSchema?.fields.count,
                slashCommands: plan.slashCommandNames.isEmpty ? nil : plan.slashCommandNames
            ),
            config: forwardedSchema
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try manifestEncoder.encode(manifest)
        try manifestData.write(to: URL(fileURLWithPath: stagingDir + "/template.json"))

        try zip(stagingDir: stagingDir, outputPath: outputZipPath)
    }

    // MARK: - Private

    /// Copy a file whose source lives on the Hermes side (possibly remote)
    /// into a local destination path under the staging dir. Using the
    /// transport for the read keeps the exporter remote-ready; the write
    /// goes through Foundation because the staging dir is always local to
    /// the Mac running Scarf.
    nonisolated private func copyFromHermes(
        _ source: String,
        to destination: String,
        transport: any ServerTransport
    ) throws {
        let data = try transport.readFile(source)
        try createParent(of: destination)
        try data.write(to: URL(fileURLWithPath: destination))
    }

    nonisolated private func createParent(of path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parent) {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }
    }

    /// Read the cached manifest from `<project>/.scarf/manifest.json` (if
    /// present) and pull out just the config schema. Values in
    /// `.scarf/config.json` are intentionally ignored — an exported
    /// bundle carries the schema's shape, never the current user's
    /// configured values.
    nonisolated private static func readCachedSchema(from projectDir: String) throws -> TemplateConfigSchema? {
        let manifestPath = projectDir + "/.scarf/manifest.json"
        guard FileManager.default.fileExists(atPath: manifestPath) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        // Use a bespoke decode rather than ProjectTemplateManifest so
        // this helper stays resilient if the manifest shape evolves
        // incompatibly in a future release.
        struct OnlyConfig: Decodable { let config: TemplateConfigSchema? }
        let onlyConfig = try JSONDecoder().decode(OnlyConfig.self, from: data)
        return onlyConfig.config
    }

    /// Convert a live cron job (with runtime state) into the spec the
    /// installer will feed back to `hermes cron create`. Only preserves
    /// fields the CLI accepts.
    nonisolated private static func strip(_ job: HermesCronJob) -> TemplateCronJobSpec {
        let schedule: String = {
            if let expr = job.schedule.expression, !expr.isEmpty { return expr }
            if let runAt = job.schedule.runAt, !runAt.isEmpty { return runAt }
            return job.schedule.display ?? ""
        }()
        return TemplateCronJobSpec(
            name: job.name,
            schedule: schedule,
            prompt: job.prompt.isEmpty ? nil : job.prompt,
            deliver: job.deliver?.isEmpty == false ? job.deliver : nil,
            skills: (job.skills?.isEmpty == false) ? job.skills : nil,
            repeatCount: nil
        )
    }

    /// Shell out to `/usr/bin/zip -r` so the file ordering is deterministic
    /// and the archive is standard — Apple-provided tools (and the system
    /// `unzip` the installer uses) will read it without trouble.
    nonisolated private func zip(stagingDir: String, outputPath: String) throws {
        // `zip` writes relative paths based on the cwd it's invoked in. Chdir
        // via Process.currentDirectoryURL so entries are `template.json`,
        // `AGENTS.md`, etc., not absolute paths.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = URL(fileURLWithPath: stagingDir)
        process.arguments = ["-qq", "-r", outputPath, "."]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Close both ends of each Pipe so we don't leak 4 fds per zip call.
        func closePipes() {
            try? outPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForWriting.close()
        }

        do {
            try process.run()
        } catch {
            closePipes()
            throw ProjectTemplateError.unzipFailed("zip failed to launch: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let errData = try? errPipe.fileHandleForReading.readToEnd()
        closePipes()

        guard process.terminationStatus == 0 else {
            let err = errData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw ProjectTemplateError.unzipFailed(err.isEmpty ? "exit \(process.terminationStatus)" : err)
        }
    }
}
