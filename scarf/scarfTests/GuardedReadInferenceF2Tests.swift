import Testing
import Foundation
import ScarfCore
@testable import scarf

/// GW-F2 — the READ side of the absent-vs-unreadable disease, one hop
/// upstream of the guarded writers GW-E1..E3 installed.
///
/// Every case here induces the failure the same way the write-side suites do:
/// a real file made genuinely unreadable (mode 0000) through a real
/// `LocalTransport`. A mock that answers honestly proves nothing, because the
/// bug was always in what the caller BELIEVED about a read that failed. The
/// 0000 cases self-skip under root.
@Suite("GW-F2 read-side inference")
struct GuardedReadInferenceF2Tests {

    private static var runningAsRoot: Bool { getuid() == 0 }

    private static func withTempDir(_ body: (String) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-f2-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try body(dir.path)
    }

    private static func chmod(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private static func write(_ contents: String, to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    }

    private static func text(_ path: String) -> String? {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    private static let realManifest = """
    {
      "schemaVersion": 3,
      "id": "alice/real-template",
      "name": "Real Template",
      "version": "2.1.0",
      "description": "A real installed template",
      "contents": {"dashboard": true, "agentsMd": true},
      "kanbanTenant": "scarf:already-minted"
    }
    """

    // MARK: - DI H1/H2 — the mint decision

    /// The read that feeds the mint decision aborts instead of answering
    /// "no tenant yet". Before: `fileExists + try? read + try? decode` said
    /// nil, a fresh slug was minted, and every task already on the existing
    /// board was orphaned.
    @Test func resolveOrMintAbortsWhenTheProjectsOwnManifestIsUnreadable() throws {
        try #require(!Self.runningAsRoot)
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "Repo", path: dir)
            let path = dir + "/.scarf/manifest.json"
            try Self.write(Self.realManifest, to: path)
            try Self.chmod(path, 0o000)

            #expect(throws: GuardedStoreError.self) {
                _ = try KanbanTenantResolver(context: .local).resolveOrMint(for: project)
            }

            try Self.chmod(path, 0o644)
            #expect(Self.text(path) == Self.realManifest, "nothing was published")
        }
    }

    /// The uniqueness set is a PROOF, not a best effort: a sibling project
    /// whose manifest cannot be read means we cannot say a candidate slug is
    /// unused, so the mint aborts rather than publishing a possible
    /// collision.
    @Test func mintAbortsWhenASiblingProjectsManifestIsUnreadable() throws {
        try #require(!Self.runningAsRoot)
        try Self.withTempDir { home in
            try Self.withTempDir { projects in
                let ctx = ServerContext.local(home: URL(fileURLWithPath: home + "/hermes"))
                let bare = projects + "/bare"
                let sibling = projects + "/sibling"
                try FileManager.default.createDirectory(
                    atPath: bare, withIntermediateDirectories: true
                )
                let siblingManifest = sibling + "/.scarf/manifest.json"
                try Self.write(Self.realManifest, to: siblingManifest)
                try Self.write("""
                {"projects": [
                  {"name": "Bare", "path": "\(bare)"},
                  {"name": "Sibling", "path": "\(sibling)"}
                ]}
                """, to: ctx.paths.projectsRegistry)
                try Self.chmod(siblingManifest, 0o000)

                let project = ProjectEntry(name: "Bare", path: bare)
                #expect(throws: GuardedStoreError.self) {
                    _ = try KanbanTenantResolver(context: ctx).resolveOrMint(for: project)
                }
                #expect(
                    !FileManager.default.fileExists(atPath: bare + "/.scarf/manifest.json"),
                    "no sentinel minted while the uniqueness set is unprovable"
                )

                try Self.chmod(siblingManifest, 0o644)
            }
        }
    }

    /// Healthy round-trip, unchanged: a bare project still mints, and a
    /// project that already has a tenant still returns it without writing.
    @Test func healthyMintAndReuseAreUnchanged() throws {
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "My Repo", path: dir)
            let resolver = KanbanTenantResolver(context: .local)
            let minted = try resolver.resolveOrMint(for: project)
            #expect(minted == "scarf:my-repo")
            let again = try resolver.resolveOrMint(for: project)
            #expect(again == minted, "idempotent")
        }
    }

    /// Display-only reads stay tolerant on purpose: nothing is written from
    /// this answer, and throwing here would break a picker over a blip.
    @Test func boundPresetIDStaysTolerantOfAFailedRead() throws {
        try #require(!Self.runningAsRoot)
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "Repo", path: dir)
            let path = dir + "/.scarf/manifest.json"
            try Self.write(Self.realManifest, to: path)
            try Self.chmod(path, 0o000)

            #expect(ProjectModelPresetBinding(context: .local).boundPresetID(for: project) == nil)

            try Self.chmod(path, 0o644)
        }
    }

    // MARK: - DI L7 — "not configurable" was a lie

    @Test func loadCachedManifestSaysCouldntReadRatherThanNotConfigurable() throws {
        try #require(!Self.runningAsRoot)
        try Self.withTempDir { dir in
            let project = ProjectEntry(name: "Repo", path: dir)
            let service = ProjectConfigService(context: .local)
            let path = ProjectConfigService.manifestCachePath(for: project)
            try Self.write(Self.realManifest, to: path)
            try Self.chmod(path, 0o000)

            #expect(throws: ProjectConfigService.ManifestCacheError.self) {
                _ = try service.loadCachedManifest(project: project)
            }

            try Self.chmod(path, 0o644)
            // A genuinely absent cache is still a plain `nil` — the state the
            // sheet legitimately renders as "not configurable".
            try FileManager.default.removeItem(atPath: path)
            #expect(try service.loadCachedManifest(project: project) == nil)
        }
    }

    // MARK: - DI H3 — the memory editor's conflict check

    /// The bug: the conflict check compared the draft's baseline against
    /// `readFile ?? ""`, so a blip presented as "the file changed to empty —
    /// reload to take the new version", and the reload-then-save published
    /// that emptiness THROUGH the guard.
    @Test func memorySaveReportsAFailedReadAsFailedNotAsAnEmptyFileConflict() async throws {
        try #require(!Self.runningAsRoot)
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-f2-mem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: base.path
            )
            try? FileManager.default.removeItem(at: base)
        }
        let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
        let path = ctx.paths.memoriesDir + "/MEMORY.md"
        try Self.write("years of the user's notes\n", to: path)
        try Self.chmod(path, 0o000)

        let vm = await MemoryViewModel(context: ctx)
        let outcome = await vm.save("my draft\n", target: .memory, baseline: "years of the user's notes\n")

        #expect(outcome != .conflict(onDisk: ""), "a blip is not an empty file on disk")
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        // And the reload the conflict banner offers refuses to hand back "".
        try Self.chmod(path, 0o644)
        #expect(Self.text(path) == "years of the user's notes\n")
    }

    @Test func memoryReloadReturnsNilRatherThanEmptinessOnAFailedRead() async throws {
        try #require(!Self.runningAsRoot)
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-f2-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: base.path
            )
            try? FileManager.default.removeItem(at: base)
        }
        let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
        let path = ctx.paths.memoriesDir + "/MEMORY.md"
        try Self.write("real prose\n", to: path)
        try Self.chmod(path, 0o000)

        let vm = await MemoryViewModel(context: ctx)
        let reloaded = await vm.reload(.memory)
        #expect(reloaded == nil)
        #expect(await vm.loadError != nil, "and the reason reaches the editor")

        try Self.chmod(path, 0o644)
        let healthy = await vm.reload(.memory)
        #expect(healthy == "real prose\n")
        #expect(await vm.loadError == nil, "a successful load clears the error — no wedge")
    }

    /// Healthy save round-trip, byte-identical: an EMPTY memory file is still
    /// a legal state and still saves.
    @Test func healthyMemorySaveAndEmptyFileStillWork() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scarf-f2-mem-ok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let ctx = ServerContext.local(home: base.appendingPathComponent("hermes"))
        let path = ctx.paths.memoriesDir + "/MEMORY.md"
        try Self.write("", to: path)

        let vm = await MemoryViewModel(context: ctx)
        #expect(await vm.save("first\n", target: .memory, baseline: "") == .saved)
        #expect(Self.text(path) == "first\n")
        #expect(await vm.save("second\n", target: .memory, baseline: "first\n") == .saved)
        #expect(Self.text(path) == "second\n")
        #expect(Self.text(path + ".bak") == "first\n", "the one-deep .bak still lands")
        // A real conflict is still a conflict.
        let conflict = await vm.save("mine\n", target: .memory, baseline: "stale\n")
        #expect(conflict == .conflict(onDisk: "second\n"))
    }
}
