import Testing
import Foundation
import ScarfCore
@testable import scarf

/// Covers `ProjectScaffolder`'s Phase-1 addition: minting a stable UUID,
/// writing the canonical `.scarf/project.json` record, and indexing the
/// project into the registry with that UUID.
///
/// Each test runs against an isolated temp Hermes home (so the registry
/// write lands in a tmpdir, never the developer's real
/// `~/.hermes/scarf/projects.json`) plus a temp parent directory for the
/// scaffolded tree.
@Suite struct ProjectScaffolderTests {

    static func withTempHomeAndParent(
        _ body: (ServerContext, _ parentDir: String) throws -> Void
    ) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-scaffolder-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let parent = home.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try body(ServerContext.local(home: home), parent.path)
    }

    @Test func scaffoldMintsUUIDAndWritesCanonicalRecord() throws {
        try Self.withTempHomeAndParent { ctx, parent in
            let entry = try ProjectScaffolder(context: ctx).scaffold(
                name: "My Project",
                slug: "my-project",
                parentDir: parent,
                description: "A scratch project"
            )

            // The returned entry carries a minted UUID.
            #expect(entry.uuid != nil)

            // The canonical record exists and matches the entry.
            let store = ProjectStore(context: ctx)
            let record = store.load(projectPath: entry.path)
            #expect(record != nil)
            #expect(record?.id == entry.uuid)
            #expect(record?.name == "My Project")
            #expect(record?.rootPath == entry.path)
            // One host binding for the scaffolding server.
            #expect(record?.hostBindings.count == 1)
            #expect(record?.hostBindings.first?.serverId == ctx.id.uuidString)
            // Scratch projects ship no template / bindings.
            #expect(record?.templateLockRef == nil)
            #expect(record?.cronJobIds.isEmpty == true)
            #expect(record?.secretsScope.isEmpty == true)
        }
    }

    @Test func scaffoldIndexesRegistryWithUUID() throws {
        try Self.withTempHomeAndParent { ctx, parent in
            let entry = try ProjectScaffolder(context: ctx).scaffold(
                name: "Indexed",
                slug: "indexed",
                parentDir: parent,
                description: nil
            )
            let registry = ProjectDashboardService(context: ctx).loadRegistry()
            let row = registry.projects.first { $0.path == entry.path }
            #expect(row != nil)
            #expect(row?.uuid == entry.uuid)
            #expect(row?.name == "Indexed")
        }
    }

    @Test func scaffoldStillWritesDashboardAndAgentsMd() throws {
        try Self.withTempHomeAndParent { ctx, parent in
            // Pin a pre-v0.16 host: the block path (#142 gates it).
            HermesVersionCache.shared.primeForTesting(.parseLine("Hermes Agent v0.15.2"), for: ctx)
            let entry = try ProjectScaffolder(context: ctx).scaffold(
                name: "Files",
                slug: "files",
                parentDir: parent,
                description: nil
            )
            let fm = FileManager.default
            #expect(fm.fileExists(atPath: entry.path + "/.scarf/dashboard.json"))
            #expect(fm.fileExists(atPath: entry.path + "/.scarf/project.json"))
            // AGENTS.md got its managed block populated via refresh().
            let agents = try String(contentsOfFile: entry.path + "/AGENTS.md", encoding: .utf8)
            #expect(agents.contains(ProjectContextBlock.beginMarker))
            #expect(agents.contains("\"Files\""))
        }
    }

    /// #142: a host that takes HERMES_ENVIRONMENT_HINT gets no stub
    /// AGENTS.md at all — the context rides the chat spawn instead.
    @Test func scaffoldOnAnEnvironmentHintHostWritesNoAgentsMd() throws {
        try Self.withTempHomeAndParent { ctx, parent in
            HermesVersionCache.shared.primeForTesting(.parseLine("Hermes Agent v0.16.0"), for: ctx)
            let entry = try ProjectScaffolder(context: ctx).scaffold(
                name: "Hinted",
                slug: "hinted",
                parentDir: parent,
                description: nil
            )
            let fm = FileManager.default
            #expect(fm.fileExists(atPath: entry.path + "/.scarf/dashboard.json"))
            #expect(fm.fileExists(atPath: entry.path + "/.scarf/project.json"))
            #expect(!fm.fileExists(atPath: entry.path + "/AGENTS.md"))
        }
    }
}
