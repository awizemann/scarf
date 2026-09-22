import Foundation

/// The pure state machine behind the chat header's Kanban live-count
/// badge. Lives here (not in the app target) so the two rules that
/// actually break — *which session a result belongs to* and *which
/// statuses count as live* — are testable without a view.
///
/// The app-side `KanbanChatBadgeViewModel` owns one of these and does
/// nothing but drive it; every decision is made here.
///
/// **Why id-tagging.** The poller runs on a detached task that view
/// cancellation does not reach, so a poll issued for chat A can return
/// after the pane has rebound to chat B. A result is therefore stamped
/// with the session id it was *issued for* and dropped when that id is
/// no longer the bound one — otherwise the badge asserts A's task count
/// for B.
public struct KanbanChatBadgeState: Sendable, Equatable {
    /// Statuses the badge counts as "live in this chat".
    ///
    /// Hermes's full task vocabulary is
    /// `{triage, todo, scheduled, ready, running, blocked, review, done, archived}`
    /// (`v2026.9.21:hermes_cli/kanban_db.py:103`). Of those:
    ///
    /// - `running` — the agent is working the card.
    /// - `blocked` — the run stopped and needs a human to unblock it.
    /// - `review` — finished work parked for a human to approve
    ///   (`kanban_db.py:2298-2321` `claim_review_task`, `:2729-2744`
    ///   "``review`` for human approval"). This is the status most
    ///   urgently waiting on the person reading the badge, and it was
    ///   previously omitted, so a card parked in Review read as 0.
    ///
    /// Everything else is deliberately out: `triage`/`todo`/`ready`/
    /// `scheduled` are not yet in flight, `done`/`archived` are over,
    /// and `unknown` is a status Scarf could not parse — counting it
    /// would be inventing state (charter identity).
    public static let liveStatuses: Set<KanbanStatus> = [.running, .blocked, .review]

    /// Count of the tasks this badge should display, by the rule above.
    public static func liveCount(of tasks: [HermesKanbanTask]) -> Int {
        tasks.reduce(0) { acc, task in
            acc + (liveStatuses.contains(KanbanStatus.from(task.status)) ? 1 : 0)
        }
    }

    /// The chat session the badge currently speaks for. `nil` means no
    /// chat session yet (a fresh window, or right after `/new`), and the
    /// badge must render nothing rather than the previous chat's number.
    public private(set) var sessionId: String?

    /// `nil` while no poll has landed for `sessionId` — the chip renders
    /// no number. Zero is a real value (an idle board).
    public private(set) var liveCount: Int?

    /// Single-flight guard. Scoped to `sessionId`: rebinding clears it,
    /// so a slow poll for the previous chat can never suppress the new
    /// chat's first tick.
    public private(set) var isInflight: Bool = false

    public let baseInterval: TimeInterval
    public let maxInterval: TimeInterval

    /// Error back-off: doubles on failure to `maxInterval`, resets to
    /// `baseInterval` on the first success.
    public private(set) var currentInterval: TimeInterval

    public init(baseInterval: TimeInterval = 5, maxInterval: TimeInterval = 30) {
        self.baseInterval = baseInterval
        self.maxInterval = maxInterval
        self.currentInterval = baseInterval
    }

    /// Point the badge at `sessionId`. A *change* (including to or from
    /// `nil`) clears the count, the in-flight flag and the back-off, so
    /// nothing from the previous chat survives the switch. Rebinding to
    /// the same id is a no-op, so a view re-render cannot wipe a good
    /// count or an in-flight poll.
    public mutating func bind(to sessionId: String?) {
        guard sessionId != self.sessionId else { return }
        self.sessionId = sessionId
        liveCount = nil
        isInflight = false
        currentInterval = baseInterval
    }

    /// Claim the single-flight slot. Returns the session id the poll is
    /// issued for — pass it back to `accept`/`fail` — or `nil` when
    /// there is no bound session or a poll is already in flight.
    public mutating func beginPoll() -> String? {
        guard let sessionId, !isInflight else { return nil }
        isInflight = true
        return sessionId
    }

    /// Record a successful poll. Returns `false` (changing nothing but
    /// the in-flight flag) when `issuedFor` is no longer the bound
    /// session — the stale-result rejection.
    @discardableResult
    public mutating func accept(count: Int, issuedFor: String) -> Bool {
        isInflight = false
        guard issuedFor == sessionId else { return false }
        liveCount = count
        currentInterval = baseInterval
        return true
    }

    /// Record a failed poll: the count goes unknown and the interval
    /// backs off. A failure for a stale session is ignored just as a
    /// success is.
    @discardableResult
    public mutating func fail(issuedFor: String) -> Bool {
        isInflight = false
        guard issuedFor == sessionId else { return false }
        liveCount = nil
        currentInterval = min(currentInterval * 2, maxInterval)
        return true
    }
}
