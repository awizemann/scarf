import Testing
import Foundation
@testable import ScarfCore

/// Chat-transcript UX package coverage:
///  - P1 `MessageGroup.transcriptItems` — partitioning assistant
///    messages into text bubbles + aggregated activity segments, with
///    identical-consecutive-call collapse (×N).
///  - P2 `RichChatViewModel.liveActivityStatus` transitions.
///  - P3 tool-call argument backfill from `tool_call_update` and the
///    "{}" summary suppression; thoughts-only messages folding into
///    activity segments instead of rendering a blank shell.
@Suite struct TranscriptActivitySegmentTests {

    // MARK: - Helpers (match MessageGroupCoalesceTests patterns)

    private static func assistant(
        id: Int,
        content: String,
        reasoning: String? = nil,
        toolCalls: [HermesToolCall] = [],
        timestamp: Date = Date()
    ) -> HermesMessage {
        HermesMessage(
            id: id,
            sessionId: "s1",
            role: "assistant",
            content: content,
            toolCallId: nil,
            toolCalls: toolCalls,
            toolName: nil,
            timestamp: timestamp,
            tokenCount: nil,
            finishReason: nil,
            reasoning: reasoning
        )
    }

    private static func toolCall(
        id: String, name: String = "shell", arguments: String = "{}"
    ) -> HermesToolCall {
        HermesToolCall(callId: id, functionName: name, arguments: arguments)
    }

    private static func group(_ assistants: [HermesMessage]) -> MessageGroup {
        MessageGroup(id: 0, userMessage: nil, assistantMessages: assistants, toolResults: [:])
    }

    private static func items(
        _ assistants: [HermesMessage], coalesceText: Bool = true
    ) -> [MessageGroup.ChatTranscriptItem] {
        group(assistants).transcriptItems(coalesceText: coalesceText)
    }

    private static func segment(
        _ item: MessageGroup.ChatTranscriptItem?
    ) -> MessageGroup.ChatActivitySegment? {
        if case .activity(let seg) = item { return seg }
        return nil
    }

    private static func bubble(
        _ item: MessageGroup.ChatTranscriptItem?
    ) -> HermesMessage? {
        if case .bubble(let msg) = item { return msg }
        return nil
    }

    // MARK: - P1 partitioning

    @Test func consecutiveToolOnlyMessagesBecomeOneActivitySegment() {
        let list = Self.items([
            Self.assistant(id: -3, content: "", toolCalls: [Self.toolCall(id: "c1", name: "read_file", arguments: #"{"path":"a"}"#)]),
            Self.assistant(id: -2, content: "", toolCalls: [Self.toolCall(id: "c2", name: "terminal", arguments: #"{"command":"ls"}"#)]),
            Self.assistant(id: -1, content: "Done.")
        ])
        #expect(list.count == 2)
        let seg = Self.segment(list.first)
        #expect(seg != nil)
        #expect(seg?.totalToolCount == 2)
        #expect(seg?.entries.count == 2)
        #expect(Self.bubble(list.last)?.content == "Done.")
    }

    @Test func textBearingMessageStaysANormalBubble() {
        let list = Self.items([
            Self.assistant(id: -2, content: "Hello"),
            Self.assistant(id: -1, content: "", toolCalls: [Self.toolCall(id: "c1")])
        ])
        #expect(list.count == 2)
        #expect(Self.bubble(list.first)?.content == "Hello")
        #expect(Self.segment(list.last)?.totalToolCount == 1)
    }

    @Test func textPlusToolsMessageSplitsIntoBubbleThenActivity() {
        // finalize packs streamed text + the turn's tool calls into ONE
        // row; the text renders first, the calls join the activity run.
        let list = Self.items([
            Self.assistant(
                id: -2, content: "Let me check.",
                toolCalls: [Self.toolCall(id: "c1", name: "read_file")]
            ),
            Self.assistant(id: -1, content: "", toolCalls: [Self.toolCall(id: "c2", name: "terminal")])
        ])
        #expect(list.count == 2)
        let text = Self.bubble(list.first)
        #expect(text?.content == "Let me check.")
        #expect(text?.toolCalls.isEmpty == true)
        // Both messages' calls merged into one trailing segment.
        let seg = Self.segment(list.last)
        #expect(seg?.totalToolCount == 2)
    }

    @Test func identicalConsecutiveCallsCollapseWithRepeatCount() {
        let args = #"{"command":"swift test"}"#
        let list = Self.items([
            Self.assistant(id: -3, content: "", toolCalls: [Self.toolCall(id: "c1", name: "terminal", arguments: args)]),
            Self.assistant(id: -2, content: "", toolCalls: [Self.toolCall(id: "c2", name: "terminal", arguments: args)]),
            Self.assistant(id: -1, content: "", toolCalls: [Self.toolCall(id: "c3", name: "terminal", arguments: #"{"command":"ls"}"#)])
        ])
        let seg = Self.segment(list.first)
        #expect(seg?.totalToolCount == 3)
        #expect(seg?.entries.count == 2)
        #expect(seg?.entries.first?.count == 2)
        // Collapsed entry keeps the LATEST call's identity.
        #expect(seg?.entries.first?.call.callId == "c2")
        #expect(seg?.entries.last?.count == 1)
    }

    @Test func differentArgumentsDoNotCollapse() {
        let list = Self.items([
            Self.assistant(id: -2, content: "", toolCalls: [
                Self.toolCall(id: "c1", name: "read_file", arguments: #"{"path":"a"}"#),
                Self.toolCall(id: "c2", name: "read_file", arguments: #"{"path":"b"}"#)
            ])
        ])
        #expect(Self.segment(list.first)?.entries.count == 2)
    }

    @Test func thoughtsOnlyMessageFoldsIntoActivityNotABlankBubble() {
        // The former blank-shell case (P3b): reasoning, no text, no
        // tools. Must contribute reasoning to the activity segment and
        // never surface as a .bubble.
        let list = Self.items([
            Self.assistant(id: -2, content: "", reasoning: "pondering"),
            Self.assistant(id: -1, content: "Answer.")
        ])
        #expect(list.count == 2)
        let seg = Self.segment(list.first)
        #expect(seg?.reasoningCount == 1)
        #expect(seg?.totalToolCount == 0)
        #expect(Self.bubble(list.last)?.content == "Answer.")
    }

    @Test func fullyEmptyMessageEmitsNothing() {
        let list = Self.items([
            Self.assistant(id: -1, content: "")
        ])
        #expect(list.isEmpty)
    }

    @Test func pureTextRunsStillCoalesce() {
        let list = Self.items([
            Self.assistant(id: -2, content: "Part one"),
            Self.assistant(id: -1, content: "Part two")
        ])
        #expect(list.count == 1)
        #expect(Self.bubble(list.first)?.content == "Part one\n\nPart two")
    }

    @Test func coalescingDisabledDuringHydration() {
        let list = Self.items([
            Self.assistant(id: -2, content: "Part one"),
            Self.assistant(id: -1, content: "Part two")
        ], coalesceText: false)
        #expect(list.count == 2)
    }

    @Test func streamingMessageMarksSegmentLive() {
        let list = Self.items([
            Self.assistant(id: 0, content: "", toolCalls: [Self.toolCall(id: "c1")])
        ])
        #expect(Self.segment(list.first)?.isLive == true)
    }

    @Test func settledSegmentIsNotLive() {
        let list = Self.items([
            Self.assistant(id: -1, content: "", toolCalls: [Self.toolCall(id: "c1")])
        ])
        #expect(Self.segment(list.first)?.isLive == false)
    }

    // MARK: - DB-history shapes (cross-group aggregation + "(empty)" sentinel)

    private static func message(
        id: Int, role: String, content: String,
        toolCallId: String? = nil, toolCalls: [HermesToolCall] = []
    ) -> HermesMessage {
        HermesMessage(
            id: id, sessionId: "s1", role: role, content: content,
            toolCallId: toolCallId, toolCalls: toolCalls, toolName: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
            tokenCount: nil, finishReason: nil, reasoning: nil
        )
    }

    @Test func historyToolLoopAggregatesAcrossRowsIntoOneCollapsedCard() {
        // The ShabuBox shape: DB-loaded rows (positive ids, no id-0
        // streaming row) — user prompt, then a long run of identical
        // `find` calls each persisted as its own assistant row with a
        // tool-result row and an "(empty)" sentinel row between them.
        let findArgs = #"{"command":"find /x -type f | sort | head -20"}"#
        var rows: [HermesMessage] = [Self.message(id: 1, role: "user", content: "audit the tracker")]
        var id = 2
        for i in 0..<15 {
            rows.append(Self.message(
                id: id, role: "assistant", content: "",
                toolCalls: [Self.toolCall(id: "c\(i)", name: "terminal", arguments: findArgs)]
            ))
            rows.append(Self.message(id: id + 1, role: "tool", content: "files", toolCallId: "c\(i)"))
            rows.append(Self.message(id: id + 2, role: "assistant", content: "(empty)"))
            id += 3
        }
        rows.append(Self.message(id: id, role: "assistant", content: "All done."))

        let groups = RichChatViewModel.buildGroups(from: rows)
        // One user-rooted group holds the entire turn.
        #expect(groups.count == 1)

        let items = groups[0].transcriptItems(coalesceText: true)
        // ONE aggregated activity segment, then the closing text bubble.
        #expect(items.count == 2)
        let seg = Self.segment(items.first)
        #expect(seg?.totalToolCount == 15)
        // Identical consecutive calls collapse to ONE ×15 card even
        // with "(empty)" sentinel rows interleaved.
        #expect(seg?.entries.count == 1)
        #expect(seg?.entries.first?.count == 15)
        #expect(seg?.emptyResponseCount == 15)
        #expect(seg?.isLive == false)
        #expect(Self.bubble(items.last)?.content == "All done.")
    }

    @Test func userlessActivityRowsShareOneGroup() {
        // A history window that starts mid-turn (no user message):
        // activity-only assistant rows must accumulate into ONE group
        // instead of one single-call group per row.
        let rows: [HermesMessage] = [
            Self.message(id: 1, role: "assistant", content: "",
                         toolCalls: [Self.toolCall(id: "c1", name: "read_file")]),
            Self.message(id: 2, role: "tool", content: "ok", toolCallId: "c1"),
            Self.message(id: 3, role: "assistant", content: "",
                         toolCalls: [Self.toolCall(id: "c2", name: "read_file")]),
            Self.message(id: 4, role: "assistant", content: "(empty)")
        ]
        let groups = RichChatViewModel.buildGroups(from: rows)
        #expect(groups.count == 1)
        #expect(groups[0].transcriptItems(coalesceText: true).count == 1)
    }

    @Test func userlessTextAssistantsStillSplitGroups() {
        // Visible-text assistants keep today's one-reply-per-group
        // behavior in user-less runs.
        let rows: [HermesMessage] = [
            Self.message(id: 1, role: "assistant", content: "Reply one"),
            Self.message(id: 2, role: "assistant", content: "Reply two")
        ]
        let groups = RichChatViewModel.buildGroups(from: rows)
        #expect(groups.count == 2)
    }

    @Test func emptySentinelNeverRendersAsATextBubble() {
        let list = Self.items([
            Self.assistant(id: -1, content: "(empty)")
        ])
        #expect(list.count == 1)
        let seg = Self.segment(list.first)
        #expect(seg != nil)
        #expect(seg?.emptyResponseCount == 1)
        #expect(seg?.totalToolCount == 0)
    }

    @Test func emptySentinelDoesNotSplitAnActivityRun() {
        let args = #"{"path":"a"}"#
        let list = Self.items([
            Self.assistant(id: -3, content: "", toolCalls: [Self.toolCall(id: "c1", name: "read_file", arguments: args)]),
            Self.assistant(id: -2, content: "(empty)"),
            Self.assistant(id: -1, content: "", toolCalls: [Self.toolCall(id: "c2", name: "read_file", arguments: args)])
        ])
        #expect(list.count == 1)
        let seg = Self.segment(list.first)
        #expect(seg?.entries.count == 1)
        #expect(seg?.entries.first?.count == 2)
        #expect(seg?.emptyResponseCount == 1)
    }

    @Test func onlyExactSentinelMatches() {
        // Real text that merely mentions "(empty)" is a normal bubble.
        let list = Self.items([
            Self.assistant(id: -1, content: "The result was (empty) today")
        ])
        #expect(Self.bubble(list.first)?.content == "The result was (empty) today")
    }

    // MARK: - P3a argument backfill + "{}" suppression

    @Test func emptyObjectArgumentsSummaryIsBlank() {
        #expect(Self.toolCall(id: "c1", arguments: "{}").argumentsSummary == "")
        #expect(Self.toolCall(id: "c2", arguments: "").argumentsSummary == "")
        #expect(
            Self.toolCall(id: "c3", arguments: #"{"path":"x"}"#).argumentsSummary == "x"
        )
    }

    @Test @MainActor func toolCallUpdateBackfillsPlaceholderArguments() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "go")

        // Start event without rawInput → stored as the "{}" placeholder.
        vm.handleACPEvent(.toolCallStart(sessionId: "s", call: ACPToolCallEvent(
            toolCallId: "t1", title: "read_file: foo",
            kind: "read", status: "in_progress",
            content: "", rawInput: nil
        )))
        // Completion carries the real arguments.
        vm.handleACPEvent(.toolCallUpdate(sessionId: "s", update: ACPToolCallUpdateEvent(
            toolCallId: "t1", kind: "read", status: "completed",
            content: "ok", rawOutput: nil,
            rawInput: ["path": "/tmp/foo.txt"]
        )))

        let call = vm.messages
            .filter(\.isAssistant)
            .flatMap(\.toolCalls)
            .first { $0.callId == "t1" }
        #expect(call != nil)
        // Note: JSONSerialization escapes "/" as "\/" — compare via the
        // parsed summary, not raw substring.
        #expect(call?.arguments != "{}")
        #expect(call?.argumentsSummary == "/tmp/foo.txt")
    }

    @Test @MainActor func toolCallUpdateNeverOverwritesRealArguments() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "go")

        vm.handleACPEvent(.toolCallStart(sessionId: "s", call: ACPToolCallEvent(
            toolCallId: "t1", title: "read_file: foo",
            kind: "read", status: "in_progress",
            content: "", rawInput: ["path": "original"]
        )))
        vm.handleACPEvent(.toolCallUpdate(sessionId: "s", update: ACPToolCallUpdateEvent(
            toolCallId: "t1", kind: "read", status: "completed",
            content: "ok", rawOutput: nil,
            rawInput: ["path": "different"]
        )))

        let call = vm.messages
            .filter(\.isAssistant)
            .flatMap(\.toolCalls)
            .first { $0.callId == "t1" }
        #expect(call?.arguments.contains("original") == true)
    }

    // MARK: - P2 live status transitions

    @Test @MainActor func liveActivityStatusFollowsTheTurn() {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        // Pre-first-event gap: nil (three-dots territory).
        vm.addUserMessage(text: "go")
        #expect(vm.liveActivityStatus == nil)

        vm.handleACPEvent(.thoughtChunk(sessionId: "s", text: "hmm"))
        #expect(vm.liveActivityStatus == .reasoning)

        vm.handleACPEvent(.toolCallStart(sessionId: "s", call: ACPToolCallEvent(
            toolCallId: "t1", title: "terminal: ls",
            kind: "execute", status: "in_progress",
            content: "", rawInput: ["command": "ls"]
        )))
        #expect(vm.liveActivityStatus == .runningTool("terminal"))

        vm.handleACPEvent(.toolCallUpdate(sessionId: "s", update: ACPToolCallUpdateEvent(
            toolCallId: "t1", kind: "execute", status: "completed",
            content: "ok", rawOutput: nil
        )))
        #expect(vm.liveActivityStatus == .receiving)

        // Visible text streaming → status stands down.
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Here"))
        #expect(vm.liveActivityStatus == nil)

        vm.handleACPEvent(.promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: "end_turn",
            inputTokens: 1, outputTokens: 1,
            thoughtTokens: 0, cachedReadTokens: 0
        )))
        #expect(vm.liveActivityStatus == nil)
    }
}
