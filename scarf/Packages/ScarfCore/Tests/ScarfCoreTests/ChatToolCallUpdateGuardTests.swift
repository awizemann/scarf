import Testing
import Foundation
@testable import ScarfCore

/// P1a (Hermes v0.21.4 / v0.21.5 parity) — `tool_call_update` handling in
/// `RichChatViewModel` (shared by the Mac app and ScarfGo), driven through
/// `ACPEventParser` with the literal wire JSON Hermes emits.
///
/// Fixtures are the exact `model_dump(by_alias=True, exclude_none=True)`
/// output of the `acp` SDK builders Hermes calls, captured from the
/// installed Hermes venv:
///  - `acp.update_tool_call("perm-check-1", status="completed")` —
///    `acp_adapter/permissions.py:113` @ v2026.9.21 closing the synthetic
///    tool call from `_build_permission_tool_call` (`:54-64`).
///  - `acp.update_tool_call("edit-approval-2", status="failed")` — the
///    same close for `build_acp_edit_tool_call` (`edit_approval.py:199-207`),
///    wired with `send_update` at `server.py:922-929` @ v2026.9.21.
///  - `build_tool_abandoned` (`tools.py:838-848` @ v2026.9.21), sent by
///    `flush_open_tool_calls` (`events.py:97`) at turn end.
///
/// Also pins `workingSince` (the #145 elapsed indicator's clock source)
/// and `formatElapsedClock`.
@Suite struct ChatToolCallUpdateGuardTests {

    // MARK: - Fixtures

    private static func notification(_ update: String) -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":"#
            + update + "}}"
    }

    private static func toolStart(id: String, title: String = "terminal: ls -la") -> String {
        notification(#"{"kind": "execute", "rawInput": {"command": "ls -la"}, "status": "pending", "title": ""#
            + title + #"", "toolCallId": ""# + id + #"", "sessionUpdate": "tool_call"}"#)
    }

    private static func toolComplete(id: String, output: String = "total 0") -> String {
        notification(#"{"kind": "execute", "status": "completed", "rawOutput": ""# + output
            + #"", "toolCallId": ""# + id + #"", "sessionUpdate": "tool_call_update"}"#)
    }

    /// permissions.py:113 @ v2026.9.21 — allow → "completed".
    private static let permCheckClose = notification(
        #"{"status": "completed", "toolCallId": "perm-check-1", "sessionUpdate": "tool_call_update"}"#
    )

    /// Same close on the edit-approval path — deny → "failed".
    private static let editApprovalClose = notification(
        #"{"status": "failed", "toolCallId": "edit-approval-2", "sessionUpdate": "tool_call_update"}"#
    )

    private static let abandonedText =
        "This tool call ended without a result (blocked, denied, or interrupted)."

    /// `build_tool_abandoned(tc_id, "terminal")` @ v2026.9.21.
    private static func toolAbandoned(id: String) -> String {
        notification(#"{"content": [{"content": {"text": ""# + abandonedText
            + #"", "type": "text"}, "type": "content"}], "kind": "execute", "status": "failed", "toolCallId": ""#
            + id + #"", "sessionUpdate": "tool_call_update"}"#)
    }

    private static func chunk(_ text: String) -> String {
        notification(#"{"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": ""#
            + text + #""}}"#)
    }

    @MainActor
    private static func feed(_ vm: RichChatViewModel, _ json: String) {
        guard let raw = try? JSONDecoder().decode(ACPRawMessage.self, from: Data(json.utf8)),
              let event = ACPEventParser.parse(notification: raw) else {
            Issue.record("fixture failed to parse: \(json)")
            return
        }
        vm.handleACPEvent(event)
    }

    @MainActor
    private static func complete(_ vm: RichChatViewModel) {
        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "end_turn", inputTokens: 1, outputTokens: 1,
            thoughtTokens: 0, cachedReadTokens: 0
        )))
    }

    @MainActor
    private static func engagedVM() -> RichChatViewModel {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "go")
        return vm
    }

    private static func toolRows(_ vm: RichChatViewModel) -> [HermesMessage] {
        vm.messages.filter { $0.role == "tool" }
    }

    // MARK: - Permission / edit-approval closes (no start) are ignored

    /// The parser really yields a `toolCallUpdate` for the bare close —
    /// otherwise every test below would pass vacuously.
    @Test func bareApprovalCloseParsesAsToolCallUpdate() throws {
        let raw = try JSONDecoder().decode(ACPRawMessage.self, from: Data(Self.permCheckClose.utf8))
        guard case .toolCallUpdate(_, let update)? = ACPEventParser.parse(notification: raw) else {
            Issue.record("perm-check close did not parse as toolCallUpdate")
            return
        }
        #expect(update.toolCallId == "perm-check-1")
        #expect(update.status == "completed")
        #expect(update.content.isEmpty)
        #expect(update.rawOutput == nil)
    }

    /// A dangerous-command approval raised mid-tool: the `perm-check-1`
    /// close used to append an empty tool row AND finalize the streaming
    /// message, locking the still-running terminal call out of its own
    /// completion telemetry (exitCode stayed nil).
    @Test @MainActor func permissionCloseNeitherAddsARowNorFinalizesTheRunningTool() {
        let vm = Self.engagedVM()
        Self.feed(vm, Self.toolStart(id: "tc-0123456789ab"))
        Self.feed(vm, Self.permCheckClose)

        #expect(Self.toolRows(vm).isEmpty, "the approval close appended a tool row")
        #expect(vm.liveActivityStatus == .runningTool("terminal"),
                "the approval close flipped the live status as if the tool had finished")

        Self.feed(vm, Self.toolComplete(id: "tc-0123456789ab"))
        Self.complete(vm)

        let rows = Self.toolRows(vm)
        #expect(rows.map(\.toolCallId) == ["tc-0123456789ab"])
        let call = vm.messages.flatMap(\.toolCalls).first { $0.callId == "tc-0123456789ab" }
        #expect(call?.exitCode == 0, "the real completion never reached the streaming call")
        #expect(call?.duration != nil)
    }

    /// Edit-approval deny close while text is streaming: must not split
    /// the reply into two assistant messages.
    @Test @MainActor func editApprovalCloseDoesNotSplitTheStreamingReply() {
        let vm = Self.engagedVM()
        Self.feed(vm, Self.chunk("Editing "))
        Self.feed(vm, Self.editApprovalClose)
        Self.feed(vm, Self.chunk("done"))
        Self.complete(vm)

        let replies = vm.messages.filter { $0.isAssistant && !$0.content.isEmpty }
        #expect(replies.map(\.content) == ["Editing done"])
        #expect(Self.toolRows(vm).isEmpty)
    }

    // MARK: - Turn-end abandoned closes (v0.21.4 flush_open_tool_calls)

    /// Parallel calls, one finishes, the other is abandoned at turn end.
    /// B has already left `streamingToolCalls` (A's completion finalized
    /// it) yet must still get exactly one result row — the guard keys on
    /// "saw the start", not on the streaming buffer. A duplicate close for
    /// the same id adds nothing.
    @Test @MainActor func abandonedCallGetsExactlyOneFailedRow() {
        let vm = Self.engagedVM()
        Self.feed(vm, Self.toolStart(id: "tc-aaaaaaaaaaaa"))
        Self.feed(vm, Self.toolStart(id: "tc-bbbbbbbbbbbb", title: "terminal: sleep 999"))
        Self.feed(vm, Self.toolComplete(id: "tc-aaaaaaaaaaaa"))
        Self.feed(vm, Self.toolAbandoned(id: "tc-bbbbbbbbbbbb"))
        Self.feed(vm, Self.toolAbandoned(id: "tc-bbbbbbbbbbbb"))
        Self.complete(vm)

        let rows = Self.toolRows(vm)
        #expect(rows.map(\.toolCallId) == ["tc-aaaaaaaaaaaa", "tc-bbbbbbbbbbbb"])
        #expect(rows.last?.content == Self.abandonedText)
    }

    /// Pre-target hosts: an ordinary start → update pair is untouched.
    @Test @MainActor func ordinaryStartUpdatePairStillProducesItsRow() {
        let vm = Self.engagedVM()
        Self.feed(vm, Self.toolStart(id: "tc-cccccccccccc"))
        Self.feed(vm, Self.toolComplete(id: "tc-cccccccccccc", output: "file.txt"))
        Self.complete(vm)

        let rows = Self.toolRows(vm)
        #expect(rows.count == 1)
        #expect(rows.first?.toolCallId == "tc-cccccccccccc")
        #expect(rows.first?.content == "file.txt")
    }

    /// `reset()` forgets open ids — a stale close from the previous
    /// session can't land a row in the next one.
    @Test @MainActor func resetForgetsOpenToolCalls() {
        let vm = Self.engagedVM()
        Self.feed(vm, Self.toolStart(id: "tc-dddddddddddd"))
        vm.reset()
        vm.setSessionId("s")
        vm.addUserMessage(text: "again")
        Self.feed(vm, Self.toolAbandoned(id: "tc-dddddddddddd"))
        #expect(Self.toolRows(vm).isEmpty)
    }

    // MARK: - workingSince (#145 elapsed indicator source)

    /// Set once at the start of the busy period and held across tool
    /// completions (unlike `currentTurnStart`, which the first
    /// finalize clears); cleared when the turn settles.
    @Test @MainActor func workingSinceSpansTheWholeTurn() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        #expect(vm.workingSince == nil)

        vm.addUserMessage(text: "go")
        let start = vm.workingSince
        #expect(start != nil)

        Self.feed(vm, Self.toolStart(id: "tc-eeeeeeeeeeee"))
        Self.feed(vm, Self.toolComplete(id: "tc-eeeeeeeeeeee"))
        #expect(vm.workingSince == start, "a tool completion restarted the clock")

        // A `/steer`-style second send mid-turn keeps the original start.
        vm.addUserMessage(text: "also this")
        #expect(vm.workingSince == start)

        Self.complete(vm)
        #expect(vm.workingSince == nil)
    }

    /// The terminal-mode poll path (`markAgentWorking`) gets a clock too,
    /// and the unwind clears it.
    @Test @MainActor func workingSinceFollowsThePollPath() {
        let vm = RichChatViewModel(context: .local)
        vm.markAgentWorking()
        #expect(vm.workingSince != nil)
        vm.cancelPendingSend()
        #expect(vm.workingSince == nil)
    }

    @Test func elapsedClockFormatting() {
        #expect(RichChatViewModel.formatElapsedClock(0) == "0:00")
        #expect(RichChatViewModel.formatElapsedClock(12.9) == "0:12")
        #expect(RichChatViewModel.formatElapsedClock(65) == "1:05")
        #expect(RichChatViewModel.formatElapsedClock(3_723) == "1:02:03")
        #expect(RichChatViewModel.formatElapsedClock(-4) == "0:00")
    }
}
