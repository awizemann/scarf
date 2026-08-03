import Testing
import Foundation
@testable import ScarfCore

/// Wave C4 (Hermes v0.20 parity, t-641d65a5): `_meta.hermes.compactionSummary`
/// / `_meta.hermes.containsCompactionSummary` on `agent_message_chunk` /
/// `user_message_chunk` `session/update` notifications — stamped only during
/// `session/load` / `session/resume` history replay (see
/// `_history_summary_meta` in Hermes' `acp_adapter/server.py`).
///
/// Covers three layers:
///  1. `ACPEventParser.parse` — the two flags parse off `_meta`, tolerate
///     absence / malformed shapes, default `false`.
///  2. `HermesMessage.classifyCompactionSummary` +
///     `HermesDataService.messageFromRow` — hydration owns the styling:
///     Hermes persists summaries as ORDINARY active rows in `state.db`
///     (no schema flag), so DB hydration classifies rows by the handoff
///     markers `ContextCompressor` embeds in the content, and the flags
///     ride the hydrated `HermesMessage`.
///  3. `RichChatViewModel.handleACPEvent` — replay chunks (summary-flagged
///     or not) stay suppressed pre-engagement; the DB-hydrated history is
///     authoritative, so no replay bypass exists.
@Suite struct HermesV020CompactionSummaryTests {

    /// Exact opener shared by Hermes' current `SUMMARY_PREFIX` and every
    /// `_HISTORICAL_SUMMARY_PREFIXES` entry (agent/context_compressor.py).
    private static let summaryOpener = "[CONTEXT COMPACTION — REFERENCE ONLY]"
    /// `LEGACY_SUMMARY_PREFIX` (pre-v0.19 short form).
    private static let legacyOpener = "[CONTEXT SUMMARY]:"
    /// `_MERGED_SUMMARY_DELIMITER` for merge-into-tail summaries.
    private static let mergedDelimiter = "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]"

    // MARK: - Helpers

    private func parse(_ json: String) -> ACPEvent? {
        let data = Data(json.utf8)
        guard let raw = try? JSONDecoder().decode(ACPRawMessage.self, from: data) else {
            Issue.record("failed to decode ACPRawMessage fixture")
            return nil
        }
        return ACPEventParser.parse(notification: raw)
    }

    // MARK: - Chunk parsing: agent_message_chunk

    @Test func agentChunkParsesStandaloneCompactionSummaryFlag() {
        let json = #"""
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{
            "sessionUpdate":"agent_message_chunk",
            "content":{"text":"Summary of prior turns..."},
            "_meta":{"hermes":{"compactionSummary":true}}
        }}}
        """#
        guard case let .messageChunk(sid, text, isSummary, containsSummary) = parse(json) else {
            Issue.record("expected .messageChunk")
            return
        }
        #expect(sid == "s1")
        #expect(text == "Summary of prior turns...")
        #expect(isSummary == true)
        #expect(containsSummary == false)
    }

    @Test func agentChunkParsesContainsCompactionSummaryFlag() {
        let json = #"""
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{
            "sessionUpdate":"agent_message_chunk",
            "content":{"text":"Real reply. Summary of earlier turns..."},
            "_meta":{"hermes":{"containsCompactionSummary":true}}
        }}}
        """#
        guard case let .messageChunk(_, _, isSummary, containsSummary) = parse(json) else {
            Issue.record("expected .messageChunk")
            return
        }
        #expect(isSummary == false)
        #expect(containsSummary == true)
    }

    @Test func agentChunkWithNoMetaDefaultsBothFlagsFalse() {
        // Live (non-replay) chunk, or an older Hermes host — no `_meta`
        // key at all. Must parse cleanly with both flags false, not throw.
        let json = #"""
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{
            "sessionUpdate":"agent_message_chunk",
            "content":{"text":"ordinary reply"}
        }}}
        """#
        guard case let .messageChunk(_, text, isSummary, containsSummary) = parse(json) else {
            Issue.record("expected .messageChunk")
            return
        }
        #expect(text == "ordinary reply")
        #expect(isSummary == false)
        #expect(containsSummary == false)
    }

    /// `_meta` is ACP's reserved extensibility namespace — any shape other
    /// clients / future Hermes versions stuff in there must be tolerated,
    /// not thrown on. Covers: `_meta` as a non-dict scalar, `hermes` as a
    /// non-dict scalar, and the two flags carrying non-bool JSON values.
    @Test func agentChunkToleratesMalformedMetaShapes() {
        let cases = [
            // `_meta` itself is a string, not an object.
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"t"},"_meta":"unexpected"}}}"#,
            // `_meta.hermes` is a number, not an object.
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"t"},"_meta":{"hermes":42}}}}"#,
            // Sibling keys under `_meta.hermes` Scarf doesn't know about yet.
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"t"},"_meta":{"hermes":{"sessionProvenance":{"acpSessionId":"x"}}}}}}"#,
            // The flags carry non-bool JSON values (a string, a number).
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"t"},"_meta":{"hermes":{"compactionSummary":"true"}}}}}"#,
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"text":"t"},"_meta":{"hermes":{"containsCompactionSummary":1}}}}}"#,
        ]
        for json in cases {
            guard case let .messageChunk(_, text, isSummary, containsSummary) = parse(json) else {
                Issue.record("expected .messageChunk for fixture: \(json)")
                continue
            }
            #expect(text == "t")
            #expect(isSummary == false)
            #expect(containsSummary == false)
        }
    }

    // MARK: - Chunk parsing: user_message_chunk

    @Test func userChunkParsesStandaloneCompactionSummaryFlag() {
        let json = #"""
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{
            "sessionUpdate":"user_message_chunk",
            "content":{"text":"Handoff summary persisted as a user turn"},
            "_meta":{"hermes":{"compactionSummary":true}}
        }}}
        """#
        guard case let .userMessageChunk(sid, text, isSummary, containsSummary) = parse(json) else {
            Issue.record("expected .userMessageChunk")
            return
        }
        #expect(sid == "s1")
        #expect(text == "Handoff summary persisted as a user turn")
        #expect(isSummary == true)
        #expect(containsSummary == false)
    }

    @Test func userChunkWithNoMetaDefaultsBothFlagsFalse() {
        let json = #"""
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{
            "sessionUpdate":"user_message_chunk",
            "content":{"text":"hi there"}
        }}}
        """#
        guard case let .userMessageChunk(_, text, isSummary, containsSummary) = parse(json) else {
            Issue.record("expected .userMessageChunk")
            return
        }
        #expect(text == "hi there")
        #expect(isSummary == false)
        #expect(containsSummary == false)
    }

    // MARK: - classifyCompactionSummary: standalone

    @Test func classifiesCurrentPrefixAsStandaloneSummary() {
        let content = Self.summaryOpener + " Earlier turns were compacted "
            + "into the summary below. ...\n## Summary\nWe discussed things."
        let flags = HermesMessage.classifyCompactionSummary(content: content)
        #expect(flags.isSummary == true)
        #expect(flags.containsSummary == false)
    }

    @Test func classifiesLegacyPrefixAsStandaloneSummary() {
        let flags = HermesMessage.classifyCompactionSummary(
            content: Self.legacyOpener + " Older-format summary body."
        )
        #expect(flags.isSummary == true)
        #expect(flags.containsSummary == false)
    }

    /// Hermes lstrips before matching (`classify_summary_content` does
    /// `.lstrip()`), so leading whitespace must not defeat detection.
    @Test func classifiesPrefixAfterLeadingWhitespace() {
        let flags = HermesMessage.classifyCompactionSummary(
            content: "\n  " + Self.summaryOpener + " summary body"
        )
        #expect(flags.isSummary == true)
    }

    // MARK: - classifyCompactionSummary: merged-tail

    @Test func classifiesMergedTailAsContainsSummary() {
        let content = "[PRIOR CONTEXT — for reference only; not a new message]\n"
            + "the preserved real tail turn\n"
            + Self.mergedDelimiter + "\n"
            + Self.summaryOpener + " summary body"
        let flags = HermesMessage.classifyCompactionSummary(content: content)
        #expect(flags.isSummary == false)
        #expect(flags.containsSummary == true)
    }

    /// The delimiter alone doesn't classify — the summary prefix must
    /// follow it, mirroring Hermes exactly.
    @Test func mergedDelimiterWithoutFollowingPrefixIsNotASummary() {
        let flags = HermesMessage.classifyCompactionSummary(
            content: "quoting the string " + Self.mergedDelimiter + " with no summary after"
        )
        #expect(flags.isSummary == false)
        #expect(flags.containsSummary == false)
    }

    // MARK: - classifyCompactionSummary: non-matches

    @Test func ordinaryContentIsNotASummary() {
        let flags = HermesMessage.classifyCompactionSummary(content: "just a normal reply")
        #expect(flags.isSummary == false)
        #expect(flags.containsSummary == false)
    }

    /// The marker mid-content (e.g. a user quoting it in a code block)
    /// must NOT match — only the documented start-of-content position.
    @Test func markerMidContentDoesNotMatch() {
        let flags = HermesMessage.classifyCompactionSummary(
            content: "What does the string " + Self.summaryOpener + " mean in my transcript?"
        )
        #expect(flags.isSummary == false)
        #expect(flags.containsSummary == false)
    }

    @Test func emptyContentIsNotASummary() {
        let flags = HermesMessage.classifyCompactionSummary(content: "")
        #expect(flags.isSummary == false)
        #expect(flags.containsSummary == false)
    }

    #if canImport(SQLite3)
    // MARK: - Hydration: messageFromRow sets the flags off persisted rows

    private func makeMessageRow(id: Int, role: String, content: String) -> Row {
        let pairs: [(String, SQLValue)] = [
            ("id", .integer(Int64(id))),
            ("session_id", .text("s1")),
            ("role", .text(role)),
            ("content", .text(content)),
            ("tool_call_id", .null),
            ("tool_calls", .null),
            ("tool_name", .null),
            ("timestamp", .real(1_700_000_000.0 + Double(id))),
            ("token_count", .integer(10)),
            ("finish_reason", .null),
        ]
        var values: [SQLValue] = []
        var columnIndex: [String: Int] = [:]
        for (i, pair) in pairs.enumerated() {
            values.append(pair.1)
            columnIndex[pair.0] = i
        }
        return Row(values: values, columnIndex: columnIndex)
    }

    /// End-to-end through the real hydration path: Hermes persists the
    /// summary as an ordinary active row (hermes_state.py
    /// `archive_and_compact`); `fetchMessages` → `messageFromRow` must
    /// classify it and set the styling flags. This is the layer the old
    /// replay-bypass tests missed — with a DB behind the VM,
    /// `loadSessionHistory` wholesale-replaces `messages` with these rows.
    @Test func hydratedStandaloneSummaryRowIsFlagged() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        _ = await service.open()
        let rows = [
            makeMessageRow(id: 3, role: "assistant", content: "real reply"),
            makeMessageRow(
                id: 2, role: "user",
                content: Self.summaryOpener + " Earlier turns were compacted...\nsummary body"
            ),
            makeMessageRow(id: 1, role: "user", content: "hi"),
        ]
        await mock._seedRows(forSQLPrefix: "SELECT id, session_id", rows)

        let messages = await service.fetchMessages(sessionId: "s1", limit: 10, before: nil)
        #expect(messages.count == 3)
        #expect(messages.map { $0.isCompactionSummary } == [false, true, false])
        #expect(messages.allSatisfy { !$0.containsCompactionSummary })
    }

    @Test func hydratedMergedTailRowGetsContainsFlagOnly() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        _ = await service.open()
        let merged = "preserved tail content\n" + Self.mergedDelimiter + "\n"
            + Self.summaryOpener + " summary body"
        await mock._seedRows(
            forSQLPrefix: "SELECT id, session_id",
            [makeMessageRow(id: 1, role: "user", content: merged)]
        )

        let messages = await service.fetchMessages(sessionId: "s1", limit: 10, before: nil)
        #expect(messages.first?.isCompactionSummary == false)
        #expect(messages.first?.containsCompactionSummary == true)
    }

    @Test func hydratedOrdinaryRowsHaveNoFlags() async {
        let mock = MockHermesQueryBackend()
        let service = HermesDataService(context: .local, backend: mock)
        _ = await service.open()
        await mock._seedRows(
            forSQLPrefix: "SELECT id, session_id",
            [makeMessageRow(id: 1, role: "user", content: "plain question about compaction")]
        )

        let messages = await service.fetchMessages(sessionId: "s1", limit: 10, before: nil)
        #expect(messages.first?.isCompactionSummary == false)
        #expect(messages.first?.containsCompactionSummary == false)
    }
    #endif

    // MARK: - RichChatViewModel: replay stays fully suppressed pre-engagement

    /// A plain (non-summary) replay chunk stays gate-dropped —
    /// unchanged pre-existing behavior (`RichChatEngagementGateTests`
    /// locks this down independently).
    @Test @MainActor func plainReplayChunkStillDroppedPreEngagement() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "ordinary replayed reply"))
        #expect(vm.messages.isEmpty)
    }

    /// Summary-flagged replay chunks are ALSO gate-dropped now: the
    /// DB-hydrated history (which classifies the persisted rows itself)
    /// is authoritative, so letting the replay copies through would
    /// double-render or be clobbered by `loadSessionHistory`.
    @Test @MainActor func summaryFlaggedReplayChunksAreAlsoDroppedPreEngagement() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.handleACPEvent(.messageChunk(
            sessionId: "s",
            text: "Summary of the conversation so far...",
            isCompactionSummary: true,
            containsCompactionSummary: false
        ))
        vm.handleACPEvent(.messageChunk(
            sessionId: "s",
            text: "Merged tail...",
            isCompactionSummary: false,
            containsCompactionSummary: true
        ))
        vm.handleACPEvent(.userMessageChunk(
            sessionId: "s",
            text: "Handoff summary under role=user",
            isCompactionSummary: true,
            containsCompactionSummary: false
        ))
        #expect(vm.messages.isEmpty)
    }

    /// `user_message_chunk` is dropped even post-engagement — Scarf
    /// never sends a live one; anything arriving is replayed history the
    /// DB already owns.
    @Test @MainActor func userChunkDroppedPostEngagementToo() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.markPromptSent()
        vm.handleACPEvent(.userMessageChunk(sessionId: "s", text: "not a summary"))
        #expect(vm.messages.isEmpty)
    }

    /// Live turns are unaffected: a normal post-engagement streaming
    /// chunk with no meta flags builds an assistant message with both
    /// flags false, matching the old zero-meta behavior exactly.
    @Test @MainActor func liveChunkAfterEngagementHasNoCompactionFlags() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.markPromptSent()
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "live reply"))
        let msg = vm.messages.first { $0.isAssistant }
        #expect(msg?.content == "live reply")
        #expect(msg?.isCompactionSummary == false)
        #expect(msg?.containsCompactionSummary == false)
    }
}
