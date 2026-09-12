import Testing
import Foundation
@testable import ScarfCore

/// Pure-logic tests for `MessageGroup.coalescedAssistantBubbles` —
/// the render-side merge that collapses runs of consecutive
/// pure-text assistant messages into a single bubble.
///
/// The data model is left untouched; only what the chat view
/// renders is merged. Tool-bearing assistants and the streaming
/// bubble (id == 0) are explicit boundaries that are never merged.
@Suite struct MessageGroupCoalesceTests {

    // MARK: - Helpers

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

    private static func toolCall(id: String, name: String = "shell") -> HermesToolCall {
        HermesToolCall(callId: id, functionName: name, arguments: "{}")
    }

    private static func group(_ assistants: [HermesMessage]) -> MessageGroup {
        MessageGroup(
            id: 0,
            userMessage: nil,
            assistantMessages: assistants,
            toolResults: [:]
        )
    }

    // MARK: - Coalescing behavior

    @Test func twoPureTextAssistantsMergeIntoOneBubble() throws {
        // The screenshot case: agent emits two consecutive pure-text
        // assistant messages with no tool call between them. They
        // should render as one bubble.
        let g = Self.group([
            Self.assistant(id: -2, content: "Part one of the table"),
            Self.assistant(id: -1, content: "Part two continuing the table")
        ])
        let bubbles = g.coalescedAssistantBubbles
        try #require(bubbles.count == 1)
        #expect(bubbles[0].content == "Part one of the table\n\nPart two continuing the table")
        // Identity is the LAST source's id so the metadata footer
        // (token count, finishReason) stays attached to the
        // turn-end message.
        #expect(bubbles[0].id == -1)
    }

    @Test func toolBearingAssistantBreaksTheRun() {
        // [text, text-with-tool-call, text] → 3 separate bubbles.
        // Tool calls are meaningful boundaries; merging them away
        // would lose the visual association between text and tool.
        let g = Self.group([
            Self.assistant(id: -3, content: "Before"),
            Self.assistant(id: -2, content: "Calling tool", toolCalls: [Self.toolCall(id: "c1")]),
            Self.assistant(id: -1, content: "After")
        ])
        let bubbles = g.coalescedAssistantBubbles
        #expect(bubbles.count == 3)
        #expect(bubbles.map(\.id) == [-3, -2, -1])
    }

    @Test func streamingBubbleIsNeverCoalesced() throws {
        // [settled-text, streaming] → 2 bubbles. Coalescing across
        // the streaming boundary would let mid-stream body re-evals
        // churn the merged content; the standalone streaming bubble
        // stays standalone until finalize.
        let g = Self.group([
            Self.assistant(id: -1, content: "Settled text"),
            Self.assistant(id: 0, content: "Streaming chunk so far")
        ])
        let bubbles = g.coalescedAssistantBubbles
        try #require(bubbles.count == 2)
        #expect(bubbles[0].id == -1)
        #expect(bubbles[1].id == 0)
    }

    @Test func reasoningChannelsAreConcatenated() throws {
        // Each source carries its own reasoning blob — preserve
        // both in the merged bubble so the disclosure renders
        // the full thought trace.
        let g = Self.group([
            Self.assistant(id: -2, content: "First", reasoning: "thought 1"),
            Self.assistant(id: -1, content: "Second", reasoning: "thought 2")
        ])
        let bubbles = g.coalescedAssistantBubbles
        try #require(bubbles.count == 1)
        #expect(bubbles[0].reasoning == "thought 1\n\nthought 2")
    }

    @Test func reasoningSkippedWhenAllNil() {
        // No source has reasoning → merged bubble has nil reasoning,
        // not an empty string. The chat bubble's `hasReasoning` check
        // is what controls whether the disclosure renders.
        let g = Self.group([
            Self.assistant(id: -2, content: "First"),
            Self.assistant(id: -1, content: "Second")
        ])
        let bubbles = g.coalescedAssistantBubbles
        #expect(bubbles[0].reasoning == nil)
        #expect(bubbles[0].hasReasoning == false)
    }

    @Test func emptyContentStringsAreFilteredFromJoin() throws {
        // A pure-text assistant with empty content (rare — recovered
        // from a finalize-with-tool-only turn) shouldn't introduce
        // leading/trailing blank-line gaps in the merged output.
        let g = Self.group([
            Self.assistant(id: -3, content: ""),
            Self.assistant(id: -2, content: "Real content"),
            Self.assistant(id: -1, content: "")
        ])
        let bubbles = g.coalescedAssistantBubbles
        try #require(bubbles.count == 1)
        #expect(bubbles[0].content == "Real content")
    }

    @Test func singleAssistantPassesThroughUnchanged() throws {
        // No coalescing required — return the source message
        // identity-preserved (not a synthesized clone). The bubble's
        // Equatable can short-circuit on `===`-like comparisons.
        let original = Self.assistant(id: -1, content: "Just one")
        let g = Self.group([original])
        let bubbles = g.coalescedAssistantBubbles
        try #require(bubbles.count == 1)
        #expect(bubbles[0].id == original.id)
        #expect(bubbles[0].content == original.content)
    }

    @Test func emptyGroupYieldsEmptyBubbles() {
        let g = Self.group([])
        #expect(g.coalescedAssistantBubbles.isEmpty)
    }

    @Test func mergedTimestampIsLastSourceTimestamp() {
        // Timestamp should reflect turn-end so the chat list's
        // chronological ordering invariants stay correct.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(5)
        let g = Self.group([
            Self.assistant(id: -2, content: "Earlier", timestamp: t0),
            Self.assistant(id: -1, content: "Later", timestamp: t1)
        ])
        #expect(g.coalescedAssistantBubbles[0].timestamp == t1)
    }
}
