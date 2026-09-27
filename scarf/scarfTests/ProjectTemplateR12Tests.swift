import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Hermes v0.21.5 audit, phase R12 (projects & templates): S12-F1..F4 plus
/// the exporter's skill-subfolder copy. Every test goes through the real
/// exporter / service / installer / uninstaller against a throwaway Hermes
/// home; nothing spawns the real `hermes` CLI (the uninstaller's cron
/// runner is injected).
@Suite struct ProjectTemplateR12Tests {

    // MARK: - Fixtures

    static let slashCommand = """
        ---
        name: deploy
        description: Ship the current build
        ---
        Deploy {{argument}}.
        """

    /// A project on disk with the three required files.
    static func makeProject(at dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir + "/.scarf", withIntermediateDirectories: true)
        try write(ProjectTemplateServiceTests.sampleDashboardJSON, to: dir + "/.scarf/dashboard.json")
        try write("# Test project", to: dir + "/README.md")
        try write("# Agent notes", to: dir + "/AGENTS.md")
    }

    static func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    static func inputs(
        project: ProjectEntry, id: String = "tester/r12", skills: [String] = []
    ) -> ProjectTemplateExporter.ExportInputs {
        ProjectTemplateExporter.ExportInputs(
            project: project, templateId: id, templateName: "R12", templateVersion: "1.0.0",
            description: "r12", authorName: "Tester", authorUrl: nil, category: nil, tags: [],
            includeSkillIds: skills, includeCronJobIds: [], memoryAppendix: nil
        )
    }

    /// Zip `files` (template.json included by the caller) into a bundle.
    static func bundle(in dir: String, _ files: [String: String]) throws -> String {
        try ProjectTemplateServiceTests.makeBundle(dir: dir, files: files, includeManifest: false)
    }

    static func manifestJSON(
        schemaVersion: Int, id: String = "tester/r12", extraContents: String = ""
    ) -> String {
        """
        {"schemaVersion": \(schemaVersion), "id": "\(id)", "name": "R12", "version": "1.0.0",
         "description": "r12", "contents": {"dashboard": true, "agentsMd": true\(extraContents)}}
        """
    }

    static let requiredFiles: [String: String] = [
        "README.md": "# R12",
        "AGENTS.md": "# Agent notes",
        "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON,
    ]

    // MARK: - S12-F1: schemaVersion 3 (slash commands) installs

    /// Export a project that has a slash command AND a skill with
    /// `references/` + `scripts/` folders, then inspect → plan → install →
    /// uninstall the bundle. Before R12 the export failed on the skill
    /// folders (read as files) and, once past that, `inspect` refused the
    /// schemaVersion 3 the exporter writes for slash commands.
    @Test func exportedProjectWithSlashCommandsAndSkillFoldersRoundTrips() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let projectDir = scratch + "/source"
        try Self.makeProject(at: projectDir)
        try Self.write(Self.slashCommand, to: projectDir + "/.scarf/slash-commands/deploy.md")

        let skillDir = home.context.paths.skillsDir + "/tools/helper"
        try Self.write("---\nname: helper\ndescription: Helps\n---\nBody", to: skillDir + "/SKILL.md")
        try Self.write("guide", to: skillDir + "/references/guide.md")
        try Self.write("#!/bin/sh\necho hi", to: skillDir + "/scripts/run.sh")
        try Self.write("deep", to: skillDir + "/references/nested/deeper.md")
        try Self.write("stale", to: skillDir + "/SKILL.md.bak")
        try Self.write("hidden", to: skillDir + "/.DS_Store")

        let outputPath = scratch + "/out.scarftemplate"
        try await ProjectTemplateExporter(context: home.context).export(
            inputs: Self.inputs(project: ProjectEntry(name: "Src", path: projectDir), skills: ["tools/helper"]),
            outputZipPath: outputPath
        )

        let service = ProjectTemplateService(context: home.context)
        let inspection = try await service.inspect(zipPath: outputPath)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        #expect(inspection.manifest.schemaVersion == 3)
        #expect(inspection.manifest.contents.slashCommands == ["deploy"])
        #expect(inspection.files.contains("slash-commands/deploy.md"))
        #expect(inspection.files.contains("skills/helper/SKILL.md"))
        #expect(inspection.files.contains("skills/helper/references/guide.md"))
        #expect(inspection.files.contains("skills/helper/references/nested/deeper.md"))
        #expect(inspection.files.contains("skills/helper/scripts/run.sh"))
        #expect(!inspection.files.contains("skills/helper/SKILL.md.bak"))
        #expect(!inspection.files.contains("skills/helper/.DS_Store"))

        let parent = scratch + "/installed"
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let plan = try service.buildPlan(inspection: inspection, parentDir: parent)
        let entry = try ProjectTemplateInstaller(context: home.context).install(plan: plan)

        let installedCommand = plan.projectDir + "/.scarf/slash-commands/deploy.md"
        #expect(Self.read(installedCommand) == Self.slashCommand)
        let commands = ProjectSlashCommandService(context: home.context).loadCommands(at: plan.projectDir)
        #expect(commands.map(\.name) == ["deploy"])
        let ns = try #require(plan.skillsNamespaceDir)
        #expect(Self.read(ns + "/helper/scripts/run.sh") == "#!/bin/sh\necho hi")
        #expect(Self.read(ns + "/helper/references/nested/deeper.md") == "deep")

        // The slash command is lock-tracked, so uninstall removes it too.
        let uninstaller = ProjectTemplateUninstaller(context: home.context, hermesRunner: { _ in ("", 0) })
        let uninstallPlan = try uninstaller.loadUninstallPlan(for: entry)
        #expect(uninstallPlan.projectFilesToRemove.contains(installedCommand))
        let outcome = try uninstaller.uninstall(plan: uninstallPlan)
        #expect(outcome.isComplete)
        #expect(!FileManager.default.fileExists(atPath: installedCommand))
    }

    @Test func inspectAcceptsSchemaVersionsOneThroughThreeOnly() async throws {
        let service = ProjectTemplateService(context: .local)
        for version in 1...4 {
            let scratch = try ProjectTemplateServiceTests.makeTempDir()
            defer { try? FileManager.default.removeItem(atPath: scratch) }
            var files = Self.requiredFiles
            files["template.json"] = Self.manifestJSON(schemaVersion: version)
            let path = try Self.bundle(in: scratch, files)
            if version <= 3 {
                let inspection = try await service.inspect(zipPath: path)
                service.cleanupTempDir(inspection.unpackedDir)
                #expect(inspection.manifest.schemaVersion == version)
            } else {
                await #expect(throws: ProjectTemplateError.self) {
                    _ = try await service.inspect(zipPath: path)
                }
            }
        }
    }

    // MARK: - S12-F2: the cached schema is read through the transport

    /// A transport whose paths live under a pseudo-remote root that does not
    /// exist on this Mac, mapped onto a local scratch dir. `FileManager`
    /// sees nothing at those paths — exactly the SSH situation.
    final class RemappedTransport: ServerTransport, @unchecked Sendable {
        let inner = LocalTransport()
        let remoteRoot: String
        let localRoot: String
        init(remoteRoot: String, localRoot: String) {
            self.remoteRoot = remoteRoot
            self.localRoot = localRoot
        }
        func map(_ path: String) -> String {
            path.hasPrefix(remoteRoot) ? localRoot + path.dropFirst(remoteRoot.count) : path
        }
        var contextID: ServerID { inner.contextID }
        var isRemote: Bool { true }
        func readFile(_ path: String) throws -> Data { try inner.readFile(map(path)) }
        func unguardedWriteFile(_ path: String, data: Data) throws {
            try inner.unguardedWriteFile(map(path), data: data)
        }
        func fileExists(_ path: String) -> Bool { inner.fileExists(map(path)) }
        func stat(_ path: String) -> FileStat? { inner.stat(map(path)) }
        func statAll(_ paths: [String]) -> [String: FileStat]? { nil }
        func listDirectory(_ path: String) throws -> [String] { try inner.listDirectory(map(path)) }
        func createDirectory(_ path: String) throws { try inner.createDirectory(map(path)) }
        func removeFile(_ path: String) throws { try inner.removeFile(map(path)) }
        func runProcess(
            executable: String, args: [String], stdin: Data?, timeout: TimeInterval
        ) throws -> ProcessResult {
            throw TransportError.fileIO(path: executable, underlying: "no processes in this test")
        }
        func makeProcess(executable: String, args: [String]) -> Process { Process() }
        func makeProcess(executable: String, args: [String], cwd: String?) -> Process { Process() }
        func watchPaths(_ paths: [String]) -> AsyncStream<WatchEvent> { AsyncStream { $0.finish() } }
        func streamScript(_ script: String, timeout: TimeInterval) async throws -> ProcessResult {
            throw TransportError.fileIO(path: "", underlying: "no processes in this test")
        }
        func streamLines(executable: String, args: [String]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @Test func cachedSchemaIsReadThroughTheTransportNotTheMacDisk() throws {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let remoteRoot = "/nonexistent-remote-\(UUID().uuidString)"
        let transport = RemappedTransport(remoteRoot: remoteRoot, localRoot: scratch)
        let remoteProject = remoteRoot + "/proj"
        #expect(!FileManager.default.fileExists(atPath: remoteProject))

        // Absent: a project that never had a schema.
        #expect(try ProjectTemplateExporter.readCachedSchema(from: remoteProject, transport: transport) == nil)

        // Present on the "remote": the schema comes back.
        try Self.write("""
            {"schemaVersion": 2, "id": "tester/r12", "config": {"schema": [
              {"key": "site_url", "type": "string", "label": "Site", "required": false}
            ]}}
            """, to: scratch + "/proj/.scarf/manifest.json")
        let schema = try #require(
            try ProjectTemplateExporter.readCachedSchema(from: remoteProject, transport: transport)
        )
        #expect(schema.fields.map(\.key) == ["site_url"])

        // Present but unreadable (a directory where the file should be):
        // the export fails instead of silently dropping the schema.
        try FileManager.default.removeItem(atPath: scratch + "/proj/.scarf/manifest.json")
        try FileManager.default.createDirectory(
            atPath: scratch + "/proj/.scarf/manifest.json", withIntermediateDirectories: true
        )
        #expect(throws: (any Error).self) {
            _ = try ProjectTemplateExporter.readCachedSchema(from: remoteProject, transport: transport)
        }
    }

    @Test func skillTreeWalksFoldersThroughTheTransportAndFollowsSymlinks() throws {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let remoteRoot = "/nonexistent-remote-\(UUID().uuidString)"
        let transport = RemappedTransport(remoteRoot: remoteRoot, localRoot: scratch)
        try Self.write("x", to: scratch + "/skill/SKILL.md")
        try Self.write("x", to: scratch + "/skill/references/a.md")
        try Self.write("x", to: scratch + "/shared/b.md")
        try Self.write("x", to: scratch + "/skill/notes.corrupt-20260101")
        try FileManager.default.createSymbolicLink(
            atPath: scratch + "/skill/linked", withDestinationPath: scratch + "/shared"
        )
        try FileManager.default.createSymbolicLink(
            atPath: scratch + "/skill/alias.md", withDestinationPath: scratch + "/shared/b.md"
        )
        try FileManager.default.createSymbolicLink(
            atPath: scratch + "/skill/dangling.md", withDestinationPath: scratch + "/nowhere.md"
        )
        let tree = try ProjectTemplateExporter.skillFileTree(at: remoteRoot + "/skill", transport: transport)
        #expect(tree == ["SKILL.md", "alias.md", "linked/b.md", "references/a.md"])
    }

    // MARK: - S12-F3: the memory block is its own Hermes entry

    /// Hermes's own reading of MEMORY.md: `_parse_entries` splits on the
    /// full `\n§\n` and strips each entry, and a file only round-trips
    /// (no `_detect_external_drift`) when its stripped bytes equal the
    /// entries re-joined (`tools/memory_tool_store.py:510-538` @ v2026.9.24).
    static func hermesEntries(_ raw: String) -> (entries: [String], roundTrips: Bool) {
        let entries = raw.components(separatedBy: "\n§\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return (entries, stripped.isEmpty || stripped == entries.joined(separator: "\n§\n"))
    }

    static func installMemoryTemplate(
        home: TempHermesHome, scratch: String, id: String = "tester/mem", parentName: String = "parent"
    ) async throws -> (entry: ProjectEntry, block: String) {
        var files = requiredFiles
        files["template.json"] = manifestJSON(
            schemaVersion: 1, id: id, extraContents: ", \"memory\": {\"append\": true}"
        )
        files["memory/append.md"] = "Template fact one.\nTemplate fact two.\n"
        let path = try bundle(in: scratch, files)
        let service = ProjectTemplateService(context: home.context)
        let inspection = try await service.inspect(zipPath: path)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let parent = scratch + "/" + parentName
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let plan = try service.buildPlan(inspection: inspection, parentDir: parent)
        let entry = try ProjectTemplateInstaller(context: home.context).install(plan: plan)
        let begin = ProjectTemplateService.memoryBlockBeginMarker(templateId: id)
        let end = ProjectTemplateService.memoryBlockEndMarker(templateId: id)
        let block = "\(begin) v1.0.0\nTemplate fact one.\nTemplate fact two.\n\(end)"
        return (entry, block)
    }

    // MARK: - R16a: memory markers Hermes's threat scan won't block

    /// Hermes's `html_comment_injection` pattern (`tools/threat_patterns.py:31`
    /// @ v2026.9.24, compiled case-insensitive). A MEMORY.md entry matching it
    /// is replaced by a [BLOCKED] placeholder at load time.
    static func hermesBlocks(_ text: String) -> Bool {
        let pattern = #"<!--[^>]{0,512}(?:ignore|override|system|secret|hidden)[^>]{0,512}-->"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    @Test(arguments: ["acme/system-monitor", "x/Secret-Santa", "h/hidden-gems", "o/override-kit", "i/ignore-list", "tester/mem"])
    func memoryMarkersNeverTripHermesThreatScan(id: String) {
        let begin = ProjectTemplateService.memoryBlockBeginMarker(templateId: id)
        let end = ProjectTemplateService.memoryBlockEndMarker(templateId: id)
        #expect(!Self.hermesBlocks(begin + " v1.0.0\nfact\n" + end))
        #expect(!begin.contains(id), "the marker carries a hash, never the id")
        #expect(begin != ProjectTemplateService.memoryBlockBeginMarker(templateId: id + "x"))
        // The premise: the legacy form is blocked for these ids.
        if id != "tester/mem" {
            #expect(Self.hermesBlocks(ProjectTemplateService.legacyMemoryBlockMarkers(templateId: id).begin))
        }
    }

    @Test func templateWithAFlaggedWordInItsIdInstallsAnUnblockedEntry() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let (entry, block) = try await Self.installMemoryTemplate(
            home: home, scratch: scratch, id: "tester/system-monitor")
        let installed = try #require(Self.read(home.context.paths.memoryMD))
        #expect(installed == block)
        #expect(Self.hermesEntries(installed).entries.allSatisfy { !Self.hermesBlocks($0) })

        let uninstaller = ProjectTemplateUninstaller(context: home.context, hermesRunner: { _ in ("", 0) })
        let plan = try uninstaller.loadUninstallPlan(for: entry)
        #expect(plan.memoryBlockPresent)
        #expect(try uninstaller.uninstall(plan: plan).isComplete)
        #expect(Self.read(home.context.paths.memoryMD) == "")
    }

    /// A block an older Scarf installed (markers spelling the id out) is
    /// still found by the plan, stripped by uninstall, and still blocks a
    /// second install of the same template.
    @Test func legacyMarkersStillDetectedAndStripped() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let memoryPath = home.context.paths.memoryMD
        try Self.write("User fact A.", to: memoryPath)
        let (entry, block) = try await Self.installMemoryTemplate(home: home, scratch: scratch)
        let legacy = ProjectTemplateService.legacyMemoryBlockMarkers(templateId: "tester/mem")
        let legacyBlock = block
            .replacingOccurrences(of: ProjectTemplateService.memoryBlockBeginMarker(templateId: "tester/mem"), with: legacy.begin)
            .replacingOccurrences(of: ProjectTemplateService.memoryBlockEndMarker(templateId: "tester/mem"), with: legacy.end)
        #expect(legacyBlock != block)
        try Self.write("User fact A.\n§\n" + legacyBlock + "\n§\nUser fact B.", to: memoryPath)

        do {
            _ = try await Self.installMemoryTemplate(home: home, scratch: scratch, parentName: "second")
            Issue.record("a second install must refuse while the legacy block is there")
        } catch ProjectTemplateError.memoryBlockAlreadyExists(let id) {
            #expect(id == "tester/mem")
        }

        let uninstaller = ProjectTemplateUninstaller(context: home.context, hermesRunner: { _ in ("", 0) })
        let plan = try uninstaller.loadUninstallPlan(for: entry)
        #expect(plan.memoryBlockPresent)
        _ = try uninstaller.uninstall(plan: plan)
        #expect(Self.read(memoryPath) == "User fact A.\n§\nUser fact B.")
    }

    @Test func memoryBlockIsAddedAsItsOwnEntryAndUninstallRemovesExactlyThatEntry() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let memoryPath = home.context.paths.memoryMD
        // What Hermes writes: entries joined by the delimiter, no trailing newline.
        let userFacts = "User fact A.\n§\nUser fact B."
        try Self.write(userFacts + "\n", to: memoryPath)

        let (entry, block) = try await Self.installMemoryTemplate(home: home, scratch: scratch)
        let installed = try #require(Self.read(memoryPath))
        #expect(installed == userFacts + "\n§\n" + block)
        let parsed = Self.hermesEntries(installed)
        #expect(parsed.entries == ["User fact A.", "User fact B.", block])
        #expect(parsed.roundTrips)

        // The agent adds a fact afterwards (Hermes rewrites the file joined).
        let withLater = installed + "\n§\nUser fact C."
        try Self.write(withLater, to: memoryPath)

        let uninstaller = ProjectTemplateUninstaller(context: home.context, hermesRunner: { _ in ("", 0) })
        let plan = try uninstaller.loadUninstallPlan(for: entry)
        #expect(plan.memoryBlockPresent)
        let outcome = try uninstaller.uninstall(plan: plan)
        #expect(outcome.isComplete)
        let after = try #require(Self.read(memoryPath))
        #expect(after == "User fact A.\n§\nUser fact B.\n§\nUser fact C.")
        #expect(Self.hermesEntries(after).roundTrips)
    }

    @Test func memoryBlockIntoAnEmptyFileIsTheOnlyEntryAndLeavesNothingBehind() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let memoryPath = home.context.paths.memoryMD

        let (entry, block) = try await Self.installMemoryTemplate(home: home, scratch: scratch)
        #expect(Self.read(memoryPath) == block)
        // The agent's later entry lands after it.
        try Self.write(block + "\n§\nLater fact.", to: memoryPath)

        let uninstaller = ProjectTemplateUninstaller(context: home.context, hermesRunner: { _ in ("", 0) })
        try uninstaller.uninstall(plan: uninstaller.loadUninstallPlan(for: entry))
        #expect(Self.read(memoryPath) == "Later fact.")
    }

    /// Blocks written by older Scarf (glued to the previous entry with a
    /// blank line) are still stripped cleanly.
    @Test func legacyGluedMemoryBlockIsStillStripped() {
        let begin = ProjectTemplateService.memoryBlockBeginMarker(templateId: "t")
        let end = ProjectTemplateService.memoryBlockEndMarker(templateId: "t")
        let text = "Fact A.\n§\nFact B.\n\n\(begin) v1\nbody\n\(end)\n"
        let b = text.range(of: begin)!
        let e = text.range(of: end)!
        #expect(ProjectTemplateUninstaller.removingMemoryBlock(from: text, begin: b, end: e)
                == "Fact A.\n§\nFact B.\n")
    }

    /// Text an agent added after the end marker inside the same entry is
    /// not the template's; it survives as its own entry.
    @Test func textAfterTheEndMarkerInTheSameEntrySurvives() {
        let begin = ProjectTemplateService.memoryBlockBeginMarker(templateId: "t")
        let end = ProjectTemplateService.memoryBlockEndMarker(templateId: "t")
        let text = "Fact A.\n§\n\(begin) v1\nbody\n\(end)\nAgent note."
        let b = text.range(of: begin)!
        let e = text.range(of: end)!
        #expect(ProjectTemplateUninstaller.removingMemoryBlock(from: text, begin: b, end: e)
                == "Fact A.\n§\nAgent note.")
    }

    // MARK: - S12-F4: uninstall reports what it couldn't remove

    static func installMinimal(home: TempHermesHome, scratch: String) async throws -> ProjectEntry {
        var files = requiredFiles
        files["template.json"] = manifestJSON(schemaVersion: 1)
        let path = try bundle(in: scratch, files)
        let service = ProjectTemplateService(context: home.context)
        let inspection = try await service.inspect(zipPath: path)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let parent = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let plan = try service.buildPlan(inspection: inspection, parentDir: parent)
        return try ProjectTemplateInstaller(context: home.context).install(plan: plan)
    }

    static func setLockCronNames(_ names: [String], projectDir: String) throws {
        let path = projectDir + "/.scarf/template.lock.json"
        var root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        )
        root["cron_job_names"] = names
        try JSONSerialization.data(withJSONObject: root).write(to: URL(fileURLWithPath: path))
    }

    static func writeJobs(_ home: TempHermesHome, _ jobs: [(id: String, name: String, prompt: String)]) throws {
        let body = jobs.map { job in
            """
            {"id": "\(job.id)", "name": "\(job.name)", "prompt": "\(job.prompt)",
             "schedule": {"kind": "cron", "expression": "0 0 * * *"}, "enabled": true, "state": "scheduled"}
            """
        }.joined(separator: ",")
        try write("{\"jobs\": [\(body)]}", to: home.context.paths.cronJobsJSON)
    }

    /// Recorder for the injected cron runner.
    final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var _argv: [[String]] = []
        var argv: [[String]] { lock.lock(); defer { lock.unlock() }; return _argv }
        func record(_ a: [String]) { lock.lock(); _argv.append(a); lock.unlock() }
    }

    @Test func aFailedCronRemoveIsReportedNotSwallowed() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let entry = try await Self.installMinimal(home: home, scratch: scratch)
        let name = "[tmpl:tester/r12] nightly"
        try Self.setLockCronNames([name], projectDir: entry.path)
        try Self.writeJobs(home, [("job-1", name, "p")])

        let runs = Runs()
        let uninstaller = ProjectTemplateUninstaller(context: home.context, hermesRunner: { argv in
            runs.record(argv)
            return ("Job not found", 1)
        })
        let plan = try uninstaller.loadUninstallPlan(for: entry)
        #expect(plan.cronJobsToRemove.map(\.id) == ["job-1"])
        let outcome = try uninstaller.uninstall(plan: plan)
        #expect(runs.argv == [["cron", "remove", "job-1"]])
        #expect(!outcome.isComplete)
        #expect(outcome.leftovers.contains { $0.contains(name) })
    }

    @Test func anUnreadableCronListIsNotReadAsAlreadyGone() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let entry = try await Self.installMinimal(home: home, scratch: scratch)
        let name = "[tmpl:tester/r12] nightly"
        try Self.setLockCronNames([name], projectDir: entry.path)
        try Self.write("{ not json", to: home.context.paths.cronJobsJSON)

        let runs = Runs()
        let uninstaller = ProjectTemplateUninstaller(context: home.context, hermesRunner: { argv in
            runs.record(argv)
            return ("", 0)
        })
        let plan = try uninstaller.loadUninstallPlan(for: entry)
        #expect(plan.cronJobsAlreadyGone.isEmpty)
        #expect(plan.cronJobsUnverified == [name])
        let outcome = try uninstaller.uninstall(plan: plan)
        #expect(runs.argv.isEmpty)
        #expect(outcome.leftovers.contains { $0.contains(name) })
    }

    /// Two installs of one template by an older Scarf share the job name.
    /// The uninstall must not take the first match (possibly the OTHER
    /// project's job): it picks the job whose prompt names this project,
    /// and reports rather than guesses when nothing tells them apart.
    @Test func sharedLegacyJobNamesResolveToThisProjectsJobOrAreReported() async throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let entry = try await Self.installMinimal(home: home, scratch: scratch)
        let name = "[tmpl:tester/r12] nightly"
        let uninstaller = ProjectTemplateUninstaller(context: home.context, hermesRunner: { _ in ("", 0) })
        let transport = home.context.makeTransport()

        try Self.writeJobs(home, [
            ("other", name, "check /elsewhere/project/status.md"),
            ("mine", name, "check \(entry.path)/status.md"),
        ])
        let resolved = uninstaller.resolveCronJobs(
            names: [name], project: entry, templateId: "tester/r12", transport: transport
        )
        #expect(resolved.toRemove.map(\.id) == ["mine"])

        try Self.writeJobs(home, [("x", name, "p"), ("y", name, "p")])
        let ambiguous = uninstaller.resolveCronJobs(
            names: [name], project: entry, templateId: "tester/r12", transport: transport
        )
        #expect(ambiguous.toRemove.isEmpty)
        #expect(ambiguous.unverified == [name])

        // A lone legacy match is this project's only when no other
        // registered project came from the same template; otherwise it may
        // be the other install's job (this one's deleted by hand).
        try Self.writeJobs(home, [("lone", name, "p")])
        let alone = uninstaller.resolveCronJobs(
            names: [name], project: entry, templateId: "tester/r12", transport: transport
        )
        #expect(alone.toRemove.map(\.id) == ["lone"])

        let other = try await Self.installMinimal(home: home, scratch: scratch + "/second")
        #expect(other.path != entry.path)
        let shared = uninstaller.resolveCronJobs(
            names: [name], project: entry, templateId: "tester/r12", transport: transport
        )
        #expect(shared.toRemove.isEmpty)
        #expect(shared.unverified == [name])
        try Self.writeJobs(home, [("lone", name, "check \(entry.path)/status.md")])
        let claimed = uninstaller.resolveCronJobs(
            names: [name], project: entry, templateId: "tester/r12", transport: transport
        )
        #expect(claimed.toRemove.map(\.id) == ["lone"])
    }

    @Test func pathMentionsNeedAWholePath() {
        #expect(ProjectTemplateUninstaller.mentions(path: "/x/foo", in: "write /x/foo/log.md"))
        #expect(ProjectTemplateUninstaller.mentions(path: "/x/foo", in: "cd /x/foo"))
        #expect(!ProjectTemplateUninstaller.mentions(path: "/x/foo", in: "write /x/foo-bar/log.md"))
        #expect(ProjectTemplateUninstaller.mentions(path: "/x/foo", in: "/x/foo-bar and /x/foo/a"))
    }

    /// A tag Scarf added on this host doesn't travel in an exported bundle.
    @Test func exportedJobNamesDropAttributionTags() {
        let id = UUID().uuidString
        #expect(ProjectTemplateExporter.strippingAttributionTags("[tmpl:a/b] [proj:\(id)] nightly") == "nightly")
        #expect(ProjectTemplateExporter.strippingAttributionTags("[proj:\(id)] refresh") == "refresh")
        #expect(ProjectTemplateExporter.strippingAttributionTags("plain [tmpl:x] name") == "plain [tmpl:x] name")
    }

    /// Stray blank lines around the delimiter are still the same entry;
    /// the strip must not leave a lone `§` (Hermes would then see the file
    /// as externally edited and refuse memory writes).
    @Test func memoryStripToleratesWhitespaceAroundTheDelimiter() {
        let begin = ProjectTemplateService.memoryBlockBeginMarker(templateId: "t")
        let end = ProjectTemplateService.memoryBlockEndMarker(templateId: "t")
        let block = "\(begin) v1\nbody\n\(end)"
        for (text, expected) in [
            ("A\n§\n\n\(block)\n\n§\nB", "A\n§\nB"),
            ("\(block)\n\n§\nB", "B"),
            ("A\n§\n\(block)\n", "A"),
            ("\n\n\(block)\n", ""),
        ] {
            let b = text.range(of: begin)!
            let e = text.range(of: end)!
            let out = ProjectTemplateUninstaller.removingMemoryBlock(from: text, begin: b, end: e)
            #expect(out == expected, "\(text.debugDescription) -> \(out.debugDescription)")
            #expect(Self.hermesEntries(out).roundTrips)
        }
    }

    /// Unreadable is decided by the far end's own "no such file", never
    /// by a `fileExists` re-probe (which a dropped SSH link also fails).
    @Test func cronListReadDistinguishesAbsentFromUnreadable() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let transport = home.context.makeTransport()
        #expect(ProjectTemplateUninstaller.readCronJobs(context: home.context, transport: transport) == [])
        try FileManager.default.createDirectory(
            atPath: home.context.paths.cronJobsJSON, withIntermediateDirectories: true
        )
        #expect(ProjectTemplateUninstaller.readCronJobs(context: home.context, transport: transport) == nil)
    }
}
