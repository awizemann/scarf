import Foundation

/// Output of `hermes kanban stats --json`. Drives the toolbar glance
/// ("12 todo · 3 running · 5 blocked"), the per-project Kanban summary
/// widget, and the column-count badges on the board header.
public struct HermesKanbanStats: Sendable, Equatable, Codable {
    public let byStatus: [String: Int]
    /// `{assignee: {status: count}}` over non-archived tasks. Nested, not a
    /// flat count: `_counts_by_assignee` (`hermes_cli/kanban_db.py:4225-4234`
    /// @ `v2026.9.24`) has built it this way since the board shipped.
    /// Decoding it as `[String: Int]` threw on every board with an assigned
    /// task, which blanked the glance everywhere.
    public let byAssignee: [String: [String: Int]]
    /// Not emitted by `board_stats` at `v2026.9.24` (`:4217-4222`); kept for
    /// callers and decoded leniently in case a host sends it.
    public let byTenant: [String: Int]
    /// Age in seconds of the oldest task currently in the `ready` status.
    /// `nil` when no tasks are ready. Helps surface a stuck dispatcher.
    public let oldestReadyAgeSeconds: Double?

    public init(
        byStatus: [String: Int],
        byAssignee: [String: [String: Int]] = [:],
        byTenant: [String: Int] = [:],
        oldestReadyAgeSeconds: Double? = nil
    ) {
        self.byStatus = byStatus
        self.byAssignee = byAssignee
        self.byTenant = byTenant
        self.oldestReadyAgeSeconds = oldestReadyAgeSeconds
    }

    public static let empty = HermesKanbanStats(byStatus: [:])

    enum CodingKeys: String, CodingKey {
        case byStatus = "by_status"
        case byAssignee = "by_assignee"
        case byTenant = "by_tenant"
        case oldestReadyAgeSeconds = "oldest_ready_age_seconds"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `by_status` drives the glance and must decode. The breakdowns
        // below are secondary: a shape Scarf does not expect costs that
        // breakdown only, never the whole stats read.
        self.byStatus = try c.decodeIfPresent([String: Int].self, forKey: .byStatus) ?? [:]
        self.byAssignee = (try? c.decodeIfPresent([String: [String: Int]].self, forKey: .byAssignee)) ?? [:]
        self.byTenant = (try? c.decodeIfPresent([String: Int].self, forKey: .byTenant)) ?? [:]
        self.oldestReadyAgeSeconds = try? c.decodeIfPresent(Double.self, forKey: .oldestReadyAgeSeconds)
    }

    /// "12 todo · 3 running · 5 blocked" formatted glance string. Skips
    /// empty buckets and never includes archived. Returns an empty
    /// string when there's nothing to show so callers can hide chrome.
    public var glanceString: String {
        let order: [(String, String)] = [
            ("todo", "todo"),
            ("ready", "ready"),
            ("running", "running"),
            ("blocked", "blocked"),
            ("done", "done")
        ]
        let parts = order.compactMap { (key, label) -> String? in
            guard let n = byStatus[key], n > 0 else { return nil }
            return "\(n) \(label)"
        }
        return parts.joined(separator: " · ")
    }

    /// Active task count across the board (everything except archived
    /// and done). Used as a badge on the sidebar / project tab.
    public var activeCount: Int {
        ["triage", "todo", "ready", "running", "blocked"]
            .map { byStatus[$0] ?? 0 }
            .reduce(0, +)
    }
}
