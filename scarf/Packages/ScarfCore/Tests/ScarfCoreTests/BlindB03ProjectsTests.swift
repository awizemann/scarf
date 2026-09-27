import Testing
import Foundation
@testable import ScarfCore

/// Blind re-audit B03, ScarfCore half: remote `~` expansion (S12-F1), fleet
/// apply's template cron jobs (S11-F2), the doctor's symlink-resolved
/// `workdir` comparison (S11-F4), and "same folder, different spelling" at
/// the add doors (t-14157321).
@Suite struct BlindB03ProjectsTests {

    // MARK: - S12-F1: tilde expansion

    @Test func expandingTildeReplacesOnlyALeadingHomeReference() {
        let home = "/home/alan"
        #expect(ServerContext.expandingTilde("~", home: home) == "/home/alan")
        #expect(ServerContext.expandingTilde("~/projects/site", home: home) == "/home/alan/projects/site")
        #expect(ServerContext.expandingTilde("~/projects/site", home: "/home/alan/") == "/home/alan/projects/site")
        // Not a home reference: left alone.
        #expect(ServerContext.expandingTilde("/srv/x", home: home) == "/srv/x")
        #expect(ServerContext.expandingTilde("~bob/x", home: home) == "~bob/x")
        #expect(ServerContext.expandingTilde("a/~/b", home: home) == "a/~/b")
        // A failed probe answers `~` (or nothing): never half-expand.
        #expect(ServerContext.expandingTilde("~/projects/site", home: "~") == "~/projects/site")
        #expect(ServerContext.expandingTilde("~/projects/site", home: "") == "~/projects/site")
        #expect(ServerContext.expandingTilde("~/x", home: "/") == "/x")
    }

    @Test func remoteBackupSharesTheSameExpansion() {
        #expect(RemoteBackupService.expandTilde("~/.hermes", home: "/root") == "/root/.hermes")
        #expect(RemoteBackupService.expandTilde("~/.hermes", home: "") == "~/.hermes")
    }

    // MARK: - S11-F2: fleet apply copies template-installed project jobs

    private static let projectID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    private static func job(_ name: String) -> HermesCronJob {
        HermesCronJob(
            id: UUID().uuidString, name: name, prompt: "go",
            schedule: CronSchedule(kind: "cron", expression: "0 3 * * *"),
            enabled: true, state: "idle"
        )
    }

    @Test func fleetCopySetIncludesTemplateInstalledProjectJobs() {
        let templated = ProjectCronAttribution.templateJobName(
            "[tmpl:acme/digest] Daily digest", templateId: "acme/digest", projectID: Self.projectID
        )
        let jobs = [
            Self.job("[proj:\(Self.projectID.uuidString)] nightly"),
            Self.job(templated),
            Self.job("[tmpl:acme/digest] legacy shared job"),
            Self.job("[tmpl:acme/digest] [proj:\(UUID().uuidString)] another install"),
            Self.job("unrelated"),
        ]
        let set = FleetApplyPlan.copyableCronJobs(from: jobs, projectID: Self.projectID)
        #expect(set.copyable.map(\.name) == ["[proj:\(Self.projectID.uuidString)] nightly", templated])
    }

    // MARK: - S11-F4: doctor compares roots the way Hermes stores workdirs

    /// A project registered through a symlinked parent; Hermes stores its
    /// cron `workdir` resolved (`cron/jobs.py:1580-1590` @ v2026.9.24,
    /// `Path.resolve()` — the spelling `realpath(3)` gives). Neither a
    /// "runs elsewhere" nor an "unlisted project" finding may come from it.
    @Test func doctorMatchesResolvedWorkdirAgainstSymlinkedRoot() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b03-doctor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let real = home.appendingPathComponent("real", isDirectory: true)
        let alphaReal = real.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(
            at: alphaReal.appendingPathComponent(".scarf"), withIntermediateDirectories: true
        )
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let ctx = ServerContext.local(home: home)

        let registered = link.path + "/alpha"
        let project = ScarfProject(name: "Alpha", rootPath: registered)
        try ProjectStore(context: ctx).save(project)

        guard let resolvedC = realpath(registered, nil) else {
            Issue.record("couldn't resolve the fixture"); return
        }
        let hermesWorkdir = String(cString: resolvedC)
        free(resolvedC)
        #expect(hermesWorkdir != registered)
        let jobs = """
        { "jobs": [ {
          "id": "j1", "name": "[proj:\(project.id.uuidString)] nightly",
          "prompt": "go", "schedule": {"kind": "cron", "expr": "0 3 * * *"},
          "enabled": true, "state": "idle", "workdir": "\(hermesWorkdir)"
        } ] }
        """
        try FileManager.default.createDirectory(
            atPath: (ctx.paths.cronJobsJSON as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(jobs.utf8).write(to: URL(fileURLWithPath: ctx.paths.cronJobsJSON))

        let report = ProjectDoctorService(context: ctx).diagnose()
        #expect(report.findings.filter { $0.kind == .pathReuseSuspicion }.isEmpty)
        #expect(report.findings.filter { $0.kind == .orphanProjectDir }.isEmpty)
    }

    /// The fix must not hide a job that genuinely runs somewhere else.
    @Test func doctorStillFlagsAJobRunningInAnotherResolvedFolder() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b03-doctor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let alpha = home.appendingPathComponent("projects/alpha", isDirectory: true)
        let other = home.appendingPathComponent("projects/other", isDirectory: true)
        for dir in [alpha, other] {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".scarf"), withIntermediateDirectories: true
            )
        }
        let ctx = ServerContext.local(home: home)
        let project = ScarfProject(name: "Alpha", rootPath: alpha.path)
        try ProjectStore(context: ctx).save(project)
        guard let resolvedC = realpath(other.path, nil) else { return }
        let otherResolved = String(cString: resolvedC)
        free(resolvedC)
        try FileManager.default.createDirectory(
            atPath: (ctx.paths.cronJobsJSON as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("""
        { "jobs": [ {
          "id": "j1", "name": "[proj:\(project.id.uuidString)] nightly",
          "prompt": "go", "schedule": {"kind": "cron", "expr": "0 3 * * *"},
          "enabled": true, "state": "idle", "workdir": "\(otherResolved)"
        } ] }
        """.utf8).write(to: URL(fileURLWithPath: ctx.paths.cronJobsJSON))

        let strays = ProjectDoctorService(context: ctx).diagnose().findings
            .filter { $0.kind == .pathReuseSuspicion }
        #expect(strays.count == 1)
    }

    // MARK: - t-14157321: same folder, different spelling

    @Test func sameLocalItemFollowsIdentityNotText() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b03-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let work = base.appendingPathComponent("Work/App", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: work)
        let sibling = base.appendingPathComponent("Work/Other", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        #expect(ProjectIdentity.isSameLocalItem(work.path, work.path + "/"))
        #expect(ProjectIdentity.isSameLocalItem(work.path, link.path))
        #expect(!ProjectIdentity.isSameLocalItem(work.path, sibling.path))
        #expect(!ProjectIdentity.isSameLocalItem(work.path, base.path + "/missing"))
        #expect(!ProjectIdentity.isSameLocalItem("~/x", "~/x"))

        // The case variant: one folder on a case-insensitive volume, two
        // (or none) on a case-sensitive one — the answer follows the disk.
        let lower = base.path + "/work/app"
        let volumeFoldsCase = FileManager.default.fileExists(atPath: lower)
        #expect(ProjectIdentity.isSameLocalItem(work.path, lower) == volumeFoldsCase)
        // And the frozen id normalization never folds.
        #expect(ProjectIdentity.normalizedPath(work.path) != ProjectIdentity.normalizedPath(lower))
    }

    @MainActor
    @Test func addProjectRefusesACaseVariantOfAListedLocalFolder() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b03-add-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let upper = home.appendingPathComponent("Work/App", isDirectory: true)
        try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: true)
        let lower = home.path + "/work/app"
        guard FileManager.default.fileExists(atPath: lower) else { return }  // case-sensitive volume
        let ctx = ServerContext.local(home: home)
        let vm = ProjectsViewModel(context: ctx)
        #expect(await vm.addProject(name: "App", path: upper.path))
        #expect(await vm.addProject(name: "App again", path: lower) == false)
        #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.count == 1)
    }
}
