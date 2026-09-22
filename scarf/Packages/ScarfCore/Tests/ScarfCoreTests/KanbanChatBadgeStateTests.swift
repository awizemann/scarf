import Foundation
import Testing
@testable import ScarfCore

/// The chat Kanban badge's three pre-existing defects, pinned as behaviour.
///
/// Not `@MainActor` and no I/O — pure value transitions (see the project's
/// ScarfCore test-hog rule).
@Suite("Kanban chat badge state")
struct KanbanChatBadgeStateTests {

    private static func task(_ status: String) -> HermesKanbanTask {
        HermesKanbanTask(id: "t-\(status)", title: status, status: status)
    }

    // MARK: - F2a: the count resets when the chat changes

    @Test("switching chats clears the previous chat's count")
    func rebindClearsTheCount() {
        var state = KanbanChatBadgeState()
        state.bind(to: "chat-A")
        let issued = state.beginPoll()
        #expect(issued == "chat-A")
        state.accept(count: 4, issuedFor: "chat-A")
        #expect(state.liveCount == 4)

        state.bind(to: "chat-B")
        #expect(
            state.liveCount == nil,
            "chat B must render no number until its own poll lands, not chat A's 4"
        )
        #expect(state.sessionId == "chat-B")
    }

    @Test("losing the session (a /new) clears the count too")
    func rebindToNilClearsTheCount() {
        var state = KanbanChatBadgeState()
        state.bind(to: "chat-A")
        state.accept(count: 3, issuedFor: "chat-A")
        #expect(state.liveCount == 3)

        state.bind(to: nil)
        #expect(state.liveCount == nil)
        #expect(state.beginPoll() == nil, "there is nothing to scope a poll by")
    }

    @Test("rebinding to the same session keeps the count and the in-flight poll")
    func rebindingToTheSameSessionIsANoOp() {
        var state = KanbanChatBadgeState()
        state.bind(to: "chat-A")
        state.accept(count: 2, issuedFor: "chat-A")
        _ = state.beginPoll()

        // A view re-render re-runs bind; it must not wipe good state or
        // release the single-flight slot.
        state.bind(to: "chat-A")
        #expect(state.liveCount == 2)
        #expect(state.isInflight)
        #expect(state.beginPoll() == nil)
    }

    // MARK: - F2b: a poll issued for the old chat must not land on the new one

    @Test("a result for a superseded session is dropped")
    func staleResultIsRejected() throws {
        var state = KanbanChatBadgeState()
        state.bind(to: "chat-A")
        let claimed = state.beginPoll()
        let issued = try #require(claimed)

        // The pane switches to chat B while A's detached CLI call is still
        // running (view cancellation does not reach `Task.detached`).
        state.bind(to: "chat-B")
        let landed = state.accept(count: 7, issuedFor: issued)

        #expect(landed == false)
        #expect(
            state.liveCount == nil,
            "chat A's 7 must not be shown as chat B's count"
        )
    }

    @Test("a failure for a superseded session neither clears nor backs off the new one")
    func staleFailureIsRejected() throws {
        var state = KanbanChatBadgeState()
        state.bind(to: "chat-A")
        let claimed = state.beginPoll()
        let issued = try #require(claimed)

        state.bind(to: "chat-B")
        state.accept(count: 1, issuedFor: "chat-B")

        let landed = state.fail(issuedFor: issued)
        #expect(landed == false)
        #expect(state.liveCount == 1, "chat B's good count survives chat A's failure")
        #expect(state.currentInterval == state.baseInterval, "and so does its cadence")
    }

    @Test("the previous chat's in-flight poll cannot suppress the new chat's first tick")
    func rebindReleasesTheSingleFlightSlot() {
        var state = KanbanChatBadgeState()
        state.bind(to: "chat-A")
        _ = state.beginPoll()
        #expect(state.beginPoll() == nil, "single-flight holds within a session")

        state.bind(to: "chat-B")
        #expect(state.beginPoll() == "chat-B")
    }

    // MARK: - F6: what counts as "live"

    @Test(
        "each Hermes status counts, or doesn't, by the badge rule",
        arguments: [
            // v2026.9.21:hermes_cli/kanban_db.py:103 VALID_STATUSES, in full.
            ("running", true),
            ("blocked", true),
            ("review", true),      // waiting on the human — previously omitted
            ("triage", false),
            ("todo", false),
            ("scheduled", false),
            ("ready", false),
            ("done", false),
            ("archived", false),
            // Not a Hermes status: a value Scarf could not parse. Counting it
            // would be inventing state.
            ("wat", false),
        ]
    )
    func countRulePerStatus(status: String, counts: Bool) {
        let n = KanbanChatBadgeState.liveCount(of: [Self.task(status)])
        #expect(n == (counts ? 1 : 0), "\(status) should \(counts ? "" : "not ")count")
    }

    @Test("a review card alone is not reported as an idle board")
    func reviewAloneIsNotZero() {
        let rows = [Self.task("review"), Self.task("done"), Self.task("todo")]
        #expect(
            KanbanChatBadgeState.liveCount(of: rows) == 1,
            "a card parked in Review is exactly the work waiting on the user"
        )
    }

    @Test("status matching is case-insensitive and mixes cleanly")
    func countRuleOverAMixedBoard() {
        let rows = ["RUNNING", "blocked", "Review", "done", "ready", "archived"].map(Self.task)
        #expect(KanbanChatBadgeState.liveCount(of: rows) == 3)
        #expect(KanbanChatBadgeState.liveCount(of: []) == 0)
    }

    // MARK: - back-off

    @Test("the interval backs off on failure and resets on the next success")
    func backOffDoublesThenResets() {
        var state = KanbanChatBadgeState(baseInterval: 5, maxInterval: 30)
        state.bind(to: "chat-A")
        for expected in [10.0, 20.0, 30.0, 30.0] {
            _ = state.beginPoll()
            state.fail(issuedFor: "chat-A")
            #expect(state.currentInterval == expected)
            #expect(state.liveCount == nil)
        }
        _ = state.beginPoll()
        state.accept(count: 0, issuedFor: "chat-A")
        #expect(state.currentInterval == 5)
        #expect(state.liveCount == 0, "zero is a real count, not 'unknown'")
    }
}
