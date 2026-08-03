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
///  2. `RichChatViewModel.handleACPEvent` — a summary-flagged chunk reaches
///     the transcript (bypassing the pre-engagement replay-suppression
///     gate) with the flag threaded onto the resulting `HermesMessage`,
///     while a plain replay chunk is still dropped.
@Suite struct HermesV020CompactionSummaryTests {

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

    // MARK: - RichChatViewModel: replayed summary gets collapsed treatment

    /// A plain (non-summary) replay chunk stays gate-dropped —
    /// unchanged pre-existing behavior (`RichChatEngagementGateTests`
    /// locks this down independently).
    @Test @MainActor func plainReplayChunkStillDroppedPreEngagement() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "ordinary replayed reply"))
        #expect(vm.messages.isEmpty)
    }

    /// The core Wave C4 behavior: a `compactionSummary`-flagged
    /// `agent_message_chunk` reaches the transcript even before the user
    /// has sent a prompt in this session (that's exactly when Hermes
    /// replays it), and the resulting message is flagged for the
    /// collapsed-by-default UI treatment.
    @Test @MainActor func standaloneSummaryChunkBypassesGateAndIsFlaggedOnMessage() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.handleACPEvent(.messageChunk(
            sessionId: "s",
            text: "Summary of the conversation so far...",
            isCompactionSummary: true,
            containsCompactionSummary: false
        ))
        let msg = vm.messages.first
        #expect(msg != nil)
        #expect(msg?.content == "Summary of the conversation so far...")
        #expect(msg?.isCompactionSummary == true)
        #expect(msg?.containsCompactionSummary == false)
    }

    /// A `containsCompactionSummary`-flagged chunk (merged-tail replay:
    /// real preserved content + summary) also bypasses the gate, but is
    /// NOT marked `isCompactionSummary` — it must stay fully visible,
    /// never collapsed.
    @Test @MainActor func mergedTailChunkBypassesGateWithoutFullCollapseFlag() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.handleACPEvent(.messageChunk(
            sessionId: "s",
            text: "Real preserved reply. Summary of earlier turns...",
            isCompactionSummary: false,
            containsCompactionSummary: true
        ))
        let msg = vm.messages.first
        #expect(msg != nil)
        #expect(msg?.isCompactionSummary == false)
        #expect(msg?.containsCompactionSummary == true)
    }

    /// Same bypass-the-gate behavior for a replayed `user_message_chunk`
    /// summary (the compressor sometimes persists the handoff under
    /// `role="user"` to preserve turn alternation).
    @Test @MainActor func standaloneSummaryUserChunkBypassesGateAndIsFlaggedOnMessage() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.handleACPEvent(.userMessageChunk(
            sessionId: "s",
            text: "Handoff summary under role=user",
            isCompactionSummary: true,
            containsCompactionSummary: false
        ))
        let msg = vm.messages.first
        #expect(msg != nil)
        #expect(msg?.role == "user")
        #expect(msg?.isCompactionSummary == true)
    }

    /// A non-summary `user_message_chunk` (shouldn't happen in practice —
    /// Scarf never sends a live one, and replay only sends this update
    /// type for summary messages — but tolerate it defensively) is still
    /// gate-dropped like any other pre-engagement replay content.
    @Test @MainActor func plainUserChunkStillDroppedPreEngagement() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
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
