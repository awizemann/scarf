#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// Blind re-audit B01 / S02-chat-events-F1: a chat Hermes compacted IN
/// PLACE must reopen with its whole history, exactly as Hermes itself
/// displays it.
///
/// The seed rows below are the `messages` table Hermes v2026.9.24's own
/// `SessionDB` wrote (reference worktree `.venv`, scratch HERMES_HOME):
/// - `s1`: four exchanges, then `archive_and_compact` carrying the head
///   (q1/a1) and the verbatim tail (q4/a4) with `tail_count=2` — the
///   0.21.5 shape, where the tail originals get rewind flags — then q5/a5,
///   a micro-compaction `model_only` merged row and a5b.
/// - `s2`: the older in-place shape (`tail_count=0`), where the carried
///   tail's originals stay `compacted = 1` next to their copies, plus one
///   rewound (undone) row.
///
/// `hermesDisplay` is what `get_resume_conversations(sid)[1]` returned for
/// the same store (display_kind 'hidden' rows removed, as every Hermes
/// display does). Scarf's transcript reads must produce the same list.
@Suite struct HermesV0215CompactedTranscriptB01Tests {

    static let seedSQL = """
    INSERT INTO sessions (id, source, started_at) VALUES
        ('s1', 'cli', 1700000000), ('s2', 'cli', 1700000000);
    INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted, display_kind, display_metadata)
    VALUES
        (1, 's1', 'user', 's1 q1', 1700000010.0, 0, 1, NULL, NULL),
        (2, 's1', 'assistant', 's1 a1', 1700000011.0, 0, 1, NULL, NULL),
        (3, 's1', 'user', 's1 q2', 1700000020.0, 0, 1, NULL, NULL),
        (4, 's1', 'assistant', 's1 a2', 1700000021.0, 0, 1, NULL, NULL),
        (5, 's1', 'user', 's1 q3', 1700000030.0, 0, 1, NULL, NULL),
        (6, 's1', 'assistant', 's1 a3', 1700000031.0, 0, 1, NULL, NULL),
        (7, 's1', 'user', 's1 q4', 1700000040.0, 0, 0, NULL, NULL),
        (8, 's1', 'assistant', 's1 a4', 1700000041.0, 0, 0, NULL, NULL),
        (9, 's1', 'user', 's1 q1', 1700000010.0, 1, 0, NULL, NULL),
        (10, 's1', 'assistant', 's1 a1', 1700000011.0, 1, 0, NULL, NULL),
        (11, 's1', 'user', '[CONTEXT COMPACTION] summary of q2..q3', 1700000075.0, 1, 0, 'hidden', NULL),
        (12, 's1', 'user', 's1 q4', 1700000040.0, 1, 0, NULL, NULL),
        (13, 's1', 'assistant', 's1 a4', 1700000041.0, 1, 0, NULL, NULL),
        (14, 's1', 'user', 's1 q5', 1700000100.0, 1, 0, NULL, NULL),
        (15, 's1', 'assistant', 's1 a5', 1700000101.0, 1, 0, NULL, NULL),
        (16, 's1', 'user', 's1 q5

    s1 q5b', 1700000102.0, 1, 0, NULL, '{"model_only": true}'),
        (17, 's1', 'assistant', 's1 a5b', 1700000103.0, 1, 0, NULL, NULL),
        (18, 's2', 'user', 's2 q1', 1700000010.0, 0, 1, NULL, NULL),
        (19, 's2', 'assistant', 's2 a1', 1700000011.0, 0, 1, NULL, NULL),
        (20, 's2', 'user', 's2 q2', 1700000020.0, 0, 1, NULL, NULL),
        (21, 's2', 'assistant', 's2 a2', 1700000021.0, 0, 1, NULL, NULL),
        (22, 's2', 'user', 's2 q3', 1700000030.0, 0, 1, NULL, NULL),
        (23, 's2', 'assistant', 's2 a3', 1700000031.0, 0, 1, NULL, NULL),
        (24, 's2', 'user', '[CONTEXT COMPACTION] s2 summary', 1700000035.0, 1, 0, 'hidden', NULL),
        (25, 's2', 'user', 's2 q3', 1700000030.0, 1, 0, NULL, NULL),
        (26, 's2', 'assistant', 's2 a3', 1700000031.0, 1, 0, NULL, NULL),
        (27, 's2', 'user', 's2 q4', 1700000040.0, 1, 0, NULL, NULL),
        (28, 's2', 'assistant', 's2 undone', 1700000041.0, 0, 0, NULL, NULL),
        (29, 's2', 'assistant', 's2 a4', 1700000042.0, 1, 0, NULL, NULL);
    """

    static let hermesDisplay: [String: [String]] = [
        "s1": ["s1 q1", "s1 a1", "s1 q2", "s1 a2", "s1 q3", "s1 a3", "s1 q4", "s1 a4", "s1 q5", "s1 a5", "s1 a5b"],
        "s2": ["s2 q1", "s2 a1", "s2 q2", "s2 a2", "s2 q3", "s2 a3", "s2 q4", "s2 a4"],
    ]

    private static func open(_ home: URL) async -> HermesDataService {
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        return service
    }

    // MARK: - Data service reads

    @Test func fullAndSkeletonReadsMatchHermesDisplayProjection() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.seedSQL)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await Self.open(home)
        for (sid, expected) in Self.hermesDisplay {
            let full = await service.fetchMessages(sessionId: sid, limit: 100)
            #expect(full.map(\.content) == expected, "full read, \(sid)")
            // Ascending ids: the order every page cursor relies on.
            #expect(full.map(\.id) == full.map(\.id).sorted())
            let skeleton = await service.fetchSkeletonMessages(sessionId: sid, limit: 100)
            #expect(skeleton.messages.map(\.content) == expected, "skeleton read, \(sid)")
        }
        await service.close()
    }

    @Test func loadEarlierPagesWalkTheWholeHistoryOnce() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.seedSQL)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await Self.open(home)
        for (sid, expected) in Self.hermesDisplay {
            var collected: [HermesMessage] = []
            var before: Int?
            while true {
                let page = await service.fetchMessages(sessionId: sid, limit: 3, before: before)
                guard !page.isEmpty else { break }
                collected = page + collected
                before = page.first?.id
            }
            #expect(collected.map(\.content) == expected, "paged read, \(sid)")
        }
        await service.close()
    }

    @Test func toolResultsFromArchivedTurnsHydrate() async throws {
        // A tool result that compaction archived is part of the display
        // history too; hydration reads it with the same projection.
        let seed = Self.seedSQL + """

        INSERT INTO messages (id, session_id, role, content, tool_call_id, tool_name, timestamp, active, compacted)
        VALUES (30, 's1', 'tool', 'archived tool output', 'call_1', 'bash', 1700000032.0, 0, 1),
               (31, 's1', 'tool', 'rewound tool output', 'call_2', 'bash', 1700000033.0, 0, 0);
        """
        let home = try HermesV0215R18bTests.makeHome(seed: seed)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = await Self.open(home)
        let tools = await service.fetchToolResultsInRange(sessionId: "s1", minId: 1, maxId: 100)
        #expect(tools.map(\.content) == ["archived tool output"])
        await service.close()
    }

    // MARK: - Chat view model

    @MainActor
    @Test func reopenedCompactedChatShowsItsEarlierTurns() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.seedSQL)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        await vm.loadSessionHistory(sessionId: "s1")
        #expect(vm.messages.map(\.content) == Self.hermesDisplay["s1"])
    }

    /// A compaction that ran while the chat was open re-inserts the tail it
    /// keeps and flags the originals out of display history. When the
    /// reconnect window's floor lands between the two, the on-screen
    /// originals sit below the floor and are kept — they must not show next
    /// to the window's copies.
    @MainActor
    @Test func reconcileDoesNotDuplicateATailCompactedMidSession() async throws {
        var rows: [String] = []
        for id in 1...12 {
            let role = id % 2 == 1 ? "user" : "assistant"
            rows.append("(\(id), 'r', '\(role)', 'turn \(id)', \(1_700_000_000 + id), 1, 0)")
        }
        let home = try HermesV0215R18bTests.makeHome(seed: """
            INSERT INTO sessions (id, source, started_at) VALUES ('r', 'acp', 1700000000);
            INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted)
            VALUES \(rows.joined(separator: ",\n"));
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        await vm.loadSessionHistory(sessionId: "r")
        #expect(vm.messages.count == 12)

        // Hermes compacts in place: archives 1-10, rewind-flags the carried
        // tail (11, 12), inserts its copies (13, 14), then the chat goes on
        // for 198 more rows — so the newest 200 display rows start exactly
        // at the first copy.
        var later: [String] = []
        for id in 15...212 {
            let role = id % 2 == 1 ? "user" : "assistant"
            later.append("(\(id), 'r', '\(role)', 'later \(id)', \(1_700_000_000 + id), 1, 0)")
        }
        try HermesV0215R18bTests.exec("""
            UPDATE messages SET active = 0, compacted = 1 WHERE session_id = 'r' AND id <= 10;
            UPDATE messages SET active = 0, compacted = 0 WHERE session_id = 'r' AND id IN (11, 12);
            INSERT INTO messages (id, session_id, role, content, timestamp, active, compacted) VALUES
                (13, 'r', 'user', 'turn 11', 1700000011, 1, 0),
                (14, 'r', 'assistant', 'turn 12', 1700000012, 1, 0),
                \(later.joined(separator: ",\n"));
            """, home: home)

        await vm.reconcileWithDB(sessionId: "r")
        let contents = vm.messages.map(\.content)
        #expect(contents.filter { $0 == "turn 11" }.count == 1)
        #expect(contents.filter { $0 == "turn 12" }.count == 1)
        // Archived history below the window stays on screen.
        #expect(contents.prefix(10) == ArraySlice((1...10).map { "turn \($0)" }))
        #expect(contents.count == 10 + 2 + 198)
    }

    // MARK: - Export note probe

    @Test func archivedTurnsProbeFindsCompactionArchivedRowsOnly() async throws {
        let home = try HermesV0215R18bTests.makeHome(seed: Self.seedSQL + """

            INSERT INTO sessions (id, source, started_at) VALUES ('fresh', 'cli', 1700000000);
            INSERT INTO messages (session_id, role, content, timestamp) VALUES ('fresh', 'user', 'hi', 1700000001);
            INSERT INTO messages (session_id, role, content, timestamp, active, compacted)
                VALUES ('fresh', 'assistant', 'undone', 1700000002, 0, 0);
            """)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = HermesDataService(context: .local(home: home))
        // Before open() the schema flags are unset: false, no query.
        #expect(await service.hasArchivedTurns(sessionIds: ["s1"]) == false)
        #expect(await service.open())
        #expect(await service.hasArchivedTurns(sessionIds: ["s1"]))
        #expect(await service.hasArchivedTurns(sessionIds: ["fresh", "s2"]))
        // A rewound row is not an archived turn.
        #expect(await service.hasArchivedTurns(sessionIds: ["fresh"]) == false)
        #expect(await service.hasArchivedTurns(sessionIds: []) == false)
        await service.close()
    }

    // MARK: - SQL gating (charter C1/C4)

    @Test func transcriptSQLIsUnchangedWithoutTheCompactedColumn() async throws {
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        await mock.setHasDisplayKindColumn(true)
        await mock.setHasDisplayMetadataColumn(true)
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchMessages(sessionId: "x", limit: 5)
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(sql.contains(" AND active = 1 AND COALESCE(display_kind, '') <> 'hidden'"))
        #expect(!sql.contains("compacted"))
        #expect(!sql.contains("model_only"))
    }

    @Test func transcriptSQLUsesTheDisplayProjectionWithTheCompactedColumn() async throws {
        let mock = MockHermesQueryBackend()
        await mock.setHasMessagesActiveColumn(true)
        await mock.setHasCompactedColumn(true)
        let service = HermesDataService(context: .local, backend: mock)
        #expect(await service.open())
        _ = await service.fetchSkeletonMessages(sessionId: "x", limit: 5)
        let sql = try #require(await mock.queryLog.last?.sql)
        #expect(sql.contains("(active = 1 OR compacted = 1)"))
        #expect(sql.contains("NOT EXISTS (SELECT 1 FROM messages _gen"))
        // No display_metadata column → no model_only clause.
        #expect(!sql.contains("model_only"))
    }
}

#endif
