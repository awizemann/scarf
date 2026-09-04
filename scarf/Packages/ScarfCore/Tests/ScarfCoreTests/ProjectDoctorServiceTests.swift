import Testing
import Foundation
@testable import ScarfCore

/// Disk-integration coverage for `ProjectDoctorService`: one fixture per
/// defect class, the repair each offers, and the round-trip property that
/// matters most — after repairing, a second pass finds nothing left to
/// repair. Every test runs against a fresh temp Hermes home injected via
/// `ServerContext.local(home:)`, so nothing touches the real `~/.hermes`.
@Suite struct ProjectDoctorServiceTests {

    // MARK: - Fixture helpers

    static func withTempHome(_ body: (ServerContext, _ projectsRoot: String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-doctor-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let projectsRoot = home.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try body(ServerContext.local(home: home), projectsRoot.path)
    }

    @discardableResult
    static func makeProjectDir(_ projectsRoot: String, slug: String) throws -> String {
        let dir = projectsRoot + "/" + slug
        try FileManager.default.createDirectory(atPath: dir + "/.scarf", withIntermediateDirectories: true)
        return dir
    }

    static func write(_ contents: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try contents.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }

    /// Write `projects.json` verbatim — the doctor's raw-uuid pass reads the
    /// bytes, so fixtures for that class cannot go through the encoder.
    static func writeRegistryJSON(_ ctx: ServerContext, _ json: String) throws {
        try write(json, to: ctx.paths.projectsRegistry)
    }

    static func registryRows(_ ctx: ServerContext) -> [ProjectEntry] {
        ProjectDashboardService(context: ctx).loadRegistry().projects
    }

    static func findings(_ ctx: ServerContext, kind: ProjectDoctorFinding.Kind) -> [ProjectDoctorFinding] {
        ProjectDoctorService(context: ctx).diagnose().findings.filter { $0.kind == kind }
    }

    // MARK: - Clean baseline

    @Test func cleanSetupReportsNoIssues() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alpha", rootPath: dir))

            let report = ProjectDoctorService(context: ctx).diagnose()
            #expect(report.isHealthy)
            #expect(report.projectCount == 1)
            #expect(report.repairBlock == nil)
            #expect(report.summary == "1 project checked — no issues.")
        }
    }

    // MARK: - Defect class: missing registry uuid

    @Test func detectsAndRepairsMissingRegistryUUID() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            let store = ProjectStore(context: ctx)
            let project = ScarfProject(name: "Alpha", rootPath: dir)
            try store.save(project)
            // Strip the uuid back out of the index, leaving the record intact.
            try Self.writeRegistryJSON(ctx, """
            { "projects": [ { "name": "Alpha", "path": "\(dir)", "archived": false } ] }
            """)

            let doctor = ProjectDoctorService(context: ctx)
            let found = doctor.diagnose().findings.filter { $0.kind == .missingRegistryUUID }
            #expect(found.count == 1)
            #expect(found.first?.repair == .reindexRegistryFromRecord(path: dir))

            try doctor.repair(found[0])
            #expect(Self.registryRows(ctx).first?.uuid == project.id)
            #expect(doctor.diagnose().isHealthy)
        }
    }

    // MARK: - Defect class: invalid registry uuid (the live 2026-09-02 case)

    @Test func detectsInvalidRegistryUUIDDistinctFromMissing() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "shabubox")
            let store = ProjectStore(context: ctx)
            let project = ScarfProject(name: "Shabubox", rootPath: dir)
            try store.save(project)
            try Self.writeRegistryJSON(ctx, """
            { "projects": [ { "name": "Shabubox", "path": "\(dir)",
              "uuid": "SHABUBOX-SEO-TRACKER-2026-09-03", "archived": false } ] }
            """)

            let doctor = ProjectDoctorService(context: ctx)
            let report = doctor.diagnose()
            // Reported as INVALID, not as merely missing — the salvage decode
            // makes the two look identical unless the raw bytes are read.
            #expect(report.findings.contains { $0.kind == .invalidRegistryUUID })
            #expect(!report.findings.contains { $0.kind == .missingRegistryUUID })
            #expect(report.worstSeverity == .high)

            try doctor.repair(report.findings.first { $0.kind == .invalidRegistryUUID }!)
            #expect(Self.registryRows(ctx).first?.uuid == project.id)
            #expect(doctor.diagnose().isHealthy)
        }
    }

    // MARK: - Defect class: registry row without a record

    @Test func detectsAndRepairsMissingRecord() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "beta")
            try Self.writeRegistryJSON(ctx, """
            { "projects": [ { "name": "Beta", "path": "\(dir)", "archived": false } ] }
            """)

            let doctor = ProjectDoctorService(context: ctx)
            let found = doctor.diagnose().findings.filter { $0.kind == .missingRecord }
            #expect(found.count == 1)

            try doctor.repair(found[0])
            let record = ProjectStore(context: ctx).load(projectPath: dir)
            #expect(record != nil)
            // The written id is the deterministic (host, path) one from P3,
            // and the index carries the same value.
            #expect(record?.id == ProjectIdentity.deterministicID(
                forProjectPath: dir,
                hostKey: ProjectIdentity.hostKey(for: ctx)
            ))
            #expect(Self.registryRows(ctx).first?.uuid == record?.id)
            #expect(doctor.diagnose().isHealthy)
        }
    }

    // MARK: - Defect class: record / registry id mismatch

    @Test func detectsAndRepairsRecordIdMismatch() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "gamma")
            let project = ScarfProject(name: "Gamma", rootPath: dir)
            try ProjectStore(context: ctx).save(project)
            let stranger = UUID()
            try Self.writeRegistryJSON(ctx, """
            { "projects": [ { "name": "Gamma", "path": "\(dir)",
              "uuid": "\(stranger.uuidString)", "archived": false } ] }
            """)

            let doctor = ProjectDoctorService(context: ctx)
            let found = doctor.diagnose().findings.filter { $0.kind == .recordIdMismatch }
            #expect(found.count == 1)

            try doctor.repair(found[0])
            // The RECORD wins: it travels with the project.
            #expect(Self.registryRows(ctx).first?.uuid == project.id)
            #expect(ProjectStore(context: ctx).load(projectPath: dir)?.id == project.id)
        }
    }

    // MARK: - Defect class: orphaned project directory

    @Test func detectsOrphanDirAndAdoptsItKeepingItsID() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let listed = try Self.makeProjectDir(projectsRoot, slug: "listed")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Listed", rootPath: listed))

            // A sibling with a real record that nothing lists.
            let orphan = try Self.makeProjectDir(projectsRoot, slug: "orphan")
            let orphanProject = ScarfProject(name: "Orphan", rootPath: orphan)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(orphanProject).write(to: URL(fileURLWithPath: orphan + "/.scarf/project.json"))

            let doctor = ProjectDoctorService(context: ctx)
            let found = doctor.diagnose().findings.filter { $0.kind == .orphanProjectDir }
            #expect(found.count == 1)
            #expect(found.first?.path == orphan)
            // Adoption is never part of "Repair All (safe)".
            #expect(found.first?.repair?.isSafe == false)
            #expect(doctor.diagnose().safelyRepairable.isEmpty)

            try doctor.repair(found[0])
            let row = Self.registryRows(ctx).first { $0.path == orphan }
            #expect(row != nil)
            // Adoption preserves the orphan's OWN id rather than minting one.
            #expect(row?.uuid == orphanProject.id)
            #expect(doctor.diagnose().findings.contains { $0.kind == .orphanProjectDir } == false)
        }
    }

    @Test func orphanScanFindsManifestOnlyDirAndSkipsPlainFolders() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let listed = try Self.makeProjectDir(projectsRoot, slug: "listed")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Listed", rootPath: listed))

            let templated = try Self.makeProjectDir(projectsRoot, slug: "templated")
            try Self.write(#"{"id":"blog","version":"1.0.0"}"#, to: templated + "/.scarf/manifest.json")
            // A plain folder is not a project.
            try FileManager.default.createDirectory(
                atPath: projectsRoot + "/notes", withIntermediateDirectories: true
            )

            let paths = Self.findings(ctx, kind: .orphanProjectDir).compactMap(\.path)
            #expect(paths == [templated])
        }
    }

    @Test func orphanScanExcludesHermesHomeAndProfiles() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let listed = try Self.makeProjectDir(projectsRoot, slug: "listed")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Listed", rootPath: listed))

            // A profile is a whole separate Hermes home, never a project —
            // even when it happens to carry `.scarf/` files.
            let profile = ctx.paths.home + "/profiles/scarfbox-1"
            try Self.write(#"{"id":"x","version":"1.0.0"}"#, to: profile + "/.scarf/manifest.json")
            try Self.write(#"{"id":"y","version":"1.0.0"}"#, to: ctx.paths.home + "/.scarf/manifest.json")
            // Reach both through cron workdirs, which are candidates directly
            // — otherwise neither is even offered to the exclusion rule.
            try Self.write("""
            { "jobs": [
              { "id": "j1", "name": "profile", "prompt": "p",
                "schedule": {"kind": "cron", "expr": "0 3 * * *"},
                "enabled": true, "state": "idle", "workdir": "\(profile)" },
              { "id": "j2", "name": "home", "prompt": "p",
                "schedule": {"kind": "cron", "expr": "0 3 * * *"},
                "enabled": true, "state": "idle", "workdir": "\(ctx.paths.home)" }
            ] }
            """, to: ctx.paths.cronJobsJSON)

            #expect(Self.findings(ctx, kind: .orphanProjectDir).isEmpty)
        }
    }

    @Test func orphanScanIgnoresTildeRootedPathsItCannotCompare() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let listed = try Self.makeProjectDir(projectsRoot, slug: "listed")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Listed", rootPath: listed))
            // A `~`-rooted workdir is exactly what a remote host's cron jobs
            // and default projects root look like. Ids never expand `~`, so
            // such a path can't be matched against the absolute paths in the
            // registry — comparing them anyway would report every listed
            // remote project as an orphan.
            try Self.write("""
            { "jobs": [ { "id": "j1", "name": "nightly", "prompt": "p",
              "schedule": {"kind": "cron", "expr": "0 3 * * *"},
              "enabled": true, "state": "idle", "workdir": "~/projects/listed" } ] }
            """, to: ctx.paths.cronJobsJSON)

            #expect(Self.findings(ctx, kind: .orphanProjectDir).isEmpty)
        }
    }

    @Test func orphanWithUnreadableRecordIsReportedNotAdopted() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let listed = try Self.makeProjectDir(projectsRoot, slug: "listed")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Listed", rootPath: listed))
            let orphan = try Self.makeProjectDir(projectsRoot, slug: "orphan")
            let recordPath = orphan + "/.scarf/project.json"
            try Self.write("{ truncated", to: recordPath)

            let doctor = ProjectDoctorService(context: ctx)
            let report = doctor.diagnose()
            // Adopting would derive a record and write it over the only copy.
            #expect(!report.findings.contains { $0.kind == .orphanProjectDir })
            #expect(report.findings.contains { $0.kind == .malformedSidecar && $0.path == recordPath })

            doctor.repairAllSafe(report)
            #expect(try String(contentsOfFile: recordPath, encoding: .utf8) == "{ truncated")
        }
    }

    @Test func orphanIsNotAdoptedUnderANameAnotherProjectAlreadyUses() throws {
        try Self.withTempHome { ctx, projectsRoot in
            // The listed project is named "orphan" too — adopting the folder
            // would make the sidebar's name-keyed delete drop both rows.
            let listed = try Self.makeProjectDir(projectsRoot, slug: "listed")
            try ProjectStore(context: ctx).save(ScarfProject(name: "orphan", rootPath: listed))
            let orphan = try Self.makeProjectDir(projectsRoot, slug: "orphan")
            try Self.write(#"{"id":"blog","version":"1.0.0"}"#, to: orphan + "/.scarf/manifest.json")

            let doctor = ProjectDoctorService(context: ctx)
            let found = doctor.diagnose().findings.filter { $0.kind == .orphanProjectDir }
            #expect(found.count == 1)
            #expect(found.first?.repair == nil)

            // And the repair refuses even if driven directly.
            #expect(throws: ProjectDoctorError.nameTaken("orphan")) {
                try doctor.repair(ProjectDoctorFinding(
                    id: "x", kind: .orphanProjectDir, severity: .medium,
                    title: "t", detail: "d",
                    repair: .adoptOrphan(path: orphan, name: "orphan")
                ))
            }
            #expect(Self.registryRows(ctx).count == 1)
        }
    }

    @Test func duplicatePathRowsGetNoIdentityRepairThatCouldNeverConverge() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alpha", rootPath: dir))
            // Both rows lack a uuid. Every writer addresses a row BY PATH and
            // stops at the first match, so repairing would fix row 1, leave
            // row 2, and re-raise the same finding forever.
            try Self.writeRegistryJSON(ctx, """
            { "projects": [
              { "name": "Alpha", "path": "\(dir)", "archived": false },
              { "name": "Alpha Two", "path": "\(dir)", "archived": false }
            ] }
            """)

            let report = ProjectDoctorService(context: ctx).diagnose()
            #expect(report.findings.contains { $0.kind == .duplicatePath })
            #expect(report.safelyRepairable.isEmpty)
        }
    }

    @Test func mismatchIsReportOnlyWhenTheRecordHoldsTheDerivedID() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            // The RECORD carries the path-derived id while the row carries a
            // minted one. "The record wins" would demote an asserted identity
            // to a derived one, so nothing is offered.
            let derived = ProjectIdentity.deterministicID(
                forProjectPath: dir,
                hostKey: ProjectIdentity.hostKey(for: ctx)
            )
            try ProjectStore(context: ctx).save(ScarfProject(id: derived, name: "Alpha", rootPath: dir))
            let minted = UUID()
            try Self.writeRegistryJSON(ctx, """
            { "projects": [ { "name": "Alpha", "path": "\(dir)",
              "uuid": "\(minted.uuidString)", "archived": false } ] }
            """)

            let found = Self.findings(ctx, kind: .recordIdMismatch)
            #expect(found.count == 1)
            #expect(found.first?.repair == nil)
        }
    }

    // MARK: - Defect class: duplicates (flagged, never auto-deleted)

    @Test func flagsDuplicatePathsAndNamesWithoutOfferingARepair() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            let other = try Self.makeProjectDir(projectsRoot, slug: "beta")
            // Two rows at the same path (spelled differently), plus a name clash.
            try Self.writeRegistryJSON(ctx, """
            { "projects": [
              { "name": "Alpha", "path": "\(dir)", "archived": false },
              { "name": "Alpha Copy", "path": "\(dir)/", "archived": false },
              { "name": "Alpha", "path": "\(other)", "archived": false }
            ] }
            """)

            let report = ProjectDoctorService(context: ctx).diagnose()
            let dupPaths = report.findings.filter { $0.kind == .duplicatePath }
            let dupNames = report.findings.filter { $0.kind == .duplicateName }
            #expect(dupPaths.count == 1)
            #expect(dupNames.count == 1)
            // Deletion is the user's call: neither offers a repair.
            #expect(dupPaths.first?.repair == nil)
            #expect(dupNames.first?.repair == nil)
        }
    }

    @Test func findingIDsAreUniqueEvenWhenRowsShareASubject() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alpha", rootPath: dir))
            // Two rows at one path, BOTH missing a uuid: each would raise its
            // own finding under the same subject-keyed id, and a SwiftUI List
            // handed two rows with one id misrenders.
            try Self.writeRegistryJSON(ctx, """
            { "projects": [
              { "name": "Alpha", "path": "\(dir)", "archived": false },
              { "name": "Alpha Two", "path": "\(dir)", "archived": false }
            ] }
            """)

            let ids = ProjectDoctorService(context: ctx).diagnose().findings.map(\.id)
            #expect(ids.count == Set(ids).count)
        }
    }

    // MARK: - Defect class: malformed agent-owned sidecars (report-only)

    @Test func reportsMalformedSidecarsAndNeverRewritesThem() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alpha", rootPath: dir))
            let dashboard = dir + "/.scarf/dashboard.json"
            let manifest = dir + "/.scarf/manifest.json"
            try Self.write("{ not json at all", to: dashboard)
            try Self.write("[[[", to: manifest)
            let dashboardBefore = try Data(contentsOf: URL(fileURLWithPath: dashboard))

            let doctor = ProjectDoctorService(context: ctx)
            let found = doctor.diagnose().findings.filter { $0.kind == .malformedSidecar }
            #expect(Set(found.compactMap(\.path)) == [dashboard, manifest])
            // Report-only: no repair offered, and Repair All leaves them alone.
            #expect(found.allSatisfy { $0.repair == nil })
            doctor.repairAllSafe(doctor.diagnose())
            #expect(try Data(contentsOf: URL(fileURLWithPath: dashboard)) == dashboardBefore)
        }
    }

    @Test func unreadableProjectRecordIsReportedNotOverwritten() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            try Self.writeRegistryJSON(ctx, """
            { "projects": [ { "name": "Alpha", "path": "\(dir)", "archived": false } ] }
            """)
            let recordPath = dir + "/.scarf/project.json"
            try Self.write("{ half-written", to: recordPath)

            let doctor = ProjectDoctorService(context: ctx)
            let report = doctor.diagnose()
            // A record that exists but doesn't parse is DAMAGE, not an absent
            // record — offering "create it" would overwrite the only copy.
            #expect(report.findings.contains { $0.kind == .malformedSidecar && $0.path == recordPath })
            #expect(!report.findings.contains { $0.kind == .missingRecord })

            doctor.repairAllSafe(report)
            #expect(try String(contentsOfFile: recordPath, encoding: .utf8) == "{ half-written")
        }
    }

    // MARK: - Defect class: dead vs unreachable root

    @Test func deadRootOffersRowRemovalGatedOutOfSafeRepairs() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let alive = try Self.makeProjectDir(projectsRoot, slug: "alive")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alive", rootPath: alive))
            let gone = projectsRoot + "/gone"
            var registry = ProjectDashboardService(context: ctx).loadRegistry()
            registry.projects.append(ProjectEntry(name: "Gone", path: gone))
            try ProjectDashboardService(context: ctx).saveRegistry(registry)

            let doctor = ProjectDoctorService(context: ctx)
            let report = doctor.diagnose()
            let dead = report.findings.filter { $0.kind == .deadRootPath }
            #expect(dead.count == 1)
            #expect(dead.first?.repair == .removeRegistryRow(path: gone))
            #expect(dead.first?.repair?.isDestructive == true)
            // Destructive work never runs unattended.
            #expect(report.safelyRepairable.isEmpty)

            try doctor.repair(dead[0])
            #expect(Self.registryRows(ctx).map(\.name) == ["Alive"])
        }
    }

    @Test func unreachableRootIsReportedWithoutARemovalOffer() throws {
        try Self.withTempHome { ctx, projectsRoot in
            // Parent gone too — indistinguishable from a transport that is
            // down, so the doctor must not offer to delete the row.
            let orphanedBranch = projectsRoot + "/vanished-parent/project"
            try Self.writeRegistryJSON(ctx, """
            { "projects": [ { "name": "Ghost", "path": "\(orphanedBranch)", "archived": false } ] }
            """)

            let report = ProjectDoctorService(context: ctx).diagnose()
            #expect(report.findings.contains { $0.kind == .unreachableRoot })
            #expect(!report.findings.contains { $0.kind == .deadRootPath })
            #expect(report.repairable.isEmpty)
        }
    }

    // MARK: - Defect class: quarantine / backup history

    @Test func surfacesQuarantineAndBackupAsHistory() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alpha", rootPath: dir))
            // A save always refreshes `.bak`; add an older quarantine copy.
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alpha", rootPath: dir))
            try Self.write("garbage", to: ctx.paths.projectsRegistry + ".corrupt-20260901T101010Z")

            let report = ProjectDoctorService(context: ctx).diagnose()
            let history = report.findings.filter { $0.kind == .registryHistory }
            #expect(history.count >= 1)
            #expect(history.allSatisfy { $0.severity == .info })
            // Informational history alone still counts as healthy.
            #expect(report.isHealthy)
        }
    }

    // MARK: - Defect class: path-reuse suspicion

    @Test func flagsCronJobTaggedForProjectButRunningElsewhere() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            let project = ScarfProject(name: "Alpha", rootPath: dir)
            try ProjectStore(context: ctx).save(project)
            try Self.write("""
            { "jobs": [ {
              "id": "j1",
              "name": "[proj:\(project.id.uuidString)] nightly",
              "prompt": "go", "schedule": {"kind": "cron", "expr": "0 3 * * *"},
              "enabled": true, "state": "idle",
              "workdir": "\(projectsRoot)/some-other-place"
            } ] }
            """, to: ctx.paths.cronJobsJSON)

            let found = Self.findings(ctx, kind: .pathReuseSuspicion)
            #expect(found.count == 1)
            #expect(found.first?.severity == .low)
            #expect(found.first?.repair == nil)
        }
    }

    @Test func doesNotFlagCronJobRunningInTheProjectItself() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            let project = ScarfProject(name: "Alpha", rootPath: dir)
            try ProjectStore(context: ctx).save(project)
            try Self.write("""
            { "jobs": [ {
              "id": "j1",
              "name": "[proj:\(project.id.uuidString)] nightly",
              "prompt": "go", "schedule": {"kind": "cron", "expr": "0 3 * * *"},
              "enabled": true, "state": "idle",
              "workdir": "\(dir)/"
            } ] }
            """, to: ctx.paths.cronJobsJSON)

            #expect(Self.findings(ctx, kind: .pathReuseSuspicion).isEmpty)
        }
    }

    // MARK: - Repair gating on a lossy registry

    @Test func repairsAreBlockedWhenRowsWereDropped() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alpha", rootPath: dir))
            let good = try Self.makeProjectDir(projectsRoot, slug: "beta")
            // The second row has no `path`, so the salvage decode drops the
            // ROW — writing the survivors back would erase it for good.
            try Self.writeRegistryJSON(ctx, """
            { "projects": [
              { "name": "Alpha", "path": "\(dir)", "archived": false },
              { "name": "Beta" },
              { "name": "Gamma", "path": "\(good)", "archived": false }
            ] }
            """)

            let doctor = ProjectDoctorService(context: ctx)
            let report = doctor.diagnose()
            #expect(report.repairBlock == .rowsDropped(1))
            #expect(report.safelyRepairable.isEmpty)
            #expect(report.repairable.isEmpty)

            // Even a hand-held finding is refused.
            let finding = ProjectDoctorFinding(
                id: "x", kind: .missingRegistryUUID, severity: .medium,
                title: "t", detail: "d", repair: .reindexRegistryFromRecord(path: dir)
            )
            #expect(throws: ProjectDoctorError.repairsBlocked(.rowsDropped(1))) {
                try doctor.repair(finding)
            }
            // And the file is untouched: Beta's row survives on disk.
            let raw = try String(contentsOfFile: ctx.paths.projectsRegistry, encoding: .utf8)
            #expect(raw.contains("\"Beta\""))
        }
    }

    @Test func repairIsRefusedWhenTheRegistryBreaksAfterTheReport() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alpha", rootPath: dir))
            try Self.writeRegistryJSON(ctx, """
            { "projects": [ { "name": "Alpha", "path": "\(dir)", "archived": false } ] }
            """)
            let doctor = ProjectDoctorService(context: ctx)
            let finding = doctor.diagnose().findings.first { $0.kind == .missingRegistryUUID }!

            // The file goes lossy between diagnose and repair — the exact race
            // a file watcher makes routine.
            try Self.writeRegistryJSON(ctx, """
            { "projects": [ { "name": "Alpha", "path": "\(dir)", "archived": false }, { "name": "Beta" } ] }
            """)
            #expect(throws: (any Error).self) { try doctor.repair(finding) }
        }
    }

    // MARK: - Repair-all + idempotency round-trip

    @Test func repairAllSafeFixesEveryRepairableClassAndConverges() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let store = ProjectStore(context: ctx)

            // 1. record present, uuid missing from the index
            let a = try Self.makeProjectDir(projectsRoot, slug: "a")
            let aProject = ScarfProject(name: "A", rootPath: a)
            try store.save(aProject)
            // 2. record present, index uuid is garbage
            let b = try Self.makeProjectDir(projectsRoot, slug: "b")
            let bProject = ScarfProject(name: "B", rootPath: b)
            try store.save(bProject)
            // 3. record present, index uuid belongs to someone else
            let c = try Self.makeProjectDir(projectsRoot, slug: "c")
            let cProject = ScarfProject(name: "C", rootPath: c)
            try store.save(cProject)
            // 4. no record at all
            let d = try Self.makeProjectDir(projectsRoot, slug: "d")
            // 5. dead row — repairable, but never unattended
            let dead = projectsRoot + "/dead"

            try Self.writeRegistryJSON(ctx, """
            { "projects": [
              { "name": "A", "path": "\(a)", "archived": false },
              { "name": "B", "path": "\(b)", "uuid": "NOT-A-UUID", "archived": false },
              { "name": "C", "path": "\(c)", "uuid": "\(UUID().uuidString)", "archived": false },
              { "name": "D", "path": "\(d)", "archived": false },
              { "name": "Dead", "path": "\(dead)", "archived": false }
            ] }
            """)

            let doctor = ProjectDoctorService(context: ctx)
            let first = doctor.diagnose()
            #expect(Set(first.findings.map(\.kind)).isSuperset(of: [
                .missingRegistryUUID, .invalidRegistryUUID, .recordIdMismatch,
                .missingRecord, .deadRootPath
            ]))
            #expect(first.safelyRepairable.count == 4)

            let failures = doctor.repairAllSafe(first)
            #expect(failures.isEmpty)

            let second = doctor.diagnose()
            // Everything safe is settled; only the destructive row is left.
            #expect(second.safelyRepairable.isEmpty)
            #expect(second.issues.map(\.kind) == [.deadRootPath])

            let rows = Dictionary(uniqueKeysWithValues: Self.registryRows(ctx).map { ($0.name, $0) })
            #expect(rows["A"]?.uuid == aProject.id)
            #expect(rows["B"]?.uuid == bProject.id)
            #expect(rows["C"]?.uuid == cProject.id)
            #expect(rows["D"]?.uuid == store.load(projectPath: d)?.id)

            // Idempotency: a second Repair All writes nothing and changes
            // nothing, and a third pass agrees with the second.
            let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: ctx.paths.projectsRegistry))
            #expect(doctor.repairAllSafe(second).isEmpty)
            let bytesAfter = try Data(contentsOf: URL(fileURLWithPath: ctx.paths.projectsRegistry))
            #expect(bytesBefore == bytesAfter)
            #expect(doctor.diagnose().issues.map(\.kind) == second.issues.map(\.kind))

            // And the destructive one still works when asked for explicitly.
            try doctor.repair(second.findings.first { $0.kind == .deadRootPath }!)
            #expect(doctor.diagnose().isHealthy)
        }
    }

    @Test func repeatedRepairOfTheSameFindingIsANoOp() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alpha", rootPath: dir))
            try Self.writeRegistryJSON(ctx, """
            { "projects": [ { "name": "Alpha", "path": "\(dir)", "archived": false } ] }
            """)
            let doctor = ProjectDoctorService(context: ctx)
            let finding = doctor.diagnose().findings.first { $0.kind == .missingRegistryUUID }!

            try doctor.repair(finding)
            let after = try Data(contentsOf: URL(fileURLWithPath: ctx.paths.projectsRegistry))
            // Same stale finding applied twice — the double-tap / watcher-race
            // case. Converges instead of compounding.
            try doctor.repair(finding)
            #expect(try Data(contentsOf: URL(fileURLWithPath: ctx.paths.projectsRegistry)) == after)
        }
    }

    @Test func removingAVanishedRowFailsLoudlyRatherThanEmptyingTheList() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let alive = try Self.makeProjectDir(projectsRoot, slug: "alive")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alive", rootPath: alive))
            let finding = ProjectDoctorFinding(
                id: "deadRootPath:/nope", kind: .deadRootPath, severity: .high,
                title: "t", detail: "d", repair: .removeRegistryRow(path: "/nope")
            )
            #expect(throws: ProjectDoctorError.rowVanished("/nope")) {
                try ProjectDoctorService(context: ctx).repair(finding)
            }
            #expect(Self.registryRows(ctx).count == 1)
        }
    }
}
