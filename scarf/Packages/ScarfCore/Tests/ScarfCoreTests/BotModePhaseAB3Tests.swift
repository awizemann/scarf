#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// B3 of the Bot Mode Phase A cycle — the bot conversation's ScarfCore
/// half: profile pinning, canonical-Bot-Chat resolution out of the *right*
/// profile's `state.db`, and the teammate attribution prefix.
///
/// Every session-lookup test runs against a real SQLite file through
/// `LocalSQLiteBackend`, following `HermesV021SessionPreviewTests`: the
/// behaviour under test is SQL (the deliberate absence of a `hidden = 0`
/// clause, the compression walk's `end_reason` gate), and a mocked backend
/// would assert on string shape instead.
@Suite struct BotModePhaseAB3Tests {

    // MARK: - Fixtures

    struct SessionRow {
        var id: String
        var title: String?
        var hidden: Int = 0
        var parent: String? = nil
        var endReason: String? = nil
        var source: String = "cli"
        var startedAt: Double = 1_000
        var endedAt: Double? = nil
        var modelConfig: String? = nil
    }

    /// Build a Hermes home with a `state.db` holding `rows`. `profiles`
    /// nests additional homes at `<home>/profiles/<name>` so the
    /// wrong-profile tests have somewhere real to be wrong about.
    @discardableResult
    private func makeHome(
        at home: URL,
        rows: [SessionRow],
        withHiddenColumn: Bool = true,
        withModelConfig: Bool = true,
        withEndReason: Bool = true
    ) throws -> URL {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dbPath = home.appendingPathComponent("state.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        var columns = """
        id TEXT PRIMARY KEY, source TEXT, user_id TEXT, model TEXT, title TEXT,
        parent_session_id TEXT, started_at REAL, ended_at REAL,
        message_count INTEGER, tool_call_count INTEGER, input_tokens INTEGER,
        output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
        estimated_cost_usd REAL
        """
        if withEndReason { columns += ", end_reason TEXT" }
        if withHiddenColumn { columns += ", hidden INTEGER NOT NULL DEFAULT 0" }
        if withModelConfig { columns += ", model_config TEXT" }

        let ddl = """
        CREATE TABLE sessions (\(columns));
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, role TEXT,
            content TEXT, tool_call_id TEXT, tool_name TEXT, timestamp REAL,
            token_count INTEGER, finish_reason TEXT
        );
        """
        guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else {
            throw TransportError.other(message: "DDL failed")
        }

        for row in rows {
            var names = ["id", "source", "title", "parent_session_id", "started_at", "ended_at"]
            var values = [
                quote(row.id), quote(row.source), quote(row.title),
                quote(row.parent), String(row.startedAt),
                row.endedAt.map { String($0) } ?? "NULL"
            ]
            if withEndReason { names.append("end_reason"); values.append(quote(row.endReason)) }
            if withHiddenColumn { names.append("hidden"); values.append(String(row.hidden)) }
            if withModelConfig { names.append("model_config"); values.append(quote(row.modelConfig)) }
            let sql = "INSERT INTO sessions (\(names.joined(separator: ", "))) VALUES (\(values.joined(separator: ", ")));"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw TransportError.other(message: "insert failed for \(row.id)")
            }
        }
        return home
    }

    private func quote(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func tempRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-b3-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func service(forHome home: URL) async -> HermesDataService {
        let svc = HermesDataService(context: .local(home: home))
        _ = await svc.open()
        return svc
    }

    // MARK: - Profile pinning (ServerContext)

    @Test func localContextPinsToTheProfilesStateDB() {
        let root = URL(fileURLWithPath: "/tmp/hermes-root")
        let pinned = ServerContext.local(home: root).pinnedToProfile("scout")
        #expect(pinned.paths.stateDB == "/tmp/hermes-root/profiles/scout/state.db")
    }

    /// The gap this method exists to close: `scoped(toProfile:)` is the
    /// per-window *viewing profile* (#126) and is deliberately a no-op for
    /// local, which would have left a local bot reading the USER's state.db
    /// under the bot's name.
    @Test func scopedIsStillALocalNoOpSoPinningIsTheOneToUse() {
        let root = URL(fileURLWithPath: "/tmp/hermes-root")
        let base = ServerContext.local(home: root)
        #expect(base.scoped(toProfile: "scout").paths.stateDB == "/tmp/hermes-root/state.db")
        #expect(base.pinnedToProfile("scout").paths.stateDB != base.paths.stateDB)
    }

    @Test func remoteContextPinsThroughRemoteHome() {
        let ctx = ServerContext(
            id: UUID(),
            displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: "~/.hermes"))
        )
        #expect(ctx.pinnedToProfile("scout").paths.stateDB == "~/.hermes/profiles/scout/state.db")
    }

    @Test func pinningIsIdempotentAndNeverNests() {
        let ctx = ServerContext(
            id: UUID(),
            displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: "~/.hermes"))
        )
        let once = ctx.pinnedToProfile("scout")
        #expect(once.pinnedToProfile("scout").paths.home == once.paths.home)
        // Re-pinning to a DIFFERENT bot must retarget, not nest.
        #expect(once.pinnedToProfile("sable").paths.home == "~/.hermes/profiles/sable")
    }

    @Test func defaultAndInvalidNamesLeaveTheRootHomeAlone() {
        let base = ServerContext.local(home: URL(fileURLWithPath: "/tmp/hermes-root"))
        for name in [nil, "", "default", "../escape", "Has Spaces", "UPPER"] {
            #expect(base.pinnedToProfile(name).paths.home == base.paths.home,
                    "\(name ?? "nil") must not repoint the home")
        }
    }

    /// The audit's finding, and the reason the test above is not sufficient
    /// on its own: it starts from a ROOT home, where "return self" and
    /// "return the root-normalized copy" are the same answer, so it could
    /// never have caught the bug.
    ///
    /// From a **profile-scoped** base — an SSH window scoped to `work`
    /// (#126) — they differ completely. Returning `self` would hand the
    /// `default` bot `work`'s `state.db` and launch its ACP unpinned inside
    /// `work`'s home: the wrong-profile bleed `pinnedToProfile` exists to
    /// prevent, arrived at through the one input everybody assumes is inert.
    @Test func defaultAndInvalidNamesFallBackToTheROOTOfAScopedBase() {
        let scoped = ServerContext(
            id: UUID(),
            displayName: "box",
            kind: .ssh(SSHConfig(host: "box", remoteHome: "~/.hermes/profiles/work"))
        )
        #expect(scoped.paths.stateDB == "~/.hermes/profiles/work/state.db")
        // NB: "work\n" is deliberately absent — `normalize` TRIMS before it
        // validates, so that IS a legitimate selection of `work`. The
        // no-trim path is `isValidName`'s guard (see BotModeFixupTests).
        for name in [nil, "", "default", "  default  ", "../escape", "Has Spaces", "UPPER"] {
            let pinned = scoped.pinnedToProfile(name)
            #expect(pinned.paths.home == "~/.hermes",
                    "\(name ?? "nil") must fall back to the ROOT home, not to work's")
            #expect(pinned.paths.stateDB == "~/.hermes/state.db")
        }
        // And a real name still retargets rather than nesting.
        #expect(scoped.pinnedToProfile("scout").paths.home == "~/.hermes/profiles/scout")
    }

    /// A local context scoped by `localHomeOverride` behaves identically —
    /// the same fallback, on the transport that has no `remoteHome`.
    @Test func aScopedLocalBaseAlsoFallsBackToItsRoot() {
        let scoped = ServerContext.local(home: URL(fileURLWithPath: "/tmp/hermes-root/profiles/work"))
        #expect(scoped.pinnedToProfile(nil).paths.home == "/tmp/hermes-root")
        #expect(scoped.pinnedToProfile("default").paths.home == "/tmp/hermes-root")
        #expect(scoped.pinnedToProfile("scout").paths.home == "/tmp/hermes-root/profiles/scout")
    }

    // MARK: - Canonical Bot Chat lookup

    @Test func findsTheHiddenBotChatThatOrdinaryListingsFilterOut() async throws {
        let home = tempRoot("hidden")
        try makeHome(at: home, rows: [
            SessionRow(id: "s-other", title: "Refactor the parser"),
            SessionRow(id: "s-bot", title: "Bot Chat", hidden: 1)
        ])
        let svc = await service(forHome: home)
        let found = await svc.locateCanonicalBotChat()
        #expect(found?.registryId == "s-bot")
        #expect(found?.liveId == "s-bot")
        // The ordinary listing must still hide it — this is the contrast
        // that makes the dedicated query necessary.
        let listed = await svc.fetchSessions(limit: 50).map(\.id)
        #expect(!listed.contains("s-bot"))
        #expect(listed.contains("s-other"))
        await svc.close()
    }

    @Test func findsAVisibleBotChatToo() async throws {
        // The session Scarf itself creates via the CLI is visible (no CLI
        // verb can hide it), so the lookup must not require hidden = 1.
        let home = tempRoot("visible")
        try makeHome(at: home, rows: [SessionRow(id: "s-bot", title: "Bot Chat", hidden: 0)])
        let svc = await service(forHome: home)
        #expect(await svc.locateCanonicalBotChat()?.registryId == "s-bot")
        await svc.close()
    }

    @Test func matchIsExactAndCaseSensitive() async throws {
        let home = tempRoot("exact")
        try makeHome(at: home, rows: [
            SessionRow(id: "s-1", title: "bot chat"),
            SessionRow(id: "s-2", title: "Bot Chat 2"),
            SessionRow(id: "s-3", title: " Bot Chat"),
            SessionRow(id: "s-4", title: "Group: Bot Chat")
        ])
        let svc = await service(forHome: home)
        #expect(await svc.locateCanonicalBotChat() == nil)
        await svc.close()
    }

    @Test func absentBotChatIsNilNotAnError() async throws {
        let home = tempRoot("absent")
        try makeHome(at: home, rows: [SessionRow(id: "s-1", title: "Something else")])
        let svc = await service(forHome: home)
        #expect(await svc.locateCanonicalBotChat() == nil)
        await svc.close()
    }

    @Test func worksOnALegacySchemaWithNoHiddenColumn() async throws {
        let home = tempRoot("nohidden")
        try makeHome(at: home, rows: [SessionRow(id: "s-bot", title: "Bot Chat")], withHiddenColumn: false)
        let svc = await service(forHome: home)
        #expect(await svc.locateCanonicalBotChat()?.registryId == "s-bot")
        await svc.close()
    }

    /// The wrong-profile bleed, made concrete: two profiles each own a Bot
    /// Chat, and a service pinned to one must never see the other's.
    @Test func eachProfileResolvesItsOwnBotChat() async throws {
        let root = tempRoot("profiles")
        try makeHome(at: root, rows: [SessionRow(id: "root-bot-chat", title: "Bot Chat", hidden: 1)])
        let scout = root.appendingPathComponent("profiles/scout", isDirectory: true)
        let sable = root.appendingPathComponent("profiles/sable", isDirectory: true)
        try makeHome(at: scout, rows: [SessionRow(id: "scout-chat", title: "Bot Chat", hidden: 1)])
        try makeHome(at: sable, rows: [SessionRow(id: "sable-chat", title: "Bot Chat", hidden: 1)])

        let base = ServerContext.local(home: root)
        for (profile, expected) in [("scout", "scout-chat"), ("sable", "sable-chat")] {
            let svc = HermesDataService(context: base.pinnedToProfile(profile))
            _ = await svc.open()
            #expect(await svc.locateCanonicalBotChat()?.registryId == expected)
            await svc.close()
        }
        // And the unpinned context still sees only the root's own row.
        let rootSvc = await service(forHome: root)
        #expect(await rootSvc.locateCanonicalBotChat()?.registryId == "root-bot-chat")
        await rootSvc.close()
    }

    /// A bot whose profile directory has no `state.db` yet (created, never
    /// run) must resolve to "no conversation", not to some other profile's.
    @Test func profileWithNoDatabaseResolvesToNothing() async throws {
        let root = tempRoot("nodb")
        try makeHome(at: root, rows: [SessionRow(id: "root-bot-chat", title: "Bot Chat", hidden: 1)])
        let svc = HermesDataService(context: ServerContext.local(home: root).pinnedToProfile("fresh"))
        _ = await svc.open()
        #expect(await svc.locateCanonicalBotChat() == nil)
        await svc.close()
    }

    // MARK: - Compression lineage

    @Test func projectsForwardToTheCompressionTip() async throws {
        let home = tempRoot("compress")
        try makeHome(at: home, rows: [
            SessionRow(id: "root", title: "Bot Chat", hidden: 1, endReason: "compression", endedAt: 2_000),
            SessionRow(id: "mid", parent: "root", endReason: "compression", startedAt: 2_001, endedAt: 3_000),
            SessionRow(id: "tip", parent: "mid", startedAt: 3_001)
        ])
        let svc = await service(forHome: home)
        let found = await svc.locateCanonicalBotChat()
        // The title stays the identity; the tip is what gets opened.
        #expect(found?.registryId == "root")
        #expect(found?.liveId == "tip")
        await svc.close()
    }

    // MARK: - Transport decision (liveSource)

    /// The resolve carries the LIVE tip's `sessions.source` because it is
    /// what decides the conversation transport: Hermes' ACP adapter
    /// restores only `source == "acp"` sessions (`acp_adapter/session.py:527`),
    /// so a CLI- or gateway-born Bot Chat must be conversed with over the
    /// CLI transport. This is the DB half of the release-blocking
    /// "Couldn't open this conversation" fix.
    @Test func liveSourceComesFromTheRegistryRowWhenThereIsNoChain() async throws {
        let home = tempRoot("source-flat")
        try makeHome(at: home, rows: [SessionRow(id: "s-bot", title: "Bot Chat", source: "cli")])
        let svc = await service(forHome: home)
        let found = await svc.locateCanonicalBotChat()
        #expect(found?.liveSource == "cli")
        #expect(found?.isACPBorn == false)
        await svc.close()
    }

    @Test func liveSourceComesFromTheTipNotTheRegistryOnACompressedChain() async throws {
        let home = tempRoot("source-chain")
        try makeHome(at: home, rows: [
            SessionRow(id: "root", title: "Bot Chat", endReason: "compression", source: "gateway", endedAt: 2_000),
            SessionRow(id: "tip", parent: "root", source: "acp", startedAt: 2_001)
        ])
        let svc = await service(forHome: home)
        let found = await svc.locateCanonicalBotChat()
        #expect(found?.liveId == "tip")
        #expect(found?.liveSource == "acp")
        #expect(found?.isACPBorn == true)
        await svc.close()
    }

    @Test func onlyAnExactACPSourceCountsAsACPBorn() {
        // Mirrors the adapter's own equality check — anything else, nil
        // included, must take the CLI transport (which works for every
        // session; the ACP resume works only for "acp" ones).
        for (source, expected) in [("acp", true), ("cli", false), ("gateway", false), ("ACP", false)] {
            let canonical = HermesDataService.CanonicalBotChat(registryId: "r", liveId: "l", liveSource: source)
            #expect(canonical.isACPBorn == expected, "\(source)")
        }
        #expect(HermesDataService.CanonicalBotChat(registryId: "r", liveId: "l").isACPBorn == false)
    }

    /// The gate that keeps the walk out of subagent transcripts: a child of
    /// a NON-compression-ended parent is not a continuation.
    @Test func doesNotFollowChildrenOfANonCompressedParent() async throws {
        let home = tempRoot("subagent")
        try makeHome(at: home, rows: [
            SessionRow(id: "root", title: "Bot Chat", hidden: 1, endReason: nil),
            SessionRow(id: "subagent", parent: "root", source: "tool", startedAt: 2_000)
        ])
        let svc = await service(forHome: home)
        #expect(await svc.locateCanonicalBotChat()?.liveId == "root")
        await svc.close()
    }

    @Test func excludesBranchDelegateAndToolChildrenUnderACompressedParent() async throws {
        let home = tempRoot("branch")
        try makeHome(at: home, rows: [
            SessionRow(id: "root", title: "Bot Chat", hidden: 1, endReason: "compression", endedAt: 2_000),
            SessionRow(id: "branch", parent: "root", startedAt: 2_100,
                       modelConfig: #"{"_branched_from": "root"}"#),
            SessionRow(id: "delegate", parent: "root", startedAt: 2_200,
                       modelConfig: #"{"_delegate_from": "root"}"#),
            SessionRow(id: "tool-child", parent: "root", source: "tool", startedAt: 2_300),
            SessionRow(id: "real-tip", parent: "root", startedAt: 2_050)
        ])
        let svc = await service(forHome: home)
        #expect(await svc.locateCanonicalBotChat()?.liveId == "real-tip")
        await svc.close()
    }

    @Test func aCyclicChainTerminatesInsteadOfHanging() async throws {
        let home = tempRoot("cycle")
        try makeHome(at: home, rows: [
            SessionRow(id: "a", title: "Bot Chat", hidden: 1, parent: "b", endReason: "compression", endedAt: 1),
            SessionRow(id: "b", parent: "a", endReason: "compression", endedAt: 2)
        ])
        let svc = await service(forHome: home)
        let found = await svc.locateCanonicalBotChat()
        #expect(found?.registryId == "a")
        #expect(["a", "b"].contains(found?.liveId ?? ""))
        await svc.close()
    }

    @Test func aSchemaWithoutModelConfigStillWalksTheChain() async throws {
        let home = tempRoot("nomodelconfig")
        try makeHome(at: home, rows: [
            SessionRow(id: "root", title: "Bot Chat", hidden: 1, endReason: "compression", endedAt: 2_000),
            SessionRow(id: "tip", parent: "root", startedAt: 2_001)
        ], withModelConfig: false)
        let svc = await service(forHome: home)
        #expect(await svc.locateCanonicalBotChat()?.liveId == "tip")
        await svc.close()
    }

    /// A database with no `end_reason` column cannot express a compression
    /// chain, and the walk's own predicate references that column — so the
    /// PRAGMA probe must short-circuit rather than let every hop fail into
    /// the catch. (`fetchSessionByExactTitle` is not exercised here:
    /// `sessionColumns` already selects `end_reason` unconditionally, so
    /// such a schema is outside what this service reads at all.)
    @Test func compressionWalkShortCircuitsWhenEndReasonIsAbsent() async throws {
        let home = tempRoot("noendreason")
        try makeHome(at: home, rows: [
            SessionRow(id: "root", title: "Bot Chat"),
            SessionRow(id: "child", parent: "root", startedAt: 2_000)
        ], withEndReason: false)
        let svc = await service(forHome: home)
        #expect(await svc.compressionTip(for: "root") == "root")
        await svc.close()
    }

    // MARK: - Canonical title + handle

    @Test func canonicalTitleIsTheExactHermesWireValue() {
        // hermes_state.SessionDB.CANONICAL_BOT_CHAT_TITLE (:10066) and
        // tools/bot_mode_probe.BOT_CHAT_TITLE (:41).
        #expect(BotChatSession.canonicalTitle == "Bot Chat")
    }

    @Test func defaultProfileIsAddressedAsHermes() {
        // tools/bot_mode_dm.py:210-211
        #expect(BotChatSession.handle(forProfile: "default") == "hermes")
        #expect(BotChatSession.handle(forProfile: "scout") == "scout")
    }

    // MARK: - Attribution prefix

    /// The format, pinned. `tools/bot_mode_dm.py:292`:
    ///     prefix = f"Message from 🤖 {sender_handle} (@{sender_handle}): "
    private func wirePrefix(_ handle: String) -> String {
        "Message from \u{1F916} \(handle) (@\(handle)): "
    }

    @Test func parsesTheExactWireFormat() {
        let parsed = BotMessageAttribution.parse(wirePrefix("scout") + "the build is green")
        #expect(parsed?.handle == "scout")
        #expect(parsed?.body == "the build is green")
    }

    @Test(arguments: [
        "scout", "hermes", "my-bot-42", "a", "b_c-d",
        // Peer handles come off another host's roster and the legacy
        // prompt-injected transport never validated them.
        "søren", "研究員", "bot\u{1F600}", "Ω-9"
    ])
    func parsesUnicodeAndPunctuatedHandles(handle: String) {
        let parsed = BotMessageAttribution.parse(wirePrefix(handle) + "hi")
        #expect(parsed?.handle == handle)
        #expect(parsed?.body == "hi")
    }

    @Test func multiLineBodiesSurviveVerbatim() {
        let body = "here is the diff:\n\n```swift\nlet x = 1\n```\n"
        let parsed = BotMessageAttribution.parse(wirePrefix("scout") + body)
        #expect(parsed?.body == body)
    }

    @Test func leadingWhitespaceBeforeThePrefixIsTolerated() {
        let parsed = BotMessageAttribution.parse("\n  " + wirePrefix("scout") + "hi")
        #expect(parsed?.handle == "scout")
    }

    @Test func extraSpacingInsideThePrefixIsTolerated() {
        let parsed = BotMessageAttribution.parse("Message from \u{1F916}  scout (@scout):   hi")
        #expect(parsed?.handle == "scout")
        #expect(parsed?.body == "hi")
    }

    // MARK: - Attribution false positives (the corruption cases)

    @Test(arguments: [
        // No prefix at all.
        "just a normal message",
        // Prefix words but no robot.
        "Message from scout (@scout): hi",
        // Robot but no parenthesized repeat — a human paraphrasing.
        "Message from \u{1F916} scout: hi",
        // Parenthesized handle DISAGREES with the bare one. This is the
        // one that matters: accepting it would attribute the message to
        // the wrong bot and eat the front of the body.
        "Message from \u{1F916} scout (@sable): hi",
        // Missing the colon.
        "Message from \u{1F916} scout (@scout) hi",
        // Missing the space after the colon.
        "Message from \u{1F916} scout (@scout):hi",
        // Empty handle.
        "Message from \u{1F916}  (@): hi",
        // Handle would have to span a newline.
        "Message from \u{1F916} scout\n(@scout): hi",
        // Someone talking ABOUT the format.
        "the prefix looks like Message from \u{1F916} scout (@scout): body",
        // Unclosed parenthesis.
        "Message from \u{1F916} scout (@scout: hi"
    ])
    func ordinaryMessagesAreNeverReattributed(content: String) {
        #expect(BotMessageAttribution.parse(content) == nil, "must not parse: \(content)")
    }

    @Test func aBodyThatItselfLooksLikeAPrefixIsNotDoubleStripped() {
        let inner = wirePrefix("sable") + "forwarded"
        let parsed = BotMessageAttribution.parse(wirePrefix("scout") + inner)
        #expect(parsed?.handle == "scout")
        // Exactly ONE prefix comes off — the body keeps the quoted one.
        #expect(parsed?.body == inner)
    }

    @Test func onlyUserRowsAreAttributed() {
        let content = wirePrefix("scout") + "hi"
        #expect(message(role: "user", content: content).botAttribution?.handle == "scout")
        // An agent recapping the prefix is quoting, not being quoted.
        #expect(message(role: "assistant", content: content).botAttribution == nil)
        #expect(message(role: "tool", content: content).botAttribution == nil)
    }

    private func message(role: String, content: String) -> HermesMessage {
        HermesMessage(
            id: 1, sessionId: "s", role: role, content: content,
            toolCallId: nil, toolCalls: [], toolName: nil,
            timestamp: nil, tokenCount: nil, finishReason: nil, reasoning: nil
        )
    }
}

#endif
