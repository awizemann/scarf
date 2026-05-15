import Testing
import Foundation
@testable import ScarfCore

/// Pure-logic tests for the chat ordering invariants that prevent
/// the "user prompt jumps below the agent response" bug.
///
/// Two layers under test:
///  1. `HermesMessage.chronologicalOrder` — the composite-key
///     comparator used by every merge/sort site in
///     `RichChatViewModel`.
///  2. `RichChatViewModel.mergedAfterPoll(fetched:currentLocal:)` —
///     the polling-tick merge that has to preserve the streaming
///     message, optimistic tool result placeholders, and pending
///     user messages whose semantic twin hasn't yet appeared in the
///     DB snapshot.
@Suite struct RichChatOrderingTests {

    // MARK: - Test helpers

    private static func msg(
        id: Int,
        role: String,
        content: String = "",
        timestamp: Date,
        toolCallId: String? = nil,
        toolCalls: [HermesToolCall] = []
    ) -> HermesMessage {
        HermesMessage(
            id: id,
            sessionId: "s1",
            role: role,
            content: content,
            toolCallId: toolCallId,
            toolCalls: toolCalls,
            toolName: nil,
            timestamp: timestamp,
            tokenCount: nil,
            finishReason: nil,
            reasoning: nil
        )
    }

    // MARK: - chronologicalOrder

    @Test func userBeforeAssistantOnTimestampTie() {
        // Repro of the prompt-jump root cause: two messages stamped in
        // the same `Date()` bucket. Without the id tie-break, Swift's
        // sort is unstable and can flip them.
        let t = Date()
        let user = Self.msg(id: -1, role: "user", content: "hi", timestamp: t)
        let assistant = Self.msg(id: 0, role: "assistant", content: "yo", timestamp: t)
        var arr = [assistant, user]
        arr.sort(by: HermesMessage.chronologicalOrder)
        #expect(arr.first?.role == "user")
        #expect(arr.last?.role == "assistant")
    }

    @Test func persistedUserBeforePersistedAssistantOnTimestampTie() {
        // Same invariant but for fully-persisted DB rows. SQLite ROWIDs
        // are monotonic and the user msg is always written before its
        // assistant within a turn, so user has the lower id.
        let t = Date()
        let user = Self.msg(id: 100, role: "user", timestamp: t)
        let assistant = Self.msg(id: 101, role: "assistant", timestamp: t)
        var arr = [assistant, user]
        arr.sort(by: HermesMessage.chronologicalOrder)
        #expect(arr.map(\.id) == [100, 101])
    }

    @Test func timestampDominatesIdTieBreak() {
        // When timestamps differ, id is irrelevant — this is the steady
        // state for cross-turn ordering.
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1)
        let earlier = Self.msg(id: 999, role: "assistant", timestamp: t0)
        let later = Self.msg(id: 1, role: "user", timestamp: t1)
        var arr = [later, earlier]
        arr.sort(by: HermesMessage.chronologicalOrder)
        #expect(arr.first?.id == 999)
    }

    @Test func nilTimestampsSortFirstButStableOnId() {
        // `.distantPast` substitution means nil-timestamp rows go to
        // the front; id tie-break still applies.
        let nilA = Self.msg(id: 1, role: "user", timestamp: .distantPast)
        let nilB = Self.msg(id: 2, role: "assistant", timestamp: .distantPast)
        let real = Self.msg(id: 3, role: "user", timestamp: Date())
        var arr = [real, nilB, nilA]
        arr.sort(by: HermesMessage.chronologicalOrder)
        #expect(arr.map(\.id) == [1, 2, 3])
    }

    @Test func crossSessionMergePreservesChronologicalInterleave() {
        // Reflects the loadSessionHistory path that merges origin +
        // ACP session rows. Different session ids, interleaved
        // timestamps; composite key reproduces real chronology.
        let t0 = Date()
        let origin1 = Self.msg(id: 50, role: "user", timestamp: t0)
        let origin2 = Self.msg(id: 51, role: "assistant", timestamp: t0.addingTimeInterval(2))
        let acp1 = Self.msg(id: 1, role: "user", timestamp: t0.addingTimeInterval(1))
        let acp2 = Self.msg(id: 2, role: "assistant", timestamp: t0.addingTimeInterval(3))
        var combined = [origin2, acp1, origin1, acp2]
        combined.sort(by: HermesMessage.chronologicalOrder)
        #expect(combined.map(\.id) == [50, 1, 51, 2])
    }

    // MARK: - render window

    @Test func visibleGroupsStartsPinnedToLatestSmallWindow() {
        let vm = RichChatViewModel()
        vm.messageGroups = (0..<60).map { idx in
            MessageGroup(id: idx, userMessage: nil, assistantMessages: [], toolResults: [:])
        }
        #expect(vm.visibleGroups.count == RenderWindow.initial)
        #expect(vm.visibleGroups.first?.id == 45)
        #expect(vm.visibleGroups.last?.id == 59)
        #expect(vm.hasHiddenOlderInMemoryGroups)
        #expect(!vm.hasHiddenNewerInMemoryGroups)
    }

    @Test func renderWindowSlidesOlderAndNewerWithFixedCapacity() {
        let vm = RichChatViewModel()
        vm.messageGroups = (0..<80).map { idx in
            MessageGroup(id: idx, userMessage: nil, assistantMessages: [], toolResults: [:])
        }
        #expect(vm.showEarlierInMemory())
        #expect(vm.visibleGroups.count == RenderWindow.capacity)
        #expect(vm.visibleGroups.first?.id == 35)
        #expect(vm.visibleGroups.last?.id == 79)
        #expect(vm.hasHiddenOlderInMemoryGroups)
        #expect(!vm.hasHiddenNewerInMemoryGroups)

        #expect(vm.showEarlierInMemory())
        #expect(vm.visibleGroups.count == RenderWindow.capacity)
        #expect(vm.visibleGroups.first?.id == 20)
        #expect(vm.visibleGroups.last?.id == 64)
        #expect(vm.hasHiddenOlderInMemoryGroups)
        #expect(vm.hasHiddenNewerInMemoryGroups)

        #expect(vm.showNewerInMemory())
        #expect(vm.visibleGroups.count == RenderWindow.initial)
        #expect(vm.visibleGroups.first?.id == 65)
        #expect(vm.visibleGroups.last?.id == 79)
        #expect(!vm.hasHiddenNewerInMemoryGroups)
    }

    // MARK: - mergedAfterPoll

    @Test func pollingPreservesStreamingMessage() {
        // A polling tick lands while the assistant is mid-stream.
        // `fetched` only carries the user prompt that Hermes has
        // committed; the streaming chunk (id == 0) lives only in
        // memory and must survive the merge.
        let t = Date()
        let userInDB = Self.msg(id: 1, role: "user", content: "ping", timestamp: t)
        let streamingLocal = Self.msg(
            id: 0, role: "assistant", content: "po", timestamp: t.addingTimeInterval(0.1)
        )
        let merged = RichChatViewModel.mergedAfterPoll(
            fetched: [userInDB],
            currentLocal: [userInDB, streamingLocal]
        )
        #expect(merged.contains { $0.id == 0 })
        #expect(merged.last?.id == 0)
    }

    @Test func pollingPreservesPendingUserMessage() {
        // Optimistic user msg created locally (negative id) before
        // Hermes persisted it. `fetched` is empty for this content;
        // merge must keep the local row.
        let t = Date()
        let pendingUser = Self.msg(id: -1, role: "user", content: "draft", timestamp: t)
        let merged = RichChatViewModel.mergedAfterPoll(
            fetched: [],
            currentLocal: [pendingUser]
        )
        #expect(merged.count == 1)
        #expect(merged.first?.content == "draft")
    }

    @Test func pollingDropsPendingUserOnceDBCatchesUp() {
        // Once the DB has a user row with the same content, the local
        // optimistic copy is redundant and gets dropped.
        let t = Date()
        let dbUser = Self.msg(id: 5, role: "user", content: "draft", timestamp: t)
        let pendingUser = Self.msg(id: -1, role: "user", content: "draft", timestamp: t)
        let merged = RichChatViewModel.mergedAfterPoll(
            fetched: [dbUser],
            currentLocal: [pendingUser]
        )
        #expect(merged.count == 1)
        #expect(merged.first?.id == 5)
    }

    @Test func pollingPreservesToolPlaceholderUntilDBCatchesUp() {
        // Tool result placeholders live only in memory until Hermes
        // persists them. Match by `toolCallId`, not content.
        let t = Date()
        let assistant = Self.msg(id: 10, role: "assistant", timestamp: t)
        let toolPlaceholder = Self.msg(
            id: -2, role: "tool", content: "stdout", timestamp: t.addingTimeInterval(0.5),
            toolCallId: "call_abc"
        )
        let merged = RichChatViewModel.mergedAfterPoll(
            fetched: [assistant],
            currentLocal: [assistant, toolPlaceholder]
        )
        #expect(merged.contains { $0.toolCallId == "call_abc" })
    }

    @Test func pollingDropsToolPlaceholderOnceDBHasIt() {
        let t = Date()
        let assistant = Self.msg(id: 10, role: "assistant", timestamp: t)
        let dbTool = Self.msg(
            id: 11, role: "tool", content: "stdout", timestamp: t.addingTimeInterval(0.4),
            toolCallId: "call_abc"
        )
        let placeholder = Self.msg(
            id: -2, role: "tool", content: "stdout", timestamp: t.addingTimeInterval(0.5),
            toolCallId: "call_abc"
        )
        let merged = RichChatViewModel.mergedAfterPoll(
            fetched: [assistant, dbTool],
            currentLocal: [assistant, placeholder]
        )
        let toolRows = merged.filter { $0.role == "tool" }
        #expect(toolRows.count == 1)
        #expect(toolRows.first?.id == 11)
    }

    @Test func pollingPreservesFinalizedAssistantUntilDBCatchesUp() {
        // PromptComplete finalizes the visible assistant reply as a
        // negative-id local row. A DB watcher can fire before Hermes has
        // persisted the same assistant; the merge must not make the last
        // exchange disappear.
        let t = Date()
        let dbUser = Self.msg(id: 10, role: "user", content: "q", timestamp: t)
        let localAssistant = Self.msg(
            id: -2,
            role: "assistant",
            content: "visible answer",
            timestamp: t.addingTimeInterval(0.5)
        )
        let merged = RichChatViewModel.mergedAfterPoll(
            fetched: [dbUser],
            currentLocal: [dbUser, localAssistant]
        )
        #expect(merged.contains { $0.id == -2 && $0.content == "visible answer" })
    }

    @Test func pollingDropsFinalizedAssistantOnceDBHasTextTwin() {
        let t = Date()
        let dbUser = Self.msg(id: 10, role: "user", content: "q", timestamp: t)
        let dbAssistant = Self.msg(
            id: 11,
            role: "assistant",
            content: "visible answer",
            timestamp: t.addingTimeInterval(0.4)
        )
        let localAssistant = Self.msg(
            id: -2,
            role: "assistant",
            content: "visible answer",
            timestamp: t.addingTimeInterval(0.5)
        )
        let merged = RichChatViewModel.mergedAfterPoll(
            fetched: [dbUser, dbAssistant],
            currentLocal: [dbUser, localAssistant]
        )
        let assistants = merged.filter(\.isAssistant)
        #expect(assistants.count == 1)
        #expect(assistants.first?.id == 11)
    }

    @Test func pollingMergeIsChronologicallyOrdered() {
        // Output must be in chronological order so the trailing
        // VStack render matches reality.
        let t = Date()
        let user = Self.msg(id: 1, role: "user", content: "q", timestamp: t)
        let streaming = Self.msg(id: 0, role: "assistant", content: "a", timestamp: t.addingTimeInterval(0.1))
        let pending = Self.msg(id: -1, role: "user", content: "q2", timestamp: t.addingTimeInterval(0.05))
        let merged = RichChatViewModel.mergedAfterPoll(
            fetched: [user],
            currentLocal: [user, pending, streaming]
        )
        #expect(merged.map(\.id) == [1, -1, 0])
    }
}
