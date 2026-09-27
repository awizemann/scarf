import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Blind re-audit B03, app half: remote template uninstall with `~`-rooted
/// paths (S12-F1), an honest outcome, the install-side expansion, and the
/// export sheet's one-shot file scan (S12-F3).
@Suite struct BlindB03TemplateTests {

    /// A pseudo-remote filesystem on this Mac: `remoteHome` (an absolute
    /// path that doesn't exist here) and `~/…` both map into `localRoot`,
    /// the way the remote shell expands them. `isRemote` is true, so
    /// `PathGuard` applies its remote (lexical-only) rules.
    final class TildeRemoteTransport: ServerTransport, @unchecked Sendable {
        let inner = LocalTransport()
        let remoteHome: String
        let localRoot: String
        init(remoteHome: String, localRoot: String) {
            self.remoteHome = remoteHome
            self.localRoot = localRoot
        }
        func map(_ path: String) -> String {
            if path.hasPrefix(remoteHome) { return localRoot + path.dropFirst(remoteHome.count) }
            if path.hasPrefix("~/") { return localRoot + path.dropFirst(1) }
            return path
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

    static func lock(projectFiles: [String], skillsDir: String?) -> TemplateLock {
        TemplateLock(
            templateId: "acme/site", templateVersion: "1.0.0", templateName: "Site",
            installedAt: "2026-09-27T00:00:00Z", projectFiles: projectFiles,
            skillsNamespaceDir: skillsDir, skillsFiles: [], cronJobNames: [],
            memoryBlockId: nil, configKeychainItems: nil, configFields: nil,
            slashCommandFiles: nil
        )
    }

    static func writeLock(_ lock: TemplateLock, at path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try JSONEncoder().encode(lock).write(to: URL(fileURLWithPath: path))
    }

    static func touch(_ path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    }

    /// The remote install as the default paths record it: registry row
    /// `~/projects/site`, lock paths `~/projects/site/…`, skills under
    /// `~/.hermes/skills/templates/site`.
    struct RemoteFixture {
        let scratch: String
        let remoteHome: String
        let context: ServerContext
        let transport: TildeRemoteTransport
        let entry: ProjectEntry
    }

    static func remoteFixture(extraLockFiles: [String] = []) throws -> RemoteFixture {
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        let remoteHome = "/nonexistent-remote-\(UUID().uuidString)/home/alan"
        let transport = TildeRemoteTransport(remoteHome: remoteHome, localRoot: scratch)
        let context = ServerContext(
            id: UUID(), displayName: "droplet", kind: .ssh(SSHConfig(host: "fake.invalid"))
        )
        #expect(context.paths.home == "~/.hermes")
        let root = scratch + "/projects/site"
        for rel in ["README.md", "AGENTS.md", ".scarf/dashboard.json"] {
            try touch(root + "/" + rel)
        }
        try touch(scratch + "/.hermes/skills/templates/site/helper/SKILL.md")
        let lock = lock(
            projectFiles: ["README.md", "AGENTS.md", ".scarf/dashboard.json"]
                .map { "~/projects/site/" + $0 } + extraLockFiles,
            skillsDir: "~/.hermes/skills/templates/site"
        )
        try writeLock(lock, at: root + "/.scarf/template.lock.json")
        return RemoteFixture(
            scratch: scratch, remoteHome: remoteHome, context: context, transport: transport,
            entry: ProjectEntry(name: "Site", path: "~/projects/site")
        )
    }

    // MARK: - S12-F1: plan

    @Test func remoteTildeInstallPlansEveryTrackedFileOnceTheHomeIsKnown() throws {
        let f = try Self.remoteFixture()
        defer { try? FileManager.default.removeItem(atPath: f.scratch) }
        let uninstaller = ProjectTemplateUninstaller(
            context: f.context, userHome: f.remoteHome, transport: f.transport
        )

        let plan = try uninstaller.loadUninstallPlan(for: f.entry)

        let root = f.remoteHome + "/projects/site"
        #expect(!plan.rootRefused)
        #expect(plan.refusedEntries.isEmpty)
        #expect(Set(plan.projectFilesToRemove) == Set([
            root + "/README.md", root + "/AGENTS.md", root + "/.scarf/dashboard.json",
            root + "/.scarf/template.lock.json",
        ]))
        #expect(plan.skillsNamespaceDir == f.remoteHome + "/.hermes/skills/templates/site")
        #expect(plan.projectDirBecomesEmpty)
        #expect(plan.extraProjectEntries.isEmpty)
    }

    /// Expansion must not loosen the guard: a tampered lock still can't
    /// reach outside the project, however it spells the escape.
    @Test func expansionKeepsContainmentStrict() throws {
        let f = try Self.remoteFixture(extraLockFiles: [
            "~/.ssh/id_rsa",
            "~/projects/site/../../.ssh/id_rsa",
            "~/projects/site-other/README.md",
            "relative/README.md",
        ])
        defer { try? FileManager.default.removeItem(atPath: f.scratch) }
        let plan = try ProjectTemplateUninstaller(
            context: f.context, userHome: f.remoteHome, transport: f.transport
        ).loadUninstallPlan(for: f.entry)

        #expect(Set(plan.refusedEntries) == Set([
            "~/.ssh/id_rsa", "~/projects/site/../../.ssh/id_rsa",
            "~/projects/site-other/README.md", "relative/README.md",
        ]))
        #expect(plan.projectFilesToRemove.allSatisfy { $0.hasPrefix(f.remoteHome + "/projects/site/") })
    }

    /// No resolved home → nothing can be proved inside the project, so the
    /// plan removes nothing and says why; executing it throws before any
    /// deletion. This is the state every remote uninstall used to be in.
    @Test func unresolvedHomeRefusesTheWholePlanWithTheReason() throws {
        let f = try Self.remoteFixture()
        defer { try? FileManager.default.removeItem(atPath: f.scratch) }
        let uninstaller = ProjectTemplateUninstaller(context: f.context, transport: f.transport)

        let plan = try uninstaller.loadUninstallPlan(for: f.entry)
        #expect(plan.rootRefused)
        #expect(plan.totalRemoveCount == 0)
        #expect(plan.refusedEntries.first?.contains("home folder on droplet") == true)
        #expect(throws: ProjectTemplateError.self) { try uninstaller.uninstall(plan: plan) }
        #expect(FileManager.default.fileExists(atPath: f.scratch + "/projects/site/README.md"))
    }

    // MARK: - S12-F1: execution and an honest outcome

    /// End to end on a registry whose row and lock are `~`-rooted (a local
    /// context stands in for the host so the registry, `.env` and cleanup
    /// services run for real): everything tracked goes, the folder goes,
    /// and the outcome says so because it LOOKED.
    @Test func tildeRootedInstallIsFullyRemovedAndReportedFromDisk() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let userHome = home.path + "/user"
        let transport = TildeRemoteTransport(remoteHome: userHome, localRoot: userHome)
        let root = userHome + "/projects/site"
        for rel in ["README.md", "AGENTS.md"] { try Self.touch(root + "/" + rel) }
        let skills = home.context.paths.skillsDir + "/templates/site"
        try Self.touch(skills + "/helper/SKILL.md")
        try Self.writeLock(
            Self.lock(projectFiles: ["~/projects/site/README.md", "~/projects/site/AGENTS.md"],
                      skillsDir: skills),
            at: root + "/.scarf/template.lock.json"
        )
        let entry = ProjectEntry(name: "Site", path: "~/projects/site", uuid: UUID())
        try ProjectDashboardService(context: home.context).saveRegistry(
            ProjectRegistry(projects: [entry]), allowEmpty: false)

        let uninstaller = ProjectTemplateUninstaller(
            context: home.context, hermesRunner: { _ in ("", 0) },
            userHome: userHome, transport: transport
        )
        let plan = try uninstaller.loadUninstallPlan(for: entry)
        let outcome = try uninstaller.uninstall(plan: plan)

        #expect(outcome.isComplete, "leftovers: \(outcome.leftovers)")
        #expect(outcome.projectDirRemoved)
        #expect(!FileManager.default.fileExists(atPath: root))
        #expect(!FileManager.default.fileExists(atPath: skills))
        #expect(ProjectDashboardService(context: home.context).loadRegistry().projects.isEmpty)
    }

    /// A file the uninstall couldn't delete keeps the folder alive: the
    /// outcome names the file AND the folder, and `projectDirRemoved` is
    /// false even though the plan predicted an empty folder. A refused lock
    /// entry is named too.
    @Test func leftoversAreNamedAndTheFolderIsNotClaimedGone() throws {
        let home = try TempHermesHome()
        let root = home.path + "/projects/site"
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
            home.cleanup()
        }
        try Self.touch(root + "/README.md")
        try Self.writeLock(
            Self.lock(projectFiles: [root + "/README.md", "/etc/hosts"], skillsDir: nil),
            at: root + "/.scarf/template.lock.json"
        )
        let entry = ProjectEntry(name: "Site", path: root, uuid: UUID())
        try ProjectDashboardService(context: home.context).saveRegistry(
            ProjectRegistry(projects: [entry]), allowEmpty: false)
        let uninstaller = ProjectTemplateUninstaller(context: home.context, hermesRunner: { _ in ("", 0) })
        let plan = try uninstaller.loadUninstallPlan(for: entry)
        #expect(plan.projectDirBecomesEmpty)
        #expect(plan.refusedEntries == ["/etc/hosts"])

        // README can't be unlinked from a read-only folder.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root)
        let outcome = try uninstaller.uninstall(plan: plan)

        #expect(!outcome.isComplete)
        #expect(!outcome.projectDirRemoved)
        #expect(FileManager.default.fileExists(atPath: root + "/README.md"))
        #expect(outcome.leftovers.contains { $0.contains(root + "/README.md") })
        #expect(outcome.leftovers.contains { $0.contains("/etc/hosts") })
        #expect(outcome.leftovers.contains { $0.contains("project folder is still there") })
    }

    // MARK: - S12-F1: install records absolute paths

    @Test func installParentIsExpandedAgainstTheHostsHome() async {
        let context = ServerContext(
            id: UUID(), displayName: "droplet", kind: .ssh(SSHConfig(host: "fake.invalid"))
        )
        await ServerContext.primeResolvedHome("/home/alan", forServerID: context.id)
        #expect(await TemplateInstallerViewModel.absoluteParent("~/projects", context: context)
            == "/home/alan/projects")
        #expect(await TemplateInstallerViewModel.absoluteParent("~", context: context) == "/home/alan")
        #expect(await TemplateInstallerViewModel.absoluteParent("/srv/projects", context: context)
            == "/srv/projects")
        // The failed-probe fallback leaves the typed path alone.
        let unresolved = ServerContext(
            id: UUID(), displayName: "down", kind: .ssh(SSHConfig(host: "fake.invalid"))
        )
        await ServerContext.primeResolvedHome("~", forServerID: unresolved.id)
        #expect(await TemplateInstallerViewModel.absoluteParent("~/projects", context: unresolved)
            == "~/projects")
    }

    // MARK: - S12-F3: export preview scan

    @Test func exportScanReportsTheProjectFolderOnce() throws {
        let dir = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Self.touch(dir + "/README.md")
        try Self.touch(dir + "/.scarf/dashboard.json")
        try Self.touch(dir + "/CLAUDE.md")
        let scan = ProjectTemplateExporter(context: .local).scanProjectFiles(projectDir: dir)
        #expect(scan == .init(
            dashboardPresent: true, readmePresent: true, agentsMdPresent: false,
            instructionFiles: ["CLAUDE.md"]
        ))
    }

    @MainActor
    @Test func exportViewModelScansOffMainAndGatesExportOnTheResult() async throws {
        let dir = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for rel in ["README.md", "AGENTS.md", ".scarf/dashboard.json"] { try Self.touch(dir + "/" + rel) }
        let vm = TemplateExporterViewModel(context: .local, project: ProjectEntry(name: "P", path: dir))
        #expect(vm.fileScan == nil)
        #expect(!vm.requiredFilesPresent)
        vm.load()
        for _ in 0..<200 where vm.fileScan == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(vm.fileScan?.agentsMdPresent == true)
        #expect(vm.requiredFilesPresent)
    }
}
