import Testing
import Foundation
@testable import ScarfCore

/// R2's doctor-trust fixes: the guards that decide whether a repair is
/// allowed to touch a file at all.
///
/// Every case here shares one shape — an agent-written `project.json` or a
/// hand-edited `projects.json` says something the doctor used to believe,
/// and believing it damaged a project the user never asked about. The
/// assertions are about what is NOT written.
@Suite struct ProjectDoctorTrustTests {

    private typealias Fixture = ProjectDoctorServiceTests

    private static func adoptFinding(
        _ ctx: ServerContext, path: String
    ) -> ProjectDoctorFinding? {
        ProjectDoctorService(context: ctx).diagnose().findings.first {
            $0.id == "orphanProjectDir:\(ProjectIdentity.normalizedPath(path))"
        }
    }

    // MARK: - H4: the name that will actually land

    @Test("an orphan whose RECORD name collides is not offered for adoption")
    func adoptionGuardsTheRecordName() throws {
        try Fixture.withTempHome { ctx, projectsRoot in
            // A listed project called "Shared".
            let listed = try Fixture.makeProjectDir(projectsRoot, slug: "listed")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Shared", rootPath: listed))

            // An unlisted folder whose BASENAME is unique but whose record
            // says "Shared" — and `indexInRegistry` writes `record.name`.
            let orphan = try Fixture.makeProjectDir(projectsRoot, slug: "orphan")
            let record = ScarfProject(name: "Shared", rootPath: orphan)
            let data = try JSONEncoder().encode(record)
            try Fixture.write(
                String(data: data, encoding: .utf8)!,
                to: ProjectStore.recordPath(forProjectPath: orphan)
            )

            let finding = Self.adoptFinding(ctx, path: orphan)
            #expect(finding != nil, "the orphan should still be reported")
            #expect(
                finding?.repair == nil,
                "adoption was offered even though it would list a second “Shared”"
            )
            #expect(finding?.detail.contains("“Shared”") == true)

            // And the repair itself refuses if it is somehow reached.
            let forced = ProjectDoctorFinding(
                id: "x", kind: .orphanProjectDir, severity: .medium, title: "t", detail: "d",
                path: orphan, repair: .adoptOrphan(path: orphan, name: "orphan")
            )
            #expect(throws: ProjectDoctorError.nameTaken("Shared")) {
                try ProjectDoctorService(context: ctx).repair(forced)
            }
            #expect(Fixture.registryRows(ctx).count == 1)
        }
    }

    // MARK: - M4: a record that claims another project's path

    @Test("a record declaring a DIFFERENT rootPath is refused, not followed")
    func adoptionRefusesAMismatchedRootPath() throws {
        try Fixture.withTempHome { ctx, projectsRoot in
            let victim = try Fixture.makeProjectDir(projectsRoot, slug: "victim")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Victim", rootPath: victim))
            let victimRecordBefore = try Data(
                contentsOf: URL(fileURLWithPath: ProjectStore.recordPath(forProjectPath: victim))
            )

            // The orphan's own record points at the victim's folder.
            let orphan = try Fixture.makeProjectDir(projectsRoot, slug: "orphan")
            let record = ScarfProject(name: "Orphan", rootPath: victim)
            try Fixture.write(
                String(data: try JSONEncoder().encode(record), encoding: .utf8)!,
                to: ProjectStore.recordPath(forProjectPath: orphan)
            )

            let forced = ProjectDoctorFinding(
                id: "x", kind: .orphanProjectDir, severity: .medium, title: "t", detail: "d",
                path: orphan, repair: .adoptOrphan(path: orphan, name: "orphan")
            )
            #expect(
                throws: ProjectDoctorError.recordPathMismatch(path: orphan, declared: victim)
            ) {
                try ProjectDoctorService(context: ctx).repair(forced)
            }

            // The victim is untouched: same record bytes, still one row.
            let after = try Data(
                contentsOf: URL(fileURLWithPath: ProjectStore.recordPath(forProjectPath: victim))
            )
            #expect(after == victimRecordBefore)
            #expect(Fixture.registryRows(ctx).count == 1)
        }
    }

    @Test("re-indexing from a record that claims another path is refused too")
    func reindexRefusesAMismatchedRootPath() throws {
        try Fixture.withTempHome { ctx, projectsRoot in
            let alpha = try Fixture.makeProjectDir(projectsRoot, slug: "alpha")
            let beta = try Fixture.makeProjectDir(projectsRoot, slug: "beta")
            try Fixture.writeRegistryJSON(ctx, """
                {"projects": [{"name": "Alpha", "path": "\(alpha)"}]}
                """)
            let record = ScarfProject(name: "Alpha", rootPath: beta)
            try Fixture.write(
                String(data: try JSONEncoder().encode(record), encoding: .utf8)!,
                to: ProjectStore.recordPath(forProjectPath: alpha)
            )

            let forced = ProjectDoctorFinding(
                id: "x", kind: .missingRegistryUUID, severity: .medium, title: "t", detail: "d",
                path: alpha, repair: .reindexRegistryFromRecord(path: alpha)
            )
            #expect(throws: ProjectDoctorError.recordPathMismatch(path: alpha, declared: beta)) {
                try ProjectDoctorService(context: ctx).repair(forced)
            }
            // No row was added for beta, and alpha's row is untouched.
            let rows = Fixture.registryRows(ctx)
            #expect(rows.count == 1)
            #expect(rows.first?.uuid == nil)
        }
    }

    // MARK: - M5: valid JSON is not a record

    @Test("a project.json that is valid JSON but not a record is never overwritten")
    func adoptionRequiresADecodableRecord() throws {
        try Fixture.withTempHome { ctx, projectsRoot in
            // A listed sibling is what puts this directory in scan range —
            // a local context's `defaultProjectsRoot` is the real ~/Projects.
            let listed = try Fixture.makeProjectDir(projectsRoot, slug: "listed")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Listed", rootPath: listed))

            let orphan = try Fixture.makeProjectDir(projectsRoot, slug: "wip")
            let note = #"{"note": "wip"}"#
            try Fixture.write(note, to: ProjectStore.recordPath(forProjectPath: orphan))
            // A manifest makes it look like a project either way, so the
            // decision rests entirely on how the record is classified.
            try Fixture.write("{}", to: orphan + "/.scarf/manifest.json")

            let report = ProjectDoctorService(context: ctx).diagnose()
            #expect(
                report.findings.contains {
                    $0.kind == .malformedSidecar
                        && $0.path == ProjectStore.recordPath(forProjectPath: orphan)
                },
                "the unreadable record should be reported"
            )
            #expect(
                !report.findings.contains { if case .adoptOrphan = $0.repair { return true } else { return false } },
                "adoption would have derived a record straight over the user's file"
            )

            let forced = ProjectDoctorFinding(
                id: "x", kind: .orphanProjectDir, severity: .medium, title: "t", detail: "d",
                path: orphan, repair: .adoptOrphan(path: orphan, name: "wip")
            )
            #expect(throws: (any Error).self) {
                try ProjectDoctorService(context: ctx).repair(forced)
            }
            let onDisk = try String(
                contentsOfFile: ProjectStore.recordPath(forProjectPath: orphan), encoding: .utf8
            )
            #expect(onDisk == note, "the user's file was rewritten")
        }
    }

    // MARK: - M6: one folder, one row

    @Test("indexing a trailing-slash spelling updates the row instead of appending")
    func indexInRegistryMatchesNormalizedPaths() throws {
        try Fixture.withTempHome { ctx, projectsRoot in
            let dir = try Fixture.makeProjectDir(projectsRoot, slug: "alpha")
            try Fixture.writeRegistryJSON(ctx, """
                {"projects": [{"name": "Alpha", "path": "\(dir)/"}]}
                """)

            let id = UUID()
            try ProjectStore(context: ctx)
                .indexInRegistry(ScarfProject(id: id, name: "Alpha", rootPath: dir))

            let rows = Fixture.registryRows(ctx)
            #expect(rows.count == 1, "a phantom second row was appended for the same folder")
            #expect(rows.first?.uuid == id)
            #expect(rows.first?.path == dir + "/", "the user's spelling should be left alone")
        }
    }

    // MARK: - M7: remove exactly what was proved dead

    @Test("two spellings of one dead folder are ONE finding that removes both rows")
    func deadRootPathRemovesEveryRowAtThatFolder() throws {
        try Fixture.withTempHome { ctx, projectsRoot in
            let gone = projectsRoot + "/gone"
            let alive = try Fixture.makeProjectDir(projectsRoot, slug: "alive")
            try Fixture.writeRegistryJSON(ctx, """
                {"projects": [
                  {"name": "Gone", "path": "\(gone)"},
                  {"name": "Gone Too", "path": "\(gone)/"},
                  {"name": "Alive", "path": "\(alive)"}
                ]}
                """)

            let dead = ProjectDoctorService(context: ctx).diagnose().findings
                .filter { $0.kind == .deadRootPath }
            #expect(dead.count == 1, "one dead folder should be one finding")
            #expect(dead.first?.affectedRowCount == 2)
            #expect(dead.first?.confirmTitle == "Remove 2 entries from the list?")
            #expect(dead.first?.confirmMessage.contains("2 entries") == true)

            try ProjectDoctorService(context: ctx).repair(dead[0])

            let rows = Fixture.registryRows(ctx)
            #expect(rows.map(\.name) == ["Alive"])
        }
    }

    @Test("the single-row case keeps its name in the confirm copy")
    func deadRootPathSingleRowCopy() throws {
        try Fixture.withTempHome { ctx, projectsRoot in
            let gone = projectsRoot + "/gone"
            try Fixture.writeRegistryJSON(ctx, """
                {"projects": [{"name": "Gone", "path": "\(gone)"}]}
                """)
            let dead = ProjectDoctorService(context: ctx).diagnose().findings
                .first { $0.kind == .deadRootPath }
            #expect(dead?.affectedRowCount == 1)
            #expect(dead?.confirmTitle == "Remove “Gone” from the list?")
            #expect(dead?.confirmMessage.hasPrefix("This removes the entry") == true)

            // Removing the only row legitimately empties the list.
            try ProjectDoctorService(context: ctx).repair(dead!)
            #expect(Fixture.registryRows(ctx).isEmpty)
        }
    }

    @Test("removing one dead row of several does not need the empty-write bypass")
    func deadRootPathRemovalKeepsSurvivors() throws {
        try Fixture.withTempHome { ctx, projectsRoot in
            let gone = projectsRoot + "/gone"
            let alive = try Fixture.makeProjectDir(projectsRoot, slug: "alive")
            try Fixture.writeRegistryJSON(ctx, """
                {"projects": [
                  {"name": "Gone", "path": "\(gone)"},
                  {"name": "Alive", "path": "\(alive)"}
                ]}
                """)
            let dead = ProjectDoctorService(context: ctx).diagnose().findings
                .first { $0.kind == .deadRootPath }
            try ProjectDoctorService(context: ctx).repair(dead!)
            #expect(Fixture.registryRows(ctx).map(\.name) == ["Alive"])
        }
    }

    @Test("a removal that matches nothing throws rather than rewriting the file")
    func removalOfAVanishedRowThrows() throws {
        try Fixture.withTempHome { ctx, projectsRoot in
            let alive = try Fixture.makeProjectDir(projectsRoot, slug: "alive")
            try ProjectStore(context: ctx).save(ScarfProject(name: "Alive", rootPath: alive))
            let forced = ProjectDoctorFinding(
                id: "x", kind: .deadRootPath, severity: .high, title: "t", detail: "d",
                path: "/nope", repair: .removeRegistryRow(path: "/nope")
            )
            #expect(throws: ProjectDoctorError.rowVanished("/nope")) {
                try ProjectDoctorService(context: ctx).repair(forced)
            }
            #expect(Fixture.registryRows(ctx).count == 1)
        }
    }

    // MARK: - M9: the scan never lists a home directory

    @Test("a tilde home never turns /home/<user> into a scan root")
    func tildeHomeDoesNotScanTheUsersHome() {
        // What an SSH context actually reports: an unexpanded `~/.hermes`
        // home with absolute rows underneath a real remote home.
        let roots = ProjectDoctorService.scanRoots(
            rowPaths: ["/home/alan/soloproject", "/home/alan/work/beta"],
            home: "~/.hermes",
            defaultProjectsRoot: "~/projects"
        )
        #expect(!roots.contains("/home/alan"), "the user's whole home became a scan root")
        #expect(roots.contains("/home/alan/work"))
        #expect(!roots.contains("~/projects"), "a tilde root can't be compared to absolute rows")
    }

    @Test("a macOS remote home is refused on the same rule")
    func tildeHomeRefusesUsersDirectoryOnMacOS() {
        let roots = ProjectDoctorService.scanRoots(
            rowPaths: ["/Users/alan/proj"], home: "~/.hermes", defaultProjectsRoot: "~/projects"
        )
        #expect(roots.isEmpty)
    }

    @Test("a local absolute home keeps scanning its projects directory")
    func absoluteHomeIsUnchanged() {
        let roots = ProjectDoctorService.scanRoots(
            rowPaths: ["/Users/alan/.hermes-test/projects/alpha"],
            home: "/Users/alan/.hermes-test",
            defaultProjectsRoot: "/Users/alan/.hermes-test/projects"
        )
        #expect(roots == ["/Users/alan/.hermes-test/projects"])
    }

    @Test("the home directory itself is still excluded when it IS comparable")
    func absoluteHomeExcludesTheHermesHome() {
        let roots = ProjectDoctorService.scanRoots(
            rowPaths: ["/Users/alan/.hermes/alpha"],
            home: "/Users/alan/.hermes",
            defaultProjectsRoot: "/Users/alan/.hermes/projects"
        )
        #expect(!roots.contains("/Users/alan/.hermes"))
        #expect(roots == ["/Users/alan/.hermes/projects"])
    }
}
