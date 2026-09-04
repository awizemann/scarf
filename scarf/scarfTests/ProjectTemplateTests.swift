import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Exercises the service's ability to unpack, parse, and validate bundles.
/// Doesn't touch the installer — see `ProjectTemplateInstallerTests` — so
/// these don't need write access to ~/.hermes.
@Suite struct ProjectTemplateServiceTests {

    @Test func manifestSlugSanitizesPunctuation() {
        let manifest = Self.sampleManifest(id: "alan@w/focus dashboard!")
        #expect(manifest.slug == "alan-w-focus-dashboard")
    }

    @Test func manifestSlugFallsBackToPlaceholder() {
        let manifest = Self.sampleManifest(id: "////")
        #expect(manifest.slug == "template")
    }

    @Test func inspectRejectsMissingManifest() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // A zip with no template.json
        let bundle = try Self.makeBundle(dir: dir, files: [
            "README.md": "hi",
            "AGENTS.md": "hi",
            "dashboard.json": "{}"
        ], includeManifest: false)

        let service = ProjectTemplateService(context: .local)
        #expect(throws: ProjectTemplateError.self) {
            try service.inspect(zipPath: bundle)
        }
    }

    @Test func inspectRejectsMissingAgentsMd() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let bundle = try Self.makeBundle(dir: dir, files: [
            "README.md": "# Readme",
            "dashboard.json": Self.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: .local)
        #expect(throws: ProjectTemplateError.self) {
            try service.inspect(zipPath: bundle)
        }
    }

    @Test func inspectAcceptsMinimalValidBundle() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let bundle = try Self.makeBundle(dir: dir, files: [
            "README.md": "# Readme",
            "AGENTS.md": "# Agents",
            "dashboard.json": Self.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: .local)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }

        #expect(inspection.manifest.id == "test/example")
        #expect(inspection.manifest.slug == "test-example")
        #expect(inspection.cronJobs.isEmpty)
        #expect(inspection.files.contains("AGENTS.md"))
    }

    @Test func inspectRejectsContentClaimMismatch() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Claim cron: 2 but ship no cron dir → service must reject.
        let manifest = Self.sampleManifest(cron: 2)
        let manifestJSON = try JSONEncoder().encode(manifest)
        let manifestString = String(data: manifestJSON, encoding: .utf8)!

        let bundle = try Self.makeBundle(dir: dir, files: [
            "README.md": "# Readme",
            "AGENTS.md": "# Agents",
            "dashboard.json": Self.sampleDashboardJSON,
            "template.json": manifestString
        ], includeManifest: false)

        let service = ProjectTemplateService(context: .local)
        #expect(throws: ProjectTemplateError.self) {
            try service.inspect(zipPath: bundle)
        }
    }

    // MARK: - Helpers

    static let sampleDashboardJSON = """
    {
        "version": 1,
        "title": "Example",
        "description": "test",
        "sections": []
    }
    """

    static func sampleManifest(
        id: String = "test/example",
        cron: Int? = nil,
        skills: [String]? = nil,
        instructions: [String]? = nil,
        configFieldCount: Int? = nil,
        configSchema: TemplateConfigSchema? = nil
    ) -> ProjectTemplateManifest {
        // schemaVersion auto-bumps to 2 when a schema is present so tests
        // that exercise the schema path mirror real manifest behaviour.
        let version = (configSchema != nil) ? 2 : 1
        return ProjectTemplateManifest(
            schemaVersion: version,
            id: id,
            name: "Example",
            version: "1.0.0",
            minScarfVersion: nil,
            minHermesVersion: nil,
            author: TemplateAuthor(name: "Tester", url: nil),
            description: "Test template",
            category: nil,
            tags: nil,
            icon: nil,
            screenshots: nil,
            contents: TemplateContents(
                dashboard: true,
                agentsMd: true,
                instructions: instructions,
                skills: skills,
                cron: cron,
                memory: nil,
                config: configFieldCount ?? configSchema?.fields.count,
                slashCommands: nil
            ),
            config: configSchema
        )
    }

    static func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "scarf-template-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write files to a staging dir, then zip them into `<dir>/bundle.scarftemplate`
    /// and return its path. When `includeManifest` is true the caller doesn't
    /// need to provide `template.json` — we synthesize a valid one.
    static func makeBundle(
        dir: String,
        files: [String: String],
        includeManifest: Bool = true
    ) throws -> String {
        let staging = dir + "/staging"
        try FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)

        for (relativePath, content) in files {
            let full = staging + "/" + relativePath
            let parent = (full as NSString).deletingLastPathComponent
            if !FileManager.default.fileExists(atPath: parent) {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            }
            try content.data(using: .utf8)!.write(to: URL(fileURLWithPath: full))
        }
        if includeManifest {
            let manifest = sampleManifest()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(manifest)
            try data.write(to: URL(fileURLWithPath: staging + "/template.json"))
        }

        let bundlePath = dir + "/bundle.scarftemplate"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = URL(fileURLWithPath: staging)
        process.arguments = ["-qq", "-r", bundlePath, "."]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return bundlePath
    }
}

/// URL-router has no filesystem side effects — safe to unit-test directly.
@Suite struct TemplateURLRouterTests {

    @Test @MainActor func refusesNonScarfScheme() {
        let router = TemplateURLRouter.shared
        router.pendingInstallURL = nil
        let ok = router.handle(URL(string: "https://example.com/foo")!)
        #expect(ok == false)
        #expect(router.pendingInstallURL == nil)
    }

    @Test @MainActor func refusesUnknownHost() {
        let router = TemplateURLRouter.shared
        router.pendingInstallURL = nil
        let ok = router.handle(URL(string: "scarf://bogus?url=https://example.com/x.scarftemplate")!)
        #expect(ok == false)
        #expect(router.pendingInstallURL == nil)
    }

    @Test @MainActor func refusesNonHttpsPayload() {
        let router = TemplateURLRouter.shared
        router.pendingInstallURL = nil
        let ok = router.handle(URL(string: "scarf://install?url=file:///etc/passwd")!)
        #expect(ok == false)
        #expect(router.pendingInstallURL == nil)
    }

    @Test @MainActor func acceptsFileURLWithScarftemplateExtension() {
        let router = TemplateURLRouter.shared
        router.pendingInstallURL = nil
        let path = "/tmp/example.scarftemplate"
        let ok = router.handle(URL(fileURLWithPath: path))
        #expect(ok)
        #expect(router.pendingInstallURL?.isFileURL == true)
        #expect(router.pendingInstallURL?.path == path)
        router.consume()
    }

    @Test @MainActor func refusesFileURLWithOtherExtension() {
        let router = TemplateURLRouter.shared
        router.pendingInstallURL = nil
        let ok = router.handle(URL(fileURLWithPath: "/tmp/somefile.zip"))
        #expect(ok == false)
        #expect(router.pendingInstallURL == nil)
    }

    @Test @MainActor func acceptsHttpsInstallUrl() {
        let router = TemplateURLRouter.shared
        router.pendingInstallURL = nil
        let target = "https://example.com/foo.scarftemplate"
        let ok = router.handle(URL(string: "scarf://install?url=\(target)")!)
        #expect(ok)
        #expect(router.pendingInstallURL?.absoluteString == target)
        router.consume()
    }
}

/// End-to-end install test against a minimal bundle (dashboard + README +
/// AGENTS.md, no skills/cron/memory). Exercises the full install path
/// through `preflight → createProjectFiles → registerProject →
/// writeLockFile`. We avoid touching user state by:
///   1. Picking a temp `projectDir` under `NSTemporaryDirectory()`.
///   2. Snapshotting and restoring `~/.hermes/scarf/projects.json` around
///      each test so the registry write is reversible.
/// Skills/cron/memory paths aren't touched because the test bundles claim
/// none. That's the intentional v1 coverage: the project-dir side effects
/// are exhaustively tested; global-state side effects (skills namespace,
/// cron CLI, memory append) are covered by manual verification per the
/// plan's step 7.
///
/// Each test injects an isolated `ServerContext.local(home:)`, so the
/// registry write lands in a per-instance temp home, never the real
/// `~/.hermes`. That replaces the old snapshot/restore-the-real-registry
/// dance (and the cross-suite `TestRegistryLock` it relied on), so the
/// suite needs no `.serialized` and runs in parallel safely.
struct ProjectTemplateInstallerTests {

    /// t-07e909e0 / DI-H5. The installer's registry registration is a
    /// read-modify-write, and it used to run outside the cross-process
    /// lock — so a `project_register` from the MCP helper landing between
    /// its load and its save was published away. Proven the deterministic
    /// way rather than with threads: hold the lock file the way another
    /// process would, and the install must REPORT `registryBusy` instead of
    /// walking through the window.
    @Test func installRefusesWhileAnotherProcessHoldsTheRegistryLock() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])
        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        // Stand in for the other process. Fresh mtime, so it is a LIVE
        // hold rather than one the staleness bound would break.
        let lockPath = home.context.paths.projectsRegistry + ".lock"
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("owner=SOMEBODY-ELSE\n".utf8).write(to: URL(fileURLWithPath: lockPath))
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        #expect(throws: ProjectRegistryError.self) {
            try ProjectTemplateInstaller(context: home.context).install(plan: plan)
        }
        // The other process's lock is still its own.
        #expect(FileManager.default.fileExists(atPath: lockPath))
    }

    @Test func installsMinimalBundleAndWritesLockFile() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        let installer = ProjectTemplateInstaller(context: home.context)
        let entry = try installer.install(plan: plan)

        #expect(FileManager.default.fileExists(atPath: plan.projectDir))
        #expect(FileManager.default.fileExists(atPath: plan.projectDir + "/AGENTS.md"))
        #expect(FileManager.default.fileExists(atPath: plan.projectDir + "/README.md"))
        #expect(FileManager.default.fileExists(atPath: plan.projectDir + "/.scarf/dashboard.json"))
        #expect(FileManager.default.fileExists(atPath: plan.projectDir + "/.scarf/template.lock.json"))
        #expect(entry.path == plan.projectDir)

        let lockData = try Data(contentsOf: URL(fileURLWithPath: plan.projectDir + "/.scarf/template.lock.json"))
        let lock = try JSONDecoder().decode(TemplateLock.self, from: lockData)
        #expect(lock.templateId == inspection.manifest.id)
        #expect(lock.templateVersion == inspection.manifest.version)
        #expect(lock.projectFiles.contains(plan.projectDir + "/AGENTS.md"))
        #expect(lock.cronJobNames.isEmpty)
        #expect(lock.memoryBlockId == nil)

        // Installer parity (M2 review): mints a stable UUID + writes the
        // canonical project.json AFTER the lock, so the record captures
        // templateLockRef.
        #expect(entry.uuid != nil)
        let recordPath = plan.projectDir + "/.scarf/project.json"
        #expect(FileManager.default.fileExists(atPath: recordPath))
        let record = try JSONDecoder().decode(
            ScarfProject.self, from: Data(contentsOf: URL(fileURLWithPath: recordPath))
        )
        #expect(record.id == entry.uuid)
        #expect(record.templateLockRef == plan.projectDir + "/.scarf/template.lock.json")
    }

    @Test func preflightRejectsExistingProjectDir() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        // Simulate a concurrent creation between buildPlan and install.
        try FileManager.default.createDirectory(atPath: plan.projectDir, withIntermediateDirectories: true)

        let installer = ProjectTemplateInstaller(context: home.context)
        #expect(throws: ProjectTemplateError.self) {
            try installer.install(plan: plan)
        }
    }

    @Test func buildPlanRefusesDuplicateProjectDir() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }

        // Pre-create the slugged project dir so buildPlan's collision check
        // fires before we get to install.
        let slugDir = parentDir + "/" + inspection.manifest.slug
        try FileManager.default.createDirectory(atPath: slugDir, withIntermediateDirectories: true)

        #expect(throws: ProjectTemplateError.self) {
            try service.buildPlan(inspection: inspection, parentDir: parentDir)
        }
    }

    // MARK: - Cron prompt token substitution

    @Test func substituteCronTokensResolvesProjectDir() throws {
        let plan = try TemplateInstallerViewModelTests.makePlanWithConfigSchema()
        let raw = "Read {{PROJECT_DIR}}/.scarf/config.json"
        let resolved = ProjectTemplateInstaller.substituteCronTokens(raw, plan: plan)
        #expect(resolved == "Read \(plan.projectDir)/.scarf/config.json")
        // Original placeholder must be fully replaced — a lingering
        // {{PROJECT_DIR}} would leave the cron job trying to read a
        // literal file named `{{PROJECT_DIR}}` which doesn't exist.
        #expect(resolved.contains("{{PROJECT_DIR}}") == false)
    }

    @Test func substituteCronTokensResolvesIdAndSlug() throws {
        let plan = try TemplateInstallerViewModelTests.makePlanWithConfigSchema()
        let raw = "Log as {{TEMPLATE_ID}} (slug {{TEMPLATE_SLUG}})"
        let resolved = ProjectTemplateInstaller.substituteCronTokens(raw, plan: plan)
        #expect(resolved.contains(plan.manifest.id))
        #expect(resolved.contains(plan.manifest.slug))
        #expect(resolved.contains("{{TEMPLATE_ID}}") == false)
        #expect(resolved.contains("{{TEMPLATE_SLUG}}") == false)
    }

    @Test func substituteCronTokensLeavesUnknownTokensUntouched() throws {
        let plan = try TemplateInstallerViewModelTests.makePlanWithConfigSchema()
        let raw = "{{PROJECT_DIR}} but keep {{UNSUPPORTED}} literal"
        let resolved = ProjectTemplateInstaller.substituteCronTokens(raw, plan: plan)
        #expect(resolved.contains(plan.projectDir))
        // Unsupported placeholders pass through verbatim — template
        // authors will notice in testing that their token didn't get
        // replaced and either use a supported one or request a new one.
        #expect(resolved.contains("{{UNSUPPORTED}}"))
    }

    @Test func substituteCronTokensRepeatsWithinString() throws {
        let plan = try TemplateInstallerViewModelTests.makePlanWithConfigSchema()
        let raw = "Read {{PROJECT_DIR}}/a and write {{PROJECT_DIR}}/b"
        let resolved = ProjectTemplateInstaller.substituteCronTokens(raw, plan: plan)
        // Both occurrences should be replaced — not just the first.
        // A single-replace bug here would leave the second relative,
        // causing the same CWD issue this whole feature was meant to
        // fix.
        let count = resolved.components(separatedBy: plan.projectDir).count - 1
        #expect(count == 2)
    }
}

/// End-to-end install + uninstall test: install a minimal bundle, uninstall
/// it, verify every tracked file is gone, the registry is restored to its
/// pre-install state, and user-added files (if any) are preserved. Scoped
/// to bundles with no skills/cron/memory so no global state is touched.
///
/// Each test injects an isolated `ServerContext.local(home:)` so the
/// install/uninstall registry writes land in a per-instance temp home,
/// never the real `~/.hermes` — replacing the old snapshot/restore +
/// cross-suite `TestRegistryLock`. No shared state, no `.serialized`.
struct ProjectTemplateUninstallerTests {

    /// t-07e909e0 / DI-H5, the uninstaller's half: its row removal is a
    /// read-modify-write and now takes the same cross-process lock, so a
    /// concurrent registration can't be erased by a list loaded before it
    /// landed. Same deterministic proof as the installer's.
    @Test func uninstallRegistryRemovalRefusesWhileTheLockIsHeld() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])
        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        let installer = ProjectTemplateInstaller(context: home.context)
        let entry = try installer.install(plan: plan)
        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        let uninstallPlan = try uninstaller.loadUninstallPlan(for: entry)

        let lockPath = home.context.paths.projectsRegistry + ".lock"
        try Data("owner=SOMEBODY-ELSE\n".utf8).write(to: URL(fileURLWithPath: lockPath))
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        #expect(throws: ProjectRegistryError.self) {
            try uninstaller.uninstall(plan: uninstallPlan)
        }
        // The row is still there — a refusal, not a half-done removal that
        // reports success.
        #expect(ProjectDashboardService(context: home.context)
            .loadRegistry().projects.contains { $0.path == entry.path })
        #expect(FileManager.default.fileExists(atPath: lockPath))
    }

    @Test func roundTripsInstallThenUninstall() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        let installer = ProjectTemplateInstaller(context: home.context)
        let entry = try installer.install(plan: plan)
        #expect(FileManager.default.fileExists(atPath: plan.projectDir))

        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        #expect(uninstaller.isTemplateInstalled(project: entry))
        let uninstallPlan = try uninstaller.loadUninstallPlan(for: entry)
        #expect(uninstallPlan.projectFilesToRemove.count == 4) // README, AGENTS, dashboard.json, lock
        #expect(uninstallPlan.extraProjectEntries.isEmpty)
        #expect(uninstallPlan.projectDirBecomesEmpty)
        #expect(uninstallPlan.skillsNamespaceDir == nil)
        #expect(uninstallPlan.cronJobsToRemove.isEmpty)
        #expect(uninstallPlan.memoryBlockPresent == false)

        try uninstaller.uninstall(plan: uninstallPlan)

        #expect(FileManager.default.fileExists(atPath: plan.projectDir) == false)
        // Registry entry gone — reload from the temp home and confirm.
        let service2 = ProjectDashboardService(context: home.context)
        let registryAfter = service2.loadRegistry()
        #expect(registryAfter.projects.contains(where: { $0.path == entry.path }) == false)
    }

    @Test func preservesUserAddedFiles() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        let installer = ProjectTemplateInstaller(context: home.context)
        let entry = try installer.install(plan: plan)

        // Simulate the user / agent creating files post-install.
        let userFile = plan.projectDir + "/sites.txt"
        try "https://example.com\n".data(using: .utf8)!
            .write(to: URL(fileURLWithPath: userFile))

        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        let uninstallPlan = try uninstaller.loadUninstallPlan(for: entry)
        #expect(uninstallPlan.extraProjectEntries.contains(userFile))
        #expect(uninstallPlan.projectDirBecomesEmpty == false)

        try uninstaller.uninstall(plan: uninstallPlan)

        // Project dir should still exist because sites.txt is there.
        #expect(FileManager.default.fileExists(atPath: plan.projectDir))
        #expect(FileManager.default.fileExists(atPath: userFile))
        // Lock-tracked files are gone.
        #expect(FileManager.default.fileExists(atPath: plan.projectDir + "/AGENTS.md") == false)
        #expect(FileManager.default.fileExists(atPath: plan.projectDir + "/README.md") == false)
        #expect(FileManager.default.fileExists(atPath: plan.projectDir + "/.scarf/template.lock.json") == false)
    }

    /// **Regression: "uninstall completes but the project stays in the
    /// sidebar."** The uninstaller itself was innocent — it removed the
    /// row and saved. What resurrected the project was the cockpit's
    /// lazy-migration fallback: the file watcher fires while uninstall
    /// deletes files, `ProjectCockpitView.onChange` calls
    /// `viewModel.load(force: true)`, `ProjectStore.load` misses the
    /// just-deleted `.scarf/project.json`, and the `derive() + save()`
    /// fallback re-creates BOTH the project dir (via `mkdir -p
    /// <root>/.scarf`) and the registry row (via `indexInRegistry`) —
    /// carrying the ORIGINAL uuid, which is why the resurrected row
    /// looked untouched. `ProjectStore.save` now refuses to save a
    /// project whose root is gone.
    @Test func cockpitStyleRefreshAfterUninstallDoesNotResurrectProject() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])
        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)
        let installer = ProjectTemplateInstaller(context: home.context)
        let entry = try installer.install(plan: plan)

        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        try uninstaller.uninstall(plan: try uninstaller.loadUninstallPlan(for: entry))

        // Replay exactly what ProjectCockpitViewModel.load(force:) does
        // with the stale `ProjectEntry` it is still holding.
        let store = ProjectStore(context: home.context)
        #expect(store.load(projectPath: entry.path) == nil)
        #expect(throws: ProjectStoreError.self) {
            try store.save(store.derive(from: entry))
        }

        // Neither the dir nor the registry row comes back.
        #expect(FileManager.default.fileExists(atPath: entry.path) == false)
        let registryAfter = ProjectDashboardService(context: home.context).loadRegistry()
        #expect(registryAfter.projects.isEmpty)
    }

    /// Registry rows carry a stable uuid; paths do not. A row whose
    /// path drifted (project moved, or the path was recorded with a
    /// different-but-equivalent spelling) must still be removed.
    @Test func removesRegistryRowByUUIDWhenPathDrifted() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let uuid = UUID()
        let service = ProjectDashboardService(context: home.context)
        try service.saveRegistry(ProjectRegistry(projects: [
            ProjectEntry(name: "Renamed", path: "/somewhere/else/moved", uuid: uuid)
        ]))
        let target = ProjectEntry(name: "Original", path: "/original/path", uuid: uuid)
        #expect(ProjectTemplateUninstaller.matches(service.loadRegistry().projects[0], project: target))
    }

    /// Pre-Phase-1 rows have no uuid, so the fallback is a PATH compare
    /// — and it must normalize both sides. `/tmp/x` and `/private/tmp/x`
    /// are the same directory on macOS; a raw `==` leaves the row behind.
    @Test func matchesRowWithDivergedUUIDBySamePath() {
        // A row re-minted with a fresh uuid for the same directory must
        // still be removed — uuid inequality alone can't clear a row.
        let path = "/Users/nobody/Developer/reminted-\(UUID().uuidString)"
        let row = ProjectEntry(name: "P", path: path, uuid: UUID())
        let target = ProjectEntry(name: "P", path: path, uuid: UUID())
        #expect(ProjectTemplateUninstaller.matches(row, project: target))
        // Different uuid AND different path stays untouched.
        let other = ProjectEntry(name: "Q", path: path + "-other", uuid: UUID())
        #expect(ProjectTemplateUninstaller.matches(other, project: target) == false)
    }

    @Test func matchesLegacyRowByNormalizedPath() throws {
        // Real directory: `URL.resolvingSymlinksInPath()` only rewrites
        // path components that actually exist, so the fixture has to be
        // on disk for `/tmp` → `/private/tmp` to resolve.
        let name = "scarf-normalize-probe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: "/tmp/" + name, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: "/tmp/" + name) }

        let uuidlessRow = ProjectEntry(name: "Legacy", path: "/tmp/" + name + "/")
        let target = ProjectEntry(name: "Legacy", path: "/private/tmp/./" + name)
        #expect(ProjectTemplateUninstaller.matches(uuidlessRow, project: target))
        // Different project at a sibling path must NOT match.
        let other = ProjectEntry(name: "Other", path: "/private/tmp/" + name + "-other")
        #expect(ProjectTemplateUninstaller.matches(uuidlessRow, project: other) == false)
    }

    /// A registry write failure used to be logged and swallowed, so the
    /// sheet showed "uninstalled" while the sidebar row survived. It now
    /// throws so the VM lands on `.failed`.
    @Test func surfacesRegistryWriteFailure() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])
        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)
        let installer = ProjectTemplateInstaller(context: home.context)
        let entry = try installer.install(plan: plan)

        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        let uninstallPlan = try uninstaller.loadUninstallPlan(for: entry)

        // Make the registry unwritable by replacing projects.json with a
        // directory — `writeFile` then fails for reasons no retry inside
        // the uninstaller could fix.
        let registryPath = home.context.paths.projectsRegistry
        try FileManager.default.removeItem(atPath: registryPath)
        try FileManager.default.createDirectory(atPath: registryPath, withIntermediateDirectories: true)

        #expect(throws: ProjectTemplateError.self) {
            try uninstaller.uninstall(plan: uninstallPlan)
        }
        // The destructive steps still ran — the throw is about the
        // registry only, and a retry is safe.
        #expect(FileManager.default.fileExists(atPath: plan.projectDir) == false)
    }

    /// **H2 — an uninstall that removes NO row must not write the
    /// registry.** The save below passes `allowEmpty: true`, which
    /// deliberately bypasses the empty-overwrite refusal, so a removal that
    /// matched nothing wrote back whatever the load produced — and a load
    /// that produced `[]` (the registry deleted or unreadable under a
    /// concurrent uninstall) BLANKED the file while reporting a clean
    /// uninstall. Mirrors `ProjectsViewModel.removeProject`'s presence
    /// check. Removing nothing is a no-op, not a failure: everything else
    /// about the uninstall succeeded.
    @Test func uninstallWithNoMatchingRegistryRowLeavesTheRegistryAlone() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])
        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)
        let installer = ProjectTemplateInstaller(context: home.context)
        let entry = try installer.install(plan: plan)

        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        let uninstallPlan = try uninstaller.loadUninstallPlan(for: entry)

        // The registry vanishes underneath the uninstall — the shape of
        // every load that comes back empty for a reason that isn't "the
        // user has no projects".
        let registryPath = home.context.paths.projectsRegistry
        try FileManager.default.removeItem(atPath: registryPath)

        try uninstaller.uninstall(plan: uninstallPlan)

        // Nothing matched, so nothing was written: no blank registry
        // conjured where the user's file used to be.
        #expect(FileManager.default.fileExists(atPath: registryPath) == false)
        // …and the rest of the uninstall still ran.
        #expect(FileManager.default.fileExists(atPath: plan.projectDir) == false)
    }

    @Test func loadUninstallPlanRejectsProjectWithoutLock() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try FileManager.default.createDirectory(atPath: scratch + "/bare", withIntermediateDirectories: true)
        let entry = ProjectEntry(name: "Bare", path: scratch + "/bare")

        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        #expect(uninstaller.isTemplateInstalled(project: entry) == false)
        #expect(throws: ProjectTemplateError.self) {
            try uninstaller.loadUninstallPlan(for: entry)
        }
    }
}

/// End-to-end tests for manifest schemaVersion 2 (template configuration).
/// Exercises the full cycle: inspect → buildPlan → install → uninstall
/// against a synthesized schemaful bundle. Uses an isolated Keychain
/// service suffix so no leftover login-Keychain items remain after the
/// test — every secret we write is deleted on teardown.
///
/// Install-path tests inject an isolated `ServerContext.local(home:)`, so
/// the registry + `.env` mirror land in a per-instance temp home, never
/// the real `~/.hermes` — replacing the old snapshot/restore +
/// cross-suite `TestRegistryLock`. No shared state, no `.serialized`.
struct ProjectTemplateConfigInstallTests {

    /// Minimal schemaful manifest with one non-secret field + one
    /// secret field. Written into the synthesized `.scarftemplate`
    /// bundle for the round-trip tests.
    static func makeSchemafulManifest() -> ProjectTemplateManifest {
        ProjectTemplateServiceTests.sampleManifest(
            id: "tester/configured",
            configSchema: TemplateConfigSchema(
                fields: [
                    .init(key: "site_url", type: .string, label: "Site URL",
                          description: "where to ping", required: true, placeholder: nil,
                          defaultValue: nil, options: nil, minLength: nil,
                          maxLength: nil, pattern: nil, minNumber: nil,
                          maxNumber: nil, step: nil, itemType: nil,
                          minItems: nil, maxItems: nil),
                    .init(key: "api_token", type: .secret, label: "API Token",
                          description: nil, required: true, placeholder: nil,
                          defaultValue: nil, options: nil, minLength: nil,
                          maxLength: nil, pattern: nil, minNumber: nil,
                          maxNumber: nil, step: nil, itemType: nil,
                          minItems: nil, maxItems: nil),
                ],
                modelRecommendation: nil
            )
        )
    }

    @Test func inspectAcceptsSchemaV2Bundle() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let manifest = Self.makeSchemafulManifest()
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestString = String(data: manifestData, encoding: .utf8)!

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "template.json": manifestString,
            "README.md": "# r",
            "AGENTS.md": "# a",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ], includeManifest: false)

        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }

        #expect(inspection.manifest.schemaVersion == 2)
        #expect(inspection.manifest.config?.fields.count == 2)
    }

    @Test func buildPlanSurfacesSchemaAndQueuesConfigFiles() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let manifest = Self.makeSchemafulManifest()
        let manifestJSON = String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "template.json": manifestJSON,
            "README.md": "# r", "AGENTS.md": "# a",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ], includeManifest: false)

        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: scratch)

        // Schema carried through the plan.
        #expect(plan.configSchema?.fields.count == 2)
        #expect(plan.manifestCachePath?.hasSuffix("/.scarf/manifest.json") == true)
        // config.json + manifest.json entries in projectFiles.
        let destinations = plan.projectFiles.map(\.destinationPath)
        #expect(destinations.contains { $0.hasSuffix("/.scarf/config.json") })
        #expect(destinations.contains { $0.hasSuffix("/.scarf/manifest.json") })
    }

    @Test func verifyClaimsRejectsConfigCountMismatch() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        // Hand-build a manifest whose contents.config claim (2) doesn't
        // match its schema.fields.count (1) — validator should reject.
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "only", type: .string, label: "Only",
                      description: nil, required: false, placeholder: nil,
                      defaultValue: nil, options: nil, minLength: nil,
                      maxLength: nil, pattern: nil, minNumber: nil,
                      maxNumber: nil, step: nil, itemType: nil,
                      minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        let bogus = ProjectTemplateServiceTests.sampleManifest(
            id: "tester/mismatch",
            configFieldCount: 2,                // claim lies
            configSchema: schema                // reality is 1
        )
        let manifestJSON = String(data: try JSONEncoder().encode(bogus), encoding: .utf8)!
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "template.json": manifestJSON,
            "README.md": "# r", "AGENTS.md": "# a",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ], includeManifest: false)

        let service = ProjectTemplateService(context: home.context)
        #expect(throws: ProjectTemplateError.self) {
            try service.inspect(zipPath: bundle)
        }
    }

    @Test func installWritesConfigJsonAndManifestCache() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let manifest = Self.makeSchemafulManifest()
        let manifestJSON = String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "template.json": manifestJSON,
            "README.md": "# r", "AGENTS.md": "# a",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ], includeManifest: false)

        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        var plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        // Isolated Keychain service suffix so the test doesn't touch
        // the real login Keychain.
        let suffix = "tests-" + UUID().uuidString
        let keychain = ProjectConfigKeychain(testServiceSuffix: suffix)
        let configService = ProjectConfigService(keychain: keychain)

        // Store secret via the service (VM would do this before install).
        let project = ProjectEntry(name: manifest.name, path: plan.projectDir)
        let secretRef = try configService.storeSecret(
            templateSlug: manifest.slug,
            fieldKey: "api_token",
            project: project,
            secret: Data("sk-top-secret".utf8)
        )
        plan.configValues = [
            "site_url": .string("https://example.com"),
            "api_token": secretRef
        ]

        let installer = ProjectTemplateInstaller(context: home.context)
        _ = try installer.install(plan: plan)

        // config.json landed with non-secret values + keychain ref.
        let configPath = plan.projectDir + "/.scarf/config.json"
        #expect(FileManager.default.fileExists(atPath: configPath))
        let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let configFile = try JSONDecoder().decode(ProjectConfigFile.self, from: configData)
        #expect(configFile.values["site_url"] == .string("https://example.com"))
        if case .keychainRef(let uri) = configFile.values["api_token"] {
            #expect(uri.hasPrefix("keychain://"))
        } else {
            Issue.record("api_token should have been stored as keychainRef")
        }

        // manifest.json cache landed for the post-install editor.
        let cachePath = plan.projectDir + "/.scarf/manifest.json"
        #expect(FileManager.default.fileExists(atPath: cachePath))
        let cachedManifest = try JSONDecoder().decode(
            ProjectTemplateManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: cachePath))
        )
        #expect(cachedManifest.config?.fields.count == 2)

        // Lock file records the keychain item so uninstall can clean up.
        let lockPath = plan.projectDir + "/.scarf/template.lock.json"
        let lockData = try Data(contentsOf: URL(fileURLWithPath: lockPath))
        let lock = try JSONDecoder().decode(TemplateLock.self, from: lockData)
        #expect(lock.configKeychainItems?.count == 1)
        #expect(lock.configFields == ["site_url", "api_token"])

        // Clean up the real Keychain entry we created outside the
        // test-suffixed namespace (storeSecret uses real service name
        // because the test's config-service wasn't isolated for this
        // call's secret; we manually delete via our test keychain).
        if let ref = TemplateKeychainRef.parse(
            (configFile.values["api_token"].flatMap { v -> String? in
                if case .keychainRef(let u) = v { return u } else { return nil }
            }) ?? ""
        ) {
            try? ProjectConfigKeychain().delete(ref: ref)
        }
    }

    @Test func uninstallDeletesKeychainItemsViaLock() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let manifest = Self.makeSchemafulManifest()
        let manifestJSON = String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "template.json": manifestJSON,
            "README.md": "# r", "AGENTS.md": "# a",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ], includeManifest: false)

        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        var plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        // Real Keychain — we store, install, then uninstall and verify
        // the item is gone. Uses the real service name (no test suffix)
        // because the installer + uninstaller go through their own
        // ProjectConfigKeychain instances without a suffix.
        let project = ProjectEntry(name: manifest.name, path: plan.projectDir)
        let configService = ProjectConfigService()
        let secretRef = try configService.storeSecret(
            templateSlug: manifest.slug,
            fieldKey: "api_token",
            project: project,
            secret: Data("delete-me".utf8)
        )
        plan.configValues = [
            "site_url": .string("https://example.com"),
            "api_token": secretRef
        ]

        let installer = ProjectTemplateInstaller(context: home.context)
        let entry = try installer.install(plan: plan)

        // Verify the secret is there before uninstall.
        guard case .keychainRef(let uri) = secretRef,
              let ref = TemplateKeychainRef.parse(uri) else {
            Issue.record("expected secret to be a keychainRef")
            return
        }
        #expect((try ProjectConfigKeychain().get(ref: ref)) == Data("delete-me".utf8))

        // Uninstall → secret should be gone.
        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        let uninstallPlan = try uninstaller.loadUninstallPlan(for: entry)
        try uninstaller.uninstall(plan: uninstallPlan)

        #expect((try ProjectConfigKeychain().get(ref: ref)) == nil)
    }
}

/// State-machine tests for `TemplateInstallerViewModel`. The install
/// flow's configure step is driven entirely through the VM — the view
/// transitions `.awaitingParentDirectory → .awaitingConfig → .planned`
/// based on `submitConfig(values:)` / `cancelConfig()` calls. If those
/// transitions break, the user lands on the wrong sheet stage (or no
/// sheet at all, as in the v1.1.0 regression where the config sheet's
/// internal `dismiss()` tore down the outer install sheet before
/// submitConfig had a chance to fire).
@Suite(.serialized) @MainActor struct TemplateInstallerViewModelTests {

    @Test func submitConfigStashesValuesAndTransitionsToPlanned() throws {
        let vm = TemplateInstallerViewModel(context: .local)
        // Seed the VM with an awaiting-config plan (schema-ful).
        let plan = try Self.makePlanWithConfigSchema()
        vm.plan = plan
        vm.stage = .awaitingConfig

        let values: [String: TemplateConfigValue] = [
            "site_url": .string("https://example.com")
        ]
        vm.submitConfig(values: values)

        // Stage must advance past the configure step, values must land
        // on the plan where install() will pick them up.
        if case .planned = vm.stage {
            // ok
        } else {
            Issue.record("expected .planned, got \(vm.stage)")
        }
        #expect(vm.plan?.configValues["site_url"] == .string("https://example.com"))
    }

    @Test func cancelConfigReturnsToAwaitingParentDirectory() throws {
        let vm = TemplateInstallerViewModel(context: .local)
        vm.plan = try Self.makePlanWithConfigSchema()
        vm.stage = .awaitingConfig

        vm.cancelConfig()

        if case .awaitingParentDirectory = vm.stage {
            // ok — user can re-pick the parent dir or fully cancel
        } else {
            Issue.record("expected .awaitingParentDirectory, got \(vm.stage)")
        }
        // Plan is preserved so re-entering the configure step doesn't
        // re-run buildPlan.
        #expect(vm.plan != nil)
    }

    @Test func submitConfigNoOpWhenPlanIsNil() {
        let vm = TemplateInstallerViewModel(context: .local)
        vm.plan = nil
        vm.stage = .awaitingConfig
        vm.submitConfig(values: ["k": .string("v")])
        // With no plan, the call should be silent — no crash, stage
        // stays where it was. (Defensive guard in submitConfig.)
        if case .awaitingConfig = vm.stage {
            // ok
        } else {
            Issue.record("expected stage to remain .awaitingConfig when plan is nil; got \(vm.stage)")
        }
    }

    // MARK: - Fixture

    /// Build a `TemplateInstallPlan` carrying a single-field config
    /// schema. Exists as a local helper rather than a shared one
    /// because no other suite needs it.
    nonisolated static func makePlanWithConfigSchema() throws -> TemplateInstallPlan {
        let schema = TemplateConfigSchema(
            fields: [
                .init(key: "site_url", type: .string, label: "Site URL",
                      description: nil, required: true, placeholder: nil,
                      defaultValue: nil, options: nil, minLength: nil,
                      maxLength: nil, pattern: nil, minNumber: nil,
                      maxNumber: nil, step: nil, itemType: nil,
                      minItems: nil, maxItems: nil)
            ],
            modelRecommendation: nil
        )
        let manifest = ProjectTemplateServiceTests.sampleManifest(
            id: "tester/vm-transitions",
            configSchema: schema
        )
        let tmp = try ProjectTemplateServiceTests.makeTempDir()
        // Not a real bundle dir — we never unzip or install from this
        // plan, we only test state transitions that don't touch disk.
        return TemplateInstallPlan(
            manifest: manifest,
            unpackedDir: tmp,
            projectDir: tmp + "/project",
            projectFiles: [],
            skillsNamespaceDir: nil,
            skillsFiles: [],
            cronJobs: [],
            memoryAppendix: nil,
            memoryPath: ServerContext.local.paths.memoryMD,
            projectRegistryName: "VM Transitions",
            configSchema: schema,
            configValues: [:],
            manifestCachePath: tmp + "/project/.scarf/manifest.json"
        )
    }
}

/// Validates every `.scarftemplate` shipped under `templates/<author>/<name>/`
/// in the repo. A template whose manifest, `contents` claim, or file set is
/// out of sync will fail here — so shipped templates can't silently rot.
@Suite struct ProjectTemplateExampleTemplateTests {

    @Test func siteStatusCheckerParsesAndPlans() throws {
        let bundle = try Self.locateExample(author: "awizemann", name: "site-status-checker")

        let service = ProjectTemplateService(context: .local)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }

        #expect(inspection.manifest.id == "awizemann/site-status-checker")
        #expect(inspection.manifest.schemaVersion == 2)  // config-enabled
        #expect(inspection.manifest.contents.dashboard)
        #expect(inspection.manifest.contents.agentsMd)
        #expect(inspection.manifest.contents.cron == 1)
        #expect(inspection.manifest.contents.config == 2)
        #expect(inspection.cronJobs.count == 1)
        #expect(inspection.cronJobs.first?.name == "Check site status")
        #expect(inspection.cronJobs.first?.schedule == "0 9 * * *")

        // Schema assertions — the two fields we declared should survive
        // unzip + parse + validate with their constraints intact.
        let schema = try #require(inspection.manifest.config)
        #expect(schema.fields.count == 2)
        let sitesField = try #require(schema.field(for: "sites"))
        #expect(sitesField.type == .list)
        #expect(sitesField.itemType == "string")
        #expect(sitesField.required == true)
        #expect(sitesField.minItems == 1)
        #expect(sitesField.maxItems == 25)
        let timeoutField = try #require(schema.field(for: "timeout_seconds"))
        #expect(timeoutField.type == .number)
        #expect(timeoutField.minNumber == 1)
        #expect(timeoutField.maxNumber == 60)
        #expect(schema.modelRecommendation?.preferred == "claude-haiku-4")

        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: scratch)
        #expect(plan.projectDir.hasSuffix("awizemann-site-status-checker"))
        #expect(plan.skillsFiles.isEmpty)
        #expect(plan.memoryAppendix == nil)
        #expect(plan.cronJobs.count == 1)
        #expect(plan.configSchema?.fields.count == 2)
        #expect(plan.manifestCachePath?.hasSuffix("/.scarf/manifest.json") == true)
        // Plan queues both config.json + manifest.json in projectFiles.
        let destinations = plan.projectFiles.map(\.destinationPath)
        #expect(destinations.contains { $0.hasSuffix("/.scarf/config.json") })
        #expect(destinations.contains { $0.hasSuffix("/.scarf/manifest.json") })
        // Cron job name gets prefixed with the template tag so users can
        // find + remove it later.
        #expect(plan.cronJobs.first?.name == "[tmpl:awizemann/site-status-checker] Check site status")

        // Verify the bundled dashboard.json decodes against the same
        // `ProjectDashboard` struct the app uses at runtime — catches drift
        // between template-author conventions and the actual renderer
        // (e.g. a widget type that ProjectsView doesn't know, a
        // non-number value for a stat, etc.).
        let dashboardPath = inspection.unpackedDir + "/dashboard.json"
        let dashboardData = try Data(contentsOf: URL(fileURLWithPath: dashboardPath))
        let dashboard = try JSONDecoder().decode(ProjectDashboard.self, from: dashboardData)
        #expect(dashboard.title == "Site Status")
        // Four sections: Current Status (stats), Watched Sites (list),
        // Live Site Preview (webview — drives the Site tab), How to Use (text).
        #expect(dashboard.sections.count == 4)

        // First section should have three stat widgets that the cron job
        // updates by value. Assert titles + types so the AGENTS.md contract
        // can't drift from the actual dashboard.
        let statsSection = dashboard.sections[0]
        #expect(statsSection.title == "Current Status")
        let statTitles = statsSection.widgets.filter { $0.type == "stat" }.map(\.title)
        #expect(statTitles.contains("Sites Up"))
        #expect(statTitles.contains("Sites Down"))
        #expect(statTitles.contains("Last Checked"))

        // Live Site Preview section must contain exactly one webview
        // widget. The presence of any webview widget is what makes Scarf
        // expose the Site tab next to Dashboard, so losing this section
        // would silently drop a user-visible feature. The cron job
        // rewrites this widget's `url` to the first configured site on
        // every run — AGENTS.md documents the contract.
        let previewSection = dashboard.sections[2]
        #expect(previewSection.title == "Live Site Preview")
        let webviews = previewSection.widgets.filter { $0.type == "webview" }
        #expect(webviews.count == 1)
        #expect(webviews.first?.title == "First Watched Site")
        #expect((webviews.first?.url ?? "").isEmpty == false)

        // Cron prompt references .scarf/config.json (where values.sites
        // + values.timeout_seconds live), the dashboard/log it writes,
        // and the {{PROJECT_DIR}} placeholder the installer resolves
        // at install time. If either stops being referenced, the cron
        // wouldn't know which data to read or where to write results.
        let cronPrompt = inspection.cronJobs.first?.prompt ?? ""
        #expect(cronPrompt.contains("config.json"))
        #expect(cronPrompt.contains("values.sites"))
        #expect(cronPrompt.contains("dashboard.json"))
        #expect(cronPrompt.contains("status-log.md"))
        // {{PROJECT_DIR}} must remain UNRESOLVED in the bundle — the
        // installer substitutes it at install time. If someone
        // accidentally baked an absolute path into the template, that
        // path would follow every install to every user's machine.
        #expect(cronPrompt.contains("{{PROJECT_DIR}}"))
    }

    /// Exercises the second shipped template — `awizemann/template-author` —
    /// which is a skill-only bundle (no config, no cron, no memory). The
    /// shape is deliberately different from site-status-checker so a
    /// regression in the installer's "no config, no cron" path can't hide
    /// behind the richer example template. Also asserts the skill lands
    /// under the expected namespaced path so Hermes's recursive skill
    /// discovery finds it.
    @Test func templateAuthorParsesAndPlans() throws {
        let bundle = try Self.locateExample(author: "awizemann", name: "template-author")

        let service = ProjectTemplateService(context: .local)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }

        // Manifest shape: schemaVersion 2 (contains `skills` claim, which
        // wasn't part of v1), no config, no cron, one skill.
        #expect(inspection.manifest.id == "awizemann/template-author")
        #expect(inspection.manifest.name == "Scarf Template Author")
        #expect(inspection.manifest.version == "1.0.0")
        #expect(inspection.manifest.schemaVersion == 2)
        #expect(inspection.manifest.contents.dashboard)
        #expect(inspection.manifest.contents.agentsMd)
        #expect(inspection.manifest.contents.cron == nil)
        #expect(inspection.manifest.contents.config == nil)
        #expect(inspection.manifest.contents.memory == nil)
        #expect(inspection.manifest.contents.skills == ["scarf-template-author"])
        #expect(inspection.manifest.config == nil)
        #expect(inspection.cronJobs.isEmpty)

        // Plan: empty config, empty cron, but one skill queued for install
        // under the template's namespaced dir. The namespace path has to
        // match what the uninstaller wipes — `skills/templates/<slug>` —
        // or uninstall leaves orphan skill files.
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: scratch)
        #expect(plan.projectDir.hasSuffix("awizemann-template-author"))
        #expect(plan.cronJobs.isEmpty)
        #expect(plan.configSchema == nil)
        #expect(plan.configValues.isEmpty)
        #expect(plan.memoryAppendix == nil)

        // The skill should land at
        // `~/.hermes/skills/templates/awizemann-template-author/scarf-template-author/SKILL.md`
        // — namespace dir + skill folder + SKILL.md. Anything else
        // breaks Hermes's recursive discovery or the uninstaller's
        // `rm -rf` on the namespace dir.
        let namespaceDir = try #require(plan.skillsNamespaceDir)
        #expect(namespaceDir.hasSuffix("/skills/templates/awizemann-template-author"))
        #expect(plan.skillsFiles.count == 1)
        let skillDest = try #require(plan.skillsFiles.first?.destinationPath)
        #expect(skillDest.hasSuffix("/scarf-template-author/SKILL.md"))
        #expect(skillDest.hasPrefix(namespaceDir))

        // No-config templates deliberately skip the manifest cache —
        // the dashboard's Configuration button only shows up when
        // `.scarf/manifest.json` exists, so a skill-only template
        // like this one correctly doesn't surface that button.
        // (See ProjectTemplateService.buildPlan lines 198–227.)
        #expect(plan.manifestCachePath == nil)
    }

    /// Resolve the example bundle path robustly. Unit-test working dirs
    /// differ between `xcodebuild test` (project root) and an Xcode IDE
    /// run (build-output dir), so we walk up from this source file until
    /// we find the repo root. Templates live at
    /// `templates/<author>/<name>/<name>.scarftemplate` per the catalog
    /// layout (see `templates/README.md`).
    nonisolated private static func locateExample(author: String, name: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("templates/\(author)/\(name)/\(name).scarftemplate")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            dir = dir.deletingLastPathComponent()
        }
        throw ProjectTemplateError.requiredFileMissing("templates/\(author)/\(name)/\(name).scarftemplate")
    }
}

/// Round-trips a real project structure through the exporter and back into
/// the service. Does NOT run the installer (which would write to
/// ~/.hermes) — it verifies the produced bundle is valid, and stops there.
@Suite struct ProjectTemplateExportTests {

    @Test func roundTripsMinimalProject() throws {
        let fakeProject = NSTemporaryDirectory() + "scarf-project-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: fakeProject + "/.scarf", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: fakeProject) }

        try ProjectTemplateServiceTests.sampleDashboardJSON
            .data(using: .utf8)!
            .write(to: URL(fileURLWithPath: fakeProject + "/.scarf/dashboard.json"))
        try "# Test project".data(using: .utf8)!
            .write(to: URL(fileURLWithPath: fakeProject + "/README.md"))
        try "# Agent notes".data(using: .utf8)!
            .write(to: URL(fileURLWithPath: fakeProject + "/AGENTS.md"))

        let entry = ProjectEntry(name: "Round Trip", path: fakeProject)
        let exporter = ProjectTemplateExporter(context: .local)
        let outputDir = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: outputDir) }
        let outputPath = outputDir + "/rt.scarftemplate"

        let inputs = ProjectTemplateExporter.ExportInputs(
            project: entry,
            templateId: "tester/round-trip",
            templateName: "Round Trip",
            templateVersion: "0.1.0",
            description: "round-trip test",
            authorName: "Tester",
            authorUrl: nil,
            category: nil,
            tags: [],
            includeSkillIds: [],
            includeCronJobIds: [],
            memoryAppendix: nil
        )

        try exporter.export(inputs: inputs, outputZipPath: outputPath)
        #expect(FileManager.default.fileExists(atPath: outputPath))

        let service = ProjectTemplateService(context: .local)
        let inspection = try service.inspect(zipPath: outputPath)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        #expect(inspection.manifest.id == "tester/round-trip")
        #expect(inspection.files.contains("dashboard.json"))
        #expect(inspection.files.contains("README.md"))
        #expect(inspection.files.contains("AGENTS.md"))
    }
}

// MARK: - Trust-boundary tests (S1)

/// `template.lock.json` is written into the project dir, which the agent
/// can rewrite at will — so these tests come at the uninstaller as an
/// ATTACKER, not as the installer's happy path: a lock that names files
/// outside the project, a skills namespace dir outside the templates
/// root, a symlink planted inside that namespace, and a `keychain://`
/// uri belonging to somebody else. Every one of them must be refused,
/// surfaced in the plan, and left untouched on disk.
struct ProjectTemplateUninstallTrustBoundaryTests {

    /// Install a minimal template into a fresh temp home and hand back
    /// everything a hostile-lock test needs.
    private struct Fixture {
        let home: TempHermesHome
        let scratch: String
        let entry: ProjectEntry
        let projectDir: String
        let slug: String
        var lockPath: String { projectDir + "/.scarf/template.lock.json" }

        func cleanup() {
            home.cleanup()
            try? FileManager.default.removeItem(atPath: scratch)
        }

        /// Rewrite the lock the way a compromised agent would: read the
        /// real one, mutate a field, write it back.
        func rewriteLock(_ mutate: (inout [String: Any]) -> Void) throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: lockPath))
            var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            mutate(&json)
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try out.write(to: URL(fileURLWithPath: lockPath))
        }
    }

    private static func makeFixture() throws -> Fixture {
        let home = try TempHermesHome()
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])
        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)
        let entry = try ProjectTemplateInstaller(context: home.context).install(plan: plan)
        return Fixture(
            home: home,
            scratch: scratch,
            entry: entry,
            projectDir: plan.projectDir,
            slug: inspection.manifest.slug
        )
    }

    // MARK: H1 — project files

    @Test func lockPathOutsideTheProjectIsRefusedAndSurvives() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        let victim = fixture.scratch + "/precious.txt"
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: victim))
        try fixture.rewriteLock { json in
            var files = json["project_files"] as? [String] ?? []
            files.append(victim)
            json["project_files"] = files
        }

        let uninstaller = ProjectTemplateUninstaller(context: fixture.home.context)
        let plan = try uninstaller.loadUninstallPlan(for: fixture.entry)
        #expect(plan.refusedEntries.contains(victim))
        #expect(plan.projectFilesToRemove.contains(victim) == false)

        try uninstaller.uninstall(plan: plan)
        #expect(FileManager.default.fileExists(atPath: victim))
    }

    @Test func lockPathEscapingViaDotDotIsRefused() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        let victim = fixture.scratch + "/escape.txt"
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: victim))
        let traversal = fixture.projectDir + "/../../escape.txt"
        try fixture.rewriteLock { json in
            json["project_files"] = [traversal]
        }

        let uninstaller = ProjectTemplateUninstaller(context: fixture.home.context)
        let plan = try uninstaller.loadUninstallPlan(for: fixture.entry)
        #expect(plan.refusedEntries.contains(traversal))
        try uninstaller.uninstall(plan: plan)
        #expect(FileManager.default.fileExists(atPath: victim))
    }

    /// The nastiest local shape: a lock-tracked path that LOOKS contained
    /// (`<project>/data/secrets.txt`) but reaches outside because `data`
    /// is a symlink. Lexical containment alone passes it; the physical
    /// re-derivation is what refuses it.
    @Test func lockPathThroughSymlinkedDirectoryIsRefused() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        let outsideDir = fixture.scratch + "/outside"
        try FileManager.default.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
        let victim = outsideDir + "/secrets.txt"
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: victim))
        let link = fixture.projectDir + "/data"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outsideDir)

        let smuggled = link + "/secrets.txt"
        try fixture.rewriteLock { json in
            json["project_files"] = [smuggled]
        }

        let uninstaller = ProjectTemplateUninstaller(context: fixture.home.context)
        let plan = try uninstaller.loadUninstallPlan(for: fixture.entry)
        #expect(plan.refusedEntries.contains(smuggled))
        #expect(plan.projectFilesToRemove.contains(smuggled) == false)

        try uninstaller.uninstall(plan: plan)
        #expect(FileManager.default.fileExists(atPath: victim))
    }

    // MARK: H1 — skills namespace dir

    @Test func skillsNamespaceDirOutsideTemplatesRootIsRefused() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        let victimDir = fixture.scratch + "/not-a-skill"
        try FileManager.default.createDirectory(atPath: victimDir, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: victimDir + "/file.txt"))
        try fixture.rewriteLock { json in
            json["skills_namespace_dir"] = victimDir
        }

        let uninstaller = ProjectTemplateUninstaller(context: fixture.home.context)
        let plan = try uninstaller.loadUninstallPlan(for: fixture.entry)
        #expect(plan.skillsNamespaceDir == nil)
        #expect(plan.refusedEntries.contains(victimDir))

        try uninstaller.uninstall(plan: plan)
        #expect(FileManager.default.fileExists(atPath: victimDir + "/file.txt"))
    }

    /// A legitimate namespace dir that contains a symlink to somewhere
    /// else. The recursive delete must unlink the link and stop — not
    /// walk through it and delete the linked tree's contents.
    @Test func recursiveSkillsRemovalUnlinksSymlinksInsteadOfFollowingThem() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        let namespaceDir = fixture.home.context.paths.skillsDir + "/templates/" + fixture.slug
        try FileManager.default.createDirectory(atPath: namespaceDir, withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: URL(fileURLWithPath: namespaceDir + "/SKILL.md"))

        let outsideDir = fixture.scratch + "/outside"
        try FileManager.default.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
        let victim = outsideDir + "/precious.txt"
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: victim))
        try FileManager.default.createSymbolicLink(
            atPath: namespaceDir + "/linked",
            withDestinationPath: outsideDir
        )

        try fixture.rewriteLock { json in
            json["skills_namespace_dir"] = namespaceDir
        }

        let uninstaller = ProjectTemplateUninstaller(context: fixture.home.context)
        let plan = try uninstaller.loadUninstallPlan(for: fixture.entry)
        #expect(plan.skillsNamespaceDir == namespaceDir)
        try uninstaller.uninstall(plan: plan)

        // The namespace dir (and its symlink) are gone…
        #expect(FileManager.default.fileExists(atPath: namespaceDir) == false)
        // …but nothing on the other side of the link was touched.
        #expect(FileManager.default.fileExists(atPath: victim))
        #expect(FileManager.default.fileExists(atPath: outsideDir))
    }

    // MARK: H3 — keychain items

    @Test func foreignKeychainRefInLockIsNotDeleted() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }

        // A secret belonging to a DIFFERENT project, stored for real.
        let otherProject = ProjectEntry(name: "other", path: fixture.scratch + "/other-project")
        let configService = ProjectConfigService()
        let stored = try configService.storeSecret(
            templateSlug: "victim-template",
            fieldKey: "api_token",
            project: otherProject,
            secret: Data("not-yours".utf8)
        )
        guard case .keychainRef(let foreignURI) = stored,
              let foreignRef = TemplateKeychainRef.parse(foreignURI) else {
            Issue.record("expected a keychain ref")
            return
        }
        defer { try? ProjectConfigKeychain().delete(ref: foreignRef) }

        try fixture.rewriteLock { json in
            json["config_keychain_items"] = [foreignURI, "keychain://com.apple.ssh/id_rsa"]
        }

        let uninstaller = ProjectTemplateUninstaller(context: fixture.home.context)
        let plan = try uninstaller.loadUninstallPlan(for: fixture.entry)
        #expect(plan.keychainItemsToDelete.isEmpty)
        #expect(plan.refusedEntries.contains(foreignURI))
        #expect(plan.refusedEntries.contains("keychain://com.apple.ssh/id_rsa"))

        try uninstaller.uninstall(plan: plan)
        #expect((try ProjectConfigKeychain().get(ref: foreignRef)) == Data("not-yours".utf8))
    }

    // MARK: PathGuard unit surface

    @Test func pathGuardAdmitsContainedPathsOnly() throws {
        let root = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        let guardian = ProjectTemplateUninstaller.PathGuard(isRemote: false)

        #expect(guardian.admits(root + "/sub/file.txt", under: root))
        #expect(guardian.admits(root + "/gone.txt", under: root)) // absent is fine
        #expect(guardian.admits(root, under: root) == false)      // root itself never
        #expect(guardian.admits(root + "/..", under: root) == false)
        #expect(guardian.admits(root + "/sub/../../x", under: root) == false)
        #expect(guardian.admits("relative/path", under: root) == false)
        #expect(guardian.admits("/etc/passwd", under: root) == false)
        // A sibling whose path merely SHARES the root's prefix.
        #expect(guardian.admits(root + "-evil/file.txt", under: root) == false)
        // A root of "/" would make the check vacuous.
        #expect(guardian.admits("/Users/someone/Documents", under: "/") == false)
    }

    @Test func pathGuardRefusesSymlinkedComponentsAndDetectsLinks() throws {
        let root = try ProjectTemplateServiceTests.makeTempDir()
        let outside = try ProjectTemplateServiceTests.makeTempDir()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }
        try FileManager.default.createSymbolicLink(
            atPath: root + "/link",
            withDestinationPath: outside
        )
        let guardian = ProjectTemplateUninstaller.PathGuard(isRemote: false)

        // Through the link: refused (the parent resolves elsewhere).
        #expect(guardian.admits(root + "/link/file.txt", under: root) == false)
        // The link ITSELF is admitted — we want to be able to unlink it —
        // and is reported as a symlink so the walk never descends.
        #expect(guardian.admits(root + "/link", under: root))
        #expect(guardian.isSymlink(root + "/link"))
        #expect(guardian.isSymlink(root) == false)
    }
}

/// H2: `keychain://` refs are namespace-restricted and bound to the
/// project that minted them, so one project's agent can't name another
/// project's item and have Scarf resolve (or delete) it.
struct TemplateKeychainRefTrustTests {

    @Test func parseRejectsRefsOutsideScarfsNamespace() {
        #expect(TemplateKeychainRef.parse("keychain://com.apple.ssh/id_rsa") == nil)
        #expect(TemplateKeychainRef.parse("keychain://com.scarf.template./k:0000abcd") == nil)
        #expect(TemplateKeychainRef.parse("keychain://com.scarf.templateX/k:0000abcd") == nil)
        // Well-formed account is required too — no free-form accounts.
        #expect(TemplateKeychainRef.parse("keychain://com.scarf.template.t/anything") == nil)
        #expect(TemplateKeychainRef.parse("keychain://com.scarf.template.t/:0000abcd") == nil)
        #expect(TemplateKeychainRef.parse("keychain://com.scarf.template.t/k:0000ABCD") == nil)
        #expect(TemplateKeychainRef.parse("keychain://com.scarf.template.t/k:zzzz") == nil)
    }

    @Test func parseAcceptsWhatMakeMints() {
        let ref = TemplateKeychainRef.make(
            templateSlug: "site-status",
            fieldKey: "api_token",
            projectPath: "/Users/a/proj"
        )
        #expect(TemplateKeychainRef.parse(ref.uri) == ref)
    }

    @Test func refsAreBoundToTheProjectThatMintedThem() {
        let mine = TemplateKeychainRef.make(
            templateSlug: "t", fieldKey: "k", projectPath: "/Users/a/proj-a"
        )
        #expect(mine.belongs(toProjectPath: "/Users/a/proj-a"))
        #expect(mine.belongs(toProjectPath: "/Users/a/proj-b") == false)
    }

    @Test func bindingToleratesSymlinkedSpellingsOfTheSameDir() {
        // A registry row can hold /tmp/x for a project installed as
        // /private/tmp/x — same directory, so the binding must hold.
        let ref = TemplateKeychainRef.make(
            templateSlug: "t", fieldKey: "k", projectPath: "/private/tmp"
        )
        #expect(ref.belongs(toProjectPath: "/private/tmp"))
        #expect(ref.belongs(toProjectPath: "/tmp"))
    }

    @Test func resolveSecretRefusesAnotherProjectsRef() throws {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let owner = ProjectEntry(name: "owner", path: scratch + "/owner")
        let attacker = ProjectEntry(name: "attacker", path: scratch + "/attacker")
        let service = ProjectConfigService()
        let stored = try service.storeSecret(
            templateSlug: "t", fieldKey: "k", project: owner, secret: Data("s3cret".utf8)
        )
        defer {
            if case .keychainRef(let uri) = stored, let ref = TemplateKeychainRef.parse(uri) {
                try? ProjectConfigKeychain().delete(ref: ref)
            }
        }

        // The owner can read it…
        #expect(try service.resolveSecret(ref: stored, for: owner) == Data("s3cret".utf8))
        // …and a project whose config.json merely NAMES the ref cannot.
        #expect(try service.resolveSecret(ref: stored, for: attacker) == nil)
    }
}

/// The env-mirror block markers carry the slug verbatim, and the manifest
/// that supplies it is agent-writable — so a slug with a newline in it
/// could forge markers and inject env vars outside any managed block.
struct KeychainEnvMirrorSlugGuardTests {

    @Test func refusesToMirrorAMalformedSlug() throws {
        let dir = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let envPath = dir + "/.env"
        try Data("EXISTING=1\n".utf8).write(to: URL(fileURLWithPath: envPath))

        let mirror = KeychainEnvMirror(context: .local)
        try mirror.mirror(
            slug: "evil\n# scarf-secrets:end evil\nPATH=/tmp/evil",
            entries: [(key: "SCARF_EVIL_K", value: "v")],
            envPath: envPath
        )
        let after = try String(contentsOf: URL(fileURLWithPath: envPath), encoding: .utf8)
        #expect(after == "EXISTING=1\n")

        // A well-formed slug still mirrors.
        try mirror.mirror(
            slug: "good-slug",
            entries: [(key: "SCARF_GOOD_SLUG_K", value: "v")],
            envPath: envPath
        )
        let ok = try String(contentsOf: URL(fileURLWithPath: envPath), encoding: .utf8)
        #expect(ok.contains("# scarf-secrets:begin good-slug"))
    }
}
