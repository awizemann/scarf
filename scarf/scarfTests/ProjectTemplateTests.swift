import Testing
import Foundation
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
                config: configFieldCount ?? configSchema?.fields.count
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
@Suite(.serialized) struct ProjectTemplateInstallerTests {

    @Test func installsMinimalBundleAndWritesLockFile() throws {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: .local)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        let registryBefore = Self.snapshotRegistry()
        defer { Self.restoreRegistry(registryBefore) }

        let installer = ProjectTemplateInstaller(context: .local)
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
    }

    @Test func preflightRejectsExistingProjectDir() throws {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: .local)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        // Simulate a concurrent creation between buildPlan and install.
        try FileManager.default.createDirectory(atPath: plan.projectDir, withIntermediateDirectories: true)

        let installer = ProjectTemplateInstaller(context: .local)
        #expect(throws: ProjectTemplateError.self) {
            try installer.install(plan: plan)
        }
    }

    @Test func buildPlanRefusesDuplicateProjectDir() throws {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: .local)
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

    // MARK: - Registry snapshot helpers

    /// Read the raw bytes of the current projects.json so we can restore
    /// it byte-for-byte after the test. `nil` means the file didn't exist
    /// — restore by deleting whatever got created.
    nonisolated private static func snapshotRegistry() -> Data? {
        let path = ServerContext.local.paths.projectsRegistry
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    nonisolated private static func restoreRegistry(_ snapshot: Data?) {
        let path = ServerContext.local.paths.projectsRegistry
        if let snapshot {
            try? snapshot.write(to: URL(fileURLWithPath: path))
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// End-to-end install + uninstall test: install a minimal bundle, uninstall
/// it, verify every tracked file is gone, the registry is restored to its
/// pre-install state, and user-added files (if any) are preserved. Scoped
/// to bundles with no skills/cron/memory so no global state is touched.
@Suite(.serialized) struct ProjectTemplateUninstallerTests {

    @Test func roundTripsInstallThenUninstall() throws {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: .local)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        let registryBefore = Self.snapshotRegistry()
        defer { Self.restoreRegistry(registryBefore) }

        let installer = ProjectTemplateInstaller(context: .local)
        let entry = try installer.install(plan: plan)
        #expect(FileManager.default.fileExists(atPath: plan.projectDir))

        let uninstaller = ProjectTemplateUninstaller(context: .local)
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
        // Registry entry gone — length matches pre-install snapshot.
        let service2 = ProjectDashboardService(context: .local)
        let registryAfter = service2.loadRegistry()
        #expect(registryAfter.projects.contains(where: { $0.path == entry.path }) == false)
    }

    @Test func preservesUserAddedFiles() throws {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let parentDir = scratch + "/parent"
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "README.md": "# Minimal",
            "AGENTS.md": "# Agent notes",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ])

        let service = ProjectTemplateService(context: .local)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        let plan = try service.buildPlan(inspection: inspection, parentDir: parentDir)

        let registryBefore = Self.snapshotRegistry()
        defer { Self.restoreRegistry(registryBefore) }

        let installer = ProjectTemplateInstaller(context: .local)
        let entry = try installer.install(plan: plan)

        // Simulate the user / agent creating files post-install.
        let userFile = plan.projectDir + "/sites.txt"
        try "https://example.com\n".data(using: .utf8)!
            .write(to: URL(fileURLWithPath: userFile))

        let uninstaller = ProjectTemplateUninstaller(context: .local)
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

    @Test func loadUninstallPlanRejectsProjectWithoutLock() throws {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        try FileManager.default.createDirectory(atPath: scratch + "/bare", withIntermediateDirectories: true)
        let entry = ProjectEntry(name: "Bare", path: scratch + "/bare")

        let uninstaller = ProjectTemplateUninstaller(context: .local)
        #expect(uninstaller.isTemplateInstalled(project: entry) == false)
        #expect(throws: ProjectTemplateError.self) {
            try uninstaller.loadUninstallPlan(for: entry)
        }
    }

    // MARK: - Registry snapshot helpers (dup'd intentionally from
    // ProjectTemplateInstallerTests — small helper, not worth a shared
    // fixture file for one more suite).

    nonisolated private static func snapshotRegistry() -> Data? {
        let path = ServerContext.local.paths.projectsRegistry
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    nonisolated private static func restoreRegistry(_ snapshot: Data?) {
        let path = ServerContext.local.paths.projectsRegistry
        if let snapshot {
            try? snapshot.write(to: URL(fileURLWithPath: path))
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

/// End-to-end tests for manifest schemaVersion 2 (template configuration).
/// Exercises the full cycle: inspect → buildPlan → install → uninstall
/// against a synthesized schemaful bundle. Uses an isolated Keychain
/// service suffix so no leftover login-Keychain items remain after the
/// test — every secret we write is deleted on teardown.
@Suite(.serialized) struct ProjectTemplateConfigInstallTests {

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

        let service = ProjectTemplateService(context: .local)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }

        #expect(inspection.manifest.schemaVersion == 2)
        #expect(inspection.manifest.config?.fields.count == 2)
    }

    @Test func buildPlanSurfacesSchemaAndQueuesConfigFiles() throws {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let manifest = Self.makeSchemafulManifest()
        let manifestJSON = String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "template.json": manifestJSON,
            "README.md": "# r", "AGENTS.md": "# a",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON
        ], includeManifest: false)

        let service = ProjectTemplateService(context: .local)
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

        let service = ProjectTemplateService(context: .local)
        #expect(throws: ProjectTemplateError.self) {
            try service.inspect(zipPath: bundle)
        }
    }

    @Test func installWritesConfigJsonAndManifestCache() throws {
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

        let service = ProjectTemplateService(context: .local)
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

        let registryBefore = Self.snapshotRegistry()
        defer { Self.restoreRegistry(registryBefore) }

        let installer = ProjectTemplateInstaller(context: .local)
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

        let service = ProjectTemplateService(context: .local)
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

        let registryBefore = Self.snapshotRegistry()
        defer { Self.restoreRegistry(registryBefore) }

        let installer = ProjectTemplateInstaller(context: .local)
        let entry = try installer.install(plan: plan)

        // Verify the secret is there before uninstall.
        guard case .keychainRef(let uri) = secretRef,
              let ref = TemplateKeychainRef.parse(uri) else {
            Issue.record("expected secret to be a keychainRef")
            return
        }
        #expect((try ProjectConfigKeychain().get(ref: ref)) == Data("delete-me".utf8))

        // Uninstall → secret should be gone.
        let uninstaller = ProjectTemplateUninstaller(context: .local)
        let uninstallPlan = try uninstaller.loadUninstallPlan(for: entry)
        try uninstaller.uninstall(plan: uninstallPlan)

        #expect((try ProjectConfigKeychain().get(ref: ref)) == nil)
    }

    // MARK: - Registry snapshot helpers (dup'd from ProjectTemplateInstallerTests)

    nonisolated private static func snapshotRegistry() -> Data? {
        let path = ServerContext.local.paths.projectsRegistry
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    nonisolated private static func restoreRegistry(_ snapshot: Data?) {
        let path = ServerContext.local.paths.projectsRegistry
        if let snapshot {
            try? snapshot.write(to: URL(fileURLWithPath: path))
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
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
        #expect(dashboard.sections.count == 3)

        // First section should have three stat widgets that the cron job
        // updates by value. Assert titles + types so the AGENTS.md contract
        // can't drift from the actual dashboard.
        let statsSection = dashboard.sections[0]
        #expect(statsSection.title == "Current Status")
        let statTitles = statsSection.widgets.filter { $0.type == "stat" }.map(\.title)
        #expect(statTitles.contains("Sites Up"))
        #expect(statTitles.contains("Sites Down"))
        #expect(statTitles.contains("Last Checked"))

        // Cron prompt references .scarf/config.json (where values.sites
        // + values.timeout_seconds live) and the dashboard/log it writes.
        // If either stops being referenced, the cron wouldn't know which
        // data to read or where to write results.
        let cronPrompt = inspection.cronJobs.first?.prompt ?? ""
        #expect(cronPrompt.contains("config.json"))
        #expect(cronPrompt.contains("values.sites"))
        #expect(cronPrompt.contains("dashboard.json"))
        #expect(cronPrompt.contains("status-log.md"))
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
