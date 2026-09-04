import Testing
import Foundation
import ScarfCore
@testable import scarf

/// S2/D2 (t-a2c169f0), Mac-target half: the uninstall's treatment of
/// untracked `.scarf/` content and of the folder it leaves behind, and the
/// `.env` block whose slug the agent gets to choose.
///
/// Real installer + real uninstaller against a real temp Hermes home — the
/// bugs here are all about what is actually on disk afterwards, so nothing
/// is stubbed.
struct ProjectsS2D2AppTests {

    // MARK: - Fixtures

    static func installedProject(
        _ home: TempHermesHome, scratch: String
    ) throws -> (entry: ProjectEntry, projectDir: String) {
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
        return (entry, plan.projectDir)
    }

    // MARK: - H8a: untracked `.scarf/` content is user content

    /// The uninstall's own promise is that user-added files survive. It
    /// skipped `.scarf/` entirely when deciding whether the project folder
    /// had any — and `LocalTransport.removeFile` is `removeItem`, which is
    /// recursive. So a slash command the user wrote, or a mini-app, was
    /// deleted by a folder removal that believed the folder was empty.
    @Test func uninstallPreservesUntrackedScarfContent() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let (entry, projectDir) = try Self.installedProject(home, scratch: scratch)
        let commandsDir = projectDir + "/.scarf/slash-commands"
        try FileManager.default.createDirectory(atPath: commandsDir, withIntermediateDirectories: true)
        let command = commandsDir + "/mine.md"
        try Data("---\nname: mine\ndescription: d\n---\nbody\n".utf8)
            .write(to: URL(fileURLWithPath: command))

        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        let plan = try uninstaller.loadUninstallPlan(for: entry)
        // The plan must SAY the folder isn't empty — that flag is what
        // authorises the recursive removal.
        #expect(plan.projectDirBecomesEmpty == false)
        #expect(plan.extraProjectEntries.contains { $0.hasSuffix("/.scarf/slash-commands") })

        try uninstaller.uninstall(plan: plan)

        #expect(FileManager.default.fileExists(atPath: command))
        #expect(FileManager.default.fileExists(atPath: projectDir))
    }

    // MARK: - H8b: no ghost for the doctor to adopt

    /// After a clean uninstall the registry row is gone. If the folder
    /// keeps `.scarf/project.json`, the Project Doctor calls it an unlisted
    /// project and offers to ADOPT it — re-registering the project the user
    /// just uninstalled, with its original uuid, which re-attaches its
    /// `[proj:<uuid>]` cron jobs. The record's meaning is "this folder is a
    /// registered project"; it must leave with the row.
    @Test func uninstallLeavesNoOrphanTheDoctorWouldOfferToAdopt() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let (entry, projectDir) = try Self.installedProject(home, scratch: scratch)
        // User content keeps the folder alive past the uninstall — the
        // interesting case, since a folder that is deleted outright can't
        // be adopted either way.
        try Data("mine\n".utf8).write(to: URL(fileURLWithPath: projectDir + "/notes.txt"))
        #expect(FileManager.default.fileExists(atPath: projectDir + "/.scarf/project.json"))

        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        try uninstaller.uninstall(plan: try uninstaller.loadUninstallPlan(for: entry))

        #expect(FileManager.default.fileExists(atPath: projectDir + "/notes.txt"))
        #expect(FileManager.default.fileExists(atPath: projectDir + "/.scarf/project.json") == false)

        let adoptions = ProjectDoctorService(context: home.context).diagnose().findings
            .filter { $0.kind == .orphanProjectDir }
        #expect(adoptions.allSatisfy { $0.path != projectDir })
    }

    /// The folder-goes-away case still goes away — the extras rule must not
    /// have turned every uninstall into a leftover directory.
    @Test func uninstallOfAProjectWithNoUserContentStillRemovesTheFolder() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let (entry, projectDir) = try Self.installedProject(home, scratch: scratch)
        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        let plan = try uninstaller.loadUninstallPlan(for: entry)
        #expect(plan.projectDirBecomesEmpty)
        try uninstaller.uninstall(plan: plan)
        #expect(FileManager.default.fileExists(atPath: projectDir) == false)
    }

    /// Grants belonging to the uninstalled project are revoked, so a folder
    /// re-used later (ids being derived from host+path) can't inherit them.
    @Test func uninstallRevokesTheProjectsMiniAppGrants() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let (entry, projectDir) = try Self.installedProject(home, scratch: scratch)
        let record = try #require(ProjectStore(context: home.context).load(projectPath: projectDir))
        let grants = MiniAppGrantStore(context: home.context)
        try grants.setGrant(
            projectId: record.id.uuidString, miniAppId: "dash", permissions: [.store]
        )
        #expect(grants.hasDecision(projectId: record.id.uuidString, miniAppId: "dash"))

        let uninstaller = ProjectTemplateUninstaller(context: home.context)
        try uninstaller.uninstall(plan: try uninstaller.loadUninstallPlan(for: entry))

        #expect(grants.hasDecision(projectId: record.id.uuidString, miniAppId: "dash") == false)
    }

    // MARK: - LOW: cron argv flag injection from a downloaded template

    /// `schedule` and the resolved `prompt` land as POSITIONALS in
    /// `hermes cron create`, so a template that starts either with `-`
    /// reconfigures the job argparse-side — past the preview sheet the user
    /// approved. Refused at inspect time, before any plan exists.
    @Test func aTemplateWithAFlagShapedCronScheduleIsRefused() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let manifest = ProjectTemplateServiceTests.sampleManifest(cron: 1)
        let manifestJSON = String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "template.json": manifestJSON,
            "README.md": "# r",
            "AGENTS.md": "# a",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON,
            "cron/jobs.json": #"""
            [{"name":"nightly","schedule":"--deliver","prompt":"do a thing"}]
            """#
        ], includeManifest: false)

        #expect(throws: ProjectTemplateError.self) {
            _ = try ProjectTemplateService(context: home.context).inspect(zipPath: bundle)
        }
    }

    @Test func aTemplateWithAFlagShapedCronSkillIsRefused() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let manifest = ProjectTemplateServiceTests.sampleManifest(cron: 1)
        let manifestJSON = String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "template.json": manifestJSON,
            "README.md": "# r",
            "AGENTS.md": "# a",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON,
            "cron/jobs.json": #"""
            [{"name":"nightly","schedule":"0 3 * * *","skills":["--deliver=all"]}]
            """#
        ], includeManifest: false)

        #expect(throws: ProjectTemplateError.self) {
            _ = try ProjectTemplateService(context: home.context).inspect(zipPath: bundle)
        }
    }

    /// The guard must not reject an ordinary cron spec.
    @Test func anOrdinaryTemplateCronJobStillInspects() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let scratch = try ProjectTemplateServiceTests.makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let manifest = ProjectTemplateServiceTests.sampleManifest(cron: 1)
        let manifestJSON = String(data: try JSONEncoder().encode(manifest), encoding: .utf8)!
        let bundle = try ProjectTemplateServiceTests.makeBundle(dir: scratch, files: [
            "template.json": manifestJSON,
            "README.md": "# r",
            "AGENTS.md": "# a",
            "dashboard.json": ProjectTemplateServiceTests.sampleDashboardJSON,
            "cron/jobs.json": #"""
            [{"name":"nightly","schedule":"0 3 * * *","prompt":"check the site"}]
            """#
        ], includeManifest: false)

        let service = ProjectTemplateService(context: home.context)
        let inspection = try service.inspect(zipPath: bundle)
        defer { service.cleanupTempDir(inspection.unpackedDir) }
        #expect(inspection.cronJobs.count == 1)
    }

    // MARK: - S1 follow-up: the `.env` slug is agent-chosen

    /// `unmirror(project:)` reads the slug out of the project's cached
    /// manifest — a file the agent working in THAT project can write. Set
    /// it to another registered project's slug and uninstalling this one
    /// deletes the other one's secrets from `~/.hermes/.env`, silently:
    /// the victim's cron jobs just start failing to authenticate.
    @Test func unmirrorRefusesASlugAnotherProjectAlsoClaims() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let victimDir = home.path + "/victim"
        let attackerDir = home.path + "/attacker"
        for dir in [victimDir, attackerDir] {
            try FileManager.default.createDirectory(
                atPath: dir + "/.scarf", withIntermediateDirectories: true
            )
        }
        // Both manifests declare the slug "victim" — the victim honestly,
        // the attacker because it can.
        for dir in [victimDir, attackerDir] {
            try Data(#"{"id":"t/victim","name":"Victim","version":"1.0.0","slug":"victim"}"#.utf8)
                .write(to: URL(fileURLWithPath: dir + "/.scarf/manifest.json"))
        }
        try ProjectDashboardService(context: home.context).saveRegistry(
            ProjectRegistry(projects: [
                ProjectEntry(name: "Victim", path: victimDir),
                ProjectEntry(name: "Attacker", path: attackerDir),
            ])
        )

        let mirror = KeychainEnvMirror(context: home.context)
        let envPath = home.context.paths.envFile
        try mirror.mirror(
            slug: "victim", entries: [("SCARF_VICTIM_TOKEN", "s3cret")], envPath: envPath
        )
        #expect(try String(contentsOfFile: envPath, encoding: .utf8).contains("SCARF_VICTIM_TOKEN"))

        // The attacker's uninstall must not be able to strip it.
        try mirror.unmirror(project: ProjectEntry(name: "Attacker", path: attackerDir))
        #expect(try String(contentsOfFile: envPath, encoding: .utf8).contains("SCARF_VICTIM_TOKEN"))
    }

    /// The guard must not break the honest case: a project whose slug
    /// nobody else claims still gets its block stripped.
    @Test func unmirrorStillStripsAnUncontestedSlug() throws {
        let home = try TempHermesHome()
        defer { home.cleanup() }
        let dir = home.path + "/solo"
        try FileManager.default.createDirectory(
            atPath: dir + "/.scarf", withIntermediateDirectories: true
        )
        try Data(#"{"id":"t/solo","name":"Solo","version":"1.0.0","slug":"solo"}"#.utf8)
            .write(to: URL(fileURLWithPath: dir + "/.scarf/manifest.json"))
        try ProjectDashboardService(context: home.context).saveRegistry(
            ProjectRegistry(projects: [ProjectEntry(name: "Solo", path: dir)])
        )

        let mirror = KeychainEnvMirror(context: home.context)
        let envPath = home.context.paths.envFile
        try mirror.mirror(slug: "solo", entries: [("SCARF_SOLO_TOKEN", "x")], envPath: envPath)
        #expect(try String(contentsOfFile: envPath, encoding: .utf8).contains("SCARF_SOLO_TOKEN"))

        try mirror.unmirror(project: ProjectEntry(name: "Solo", path: dir))
        #expect(try String(contentsOfFile: envPath, encoding: .utf8).contains("SCARF_SOLO_TOKEN") == false)
    }
}
