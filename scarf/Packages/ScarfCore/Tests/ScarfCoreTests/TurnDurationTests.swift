import Testing
import Foundation
@testable import ScarfCore

/// #148 — one total processing time per prompt, live and for history.
@Suite struct TurnDurationTests {

    private static let readA = #"{"sessionId": "s", "update": {"kind": "read", "locations": [{"path": "a.swift"}], "title": "read_file: a.swift", "toolCallId": "tc-a", "sessionUpdate": "tool_call"}}"#
    private static let doneA = #"{"sessionId": "s", "update": {"content": [{"content": {"text": "ok", "type": "text"}, "type": "content"}], "kind": "read", "status": "completed", "toolCallId": "tc-a", "sessionUpdate": "tool_call_update"}}"#

    private static func parse(_ updateJSON: String) throws -> ACPEvent {
        let json = #"{"jsonrpc":"2.0","method":"session/update","params":"# + updateJSON + "}"
        let raw = try JSONDecoder().decode(ACPRawMessage.self, from: Data(json.utf8))
        return try #require(ACPEventParser.parse(notification: raw))
    }

    private static func complete(_ reason: String) -> ACPEvent {
        .promptComplete(sessionId: "s", response: ACPPromptResult(
            stopReason: reason, inputTokens: 1, outputTokens: 1, thoughtTokens: 0, cachedReadTokens: 0
        ))
    }

    @MainActor private static func engagedVM() -> RichChatViewModel {
        let vm = RichChatViewModel(context: .local)
        vm.setSessionId("s")
        vm.addUserMessage(text: "go")
        return vm
    }

    private static func row(_ id: Int, _ role: String, _ t: Double?) -> HermesMessage {
        HermesMessage(id: id, sessionId: "s", role: role, content: "x", toolCallId: nil,
                      toolCalls: [], toolName: nil,
                      timestamp: t.map { Date(timeIntervalSince1970: $0) },
                      tokenCount: nil, finishReason: nil, reasoning: nil)
    }

    // MARK: - Live

    /// Text, then a tool, then the answer: several finalizes, one duration,
    /// on the turn's LAST assistant message, recorded at prompt complete.
    @Test @MainActor func multiSegmentTurnGetsOneDurationOnLastMessage() async throws {
        let vm = Self.engagedVM()
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Let me look", messageId: nil))
        vm.handleACPEvent(try Self.parse(Self.readA))
        vm.handleACPEvent(try Self.parse(Self.doneA))
        #expect(vm.turnDurations.isEmpty, "no pill while the turn is still running")
        try await Task.sleep(for: .milliseconds(60))
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Answer", messageId: nil))
        vm.handleACPEvent(Self.complete("end_turn"))

        let assistants = vm.messages.filter(\.isAssistant)
        #expect(assistants.count >= 2)
        #expect(vm.turnDurations.count == 1)
        let last = try #require(assistants.last)
        #expect(last.content == "Answer")
        let d = try #require(vm.turnDuration(forMessageId: last.id))
        #expect(d >= 0.05, "measures the whole turn, not time to first text")
        for m in assistants.dropLast() { #expect(vm.turnDuration(forMessageId: m.id) == nil) }
    }

    /// Tools first, text only at the end: the turn still gets its pill.
    @Test @MainActor func toolsThenTextTurnGetsDuration() throws {
        let vm = Self.engagedVM()
        vm.handleACPEvent(try Self.parse(Self.readA))
        vm.handleACPEvent(try Self.parse(Self.doneA))
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Done", messageId: nil))
        vm.handleACPEvent(Self.complete("end_turn"))
        let last = try #require(vm.messages.filter(\.isAssistant).last)
        #expect(last.content == "Done")
        #expect(vm.turnDuration(forMessageId: last.id) != nil)
        #expect(vm.turnDurations.count == 1)
    }

    /// A stopped turn records its duration on the partial reply; the next
    /// turn gets its own separate one.
    @Test @MainActor func cancelledTurnRecordsDurationAndNextTurnIsSeparate() throws {
        let vm = Self.engagedVM()
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Partial", messageId: nil))
        vm.noteTurnStopRequestedByUser()
        vm.handleACPEvent(Self.complete("cancelled"))
        let first = try #require(vm.messages.filter(\.isAssistant).last)
        #expect(vm.turnDuration(forMessageId: first.id) != nil)

        vm.addUserMessage(text: "again")
        vm.handleACPEvent(.messageChunk(sessionId: "s", text: "Second", messageId: nil))
        vm.handleACPEvent(Self.complete("end_turn"))
        let second = try #require(vm.messages.filter(\.isAssistant).last)
        #expect(second.id != first.id)
        #expect(vm.turnDurations.count == 2)
    }

    /// A turn with no assistant output records nothing.
    @Test @MainActor func emptyTurnRecordsNothing() {
        let vm = Self.engagedVM()
        vm.handleACPEvent(Self.complete("end_turn"))
        #expect(vm.turnDurations.isEmpty)
    }

    // MARK: - History derivation

    @Test func historyDurationIsUserToLastAssistantOfTurn() {
        let rows = [
            Self.row(1, "user", 100),
            Self.row(2, "assistant", 103),
            Self.row(3, "tool", 104),
            Self.row(4, "assistant", 112.5),
            Self.row(5, "user", 200),
            Self.row(6, "assistant", 201),
        ]
        let d = RichChatViewModel.derivedHistoryTurnDurations(from: rows)
        #expect(d == [4: 12.5, 6: 1])
    }

    @Test func historyHidesMissingOrImplausibleTimestamps() {
        let rows = [
            Self.row(1, "user", nil), Self.row(2, "assistant", 10),           // no start
            Self.row(3, "user", 20), Self.row(4, "assistant", nil),           // no end
            Self.row(5, "user", 50), Self.row(6, "assistant", 40),            // negative
            Self.row(7, "user", 60), Self.row(8, "assistant", 60 + 7 * 3600), // too long
            Self.row(9, "user", 0),                                           // unanswered
        ]
        #expect(RichChatViewModel.derivedHistoryTurnDurations(from: rows).isEmpty)
    }

    /// Assistant rows before the first user row (a truncated page) and
    /// local (non-DB) rows never get a derived duration.
    @Test func historyIgnoresLeadingAssistantsAndLocalRows() {
        let rows = [
            Self.row(1, "assistant", 5),
            Self.row(-3, "user", 10), Self.row(-4, "assistant", 12),
        ]
        #expect(RichChatViewModel.derivedHistoryTurnDurations(from: rows).isEmpty)
    }

    /// A pending local user echo ends the previous DB turn: a later DB
    /// assistant row must not stretch that turn's duration.
    @Test func localUserRowClosesPreviousTurn() {
        let rows = [
            Self.row(1, "user", 10), Self.row(2, "assistant", 12),
            Self.row(-3, "user", 100), Self.row(4, "assistant", 150),
        ]
        #expect(RichChatViewModel.derivedHistoryTurnDurations(from: rows) == [2: 2])
    }
}
