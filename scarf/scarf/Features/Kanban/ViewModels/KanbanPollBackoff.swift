import Foundation

/// Shared cadence + failure backoff for the three Kanban poll loops
/// (`KanbanBoardViewModel`, `KanbanViewModel`, `KanbanTaskDetailViewModel`).
///
/// Before F6 each loop slept a hardcoded flat interval and never widened it.
/// Between them a single open board spawned five `hermes kanban …` process
/// invocations every two-to-five seconds — two from the board, two from the
/// open detail inspector, one from the log stream — and against an
/// unreachable or failing host every one of them retried at that same rate
/// indefinitely. `nextInterval` doubles the wait after each failure up to a
/// ceiling; one success drops straight back to the base cadence, so a
/// transient blip costs at most one slow tick.
///
/// Deliberately NOT jittered: these are user-visible refresh loops on one
/// host, not a thundering herd against a service.
enum KanbanPollBackoff {
    /// Board / list cadence.
    static let boardBase: UInt64 = 5_000_000_000
    /// Log-stream cadence — a running worker's log is the one surface where
    /// latency reads as lag, so it stays fast while it is succeeding.
    static let logBase: UInt64 = 2_000_000_000
    /// Ceiling for every loop. A minute is long enough that a dead host stops
    /// costing anything, short enough that recovery is noticed unprompted.
    static let ceiling: UInt64 = 60_000_000_000

    /// The next sleep interval given the current one and whether the tick
    /// that just ran succeeded.
    static func nextInterval(current: UInt64, base: UInt64, succeeded: Bool) -> UInt64 {
        succeeded ? base : min(current * 2, ceiling)
    }

    /// How many bytes of a worker log to pull per tick.
    ///
    /// `KanbanService.log` has supported `--tail` all along; the poll loop
    /// passed `nil`, so every 2-second tick dragged the WHOLE log file back
    /// over the transport — a long-running worker's log grows without bound,
    /// so the cost of a tick grew with the age of the run. 256 KiB is a
    /// generous read for a log view whose tail is the only part anyone looks
    /// at, and the truncation is announced (see `logTruncationNotice`) rather
    /// than silently cutting the top off.
    static let logTailBytes = 256 * 1024
}
