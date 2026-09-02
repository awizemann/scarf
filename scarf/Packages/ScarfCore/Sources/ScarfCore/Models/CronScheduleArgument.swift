import Foundation

/// The positional `schedule` argument `hermes cron create` takes, as a
/// **structured** value rather than "whatever string we happened to have".
///
/// Hermes parses this positional in `cron/jobs.py::parse_schedule`
/// (verified at tag `v2026.8.31`) into exactly three kinds:
/// - `cron`     — a 5/6-field cron expression (persisted as `schedule.expr`)
/// - `interval` — `"30m"` / `"every 2h"` (persisted as `schedule.minutes`)
/// - `once`     — an ISO timestamp (persisted as `schedule.run_at`)
///
/// A copied job must be reconstructed from the SAME three kinds, not from
/// the free-text `schedule.display` string: `display` is a human label
/// (Hermes writes the user's original phrasing there, and Scarf's own
/// editors write prose), so feeding it back to `cron create` is a guess —
/// it happens to round-trip for `"every 30m"` and silently fails argparse
/// or, worse, parses to a *different* cadence for anything else. Resolving
/// by `kind` first and falling back only through modeled fields keeps the
/// recreated job's cadence provably equal to the source's.
public enum CronScheduleArgument: Sendable, Equatable {
    /// A cron expression, forwarded verbatim (`"0 9 * * *"`).
    case cronExpression(String)
    /// A recurring interval, rendered as Hermes's canonical `"every <n>m"`.
    case intervalMinutes(Int)
    /// A one-shot ISO timestamp (`schedule.run_at`).
    case once(String)

    /// The exact argv element to hand `hermes cron create`.
    public var argumentValue: String {
        switch self {
        case .cronExpression(let expr): return expr
        case .intervalMinutes(let minutes): return "every \(minutes)m"
        case .once(let timestamp): return timestamp
        }
    }

    /// Short human label for the plan/result UI.
    public var summary: String {
        switch self {
        case .cronExpression(let expr): return "cron \(expr)"
        case .intervalMinutes(let m): return "every \(m)m"
        case .once(let t): return "once at \(t)"
        }
    }

    /// Resolve a loaded job's schedule into the argument that recreates it.
    /// `nil` when the schedule carries no modeled field we can rebuild from
    /// (the caller must then skip the job and SAY so — never invent one).
    ///
    /// Resolution is by `kind` first (the authoritative discriminator Hermes
    /// persists), then by whichever modeled field is present, so a jobs.json
    /// written by an older Scarf with a missing/unknown `kind` still copies.
    public static func resolve(_ schedule: CronSchedule) -> CronScheduleArgument? {
        switch schedule.kind {
        case "cron":
            if let expr = trimmed(schedule.expression) { return .cronExpression(expr) }
        case "interval":
            if let minutes = schedule.minutes, minutes > 0 { return .intervalMinutes(minutes) }
        case "once":
            if let runAt = trimmed(schedule.runAt) { return .once(runAt) }
        default:
            break
        }
        // Kind missing / unknown / inconsistent with its payload: fall through
        // the modeled fields in specificity order. Still structured — the
        // free-text `display` is deliberately never used.
        if let expr = trimmed(schedule.expression) { return .cronExpression(expr) }
        if let minutes = schedule.minutes, minutes > 0 { return .intervalMinutes(minutes) }
        if let runAt = trimmed(schedule.runAt) { return .once(runAt) }
        return nil
    }

    private static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
