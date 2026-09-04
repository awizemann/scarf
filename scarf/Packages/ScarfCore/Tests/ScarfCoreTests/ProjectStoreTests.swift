import Testing
import Foundation
@testable import ScarfCore

/// Disk-integration coverage for `ProjectStore`: canonical record
/// round-trip, facet derivation from existing on-disk state, registry
/// UUID back-fill, and additive/idempotent migration. Each test runs
/// against a fresh per-test temp Hermes home injected via
/// `ServerContext.local(home:)`, so reads/writes never touch the
/// developer's real `~/.hermes`.
@Suite struct ProjectStoreTests {

    /// Run `body` against a `.local` context rooted at a unique temp
    /// home, with a `projects/` subdir for project trees. Cleaned up
    /// afterwards.
    static func withTempHome(_ body: (ServerContext, _ projectsRoot: String) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-projectstore-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let projectsRoot = home.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try body(ServerContext.local(home: home), projectsRoot.path)
    }

    /// Create `<projectsRoot>/<slug>/.scarf/` and return the project dir.
    static func makeProjectDir(_ projectsRoot: String, slug: String) throws -> String {
        let dir = projectsRoot + "/" + slug
        try FileManager.default.createDirectory(atPath: dir + "/.scarf", withIntermediateDirectories: true)
        return dir
    }

    static func write(_ contents: String, to path: String) throws {
        try contents.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Record round-trip

    @Test func saveWritesRecordAndIndexesRegistry() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "alpha")
            let store = ProjectStore(context: ctx)
            let project = ScarfProject(name: "Alpha", rootPath: dir, board: "scarf:alpha")
            try store.save(project)

            // Canonical record landed.
            let loaded = store.load(projectPath: dir)
            #expect(loaded?.id == project.id)
            #expect(loaded?.name == "Alpha")
            #expect(loaded?.board == "scarf:alpha")

            // Registry index carries the UUID.
            let registry = ProjectDashboardService(context: ctx).loadRegistry()
            let entry = registry.projects.first { $0.path == dir }
            #expect(entry != nil)
            #expect(entry?.uuid == project.id)
        }
    }

    @Test func loadReturnsNilWhenRecordMissing() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "ghost")
            #expect(ProjectStore(context: ctx).load(projectPath: dir) == nil)
        }
    }

    // MARK: - Derive from existing facets

    @Test func deriveReadsManifestConfigCronLock() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "example")
            let scarf = dir + "/.scarf"

            // manifest.json → modelPresetID + kanbanTenant + template id/version
            try Self.write("""
            {
              "schemaVersion": 3,
              "id": "author/example",
              "name": "Example",
              "version": "1.2.3",
              "description": "x",
              "contents": { "dashboard": true, "agentsMd": true },
              "kanbanTenant": "scarf:example",
              "modelPresetID": "11111111-2222-3333-4444-555555555555"
            }
            """, to: scarf + "/manifest.json")

            // config.json → one secret (keychain ref) + one plain value
            try Self.write("""
            {
              "schemaVersion": 2,
              "templateId": "author/example",
              "values": {
                "site_url": "https://example.com",
                "api_token": "keychain://com.scarf.template.author-example/api_token:abc123"
              },
              "updatedAt": "2026-04-24T00:00:00Z"
            }
            """, to: scarf + "/config.json")

            // template.lock.json → templateLockRef + memory block id
            try Self.write("""
            {
              "template_id": "author/example",
              "template_version": "1.2.3",
              "template_name": "Example",
              "installed_at": "2026-04-24T00:00:00Z",
              "project_files": [],
              "skills_files": [],
              "cron_job_names": ["[tmpl:author/example] nightly"],
              "memory_block_id": "scarf-template:author/example"
            }
            """, to: scarf + "/template.lock.json")

            // ~/.hermes/cron/jobs.json → one [tmpl:] job for this template
            try FileManager.default.createDirectory(atPath: ctx.paths.home + "/cron", withIntermediateDirectories: true)
            try Self.write("""
            {
              "jobs": [
                {
                  "id": "job-nightly",
                  "name": "[tmpl:author/example] nightly",
                  "prompt": "do it",
                  "schedule": { "kind": "cron", "expression": "0 0 * * *" },
                  "enabled": true,
                  "state": "scheduled"
                },
                {
                  "id": "job-unrelated",
                  "name": "some other job",
                  "prompt": "p",
                  "schedule": { "kind": "cron", "expression": "0 1 * * *" },
                  "enabled": true,
                  "state": "scheduled"
                }
              ]
            }
            """, to: ctx.paths.cronJobsJSON)

            let entry = ProjectEntry(name: "Example", path: dir)
            let derived = ProjectStore(context: ctx).derive(from: entry)

            #expect(derived.name == "Example")
            #expect(derived.rootPath == dir)
            #expect(derived.modelPresetId == "11111111-2222-3333-4444-555555555555")
            #expect(derived.board == "scarf:example")
            #expect(derived.templateLockRef == scarf + "/template.lock.json")
            #expect(derived.memoryNamespace == "scarf-template:author/example")
            // Only the matching [tmpl:] job is attributed.
            #expect(derived.cronJobIds == ["job-nightly"])
            // SECRET-SAFE: only the secret KEY name, never the value.
            #expect(derived.secretsScope == ["api_token"])
            #expect(!derived.secretsScope.contains("site_url"))
            // One host binding, this server.
            #expect(derived.hostBindings.count == 1)
            #expect(derived.hostBindings.first?.serverId == ctx.id.uuidString)
        }
    }

    @Test func deriveBareProjectIsEmpty() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "bare")
            let derived = ProjectStore(context: ctx).derive(from: ProjectEntry(name: "Bare", path: dir))
            #expect(derived.modelPresetId == nil)
            #expect(derived.board == nil)
            #expect(derived.templateLockRef == nil)
            #expect(derived.cronJobIds.isEmpty)
            #expect(derived.secretsScope.isEmpty)
            #expect(derived.memoryNamespace == nil)
        }
    }

    @Test func deriveReusesEntryUUID() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "stable")
            let id = UUID()
            let derived = ProjectStore(context: ctx)
                .derive(from: ProjectEntry(name: "Stable", path: dir, uuid: id))
            #expect(derived.id == id)
        }
    }

    // MARK: - Sentinel manifest (one shared suppression rule)

    /// A `KanbanTenantResolver`-minted manifest carries no template
    /// identity — `templateInfo` (the single reader both app targets use)
    /// suppresses it, while a real installed template reads through.
    @Test func templateInfoSuppressesSentinelManifest() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "sentinel")
            let store = ProjectStore(context: ctx)
            try Self.write(
                #"{"id":"\#(ProjectManifestProjection.sentinelIDPrefix)sentinel","version":"\#(ProjectManifestProjection.sentinelVersion)"}"#,
                to: dir + "/.scarf/manifest.json"
            )
            #expect(store.templateInfo(projectPath: dir) == nil)

            try Self.write(#"{"id":"acme/tracker","version":"1.2.0"}"#, to: dir + "/.scarf/manifest.json")
            let info = store.templateInfo(projectPath: dir)
            #expect(info?.id == "acme/tracker")
            #expect(info?.version == "1.2.0")
        }
    }

    // MARK: - Stable identity (Phase 3)

    /// The derived value is a well-formed UUID: RFC 9562 version 8 (custom)
    /// with the RFC 4122 variant bits, so it round-trips through every
    /// `UUID`/string boundary it crosses (registry JSON, `[proj:<uuid>]`
    /// cron tags, grant keys). Also pins the wire format: these bytes are
    /// frozen, and a change to the namespace or digest breaks this test
    /// deliberately.
    @Test func derivedIDIsAWellFormedUUIDv8() throws {
        let id = ProjectIdentity.deterministicID(forProjectPath: "/Users/x/Projects/alpha")
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        #expect(bytes[6] >> 4 == 8)          // version 8
        #expect(bytes[8] & 0xC0 == 0x80)     // variant 10xx
        #expect(UUID(uuidString: id.uuidString) == id)
        // Frozen: the id for a given path never changes across versions.
        #expect(id == ProjectIdentity.deterministicID(forProjectPath: "/Users/x/Projects/alpha"))
    }

    /// Two SSH hosts must never derive the same id. They share a default
    /// projects root (`~/projects`, unexpanded), so without the host salt
    /// same-named projects on unrelated hosts collide — and a persisted
    /// collision lets a fleet apply write to the wrong machine.
    @Test func derivedIDIsSaltedPerHost() throws {
        let path = "~/projects/api"
        let hostA = ServerContext(id: UUID(), displayName: "A", kind: .ssh(SSHConfig(host: "a.example", user: "root")))
        let hostB = ServerContext(id: UUID(), displayName: "B", kind: .ssh(SSHConfig(host: "b.example", user: "root")))
        let a = ProjectIdentity.deterministicID(forProjectPath: path, hostKey: ProjectIdentity.hostKey(for: hostA))
        let b = ProjectIdentity.deterministicID(forProjectPath: path, hostKey: ProjectIdentity.hostKey(for: hostB))
        #expect(a != b)
        // Same host, same path — still stable.
        #expect(a == ProjectIdentity.deterministicID(forProjectPath: path, hostKey: ProjectIdentity.hostKey(for: hostA)))
        // The local Mac's key is empty, and differs from any remote's.
        #expect(ProjectIdentity.hostKey(for: .local).isEmpty)
        #expect(ProjectIdentity.deterministicID(forProjectPath: path) != a)
        // A different user or port on the same host is a different host key.
        let hostAAlt = ServerContext(id: UUID(), displayName: "A", kind: .ssh(SSHConfig(host: "a.example", user: "deploy")))
        #expect(ProjectIdentity.hostKey(for: hostAAlt) != ProjectIdentity.hostKey(for: hostA))
    }

    /// The host key is a FROZEN wire format, so its canonicalization had to
    /// be settled before release: one machine spelled two ways must not
    /// derive two identities for the same project, and two different
    /// accounts must not collapse into one (an id collision across accounts
    /// is the fleet hazard the salt exists to prevent).
    @Test func hostKeyCanonicalizesTheSpellingsOfOneHost() throws {
        func key(_ host: String, user: String? = "deploy", port: Int? = nil) -> String {
            ProjectIdentity.hostKey(for: ServerContext(
                id: UUID(), displayName: "h",
                kind: .ssh(SSHConfig(host: host, user: user, port: port))
            ))
        }

        let canonical = key("a.example")
        #expect(canonical == "deploy@a.example:22")
        // Surrounding whitespace is a text-field artefact, never identity.
        #expect(key("  a.example  ") == canonical)
        #expect(key("a.example", user: " deploy ") == canonical)
        // Omitted port means SSH's own default — genuinely the same host.
        #expect(key("a.example", port: 22) == canonical)
        #expect(key("a.example", port: 2222) != canonical)
        // NOTHING is case-folded. `host` is as often an ~/.ssh/config alias
        // as a DNS name, and OpenSSH matches `Host` patterns
        // case-sensitively, so `Prod` and `prod` may be two machines;
        // usernames are case-sensitive too. Folding either would trade a
        // cheap extra derived id for an id COLLISION across hosts — the
        // fleet-writes-to-the-wrong-machine hazard this salt exists for.
        #expect(key("A.Example") != canonical)
        #expect(key("a.example.") != canonical)
        #expect(key("a.example", user: "Deploy") != canonical)
        // An omitted user stays empty rather than being invented.
        #expect(key("a.example", user: nil) == "@a.example:22")
        #expect(key("a.example", user: "") == "@a.example:22")
        // The local Mac is still the empty key.
        #expect(ProjectIdentity.hostKey(for: .local).isEmpty)
    }

    /// Lexical normalization: equivalent spellings of one path agree, and a
    /// remote `~`-rooted relative path is never resolved against the local
    /// process CWD.
    @Test func derivedIDNormalizesPathSpellings() throws {
        let canonical = ProjectIdentity.deterministicID(forProjectPath: "/Users/x/Projects/alpha")
        #expect(ProjectIdentity.deterministicID(forProjectPath: "/Users/x/Projects/alpha/") == canonical)
        #expect(ProjectIdentity.deterministicID(forProjectPath: "/Users//x/Projects/alpha") == canonical)
        #expect(ProjectIdentity.deterministicID(forProjectPath: "/Users/x/./Projects/alpha") == canonical)
        #expect(ProjectIdentity.deterministicID(forProjectPath: "/Users/x/Projects/beta/../alpha") == canonical)
        // Case is load-bearing (no folding), and unrelated paths differ.
        #expect(ProjectIdentity.deterministicID(forProjectPath: "/Users/x/Projects/Alpha") != canonical)
        // Remote tilde paths keep their `~` root rather than becoming absolute.
        let remote = ProjectIdentity.deterministicID(forProjectPath: "~/projects/api")
        #expect(remote == ProjectIdentity.deterministicID(forProjectPath: "~/projects/./api/"))
        #expect(remote != ProjectIdentity.deterministicID(forProjectPath: "/projects/api"))
    }

    /// The regression this phase exists for: an UNPERSISTED project must
    /// yield the same id no matter who derives it, or how often.
    @Test func deriveIsStableForUnpersistedProject() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "unpersisted")
            let entry = ProjectEntry(name: "Unpersisted", path: dir)
            let store = ProjectStore(context: ctx)
            let first = store.derive(from: entry).id
            #expect(store.derive(from: entry).id == first)
            // A separate store instance (a different caller, another
            // launch) must agree too.
            #expect(ProjectStore(context: ctx).derive(from: entry).id == first)
            #expect(first == ProjectIdentity.deterministicID(forProjectPath: dir))
        }
    }

    /// No double-mint across the three observers of an unmigrated row:
    /// `list()`, a bare `derive(from:)` (what the render-only
    /// `ProjectAgentContextService.refresh` does), and the persisting
    /// `derive()` migration. The id the readers saw is the id that lands.
    @Test func deriveListAndMigrationAgreeOnOneID() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "observed")
            let entry = ProjectEntry(name: "Observed", path: dir)
            try ProjectDashboardService(context: ctx).saveRegistry(ProjectRegistry(projects: [entry]))

            let store = ProjectStore(context: ctx)
            let listed = store.list().first { $0.rootPath == dir }?.id
            let refreshed = store.derive(from: entry).id
            #expect(listed == refreshed)

            #expect(store.derive() == 1)
            #expect(store.load(projectPath: dir)?.id == listed)
            let row = ProjectDashboardService(context: ctx).loadRegistry().projects.first { $0.path == dir }
            #expect(row?.uuid == listed)
        }
    }

    /// A registry row that loses its `uuid` (bad agent write, salvaged
    /// decode) recovers the id it had rather than detaching from its
    /// record — the id is a function of the path.
    @Test func lostRegistryUUIDIsRederivedNotReminted() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "amnesiac")
            let dashboard = ProjectDashboardService(context: ctx)
            let store = ProjectStore(context: ctx)
            try dashboard.saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "Amnesiac", path: dir)]))
            #expect(store.derive() == 1)
            let original = store.load(projectPath: dir)?.id

            // Row rewritten without the uuid, record removed.
            try dashboard.saveRegistry(ProjectRegistry(projects: [ProjectEntry(name: "Amnesiac", path: dir)]))
            try FileManager.default.removeItem(atPath: ProjectStore.recordPath(forProjectPath: dir))

            #expect(store.derive(from: ProjectEntry(name: "Amnesiac", path: dir)).id == original)
        }
    }

    /// An ASSERTED id (randomly minted by the scaffolder/installer, frozen
    /// into `project.json`) always beats the path-derived one — through
    /// `derive(from:)`, through `list()`, and through the `derive()`
    /// migration's registry back-fill. The derived id is an interim value,
    /// never a claim that overrides one somebody made.
    @Test func mintedIDAlwaysBeatsDerivedID() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "asserted")
            let store = ProjectStore(context: ctx)
            let minted = ScarfProject(name: "Asserted", rootPath: dir)
            #expect(minted.id != ProjectIdentity.deterministicID(forProjectPath: dir))
            try store.writeRecordForTest(minted)
            // Registry row has no uuid — the lossy-write case.
            try ProjectDashboardService(context: ctx).saveRegistry(
                ProjectRegistry(projects: [ProjectEntry(name: "Asserted", path: dir)])
            )

            #expect(store.list().first { $0.rootPath == dir }?.id == minted.id)
            #expect(store.derive() == 1)
            let row = ProjectDashboardService(context: ctx).loadRegistry().projects.first { $0.path == dir }
            #expect(row?.uuid == minted.id)
            // And with the uuid restored, derive agrees with the record.
            #expect(store.derive(from: ProjectEntry(name: "Asserted", path: dir, uuid: minted.id)).id == minted.id)
        }
    }

    /// `loadOrDerive` honours the registry row's uuid when the record is
    /// missing, so a path-only caller (iOS chat-start) renders the same
    /// identity the Mac does instead of the interim derived one.
    @Test func loadOrDeriveHonoursRegistryUUID() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "pathonly")
            let id = UUID()
            try ProjectDashboardService(context: ctx).saveRegistry(
                ProjectRegistry(projects: [ProjectEntry(name: "PathOnly", path: dir, uuid: id)])
            )
            let store = ProjectStore(context: ctx)
            #expect(store.loadOrDerive(projectPath: dir, name: "PathOnly").id == id)
            // No registry row at all — falls back to the derived id.
            let orphan = try Self.makeProjectDir(projectsRoot, slug: "orphan")
            #expect(store.loadOrDerive(projectPath: orphan, name: "Orphan").id
                == ProjectIdentity.deterministicID(forProjectPath: orphan))
            // And it stays read-only.
            #expect(store.load(projectPath: dir) == nil)
        }
    }

    /// Deriving is pure: no record, no registry row, no directory gets
    /// written — the render-only refresh path must not churn files.
    @Test func deriveWritesNothing() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "quiet")
            let store = ProjectStore(context: ctx)
            _ = store.derive(from: ProjectEntry(name: "Quiet", path: dir))
            #expect(store.load(projectPath: dir) == nil)
            #expect(ProjectDashboardService(context: ctx).loadRegistry().projects.isEmpty)
        }
    }

    /// Distinct paths get distinct ids; the same path is stable across
    /// name changes (a rename must never change the identifier).
    @Test func derivedIDKeysOnPathNotName() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dirA = try Self.makeProjectDir(projectsRoot, slug: "one")
            let dirB = try Self.makeProjectDir(projectsRoot, slug: "two")
            let store = ProjectStore(context: ctx)
            #expect(store.derive(from: ProjectEntry(name: "X", path: dirA)).id
                != store.derive(from: ProjectEntry(name: "X", path: dirB)).id)
            #expect(store.derive(from: ProjectEntry(name: "Before", path: dirA)).id
                == store.derive(from: ProjectEntry(name: "After", path: dirA)).id)
            // Trailing-separator spellings of the same path agree.
            #expect(ProjectIdentity.deterministicID(forProjectPath: dirA)
                == ProjectIdentity.deterministicID(forProjectPath: dirA + "/"))
        }
    }

    /// `indexInRegistry` matches the existing row by PATH — a project
    /// renamed in the registry gets its uuid back-filled in place, not a
    /// duplicate row appended under the new name.
    @Test func indexInRegistryMatchesByPath() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "renamed")
            let dashboard = ProjectDashboardService(context: ctx)
            try dashboard.saveRegistry(ProjectRegistry(projects: [
                ProjectEntry(name: "New Name", path: dir)
            ]))
            let store = ProjectStore(context: ctx)
            let project = ScarfProject(name: "Old Name", rootPath: dir)
            try store.save(project)

            let rows = dashboard.loadRegistry().projects
            #expect(rows.count == 1)
            #expect(rows.first?.name == "New Name")
            #expect(rows.first?.uuid == project.id)
        }
    }

    // MARK: - Migration

    @Test func migrationIsAdditiveAndIdempotent() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dirA = try Self.makeProjectDir(projectsRoot, slug: "a")
            let dirB = try Self.makeProjectDir(projectsRoot, slug: "b")
            let dashboard = ProjectDashboardService(context: ctx)
            try dashboard.saveRegistry(ProjectRegistry(projects: [
                ProjectEntry(name: "A", path: dirA),
                ProjectEntry(name: "B", path: dirB),
            ]))

            let store = ProjectStore(context: ctx)
            // First run migrates both rows.
            #expect(store.derive() == 2)
            #expect(store.load(projectPath: dirA) != nil)
            #expect(store.load(projectPath: dirB) != nil)
            let after = dashboard.loadRegistry()
            #expect(after.projects.allSatisfy { $0.uuid != nil })

            // Second run is a no-op — records + UUIDs already present.
            #expect(store.derive() == 0)
        }
    }

    @Test func migrationBackfillsUUIDWithoutRewritingExistingRecord() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dir = try Self.makeProjectDir(projectsRoot, slug: "rec")
            let store = ProjectStore(context: ctx)
            // Pre-existing canonical record, but the registry row lacks
            // the UUID (simulates a record written by a peer + a
            // legacy registry).
            let project = ScarfProject(name: "Rec", rootPath: dir)
            try store.writeRecordForTest(project)
            try ProjectDashboardService(context: ctx).saveRegistry(
                ProjectRegistry(projects: [ProjectEntry(name: "Rec", path: dir)])
            )

            #expect(store.derive() == 1)
            let entry = ProjectDashboardService(context: ctx).loadRegistry().projects.first { $0.path == dir }
            // Back-filled to the record's id (not a freshly minted one).
            #expect(entry?.uuid == project.id)
        }
    }

    // MARK: - List

    @Test func listPrefersCanonicalRecordThenDerives() throws {
        try Self.withTempHome { ctx, projectsRoot in
            let dirSaved = try Self.makeProjectDir(projectsRoot, slug: "saved")
            let dirBare = try Self.makeProjectDir(projectsRoot, slug: "barelisted")
            let store = ProjectStore(context: ctx)
            let saved = ScarfProject(name: "Saved", rootPath: dirSaved, board: "scarf:saved")
            try store.save(saved)
            try ProjectDashboardService(context: ctx).saveRegistry(ProjectRegistry(projects: [
                ProjectEntry(name: "Saved", path: dirSaved, uuid: saved.id),
                ProjectEntry(name: "Bare", path: dirBare),
            ]))

            let listed = store.list()
            #expect(listed.count == 2)
            let savedOut = listed.first { $0.rootPath == dirSaved }
            #expect(savedOut?.id == saved.id)
            #expect(savedOut?.board == "scarf:saved")
            // Bare one is derived (no record) — still appears.
            #expect(listed.contains { $0.rootPath == dirBare })
        }
    }
}

// Test-only seam: write the canonical record WITHOUT touching the
// registry, to set up the "record exists, registry stale" migration case.
extension ProjectStore {
    nonisolated func writeRecordForTest(_ project: ScarfProject) throws {
        let scarfDir = project.rootPath + "/.scarf"
        try transport.createDirectory(scarfDir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try transport.writeFile(
            ProjectStore.recordPath(forProjectPath: project.rootPath),
            data: encoder.encode(project)
        )
    }
}
