import Testing
import Foundation
import ScarfCore
@testable import scarf

/// T1 (t-09019d73), app-target half: `ProjectRootPolicy` applied at TIME OF
/// USE rather than only at registration.
///
/// The S1 batch made every uninstall deletion re-derive containment from the
/// project root instead of believing `template.lock.json`. P8 SEC-H1 pointed
/// out the door that left open: the ROOT itself comes from `projects.json`,
/// which the agent can write directly, so a row appended with
/// `path: "/Users/me"` makes every one of those containment checks pass
/// against the user's home. These tests come at it as the attacker — a
/// registry row, not a lock entry.
@Suite struct ProjectsT1TrustAtUseTests {

    static func makeTempDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-t1-use-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// A lock file in the shape the installer writes, with only the fields
    /// these tests vary.
    static func writeLock(at path: String, projectFiles: [String]) throws {
        let lock: [String: Any] = [
            "template_id": "tester/fixture",
            "template_version": "1.0.0",
            "template_name": "Fixture",
            "installed_at": "2026-09-04T00:00:00Z",
            "project_files": projectFiles,
            "skills_files": [],
            "cron_job_names": [],
        ]
        try JSONSerialization.data(withJSONObject: lock)
            .write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Uninstall: plan build

    /// A row whose root sits ABOVE the Hermes home. Every containment check
    /// downstream would say yes to `.env`, `state.db` and `projects.json`,
    /// so the plan must be refused wholesale — with the reason visible.
    @Test func aRowWhoseRootContainsTheHermesHomeIsRefusedAtPlanBuild() throws {
        // A private container so nothing here touches the shared temp dir:
        // <container>/.hermes is the Hermes home, and the hostile registry
        // row names <container> itself.
        let container = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: container) }
        let hermesHome = container + "/.hermes"
        try FileManager.default.createDirectory(atPath: hermesHome, withIntermediateDirectories: true)
        let context = ServerContext.local(home: URL(fileURLWithPath: hermesHome))

        let root = container
        let scarfDir = root + "/.scarf"
        try FileManager.default.createDirectory(atPath: scarfDir, withIntermediateDirectories: true)
        let victim = root + "/precious.txt"
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: victim))
        try Self.writeLock(at: scarfDir + "/template.lock.json", projectFiles: [victim])

        let entry = ProjectEntry(name: "evil", path: root)
        let uninstaller = ProjectTemplateUninstaller(context: context)
        let plan = try uninstaller.loadUninstallPlan(for: entry)

        // Nothing to do, and the reason is in the list the sheet renders.
        #expect(plan.projectFilesToRemove.isEmpty)
        #expect(plan.totalRemoveCount == 0)
        #expect(plan.refusedEntries.contains(victim))
        #expect(plan.refusedEntries.contains { $0.contains(hermesHome) })

        // Executing it anyway (the "plan built elsewhere" case) throws
        // rather than half-running, and the victim survives.
        #expect(throws: ProjectTemplateError.self) {
            try uninstaller.uninstall(plan: plan)
        }
        #expect(FileManager.default.fileExists(atPath: victim))
    }

    /// The execute-side re-check, reached with a plan this process never
    /// built — the plan is a plain value, and `uninstall(plan:)` is not
    /// entitled to assume it came from `loadUninstallPlan`. A root of the
    /// user's actual home is the audit's own example.
    @Test func uninstallRefusesAPlanWhoseRootIsTheHomeDirectory() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let victim = home.path + "/precious.txt"
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: victim))

        let lock = TemplateLock(
            templateId: "tester/evil",
            templateVersion: "1.0.0",
            templateName: "Evil",
            installedAt: "2026-09-04T00:00:00Z",
            projectFiles: [victim],
            skillsNamespaceDir: nil,
            skillsFiles: [],
            cronJobNames: [],
            memoryBlockId: nil,
            configKeychainItems: nil,
            configFields: nil,
            slashCommandFiles: nil
        )
        let plan = TemplateUninstallPlan(
            lock: lock,
            project: ProjectEntry(name: "evil", path: NSHomeDirectory()),
            projectFilesToRemove: [victim],
            projectFilesAlreadyGone: [],
            extraProjectEntries: [],
            projectDirBecomesEmpty: false,
            refusedEntries: [],
            keychainItemsToDelete: [],
            skillsNamespaceDir: nil,
            cronJobsToRemove: [],
            cronJobsAlreadyGone: [],
            memoryBlockPresent: false,
            memoryPath: home.context.paths.memoryMD
        )

        #expect(throws: ProjectTemplateError.self) {
            try ProjectTemplateUninstaller(context: home.context).uninstall(plan: plan)
        }
        #expect(FileManager.default.fileExists(atPath: victim))
    }

    /// The policy must not become the reason an ordinary uninstall stops
    /// working — a sane root still builds a plan that removes things.
    @Test func anOrdinaryRootStillBuildsAWorkingPlan() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let root = home.path + "/projects/site"
        let scarfDir = root + "/.scarf"
        try FileManager.default.createDirectory(atPath: scarfDir, withIntermediateDirectories: true)
        let tracked = root + "/README.md"
        try Data("# hi".utf8).write(to: URL(fileURLWithPath: tracked))
        try Self.writeLock(at: scarfDir + "/template.lock.json", projectFiles: [tracked])

        let plan = try ProjectTemplateUninstaller(context: home.context)
            .loadUninstallPlan(for: ProjectEntry(name: "site", path: root))
        #expect(plan.projectFilesToRemove.contains(tracked))
        #expect(plan.refusedEntries.isEmpty)
    }

    // MARK: - Keychain migration

    /// A lock written before the SHA-256 binding names the OLD account. If
    /// the user has since re-saved that field, the live item is under the
    /// NEW account and the lock never learned about it — so an uninstall
    /// that deleted only what the lock names would leave the secret behind
    /// while reporting a clean removal. The plan queues both.
    @Test func aLegacyLockEntryAlsoQueuesTheReMintedItem() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let root = home.path + "/projects/site"
        let scarfDir = root + "/.scarf"
        try FileManager.default.createDirectory(atPath: scarfDir, withIntermediateDirectories: true)

        let legacyAccount = "api_key:\(TemplateKeychainRef.legacyShortHash(of: root))"
        let legacyURI = "keychain://com.scarf.template.acme/\(legacyAccount)"
        let lock: [String: Any] = [
            "template_id": "tester/acme",
            "template_version": "1.0.0",
            "template_name": "Acme",
            "installed_at": "2026-09-04T00:00:00Z",
            "project_files": [],
            "skills_files": [],
            "cron_job_names": [],
            "config_keychain_items": [legacyURI],
        ]
        try JSONSerialization.data(withJSONObject: lock)
            .write(to: URL(fileURLWithPath: scarfDir + "/template.lock.json"))

        let plan = try ProjectTemplateUninstaller(context: home.context)
            .loadUninstallPlan(for: ProjectEntry(name: "site", path: root))

        let accounts = Set(plan.keychainItemsToDelete.map(\.account))
        #expect(accounts.contains(legacyAccount))
        let modern = TemplateKeychainRef.make(
            templateSlug: "acme", fieldKey: "api_key", projectPath: root
        )
        #expect(accounts.contains(modern.account))
        #expect(plan.refusedEntries.isEmpty)
    }

    /// …and a lock that already names the modern account doesn't grow a
    /// phantom second entry.
    @Test func aModernLockEntryQueuesExactlyOneItem() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let root = home.path + "/projects/site"
        let scarfDir = root + "/.scarf"
        try FileManager.default.createDirectory(atPath: scarfDir, withIntermediateDirectories: true)

        let ref = TemplateKeychainRef.make(
            templateSlug: "acme", fieldKey: "api_key", projectPath: root
        )
        let lock: [String: Any] = [
            "template_id": "tester/acme",
            "template_version": "1.0.0",
            "template_name": "Acme",
            "installed_at": "2026-09-04T00:00:00Z",
            "project_files": [],
            "skills_files": [],
            "cron_job_names": [],
            "config_keychain_items": [ref.uri],
        ]
        try JSONSerialization.data(withJSONObject: lock)
            .write(to: URL(fileURLWithPath: scarfDir + "/template.lock.json"))

        let plan = try ProjectTemplateUninstaller(context: home.context)
            .loadUninstallPlan(for: ProjectEntry(name: "site", path: root))
        #expect(plan.keychainItemsToDelete.count == 1)
        #expect(plan.keychainItemsToDelete.first?.account == ref.account)
    }

    // MARK: - Widget file reads

    /// A dashboard widget's `path` is resolved against the project root, so
    /// a row rewritten to the home turns `markdown_file` into a reader for
    /// every document the user owns. The read is refused with the policy's
    /// own reason — the widget shows it, the project stays in the sidebar.
    @Test func widgetReadsAreRefusedAgainstAnInadmissibleRoot() {
        let result = WidgetPathResolver.resolve("notes.md", projectRoot: NSHomeDirectory())
        guard case .failure(let error) = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        guard case .inadmissibleRoot(let reason) = error else {
            Issue.record("expected .inadmissibleRoot, got \(error)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(error.userMessage == reason)
    }

    /// `/` is absurd on every host, so it is refused even for a root this
    /// Mac can't judge physically (the remote case).
    @Test func theFilesystemRootIsRefusedAsAWidgetRoot() {
        let result = WidgetPathResolver.resolve("notes.md", projectRoot: "/")
        if case .failure(.inadmissibleRoot) = result {} else {
            Issue.record("expected .inadmissibleRoot, got \(result)")
        }
    }

    /// A root that isn't on this machine (so: presumed remote) keeps
    /// working — the local home says nothing about a remote host, and
    /// refusing there would break every SSH-backed project's widgets.
    @Test func anUnseenRemoteRootStillResolves() {
        let result = WidgetPathResolver.resolve(
            "reports/weekly.md", projectRoot: "/home/deploy/site-not-on-this-mac"
        )
        #expect(result == .success("/home/deploy/site-not-on-this-mac/reports/weekly.md"))
    }

    /// Regression: ordinary local projects are unaffected.
    @Test func anOrdinaryLocalRootStillResolves() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let root = home.path + "/projects/site"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let result = WidgetPathResolver.resolve("reports/weekly.md", projectRoot: root)
        guard case .success(let path) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(path.hasSuffix("/reports/weekly.md"))
    }
}
