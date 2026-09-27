#if canImport(SQLite3)

import Testing
import Foundation
import SQLite3
@testable import ScarfCore

/// R16b (Hermes v0.21.5 audit follow-ups, t-25209c91) — the ScarfCore half
/// of the chat / sessions / compression-chain fixes:
///
/// - R11 carry-over: the chat pane loads a rotated compression chain's
///   whole lineage, not just the tip's rows.
/// - R14-2: a mid-chat rotation (ACP `sessionProvenance`) extends the live
///   transcript to the new internal session.
/// - R14-3: `SessionChainDelete` deletes every segment, tip first.
/// - R14-1: `fetchSessionForDetail` resolves a search hit the list does
///   not show.
/// - R09 carry-over: a plugin-rewritten reply replaces the streamed bubble.
///
/// DB tests run on Hermes's own v0.21.5 DDL with the R11 seed (chainRoot →
/// chainMid → chainTip, archivedRoot, orphanDelegate, delegateChild, …).
@Suite struct ChatLineageR16bTests {

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-r16b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let path = home.appendingPathComponent("state.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw TransportError.other(message: "sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        let sql = HermesV0215StateDDL.schemaSQL + HermesV0215StateDDL.ftsSQL
            + HermesV0215SessionsDataR11Tests.seedSQL
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TransportError.other(message: "fixture failed: \(msg)")
        }
        return home
    }

    private static let chain = ["chainRoot", "chainMid", "chainTip"]

    // MARK: - Provenance parsing

    private static func infoUpdate(sessionId: String, meta: [String: Any]?) -> ACPEvent? {
        var update: [String: Any] = ["sessionUpdate": "session_info_update", "title": "T"]
        if let meta { update["_meta"] = meta }
        let obj: [String: Any] = ["jsonrpc": "2.0", "method": "session/update",
                                  "params": ["sessionId": sessionId, "update": update]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let raw = try! JSONDecoder().decode(ACPRawMessage.self, from: data)
        return ACPEventParser.parse(notification: raw)
    }

    /// The shape `build_session_provenance` emits after a rotation
    /// (acp_adapter/provenance.py @ v2026.9.24).
    nonisolated(unsafe) private static let rotationMeta: [String: Any] = ["hermes": ["sessionProvenance": [
        "acpSessionId": "chainRoot", "currentHermesSessionId": "chainMid",
        "rootHermesSessionId": "chainRoot", "parentHermesSessionId": "chainRoot",
        "sessionKind": "continuation", "compressionDepth": 1,
        "previousHermesSessionId": "chainRoot", "reason": "compression", "creatorKind": "compression",
    ]]]

    @Test func provenanceParsesFromSessionInfoUpdate() throws {
        let event = try #require(Self.infoUpdate(sessionId: "chainRoot", meta: Self.rotationMeta))
        guard case let .sessionInfoUpdate(sid, title, _, provenance) = event else {
            Issue.record("wrong event \(event)"); return
        }
        #expect(sid == "chainRoot")
        #expect(title == "T")
        #expect(provenance == ACPSessionProvenance(
            currentHermesSessionId: "chainMid", rootHermesSessionId: "chainRoot",
            previousHermesSessionId: "chainRoot", reason: "compression"))
        // Hosts without the extension: no `_meta`, no provenance (C1).
        let plain = try #require(Self.infoUpdate(sessionId: "s", meta: nil))
        guard case let .sessionInfoUpdate(_, _, _, none) = plain else { return }
        #expect(none == nil)
    }

    // MARK: - R11 carry-over: lineage load

    @Test func resumedChainLoadsTheWholeLineage() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let tipOnly = RichChatViewModel(context: .local(home: home))
        await tipOnly.loadSessionHistory(sessionId: "chainTip")
        #expect(tipOnly.messages.map(\.content) == ["tip turn", "tip reply"])

        let vm = RichChatViewModel(context: .local(home: home))
        await vm.loadSessionHistory(sessionId: "chainTip", lineage: Self.chain)
        #expect(vm.messages.map(\.content)
                == ["chain opening", "chain early reply", "mid turn", "tip turn", "tip reply"])
        #expect(vm.transcriptSessionIds == Self.chain)
        // The pagination cursor covers the whole lineage.
        #expect(vm.oldestLoadedMessageID == 5)
        await vm.cleanup()
        await tipOnly.cleanup()
    }

    /// A lineage that doesn't include the attached id is ignored.
    @Test func unrelatedLineageIsIgnored() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        await vm.loadSessionHistory(sessionId: "live", lineage: Self.chain)
        #expect(vm.transcriptSessionIds == ["live"])
        #expect(!vm.messages.contains { $0.content == "chain opening" })
        await vm.cleanup()
    }

    // MARK: - R14-2: rotation extends the live transcript

    @Test func rotationFollowsTheNewInternalSession() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = RichChatViewModel(context: .local(home: home))
        await vm.loadSessionHistory(sessionId: "chainRoot")
        vm.setSessionId("chainRoot")
        #expect(!vm.messages.contains { $0.content == "mid turn" })

        // A title-only update names the ACP id itself: no rotation.
        vm.handleACPEvent(try #require(Self.infoUpdate(sessionId: "chainRoot", meta: ["hermes": ["sessionProvenance": [
            "currentHermesSessionId": "chainRoot"]]])))
        #expect(vm.transcriptSessionIds == ["chainRoot"])

        vm.handleACPEvent(try #require(Self.infoUpdate(sessionId: "chainRoot", meta: Self.rotationMeta)))
        #expect(vm.transcriptSessionIds == ["chainRoot", "chainMid"])
        #expect(vm.transcriptCovers("chainMid"))

        // The next DB reconcile reads the rows stored after the rotation.
        await vm.reconcileWithDB(sessionId: "chainRoot")
        #expect(vm.messages.map(\.content) == ["chain opening", "chain early reply", "mid turn"])
        await vm.cleanup()
    }

    // MARK: - R14-3: chain delete

    @Test func chainDeleteRunsTipFirstAndStopsAtAFailure() {
        #expect(SessionChainDelete.deletionOrder(lineage: Self.chain, rowId: "chainTip")
                == ["chainTip", "chainMid", "chainRoot"])
        #expect(SessionChainDelete.deletionOrder(lineage: [], rowId: "solo") == ["solo"])

        var calls: [String] = []
        let all = SessionChainDelete.run(["chainTip", "chainMid", "chainRoot"]) { calls.append($0); return 0 }
        #expect(all == SessionChainDelete.Outcome(deleted: ["chainTip", "chainMid", "chainRoot"], failed: nil))

        calls = []
        let partial = SessionChainDelete.run(["chainTip", "chainMid", "chainRoot"]) { id in
            calls.append(id); return id == "chainMid" ? 1 : 0
        }
        // The root is never attempted after the middle fails: it stays,
        // still a chain root, rather than an orphaned fragment.
        #expect(calls == ["chainTip", "chainMid"])
        #expect(partial == SessionChainDelete.Outcome(deleted: ["chainTip"], failed: ("chainMid", 1)))
    }

    // MARK: - R14-1: search hits outside the list

    @Test func searchHitsOutsideTheListResolveForDisplay() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let service = HermesDataService(context: .local(home: home))
        #expect(await service.open())

        let archived = try #require(await service.fetchSessionForDetail(id: "archivedRoot"))
        #expect(archived.session.id == "archivedRoot")
        #expect(archived.isArchived)
        #expect(!archived.isListed)

        let orphan = try #require(await service.fetchSessionForDetail(id: "orphanDelegate"))
        #expect(!orphan.isArchived)
        #expect(!orphan.isListed)

        let delegate = try #require(await service.fetchSessionForDetail(id: "delegateChild"))
        #expect(delegate.session.id == "delegateChild")
        #expect(!delegate.isListed)

        // A hit in the middle of a chain opens the whole chain, as listed.
        let mid = try #require(await service.fetchSessionForDetail(id: "chainMid"))
        #expect(mid.session.id == "chainTip")
        #expect(mid.session.lineageIds == Self.chain)
        #expect(mid.isListed)
        #expect(!mid.isArchived)

        let live = try #require(await service.fetchSessionForDetail(id: "live"))
        #expect(live.isListed)
        #expect(await service.fetchSessionForDetail(id: "no-such-session") == nil)
        await service.close()
    }

    /// One id keeps the single-session SQL byte for byte.
    @Test func singleIdPredicateIsTheSingleSessionSQL() {
        let one = HermesDataService.sessionIdPredicate(["a"])
        #expect(one.sql == "session_id = ?")
        #expect(one.params.count == 1)
        let many = HermesDataService.sessionIdPredicate(["a", "b", "a", ""])
        #expect(many.sql == "session_id IN (?,?)")
        #expect(many.params.count == 2)
    }

    // MARK: - R09 carry-over: plugin-rewritten replies

    private static func chunk(_ text: String, id: String?) -> ACPEvent {
        .messageChunk(sessionId: "s", text: text, messageId: id)
    }

    @MainActor private static func engaged() -> RichChatViewModel {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "q")
        vm.markPromptSent()
        return vm
    }

    @MainActor private static func assistantTexts(_ vm: RichChatViewModel) -> [String] {
        vm.messages.filter(\.isAssistant).map(\.content)
    }

    /// A rewrite that restates the streamed text (a footer plugin) replaces
    /// it instead of doubling it.
    @Test @MainActor func restatingRewriteReplacesTheStreamingReply() {
        let vm = Self.engaged()
        vm.handleACPEvent(Self.chunk("Here is the answer ", id: "m1"))
        vm.handleACPEvent(Self.chunk("you asked for.", id: "m1"))
        vm.handleACPEvent(Self.chunk("Here is the answer you asked for.\n\n[footer]", id: "m1"))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "end_turn", inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0)))
        #expect(Self.assistantTexts(vm) == ["Here is the answer you asked for.\n\n[footer]"])
    }

    /// A short reply so far is never taken for a restatement: "*" then
    /// "**Note" is two real deltas.
    @Test @MainActor func shortReplyPrefixIsNotARewrite() {
        let vm = Self.engaged()
        vm.handleACPEvent(Self.chunk("*", id: "m1"))
        vm.handleACPEvent(Self.chunk("**Note", id: "m1"))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "end_turn", inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0)))
        #expect(Self.assistantTexts(vm) == ["***Note"])
    }

    /// The rewrite of a reply a tool round already finalized replaces that
    /// bubble — its id is closed, and only the rewrite reuses it.
    @Test @MainActor func rewriteOfAFinalizedReplyReplacesThatBubble() {
        let vm = Self.engaged()
        vm.handleACPEvent(Self.chunk("Let me check.", id: "m1"))
        vm.handleACPEvent(.toolCallStart(sessionId: "s", call: ACPToolCallEvent(
            toolCallId: "t1", title: "terminal: ls", kind: "execute", status: "pending", content: "", rawInput: nil)))
        vm.handleACPEvent(.toolCallUpdate(sessionId: "s", update: ACPToolCallUpdateEvent(
            toolCallId: "t1", kind: "execute", status: "completed", content: "ok", rawOutput: nil, rawInput: nil)))
        vm.handleACPEvent(Self.chunk("REWRITTEN", id: "m1"))
        #expect(Self.assistantTexts(vm).contains("REWRITTEN"))
        #expect(!Self.assistantTexts(vm).contains("Let me check."))
        #expect(!Self.assistantTexts(vm).contains { $0.contains("Let me check.REWRITTEN") })
    }

    /// Ordinary deltas, and a new reply under a new id, are untouched.
    @Test @MainActor func ordinaryDeltasStillAppend() {
        let vm = Self.engaged()
        vm.handleACPEvent(Self.chunk("ab", id: "m1"))
        vm.handleACPEvent(Self.chunk("ab", id: "m1")) // repeats, but no longer than the reply
        vm.handleACPEvent(Self.chunk("c", id: "m1"))
        vm.handleACPEvent(Self.chunk("second reply", id: "m2"))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "end_turn", inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0)))
        #expect(Self.assistantTexts(vm) == ["ababc", "second reply"])
    }

    /// A new turn forgets the last turn's reply ids.
    @Test @MainActor func finalizedIdsDoNotCarryIntoTheNextTurn() {
        let vm = Self.engaged()
        vm.handleACPEvent(Self.chunk("first", id: "m1"))
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "end_turn", inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedReadTokens: 0)))
        vm.addUserMessage(text: "again")
        vm.markPromptSent()
        vm.handleACPEvent(Self.chunk("reply", id: "m1"))
        #expect(Self.assistantTexts(vm).first == "first")
    }
}

#endif
