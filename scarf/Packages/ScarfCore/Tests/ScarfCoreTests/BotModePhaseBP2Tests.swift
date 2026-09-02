#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// P2 of the Bot Mode **Phase B** cycle — roster quality (search, activity,
/// presence) and the audit board's performance items A1-M3/M4.
///
/// The load-bearing claims pinned here:
///
/// - **Batched-scan parity.** `BotsService.batchedRosterEntries()` and
///   `rosterEntriesPerFile()` must be indistinguishable, *including* their
///   degradations — a missing, malformed, oversized or non-UTF-8
///   `profile.yaml`, an invalid directory name, an avatar in any of the three
///   probed extensions. Both are run against a real `LocalTransport` over a
///   real temporary tree, so the script actually executes.
/// - **Preview reuse.** The single-session entry point returns exactly what
///   the session-list query returns for that session, carrier stripping
///   included — because it is the same builders, and this is what stops them
///   drifting apart.
/// - **No Bot Chat is not an error.** A profile database with no session
///   titled "Bot Chat" (or with no sessions table at all) yields nil, quietly.
@Suite struct BotModePhaseBP2Tests {

    static let capabilities = HermesCapabilities.parseLine("Hermes Agent v0.21.0 (2026.8.31)")

    // MARK: - Roster fixtures

    private func tempRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-bp2-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// A profile tree. `nil` yaml means "no profile.yaml at all".
    @discardableResult
    private func makeTree(
        at root: URL,
        rootYAML: String? = nil,
        profiles: [String: String?] = [:],
        avatars: [String: (ext: String, bytes: Data)] = [:],
        extraDirectoryNames: [String] = [],
        strayFileNames: [String] = []
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let rootYAML {
            try rootYAML.write(to: root.appendingPathComponent("profile.yaml"), atomically: true, encoding: .utf8)
        }
        let profilesDir = root.appendingPathComponent("profiles", isDirectory: true)
        for (name, yaml) in profiles {
            let dir = profilesDir.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let yaml {
                try yaml.write(to: dir.appendingPathComponent("profile.yaml"), atomically: true, encoding: .utf8)
            }
        }
        for name in extraDirectoryNames {
            try fm.createDirectory(
                at: profilesDir.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        for name in strayFileNames {
            try fm.createDirectory(at: profilesDir, withIntermediateDirectories: true)
            try Data("not a directory".utf8).write(to: profilesDir.appendingPathComponent(name))
        }
        for (name, avatar) in avatars {
            let dir = name == "default"
                ? root.appendingPathComponent("assets", isDirectory: true)
                : profilesDir.appendingPathComponent(name + "/assets", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try avatar.bytes.write(to: dir.appendingPathComponent("avatar." + avatar.ext))
        }
        return root
    }

    private func service(root: URL) -> BotsService {
        let context = ServerContext.local(home: root)
        return BotsService(
            transport: context.makeTransport(),
            paths: context.paths,
            capabilities: Self.capabilities,
            prefersBatchedScan: true
        )
    }

    private func botYAML(title: String, description: String = "") -> String {
        """
        display_name: \(title)
        description: \(description)
        ui_meta:
          hermes-bots:
            title: \(title)
            pinned: false
        """
    }

    // MARK: - 1. Batched scan ≡ per-file scan

    @Test("the batched scan returns exactly what the per-file scan returns")
    func batchedScanMatchesPerFileScan() async throws {
        let root = tempRoot("parity")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTree(
            at: root,
            rootYAML: botYAML(title: "Hermes"),
            profiles: [
                "ops": botYAML(title: "Ops Bot", description: "keeps the lights on"),
                "research": botYAML(title: "Research"),
                // A profile with no metadata at all — normal, Hermes writes
                // profile.yaml lazily.
                "bare": String?.none,
                // Malformed: `read_profile_meta` swallows this, so must Scarf.
                "broken": "ui_meta: [this is not: a mapping",
                // Present but empty — must not be confused with absent.
                "blank": ""
            ],
            avatars: [
                "ops": (ext: "png", bytes: Data(repeating: 0x89, count: 512)),
                "research": (ext: "webp", bytes: Data(repeating: 0x52, count: 64))
            ],
            // Not addressable by `hermes -p`, so neither path may list it.
            extraDirectoryNames: ["Not-A-Valid-Name", ".hidden"],
            strayFileNames: ["loose.txt"]
        )

        let service = service(root: root)
        let perFile = service.rosterEntriesPerFile()
        let batched = try #require(await service.batchedRosterEntries())

        #expect(batched.map(\.identity.profileName) == perFile.map(\.identity.profileName))
        // `default` first, then ids sorted — and neither the invalid
        // directory names nor the stray file appear.
        #expect(batched.map(\.identity.profileName) == ["default", "bare", "blank", "broken", "ops", "research"])
        #expect(batched == perFile)
    }

    @Test("an oversized profile.yaml degrades identically on both paths")
    func batchedScanMatchesPerFileOnOversizedYAML() async throws {
        let root = tempRoot("oversize")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTree(at: root, profiles: ["big": String?.none])
        // One byte over the cap: neither path may read it, and both must
        // render the profile as unmanaged rather than dropping it.
        let oversized = String(repeating: "a", count: BotsService.maxProfileYAMLBytes + 1)
        try oversized.write(
            to: root.appendingPathComponent("profiles/big/profile.yaml"),
            atomically: true,
            encoding: .utf8
        )

        let service = service(root: root)
        let perFile = service.rosterEntriesPerFile()
        let batched = try #require(await service.batchedRosterEntries())
        #expect(batched == perFile)
        let big = try #require(batched.first { $0.identity.profileName == "big" })
        #expect(big.identity.isBotManaged == false)
        #expect(big.identity.displayName.isEmpty)
    }

    @Test("a profile.yaml that isn't UTF-8 degrades identically on both paths")
    func batchedScanMatchesPerFileOnNonUTF8YAML() async throws {
        let root = tempRoot("binary")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTree(at: root, profiles: ["bin": String?.none])
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(
            to: root.appendingPathComponent("profiles/bin/profile.yaml")
        )

        let service = service(root: root)
        #expect(try await #require(service.batchedRosterEntries()) == service.rosterEntriesPerFile())
    }

    @Test("a host with no profiles directory still reports the default profile")
    func batchedScanHandlesEmptyRoster() async throws {
        let root = tempRoot("empty")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let service = service(root: root)
        let batched = try #require(await service.batchedRosterEntries())
        #expect(batched.map(\.identity.profileName) == ["default"])
        #expect(batched == service.rosterEntriesPerFile())
    }

    @Test("truncated or refused script output is rejected, never half-believed")
    func parseRefusesIncompleteOutput() {
        let root = "/home/me/.hermes"
        // No OK sentinel — the stream was cut off mid-scan.
        #expect(BotsRosterScan.parse("Y\tdefault\t0\t\n", rootHome: root) == nil)
        // The host has no base64 at all.
        #expect(BotsRosterScan.parse("E\tno-base64\n", rootHome: root) == nil)
        // A scan that somehow lost the default profile is not a roster.
        #expect(BotsRosterScan.parse("Y\tops\t0\t\nOK\n", rootHome: root) == nil)
        // The minimum believable answer.
        #expect(BotsRosterScan.parse("Y\tdefault\t0\t\nOK\n", rootHome: root)?.count == 1)
    }

    @Test("a root home with shell metacharacters is quoted, not expanded")
    func scriptQuotesHostilePaths() {
        let script = BotsRosterScan.script(rootHome: "/tmp/a b$(touch /tmp/pwned)'c", maxYAMLBytes: 10)
        #expect(script.contains("'/tmp/a b$(touch /tmp/pwned)'\\''c'"))
        // `~` stays live so it still expands on the remote.
        #expect(BotsRosterScan.script(rootHome: "~/.hermes", maxYAMLBytes: 10).contains("\"$HOME\"'/.hermes'"))
    }

    @Test("a root home with a single quote survives a real round trip")
    func scriptSurvivesQuoteInPath() async throws {
        let root = tempRoot("quo'te")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTree(at: root, profiles: ["ops": botYAML(title: "Ops")])
        let service = service(root: root)
        let batched = try #require(await service.batchedRosterEntries())
        #expect(batched == service.rosterEntriesPerFile())
        #expect(batched.contains { $0.identity.resolvedTitle == "Ops" })
    }

    // MARK: - 2. Avatar stats + bounded byte reads

    @Test("the scan reports an avatar's stat without reading its bytes")
    func avatarStatIsCarriedByTheScan() async throws {
        let root = tempRoot("avatar")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x89, count: 4096)
        try makeTree(at: root, profiles: ["ops": botYAML(title: "Ops")], avatars: ["ops": (ext: "jpg", bytes: bytes)])

        let service = service(root: root)
        let batched = try #require(await service.batchedRosterEntries())
        let ops = try #require(batched.first { $0.identity.profileName == "ops" })
        let stat = try #require(ops.avatar)
        #expect(stat.size == 4096)
        #expect(stat.mime == "image/jpeg")
        #expect(stat.path.hasSuffix("/profiles/ops/assets/avatar.jpg"))
        #expect(stat.mtime > 0)
        // And the bytes come back only when explicitly asked for.
        #expect(try service.loadAvatar(at: stat).data == bytes)
    }

    @Test("an oversized avatar is refused before its bytes cross the transport")
    func loadAvatarAtStatEnforcesTheCap() throws {
        let root = tempRoot("bigavatar")
        defer { try? FileManager.default.removeItem(at: root) }
        let stat = BotAvatarStat(
            path: root.appendingPathComponent("nope.png").path,
            mime: "image/png",
            size: Int64(HermesBotAvatar.maxBytes) + 1,
            mtime: 1
        )
        #expect(throws: BotsError.self) { try service(root: root).loadAvatar(at: stat) }
    }

    // MARK: - 3. Avatar cache

    @MainActor
    @Test("the avatar cache decodes once per key and drops a profile on write")
    func avatarCacheInvalidatesOnWrite() {
        var decoded = 0
        let cache = BotAvatarCache { _ in
            decoded += 1
            return Image(systemName: "circle")
        }
        let first = BotAvatarStat(path: "/h/profiles/ops/assets/avatar.png", mime: "image/png", size: 10, mtime: 100)
        let key = BotAvatarCache.Key(profileName: "ops", stat: first)
        cache.store(HermesBotAvatar(data: Data(repeating: 1, count: 10), mimeType: "image/png", path: first.path), for: key)

        #expect(cache.image(for: key) != nil)
        #expect(cache.image(for: key) != nil)
        #expect(decoded == 1, "a second read of the same key must not decode again")
        #expect(cache.avatar(for: key) != nil)

        // The write path's explicit invalidation — the case a (path, size,
        // mtime) key cannot catch, because a remote stat's mtime is whole
        // seconds and a re-write can land in the same second at the same size.
        cache.invalidate(profileName: "ops")
        #expect(cache.avatar(for: key) == nil)
        #expect(cache.image(for: key) == nil)
        #expect(cache.count == 0)
    }

    @MainActor
    @Test("the avatar cache is keyed by profile, not just path")
    func avatarCacheKeyIncludesProfile() {
        let cache = BotAvatarCache { _ in Image(systemName: "circle") }
        let stat = BotAvatarStat(path: "/h/assets/avatar.png", mime: "image/png", size: 10, mtime: 1)
        cache.store(
            HermesBotAvatar(data: Data([1]), mimeType: "image/png", path: stat.path),
            for: BotAvatarCache.Key(profileName: "ops", stat: stat)
        )
        #expect(cache.avatar(for: BotAvatarCache.Key(profileName: "research", stat: stat)) == nil)
        // A changed stat is a changed key, so a re-written avatar is a miss
        // even without the explicit invalidation.
        let rewritten = BotAvatarStat(path: stat.path, mime: stat.mime, size: 11, mtime: 2)
        #expect(cache.avatar(for: BotAvatarCache.Key(profileName: "ops", stat: rewritten)) == nil)
    }

    // MARK: - 4. Presence mapping

    @Test("presence maps the conversation's own state, and nothing else")
    func presenceMapping() {
        func resolve(
            current: Bool = true,
            resolving: Bool = false,
            failed: Bool = false,
            connected: Bool = false,
            working: Bool = false
        ) -> BotPresence {
            BotPresence.resolve(
                isCurrentConversation: current,
                isResolving: resolving,
                isFailed: failed,
                isConnected: connected,
                isAgentWorking: working
            )
        }
        // Another bot's conversation never lights up this row.
        #expect(resolve(current: false, connected: true, working: true) == .offline)
        // A failed open holds no process — it must not read as live.
        #expect(resolve(failed: true, connected: true) == .offline)
        #expect(resolve(resolving: true) == .connecting)
        #expect(resolve(connected: true) == .connected)
        #expect(resolve(connected: true, working: true) == .streaming)
        // Idle with no channel and no resolve in flight is simply nothing.
        #expect(resolve() == .offline)
        #expect(BotPresence.offline.isLive == false)
        #expect(BotPresence.streaming.isLive)
    }

    // MARK: - 5. Preview + activity against a real profile database

    struct Msg {
        var session: String
        var role: String = "user"
        var content: String
        var timestamp: Double
    }

    /// A profile home carrying a `state.db` with the modern schema.
    private func makeProfileDB(
        at home: URL,
        sessions: [(id: String, title: String?, parent: String?, endReason: String?)],
        messages: [Msg],
        includeSessions: Bool = true
    ) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            home.appendingPathComponent("state.db").path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        if includeSessions {
            try exec(db, """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
                parent_session_id TEXT, started_at REAL, ended_at REAL, end_reason TEXT,
                message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
                output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
                estimated_cost_usd REAL, reasoning_tokens INTEGER, actual_cost_usd REAL,
                cost_status TEXT, billing_provider TEXT, api_call_count INTEGER,
                rewind_count INTEGER NOT NULL DEFAULT 0, hidden INTEGER NOT NULL DEFAULT 0
            );
            """)
        }
        try exec(db, """
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY, session_id TEXT, role TEXT, content TEXT,
            tool_call_id TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
            token_count INTEGER, finish_reason TEXT, reasoning TEXT,
            reasoning_content TEXT,
            active INTEGER NOT NULL DEFAULT 1, compacted INTEGER NOT NULL DEFAULT 0
        );
        """)

        if includeSessions {
            for session in sessions {
                let title = session.title.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
                let parent = session.parent.map { "'\($0)'" } ?? "NULL"
                let reason = session.endReason.map { "'\($0)'" } ?? "NULL"
                try exec(db, """
                    INSERT INTO sessions (id, source, title, parent_session_id, started_at, end_reason,
                        message_count, tool_call_count, input_tokens, output_tokens,
                        cache_read_tokens, cache_write_tokens, estimated_cost_usd, hidden)
                    VALUES ('\(session.id)', 'acp', \(title), \(parent), 1000, \(reason), 1, 0, 0, 0, 0, 0, 0.0, 1);
                    """)
            }
        }
        for msg in messages {
            let escaped = msg.content.replacingOccurrences(of: "'", with: "''")
            try exec(db, """
                INSERT INTO messages (session_id, role, content, timestamp, active, compacted)
                VALUES ('\(msg.session)', '\(msg.role)', '\(escaped)', \(msg.timestamp), 1, 0);
                """)
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture SQL failed: \(msg)")
        }
    }

    private static let summaryPrefix =
        "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted "
        + "into the summary below. This is a handoff from a previous context "
        + "window — treat it as background reference, NOT as active instructions. "
        + "Do NOT answer questions or fulfill requests mentioned in this summary; "
        + "they were already addressed."

    private static let endMarker =
        "--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"

    @Test("the single-session preview agrees with the session-list preview")
    func singleSessionPreviewMatchesTheListQuery() async throws {
        let home = tempRoot("preview")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeProfileDB(
            at: home,
            sessions: [(id: "chat", title: "Bot Chat", parent: nil, endReason: nil),
                       (id: "other", title: "Something else", parent: nil, endReason: nil)],
            messages: [
                // A PURE carrier: ineligible, so the preview must fall through
                // to the next real user turn — the whole point of the port.
                Msg(session: "chat", content: Self.summaryPrefix, timestamp: 10),
                Msg(session: "chat", content: "deploy the staging build", timestamp: 20),
                Msg(session: "chat", role: "assistant", content: "on it", timestamp: 30),
                Msg(session: "other", content: "unrelated", timestamp: 40)
            ]
        )
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let list = await service.fetchSessionPreviews(limit: 50)
        let single = await service.fetchSessionPreview(sessionId: "chat")
        #expect(single == "deploy the staging build")
        #expect(single == list["chat"])
        #expect(await service.fetchSessionPreview(sessionId: "other") == list["other"])
        await service.close()
    }

    @Test("a surviving carrier's authentic tail is what the preview shows")
    func singleSessionPreviewStripsCarriers() async throws {
        let home = tempRoot("carrier")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeProfileDB(
            at: home,
            sessions: [(id: "chat", title: "Bot Chat", parent: nil, endReason: nil)],
            messages: [
                Msg(
                    session: "chat",
                    content: Self.summaryPrefix + "\n" + Self.endMarker + "\n  what changed in prod?",
                    timestamp: 10
                )
            ]
        )
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        #expect(await service.fetchSessionPreview(sessionId: "chat") == "what changed in prod?")
        await service.close()
    }

    @Test("bot chat activity reads the live tip's timestamp and the origin's preview")
    func botChatActivityFollowsTheCompressionChain() async throws {
        let home = tempRoot("activity")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeProfileDB(
            at: home,
            sessions: [
                (id: "origin", title: "Bot Chat", parent: nil, endReason: "compression"),
                (id: "tip", title: nil, parent: "origin", endReason: nil)
            ],
            messages: [
                Msg(session: "origin", content: "first thing I ever asked", timestamp: 100),
                Msg(session: "tip", content: "and the latest thing", timestamp: 900),
                Msg(session: "tip", role: "assistant", content: "answered", timestamp: 950)
            ]
        )
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let activity = try #require(await service.fetchBotChatActivity())
        #expect(activity.preview == "first thing I ever asked")
        #expect(activity.lastMessageAt == Date(timeIntervalSince1970: 950))
        await service.close()
    }

    @Test("a profile with no Bot Chat reports no activity, and no error")
    func noBotChatIsNotAnError() async throws {
        let home = tempRoot("nochat")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeProfileDB(
            at: home,
            sessions: [(id: "s1", title: "My own session", parent: nil, endReason: nil)],
            messages: [Msg(session: "s1", content: "hello", timestamp: 1)]
        )
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        #expect(await service.fetchBotChatActivity() == nil)
        #expect(await service.lastOpenError == nil)
        await service.close()
    }

    @Test("a database with no sessions table reports no activity, and no error")
    func missingSessionsTableIsNotAnError() async throws {
        let home = tempRoot("noschema")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeProfileDB(at: home, sessions: [], messages: [], includeSessions: false)
        let service = HermesDataService(context: .local(home: home))
        _ = await service.open()
        #expect(await service.fetchBotChatActivity() == nil)
        #expect(await service.fetchSessionPreview(sessionId: "anything") == nil)
        await service.close()
    }

    @Test("an empty Bot Chat has activity with no preview and no timestamp")
    func emptyBotChatHasNoPreview() async throws {
        let home = tempRoot("emptychat")
        defer { try? FileManager.default.removeItem(at: home) }
        try makeProfileDB(
            at: home,
            sessions: [(id: "chat", title: "Bot Chat", parent: nil, endReason: nil)],
            messages: []
        )
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())
        let activity = try #require(await service.fetchBotChatActivity())
        #expect(activity.preview.isEmpty)
        #expect(activity.lastMessageAt == nil)
        await service.close()
    }

    // MARK: - 6. The session-scoped SQL is the SAME expressions

    @Test("the session-scoped builder differs from the list builder only by its predicate")
    func sessionScopedSQLReusesTheListBuilders() {
        let list = SessionPreviewSQL.firstEligibleUserRowSQL(hasActiveColumn: true, hasCompactedColumn: true)
        let scoped = SessionPreviewSQL.firstEligibleUserRowSQL(
            sessionScoped: true,
            hasActiveColumn: true,
            hasCompactedColumn: true
        )
        // Same eligibility expression, byte for byte.
        #expect(scoped.contains(SessionPreviewSQL.eligiblePredicate()))
        #expect(list.contains(SessionPreviewSQL.eligiblePredicate()))
        #expect(scoped.contains("m.session_id = ?"))
        #expect(scoped.contains("GROUP BY") == false)
        // And the schema gate still gates.
        let legacy = SessionPreviewSQL.firstEligibleUserRowSQL(
            sessionScoped: true,
            hasActiveColumn: false,
            hasCompactedColumn: false
        )
        #expect(legacy.contains("m.active") == false)
        #expect(legacy.contains("m.compacted") == false)
        // `sessionScoped: false` is the list query exactly.
        #expect(SessionPreviewSQL.firstEligibleUserRowSQL(
            sessionScoped: false,
            hasActiveColumn: true,
            hasCompactedColumn: true
        ) == list)
    }
}

#if canImport(SwiftUI)
import SwiftUI
#endif

#endif
