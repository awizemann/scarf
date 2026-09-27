import Testing
import Foundation
@testable import ScarfCore

/// D2 (t-a2c169f0): lifecycle integrity — the transitions that used to
/// update one store and leave the other four describing a project that no
/// longer exists in that shape.
///
/// Real `ProjectsViewModel` / `ProjectStore` / `ProjectDoctorService`
/// against a real temp Hermes home. Nothing is stubbed, so a regression in
/// the service surfaces here instead of passing against a mock.
@MainActor
@Suite struct ProjectsD2LifecycleTests {

    // MARK: - Harness

    static func withTempHome(
        _ body: (ServerContext, _ projectsRoot: String) async throws -> Void
    ) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-d2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let ctx = ServerContext.local(home: home)
        let projectsRoot = home.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: ctx.paths.scarfDir, withIntermediateDirectories: true
        )
        try await body(ctx, projectsRoot.path)
    }

    @discardableResult
    static func makeProject(
        _ ctx: ServerContext, root: String, slug: String, name: String
    ) throws -> ScarfProject {
        let dir = root + "/" + slug
        try FileManager.default.createDirectory(
            atPath: dir + "/.scarf", withIntermediateDirectories: true
        )
        let project = ScarfProject(name: name, rootPath: dir)
        try ProjectStore(context: ctx).save(project)
        return project
    }

    static func loadedVM(_ ctx: ServerContext) -> ProjectsViewModel {
        let vm = ProjectsViewModel(context: ctx)
        vm.load()
        return vm
    }

    // MARK: - H6: rename propagates to the canonical record

    /// The record's `name` is what `renderAgentContextBlock` injects into
    /// every chat opened in the project. A rename that only touched the
    /// registry meant the agent was told the OLD name forever.
    @Test func renamePropagatesIntoTheProjectRecord() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let vm = Self.loadedVM(ctx)
            let row = try #require(vm.projects.first)

            #expect(await vm.renameProject(row, to: "Renamed"))

            let record = try #require(ProjectStore(context: ctx).load(projectPath: project.rootPath))
            #expect(record.name == "Renamed")
            // The identity must NOT move with the label.
            #expect(record.id == project.id)
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.first?.name == "Renamed")
        }
    }

    /// A rename whose record can't be written still succeeds — the registry
    /// write is the one the user sees. The doctor is the backstop, and the
    /// next test proves it fires.
    @Test func renameStillSucceedsWhenThereIsNoRecordToPropagateInto() async throws {
        try await Self.withTempHome { ctx, root in
            let dir = root + "/bare"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try ProjectDashboardService(context: ctx).saveRegistry(
                ProjectRegistry(projects: [ProjectEntry(name: "Bare", path: dir)])
            )
            let vm = Self.loadedVM(ctx)
            #expect(await vm.renameProject(try #require(vm.projects.first), to: "Still Fine"))
            #expect(vm.mutationError == nil)
        }
    }

    // MARK: - H7: the doctor can see divergence

    @Test func doctorReportsAndRepairsANameDivergence() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            // The pre-propagation state: registry renamed, record stale.
            var registry = ProjectDashboardService(context: ctx).loadRegistry()
            registry.projects[0] = ProjectEntry(
                name: "New Name", path: project.rootPath, uuid: project.id
            )
            try ProjectDashboardService(context: ctx).saveRegistry(registry)

            let doctor = ProjectDoctorService(context: ctx)
            let found = doctor.diagnose().findings.filter { $0.kind == .recordNameMismatch }
            #expect(found.count == 1)
            #expect(found.first?.repair == .renameRecordFromRegistry(path: project.rootPath))
            #expect(found.first?.repair?.isSafe == true)

            try doctor.repair(try #require(found.first))
            #expect(ProjectStore(context: ctx).load(projectPath: project.rootPath)?.name == "New Name")
            #expect(doctor.diagnose().findings.filter { $0.kind == .recordNameMismatch }.isEmpty)
        }
    }

    /// The move case: a record found at X declaring it belongs at Y. Every
    /// writer underneath addresses the project by `record.rootPath`, so
    /// this is reported and never auto-repaired.
    @Test func doctorReportsAMovedProjectAndOffersNoRepair() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "moved", name: "Moved")
            // Simulate the hand-move: the record still names the old home.
            var record = try #require(ProjectStore(context: ctx).load(projectPath: project.rootPath))
            let oldPath = root + "/before-the-move"
            record.rootPath = oldPath
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(
                to: URL(fileURLWithPath: ProjectStore.recordPath(forProjectPath: project.rootPath))
            )

            let found = ProjectDoctorService(context: ctx).diagnose()
                .findings.filter { $0.kind == .recordPathDivergence }
            #expect(found.count == 1)
            #expect(found.first?.severity == .high)
            #expect(found.first?.repair == nil)
            #expect(found.first?.detail.contains(oldPath) == true)
        }
    }

    @Test func aHealthyProjectProducesNeitherDivergenceFinding() async throws {
        try await Self.withTempHome { ctx, root in
            try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let report = ProjectDoctorService(context: ctx).diagnose()
            #expect(report.findings.filter { $0.kind == .recordNameMismatch }.isEmpty)
            #expect(report.findings.filter { $0.kind == .recordPathDivergence }.isEmpty)
            #expect(report.isHealthy)
        }
    }

    // MARK: - Removal is keyed by identity, not by display name

    /// The registry can hold two rows with one name — the doctor reports it
    /// as a `duplicateName` finding the user is meant to be able to resolve
    /// row by row. Name-keyed removal made that impossible: removing either
    /// one removed both.
    @Test func removingOneOfTwoRowsSharingANameLeavesTheOther() async throws {
        try await Self.withTempHome { ctx, root in
            let a = try Self.makeProject(ctx, root: root, slug: "a", name: "Twin")
            let b = try Self.makeProject(ctx, root: root, slug: "b", name: "Other")
            // Force the name collision behind the store's back.
            var registry = ProjectDashboardService(context: ctx).loadRegistry()
            for i in registry.projects.indices {
                registry.projects[i] = ProjectEntry(
                    name: "Twin",
                    path: registry.projects[i].path,
                    uuid: registry.projects[i].uuid
                )
            }
            try ProjectDashboardService(context: ctx).saveRegistry(registry)

            let vm = Self.loadedVM(ctx)
            let target = try #require(vm.projects.first { $0.uuid == a.id })
            #expect(await vm.removeProject(target))

            let rows = ProjectDashboardService(context: ctx).loadRegistry().projects
            #expect(rows.count == 1)
            #expect(rows.first?.uuid == b.id)
        }
    }

    // MARK: - Removal cleans up what lives outside the registry

    @Test func removalRevokesGrantsAndStripsTheAgentsBlock() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let grants = MiniAppGrantStore(context: ctx)
            try grants.setGrant(
                projectId: project.id.uuidString, miniAppId: "dash", permissions: [.store]
            )
            let agentsPath = project.rootPath + "/AGENTS.md"
            let block = ProjectStore(context: ctx).renderAgentContextBlock(for: project)
            try Data((block + "\n\nUser's own notes.\n").utf8)
                .write(to: URL(fileURLWithPath: agentsPath))

            let vm = Self.loadedVM(ctx)
            #expect(await vm.removeProject(try #require(vm.projects.first)))

            // Grants gone — otherwise re-using this folder resurrects them,
            // ids being derived from (host, path).
            #expect(grants.hasDecision(projectId: project.id.uuidString, miniAppId: "dash") == false)
            // Block gone, user's prose intact.
            let after = try String(contentsOfFile: agentsPath, encoding: .utf8)
            #expect(!after.contains(ProjectContextBlock.beginMarker))
            #expect(after.contains("User's own notes."))
        }
    }

    @Test func removalOfAProjectWhoseFolderIsGoneStillSucceeds() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            try FileManager.default.removeItem(atPath: project.rootPath)
            let vm = Self.loadedVM(ctx)
            #expect(await vm.removeProject(try #require(vm.projects.first)))
            #expect(vm.mutationError == nil)
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.isEmpty)
        }
    }

    // MARK: - Archive is no longer inert

    @Test func archivingStopsTheProjectBeingWatched() async throws {
        try await Self.withTempHome { ctx, root in
            try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            try Self.makeProject(ctx, root: root, slug: "beta", name: "Beta")
            let vm = Self.loadedVM(ctx)
            #expect(vm.dashboardPaths.count == 2)
            #expect(vm.projectScarfDirs.count == 2)

            let alpha = try #require(vm.projects.first { $0.name == "Alpha" })
            #expect(await vm.archiveProject(alpha))

            #expect(vm.dashboardPaths.count == 1)
            #expect(vm.projectScarfDirs.count == 1)
            #expect(vm.dashboardPaths.allSatisfy { $0.contains("/beta/") })
        }
    }

    @Test func unarchivingPutsTheProjectBackUnderWatch() async throws {
        try await Self.withTempHome { ctx, root in
            try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let vm = Self.loadedVM(ctx)
            let alpha = try #require(vm.projects.first)
            #expect(await vm.archiveProject(alpha))
            #expect(vm.dashboardPaths.isEmpty)
            let archived = try #require(vm.projects.first)
            #expect(await vm.unarchiveProject(archived))
            #expect(vm.dashboardPaths.count == 1)
        }
    }

    /// The lifecycle resolves the jobs it will act on from the SAME tags
    /// `ProjectStore.derive` uses. With no cron file there is nothing to
    /// pause and nothing to fail — archiving a project on a host without
    /// Hermes running must not report an error.
    @Test func archivingWithNoCronJobsIsANoOp() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let lifecycle = ProjectLifecycleService(context: ctx, cronRunner: { _ in
                Issue.record("nothing to pause, so nothing may be spawned")
                return false
            })
            let entry = ProjectEntry(name: "Alpha", path: project.rootPath, uuid: project.id)
            #expect(lifecycle.cronJobIDs(for: entry).isEmpty)
            #expect(lifecycle.runnableCronJobIDs(for: entry) == [])
            #expect(lifecycle.resumeArchivedCronJobs([]).isEmpty)
        }
    }

    // MARK: - S11-F2: archive pauses and restore resumes only what archive paused

    /// Stands in for `hermes cron pause|resume <id>`: records the argv and
    /// rewrites `jobs.json` the way Hermes does — `pause_job` writes
    /// enabled=false/state=paused/paused_at (`cron/jobs.py:2067-2077` @
    /// v2026.9.24), `resume_job` enabled=true/state=scheduled/no marker.
    final class FakeCron: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        let jobsPath: String
        var failing: Set<String> = []
        /// When set, every call waits on it first — to hold a follow-up
        /// in flight while the test starts the next transition.
        var gate: DispatchSemaphore?
        init(jobsPath: String) { self.jobsPath = jobsPath }
        var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }

        func run(_ args: [String]) -> Bool {
            gate?.wait()
            lock.lock(); defer { lock.unlock() }
            _calls.append(args)
            guard args.count == 3, !failing.contains(args[2]),
                  let data = FileManager.default.contents(atPath: jobsPath),
                  var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var jobs = root["jobs"] as? [[String: Any]],
                  let index = jobs.firstIndex(where: { $0["id"] as? String == args[2] })
            else { return false }
            if args[1] == "pause" {
                jobs[index]["enabled"] = false
                jobs[index]["state"] = "paused"
                jobs[index]["paused_at"] = "2026-09-26T09:00:00+00:00"
            } else {
                jobs[index]["enabled"] = true
                jobs[index]["state"] = "scheduled"
                jobs[index]["paused_at"] = NSNull()
            }
            root["jobs"] = jobs
            return FileManager.default.createFile(
                atPath: jobsPath, contents: try? JSONSerialization.data(withJSONObject: root))
        }

        func job(_ id: String) -> [String: Any]? {
            guard let data = FileManager.default.contents(atPath: jobsPath),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (root["jobs"] as? [[String: Any]])?.first { $0["id"] as? String == id }
        }
    }

    /// Four jobs: `live` (scheduled), `mine` (paused by the user before
    /// archiving), `tmpl` (a template job created paused, never reviewed)
    /// — all tagged for the project — and `other`, another project's.
    static func writeJobs(_ ctx: ServerContext, projectID: UUID) throws -> String {
        let tag = "[proj:\(projectID.uuidString)]"
        let schedule = #""schedule": {"kind": "cron", "expr": "0 9 * * *", "display": "0 9 * * *"}"#
        func job(_ id: String, _ name: String, enabled: Bool, state: String, pausedAt: Bool = false) -> String {
            let marker = pausedAt ? #", "paused_at": "2026-09-01T09:00:00+00:00""# : ""
            return #"{"id": "\#(id)", "name": "\#(name)", "prompt": "p", \#(schedule), "enabled": \#(enabled), "state": "\#(state)"\#(marker)}"#
        }
        let jobs = [
            job("live", "\(tag) Live", enabled: true, state: "scheduled"),
            job("mine", "\(tag) Mine", enabled: false, state: "paused", pausedAt: true),
            job("tmpl", "\(tag) Template job", enabled: false, state: "paused", pausedAt: true),
            job("other", "[proj:\(UUID().uuidString)] Other", enabled: true, state: "scheduled"),
        ].joined(separator: ",")
        let path = ctx.paths.cronJobsJSON
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(#"{"jobs": [\#(jobs)], "updated_at": "2026-09-26T08:00:00+00:00"}"#.utf8)
            .write(to: URL(fileURLWithPath: path))
        return path
    }

    static func vm(_ ctx: ServerContext, _ fake: FakeCron) -> ProjectsViewModel {
        let vm = loadedVM(ctx)
        vm.makeLifecycle = { ProjectLifecycleService(context: $0, cronRunner: { fake.run($0) }) }
        return vm
    }

    @Test func archiveThenRestoreResumesOnlyWhatArchivePaused() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let fake = FakeCron(jobsPath: try Self.writeJobs(ctx, projectID: project.id))
            let vm = Self.vm(ctx, fake)

            #expect(await vm.archiveProject(try #require(vm.projects.first)))
            await vm.cronFollowUp?.value
            #expect(fake.calls == [["cron", "pause", "live"]])
            #expect(vm.mutationError == nil)
            // The record is on the registry row as written to disk.
            let archivedRow = try #require(ProjectDashboardService(context: ctx).loadRegistry().projects.first)
            #expect(archivedRow.archived)
            #expect(archivedRow.archivePausedCronJobIDs == ["live"])

            #expect(await vm.unarchiveProject(try #require(vm.projects.first)))
            await vm.cronFollowUp?.value
            #expect(fake.calls == [["cron", "pause", "live"], ["cron", "resume", "live"]])
            #expect(fake.job("live")?["enabled"] as? Bool == true)
            // Paused before archive → still paused after restore.
            #expect(fake.job("mine")?["enabled"] as? Bool == false)
            #expect(fake.job("tmpl")?["enabled"] as? Bool == false)
            #expect(fake.job("other")?["enabled"] as? Bool == true)
            let restoredRow = try #require(ProjectDashboardService(context: ctx).loadRegistry().projects.first)
            #expect(!restoredRow.archived)
            #expect(restoredRow.archivePausedCronJobIDs == nil)
            #expect(restoredRow.extra[ProjectEntry.archivePausedCronJobIDsKey] == nil)
            #expect(vm.mutationError == nil)
        }
    }

    /// R16a X1: renaming an archived project must keep its archive record
    /// (and any other unmodelled key). The rename rebuilt the row from the
    /// model and dropped `extra`, so restoring afterwards resumed nothing.
    @Test func renameWhileArchivedKeepsTheArchiveRecord() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let fake = FakeCron(jobsPath: try Self.writeJobs(ctx, projectID: project.id))
            // An agent's own annotation on the row rides along too.
            var registry = ProjectDashboardService(context: ctx).loadRegistry()
            registry.projects[0].extra["agent_note"] = .string("keep me")
            try ProjectDashboardService(context: ctx).saveRegistry(registry)
            let vm = Self.vm(ctx, fake)

            #expect(await vm.archiveProject(try #require(vm.projects.first)))
            await vm.cronFollowUp?.value
            #expect(await vm.renameProject(try #require(vm.projects.first), to: "Alpha Renamed"))

            let renamed = try #require(ProjectDashboardService(context: ctx).loadRegistry().projects.first)
            #expect(renamed.name == "Alpha Renamed")
            #expect(renamed.uuid == project.id)
            #expect(renamed.archived)
            #expect(renamed.archivePausedCronJobIDs == ["live"])
            #expect(renamed.extra["agent_note"] == .string("keep me"))

            #expect(await vm.unarchiveProject(try #require(vm.projects.first)))
            await vm.cronFollowUp?.value
            #expect(fake.calls == [["cron", "pause", "live"], ["cron", "resume", "live"]])
            #expect(fake.job("live")?["enabled"] as? Bool == true)
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.first?.extra["agent_note"]
                    == .string("keep me"))
            #expect(vm.mutationError == nil)
        }
    }

    /// A pause that fails is shown, not swallowed: the job is still firing.
    @Test func archiveSurfacesAPauseFailure() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let fake = FakeCron(jobsPath: try Self.writeJobs(ctx, projectID: project.id))
            fake.failing = ["live"]
            let vm = Self.vm(ctx, fake)

            #expect(await vm.archiveProject(try #require(vm.projects.first)))
            await vm.cronFollowUp?.value
            let error = try #require(vm.mutationError)
            #expect(error.title.contains("still scheduled"))
            #expect(error.message.contains("live"))
            // The archive itself stands.
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.first?.archived == true)
        }
    }

    /// A job the user resumed (or deleted) while the project was archived
    /// is not touched again on restore.
    @Test func restoreSkipsAJobNoLongerPaused() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let fake = FakeCron(jobsPath: try Self.writeJobs(ctx, projectID: project.id))
            let vm = Self.vm(ctx, fake)
            #expect(await vm.archiveProject(try #require(vm.projects.first)))
            await vm.cronFollowUp?.value
            #expect(fake.run(["cron", "resume", "live"]))

            #expect(await vm.unarchiveProject(try #require(vm.projects.first)))
            await vm.cronFollowUp?.value
            #expect(fake.calls.filter { $0.starts(with: ["cron", "resume"]) }.count == 1,
                    "only the user's own resume; restore found nothing paused to resume")
            #expect(vm.mutationError == nil)
        }
    }

    /// A row archived by an older Scarf carries no record; restoring it
    /// resumes nothing rather than every attributed job.
    @Test func restoreOfALegacyArchiveResumesNothing() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let fake = FakeCron(jobsPath: try Self.writeJobs(ctx, projectID: project.id))
            var registry = ProjectDashboardService(context: ctx).loadRegistry()
            registry.projects[0].archived = true
            try ProjectDashboardService(context: ctx).saveRegistry(registry)
            let vm = Self.vm(ctx, fake)

            #expect(await vm.unarchiveProject(try #require(vm.projects.first)))
            await vm.cronFollowUp?.value
            #expect(fake.calls.isEmpty)
            #expect(fake.job("tmpl")?["enabled"] as? Bool == false)
            // …but says so: `mine` and `tmpl` are the project's paused jobs.
            let notice = try #require(vm.mutationError)
            #expect(notice.message.hasPrefix("2 of this project's cron jobs are paused"))
        }
    }

    /// A record of "paused nothing" is not a legacy archive: no notice,
    /// even though the project has jobs the user had paused themselves.
    @Test func restoreAfterAnArchiveThatPausedNothingIsQuiet() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let fake = FakeCron(jobsPath: try Self.writeJobs(ctx, projectID: project.id))
            #expect(fake.run(["cron", "pause", "live"]))
            let vm = Self.vm(ctx, fake)
            #expect(await vm.archiveProject(try #require(vm.projects.first)))
            await vm.cronFollowUp?.value
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.first?
                .archivePausedCronJobIDs == [])
            #expect(await vm.unarchiveProject(try #require(vm.projects.first)))
            await vm.cronFollowUp?.value
            #expect(vm.mutationError == nil)
            #expect(fake.calls == [["cron", "pause", "live"]])
        }
    }

    /// Restore started while archive's pause is still running waits for it,
    /// so the job is paused THEN resumed — not skipped as "not paused" and
    /// then paused for good under a restored project.
    @Test func restoreWaitsForAnArchivePauseStillInFlight() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let fake = FakeCron(jobsPath: try Self.writeJobs(ctx, projectID: project.id))
            let gate = DispatchSemaphore(value: 0)
            fake.gate = gate
            let vm = Self.vm(ctx, fake)

            #expect(await vm.archiveProject(try #require(vm.projects.first)))
            // The pause is now blocked in the fake. Start the restore, then
            // let the pause (and the resume after it) through.
            let archived = try #require(vm.projects.first)
            let restore = Task { await vm.unarchiveProject(archived) }
            try await Task.sleep(nanoseconds: 100_000_000)
            gate.signal()
            gate.signal()
            #expect(await restore.value)
            await vm.cronFollowUp?.value
            #expect(fake.calls == [["cron", "pause", "live"], ["cron", "resume", "live"]])
            #expect(fake.job("live")?["enabled"] as? Bool == true)
        }
    }

    /// An unreadable `jobs.json` doesn't block the archive, but it is said:
    /// Scarf paused nothing, so the jobs may still be firing.
    @Test func archiveWithUnreadableJobsIsArchivedAndReported() async throws {
        try await Self.withTempHome { ctx, root in
            try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let path = ctx.paths.cronJobsJSON
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("{ not json".utf8).write(to: URL(fileURLWithPath: path))
            let fake = FakeCron(jobsPath: path)
            let vm = Self.vm(ctx, fake)

            #expect(await vm.archiveProject(try #require(vm.projects.first)))
            #expect(fake.calls.isEmpty)
            #expect(vm.mutationError?.title.contains("may still be scheduled") == true)
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.first?.archived == true)
        }
    }

    /// Archiving a row that is already archived keeps the earlier record.
    @Test func reArchivingKeepsTheEarlierRecord() async throws {
        try await Self.withTempHome { ctx, root in
            let project = try Self.makeProject(ctx, root: root, slug: "alpha", name: "Alpha")
            let fake = FakeCron(jobsPath: try Self.writeJobs(ctx, projectID: project.id))
            let vm = Self.vm(ctx, fake)
            let row = try #require(vm.projects.first)
            #expect(await vm.archiveProject(row))
            await vm.cronFollowUp?.value
            // A stale menu hands in the pre-archive row again.
            #expect(await vm.archiveProject(row))
            await vm.cronFollowUp?.value
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.first?
                .archivePausedCronJobIDs == ["live"])
        }
    }

    /// The record survives an encode/decode of the registry row alongside
    /// any other unknown key (`extra` round trip).
    @Test func archiveRecordRoundTripsThroughTheRegistryCodable() throws {
        var entry = ProjectEntry(name: "A", path: "/tmp/a", archived: true, extra: ["agentNote": .string("keep")])
        entry.archivePausedCronJobIDs = ["j1", "j2"]
        let decoded = try JSONDecoder().decode(ProjectEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.archivePausedCronJobIDs == ["j1", "j2"])
        #expect(decoded.extra["agentNote"] == .string("keep"))
        var empty = decoded
        empty.archivePausedCronJobIDs = []
        #expect(empty.archivePausedCronJobIDs == [])
        var cleared = decoded
        cleared.archivePausedCronJobIDs = nil
        #expect(cleared.archivePausedCronJobIDs == nil)
        #expect(cleared.extra[ProjectEntry.archivePausedCronJobIDsKey] == nil)
    }

    // MARK: - Root policy at the app's own door

    @Test func theSidebarRefusesAnAbsurdProjectRoot() async throws {
        try await Self.withTempHome { ctx, _ in
            let vm = Self.loadedVM(ctx)
            #expect(await vm.addProject(name: "Everything", path: "/") == false)
            #expect(vm.mutationError != nil)
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.isEmpty)
        }
    }

    // MARK: - AGENTS.md block removal is surgical

    @Test func removingTheContextBlockPreservesEverythingAroundIt() {
        let block = ProjectContextBlock.beginMarker + "\nmanaged\n" + ProjectContextBlock.endMarker
        let before = "# Title\n\nProse above.\n\n" + block + "\n\nProse below.\n"
        let after = ProjectContextBlock.removeBlock(from: before)
        #expect(!after.contains(ProjectContextBlock.beginMarker))
        #expect(after.contains("Prose above."))
        #expect(after.contains("Prose below."))
        #expect(after.contains("# Title"))
    }

    @Test func removingTheContextBlockIsANoOpWhenThereIsNone() {
        let text = "# Just a file\n\nNothing managed here.\n"
        #expect(ProjectContextBlock.removeBlock(from: text) == text)
    }

    /// A file with only an opening marker cannot be bounded — guessing
    /// where the block ends would eat the user's text.
    @Test func removingTheContextBlockRefusesAnUnboundedRegion() {
        let text = ProjectContextBlock.beginMarker + "\nhalf a block\nuser text\n"
        #expect(ProjectContextBlock.removeBlock(from: text) == text)
    }

    @Test func applyThenRemoveReturnsToTheOriginalShape() {
        let original = "# Notes\n\nMine.\n"
        let block = ProjectContextBlock.beginMarker + "\nx\n" + ProjectContextBlock.endMarker
        let withBlock = ProjectContextBlock.applyBlock(block, to: original)
        #expect(withBlock.contains(ProjectContextBlock.beginMarker))
        let removed = ProjectContextBlock.removeBlock(from: withBlock)
        #expect(removed.contains("# Notes"))
        #expect(removed.contains("Mine."))
        #expect(!removed.contains(ProjectContextBlock.beginMarker))
    }

    // MARK: - Normalization uniformity

    /// `loadOrDerive` looked its row up with a raw `==`, so a registry that
    /// spelled the folder with a trailing slash missed the row and derived
    /// from a uuid-less entry — keying the AGENTS.md block on the interim
    /// path-derived id instead of the registry's.
    @Test func loadOrDeriveFindsTheRowThroughADifferentPathSpelling() async throws {
        try await Self.withTempHome { ctx, root in
            let dir = root + "/alpha"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let asserted = UUID()
            try ProjectDashboardService(context: ctx).saveRegistry(
                ProjectRegistry(projects: [
                    ProjectEntry(name: "Alpha", path: dir + "/", uuid: asserted)
                ])
            )
            let derived = ProjectStore(context: ctx).loadOrDerive(projectPath: dir, name: "Alpha")
            #expect(derived.id == asserted)
        }
    }
}
