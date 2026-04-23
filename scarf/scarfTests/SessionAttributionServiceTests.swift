import Testing
import Foundation
@testable import scarf

/// Exercises the v2.3 sidecar at `~/.hermes/scarf/session_project_map.json`
/// via the real `ServerContext.local`. Each test snapshots + restores
/// the file through `TestRegistryLock` (reused — the sidecar lives
/// in the same scarf/ dir as projects.json, so serialising on one
/// lock prevents both cross-suite races).
///
/// We scope the shared lock to this file's registry helper so tests
/// here don't step on the real registry either.
@Suite(.serialized) struct SessionAttributionServiceTests {

    @Test func loadOnMissingFileReturnsEmptyMap() throws {
        let snapshot = Self.snapshot()
        defer { Self.restore(snapshot) }
        Self.deleteSidecar()

        let svc = SessionAttributionService(context: .local)
        let map = svc.load()
        #expect(map.mappings.isEmpty)
        #expect(svc.projectPath(for: "anything") == nil)
        #expect(svc.sessionIDs(forProject: "/anything").isEmpty)
    }

    @Test func attributeWritesMappingAndPersists() throws {
        let snapshot = Self.snapshot()
        defer { Self.restore(snapshot) }
        Self.deleteSidecar()

        let svc = SessionAttributionService(context: .local)
        svc.attribute(sessionID: "sess-1", toProjectPath: "/proj/a")

        // Read back via a fresh service instance — confirms the
        // write actually landed on disk, not just the in-memory map.
        let fresh = SessionAttributionService(context: .local)
        #expect(fresh.projectPath(for: "sess-1") == "/proj/a")

        // updatedAt populated on write.
        let map = fresh.load()
        let ts = try #require(map.updatedAt)
        #expect(!ts.isEmpty)
    }

    @Test func attributeIsIdempotent() throws {
        let snapshot = Self.snapshot()
        defer { Self.restore(snapshot) }
        Self.deleteSidecar()

        let svc = SessionAttributionService(context: .local)
        svc.attribute(sessionID: "s", toProjectPath: "/p")
        let firstStamp = svc.load().updatedAt
        // Call again with the same pair — should short-circuit, NOT
        // bump updatedAt. We check that the timestamp didn't change
        // even if the file would have been rewritten.
        svc.attribute(sessionID: "s", toProjectPath: "/p")
        let secondStamp = svc.load().updatedAt
        #expect(firstStamp == secondStamp)
    }

    @Test func reattributeChangesMapping() throws {
        let snapshot = Self.snapshot()
        defer { Self.restore(snapshot) }
        Self.deleteSidecar()

        let svc = SessionAttributionService(context: .local)
        svc.attribute(sessionID: "s", toProjectPath: "/a")
        svc.attribute(sessionID: "s", toProjectPath: "/b")
        #expect(svc.projectPath(for: "s") == "/b")
        #expect(svc.sessionIDs(forProject: "/a").isEmpty)
        #expect(svc.sessionIDs(forProject: "/b") == ["s"])
    }

    @Test func reverseLookupReturnsAllAttributedSessions() throws {
        let snapshot = Self.snapshot()
        defer { Self.restore(snapshot) }
        Self.deleteSidecar()

        let svc = SessionAttributionService(context: .local)
        svc.attribute(sessionID: "s1", toProjectPath: "/proj")
        svc.attribute(sessionID: "s2", toProjectPath: "/proj")
        svc.attribute(sessionID: "s3", toProjectPath: "/other")

        #expect(svc.sessionIDs(forProject: "/proj") == ["s1", "s2"])
        #expect(svc.sessionIDs(forProject: "/other") == ["s3"])
        #expect(svc.sessionIDs(forProject: "/nobody").isEmpty)
    }

    @Test func forgetRemovesMapping() throws {
        let snapshot = Self.snapshot()
        defer { Self.restore(snapshot) }
        Self.deleteSidecar()

        let svc = SessionAttributionService(context: .local)
        svc.attribute(sessionID: "s", toProjectPath: "/p")
        #expect(svc.projectPath(for: "s") == "/p")

        svc.forget(sessionID: "s")
        #expect(svc.projectPath(for: "s") == nil)
        // Forget on a missing session is a no-op, not an error.
        svc.forget(sessionID: "s")
        #expect(svc.projectPath(for: "s") == nil)
    }

    @Test func corruptedFileReturnsEmptyMap() throws {
        let snapshot = Self.snapshot()
        defer { Self.restore(snapshot) }
        // Write garbage to the sidecar path and confirm the service
        // treats it as "no attributions" rather than crashing. Users
        // hand-editing the JSON shouldn't soft-brick the Sessions tab.
        let path = ServerContext.local.paths.sessionProjectMap
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "not json at all".data(using: .utf8)!.write(to: URL(fileURLWithPath: path))

        let svc = SessionAttributionService(context: .local)
        let map = svc.load()
        #expect(map.mappings.isEmpty)
    }

    // MARK: - Helpers

    /// Snapshot + restore the sidecar file (and delete if missing).
    /// Uses the shared TestRegistryLock so this suite serialises
    /// with any other registry-writing suite — both touch scarfDir.
    static func snapshot() -> (lockToken: Any, data: Data?) {
        // Re-use the ProjectTemplateTests lock implementation —
        // same NSLock gates all scarfDir writes across suites.
        let projectSnapshot = TestRegistryLock.acquireAndSnapshot()
        let path = ServerContext.local.paths.sessionProjectMap
        let sidecarData = try? Data(contentsOf: URL(fileURLWithPath: path))
        return (lockToken: projectSnapshot as Any, data: sidecarData)
    }

    static func restore(_ snapshot: (lockToken: Any, data: Data?)) {
        let path = ServerContext.local.paths.sessionProjectMap
        if let data = snapshot.data {
            try? data.write(to: URL(fileURLWithPath: path))
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
        // Release the shared lock via the existing helper.
        TestRegistryLock.restore(snapshot.lockToken as? Data)
    }

    static func deleteSidecar() {
        let path = ServerContext.local.paths.sessionProjectMap
        try? FileManager.default.removeItem(atPath: path)
    }
}
