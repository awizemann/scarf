import Testing
import Foundation
@testable import ScarfCore

/// Coverage for the session→project attribution sidecar and its
/// `resolveProjectPath` recovery seam — the source of truth that lets a
/// RESUMED / reconnected / auto-started project chat re-derive its
/// project dir (cwd) when the UI doesn't pass one in (t-24594c4a).
/// Runs against a fresh temp Hermes home so it never touches the real
/// `~/.hermes/scarf/session_project_map.json`.
@Suite struct SessionAttributionServiceTests {

    static func withTempHome(_ body: (ServerContext) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-attribution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try body(ServerContext.local(home: home))
    }

    // MARK: - attribute → projectPath round-trip (the recovery source)

    @Test func attributeThenLookupRoundTrips() throws {
        try Self.withTempHome { ctx in
            let svc = SessionAttributionService(context: ctx)
            #expect(svc.projectPath(for: "s1") == nil)
            svc.attribute(sessionID: "s1", toProjectPath: "/Projects/news")
            #expect(svc.projectPath(for: "s1") == "/Projects/news")
        }
    }

    @Test func attributeIsIdempotentAndLastWriteWins() throws {
        try Self.withTempHome { ctx in
            let svc = SessionAttributionService(context: ctx)
            svc.attribute(sessionID: "s1", toProjectPath: "/Projects/news")
            svc.attribute(sessionID: "s1", toProjectPath: "/Projects/news")  // idempotent
            #expect(svc.projectPath(for: "s1") == "/Projects/news")
            svc.attribute(sessionID: "s1", toProjectPath: "/Projects/stocker")  // re-point
            #expect(svc.projectPath(for: "s1") == "/Projects/stocker")
        }
    }

    @Test func reverseLookupAndForget() throws {
        try Self.withTempHome { ctx in
            let svc = SessionAttributionService(context: ctx)
            svc.attribute(sessionID: "a", toProjectPath: "/Projects/news")
            svc.attribute(sessionID: "b", toProjectPath: "/Projects/news")
            svc.attribute(sessionID: "c", toProjectPath: "/Projects/stocker")
            #expect(svc.sessionIDs(forProject: "/Projects/news") == ["a", "b"])
            svc.forget(sessionID: "a")
            #expect(svc.sessionIDs(forProject: "/Projects/news") == ["b"])
            #expect(svc.projectPath(for: "a") == nil)
        }
    }

    // MARK: - resolveProjectPath (the resume/reconnect/auto-start seam)

    @Test func resolveKnownPathWinsWithoutTouchingSidecar() throws {
        try Self.withTempHome { ctx in
            let svc = SessionAttributionService(context: ctx)
            // Even when the session is attributed elsewhere, a caller-known
            // path takes precedence (reconnect/auto-start pass currentProjectPath).
            svc.attribute(sessionID: "s1", toProjectPath: "/Projects/attributed")
            #expect(svc.resolveProjectPath(known: "/Projects/explicit", sessionID: "s1") == "/Projects/explicit")
            // Known path wins even with no session id at all.
            #expect(svc.resolveProjectPath(known: "/Projects/explicit", sessionID: nil) == "/Projects/explicit")
        }
    }

    @Test func resolveFallsBackToAttributionWhenKnownIsNilOrEmpty() throws {
        try Self.withTempHome { ctx in
            let svc = SessionAttributionService(context: ctx)
            svc.attribute(sessionID: "s1", toProjectPath: "/Projects/news")
            // nil known → recover via the sidecar (the RESUME path).
            #expect(svc.resolveProjectPath(known: nil, sessionID: "s1") == "/Projects/news")
            // empty / whitespace-only known is treated as "no known path".
            #expect(svc.resolveProjectPath(known: "", sessionID: "s1") == "/Projects/news")
            #expect(svc.resolveProjectPath(known: "   ", sessionID: "s1") == "/Projects/news")
        }
    }

    @Test func resolveReturnsRealKnownPathVerbatim() throws {
        try Self.withTempHome { ctx in
            let svc = SessionAttributionService(context: ctx)
            // A real path is returned unchanged — including a legitimate
            // trailing-space directory name (only the emptiness test trims).
            #expect(svc.resolveProjectPath(known: "/Projects/has space ", sessionID: nil) == "/Projects/has space ")
        }
    }

    // MARK: - Pruning fires on the WRITE path (t-682b7f47)

    /// Seed the sidecar directly with `count` mappings, bypassing the
    /// service — this is the shape a long-lived install (or an older Scarf
    /// that predates pruning) leaves behind.
    private static func seedSidecar(
        _ ctx: ServerContext, count: Int, stamped: Bool = true
    ) throws {
        var map = SessionProjectMap()
        for i in 0..<count {
            // Zero-padded so the ISO-8601-shaped stamps sort the same way the
            // ids do, and "newest" is unambiguous.
            let id = String(format: "s%06d", i)
            map.mappings[id] = "/Projects/p\(i % 20)"
            if stamped {
                map.touched = (map.touched ?? [:]).merging(
                    [id: String(format: "2026-01-01T00:00:%02d.%03dZ", i % 60, i % 1000)]
                ) { _, new in new }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dir = (ctx.paths.sessionProjectMap as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        try encoder.encode(map).write(to: URL(fileURLWithPath: ctx.paths.sessionProjectMap))
    }

    private static func sidecarBytes(_ ctx: ServerContext) throws -> Int {
        try Data(contentsOf: URL(fileURLWithPath: ctx.paths.sessionProjectMap)).count
    }

    /// The reason this matters: crossing `maxSidecarBytes` makes
    /// `GuardedJSONStore` quarantine the file, and EVERY session loses its
    /// project at once. Pruning has to fire before the file gets there, on
    /// the write path both writers (Mac `ChatViewModel`, iOS `ChatView`)
    /// share — `attribute` → `mutate` → `mutateLocked`.
    @Test func attributePrunesToTheCap() throws {
        try Self.withTempHome { ctx in
            try Self.seedSidecar(ctx, count: SessionProjectMap.maxMappings + 500)
            let svc = SessionAttributionService(context: ctx)
            svc.attribute(sessionID: "brand-new", toProjectPath: "/Projects/new")
            let after = svc.load()
            #expect(after.mappings.count == SessionProjectMap.maxMappings)
            // The write that triggered the prune is itself the newest entry,
            // so it must survive its own pruning pass.
            #expect(after.mappings["brand-new"] == "/Projects/new")
            // The oldest seeded entry is the one that went.
            #expect(after.mappings["s000000"] == nil)
            // Stamps are pruned in lockstep — a stamp map that outgrew the
            // mappings would defeat the whole point.
            #expect((after.touched ?? [:]).count <= SessionProjectMap.maxMappings)
        }
    }

    /// A capped file must land comfortably under the quarantine ceiling, not
    /// merely under the entry count — the count is a proxy for the bytes.
    @Test func aPrunedSidecarStaysWellUnderTheQuarantineCap() throws {
        try Self.withTempHome { ctx in
            try Self.seedSidecar(ctx, count: SessionProjectMap.maxMappings + 500)
            let svc = SessionAttributionService(context: ctx)
            svc.attribute(sessionID: "brand-new", toProjectPath: "/Projects/new")
            let bytes = try Self.sidecarBytes(ctx)
            #expect(bytes < SessionAttributionService.maxSidecarBytes)
            // And the load that follows actually decodes — i.e. the store did
            // not quarantine it.
            #expect(svc.load().mappings.count == SessionProjectMap.maxMappings)
        }
    }

    /// THE GAP THAT WAS OPEN. `attribute` of a session already pointing at
    /// the same project reports "no change" and used to return before
    /// pruning ran. An install that only ever re-attributes sessions it
    /// already knows (every resume of an existing project chat does exactly
    /// this) would then never trim an over-cap file it inherited.
    @Test func idempotentReAttributionStillPrunesAnOverCapFile() throws {
        try Self.withTempHome { ctx in
            try Self.seedSidecar(ctx, count: SessionProjectMap.maxMappings + 500)
            let svc = SessionAttributionService(context: ctx)
            // Idempotent by construction: same id, same path already on file.
            svc.attribute(sessionID: "s002400", toProjectPath: svc.projectPath(for: "s002400")!)
            #expect(svc.load().mappings.count == SessionProjectMap.maxMappings)
        }
    }

    /// Unstamped entries predate the recency stamp, so they are by
    /// construction the oldest — and a file made ENTIRELY of them must still
    /// prune deterministically rather than refusing to choose.
    @Test func prunesAFileWithNoRecencyStampsAtAll() throws {
        try Self.withTempHome { ctx in
            try Self.seedSidecar(ctx, count: SessionProjectMap.maxMappings + 100, stamped: false)
            let svc = SessionAttributionService(context: ctx)
            svc.attribute(sessionID: "brand-new", toProjectPath: "/Projects/new")
            let after = svc.load()
            #expect(after.mappings.count == SessionProjectMap.maxMappings)
            #expect(after.mappings["brand-new"] == "/Projects/new")
        }
    }

    /// The other write verb reaches the same chokepoint.
    @Test func forgetAlsoPrunes() throws {
        try Self.withTempHome { ctx in
            try Self.seedSidecar(ctx, count: SessionProjectMap.maxMappings + 500)
            let svc = SessionAttributionService(context: ctx)
            svc.forget(sessionID: "s002400")
            #expect(svc.load().mappings.count == SessionProjectMap.maxMappings)
            #expect(svc.projectPath(for: "s002400") == nil)
        }
    }

    /// A map that is already under the cap is left completely alone — pruning
    /// must not cost a write (or an entry) on the overwhelmingly common path.
    @Test func anUnderCapMapIsUntouched() throws {
        try Self.withTempHome { ctx in
            try Self.seedSidecar(ctx, count: 10)
            let svc = SessionAttributionService(context: ctx)
            let before = try Self.sidecarBytes(ctx)
            // Idempotent AND under the cap → nothing to change, nothing to
            // prune, so the file must not be rewritten at all.
            svc.attribute(sessionID: "s000003", toProjectPath: svc.projectPath(for: "s000003")!)
            #expect(try Self.sidecarBytes(ctx) == before)
            #expect(svc.load().mappings.count == 10)
        }
    }

    @Test func resolveReturnsNilForUnattributedOrMissingSession() throws {
        try Self.withTempHome { ctx in
            let svc = SessionAttributionService(context: ctx)
            // Unattributed session (e.g. a global/CLI chat) → nil → caller
            // uses home cwd, preserving non-project behavior.
            #expect(svc.resolveProjectPath(known: nil, sessionID: "unknown") == nil)
            // No known path and no session to look up → nil.
            #expect(svc.resolveProjectPath(known: nil, sessionID: nil) == nil)
            #expect(svc.resolveProjectPath(known: "", sessionID: nil) == nil)
        }
    }
}
