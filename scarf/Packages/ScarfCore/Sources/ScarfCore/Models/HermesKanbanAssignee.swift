import Foundation

/// One row from `hermes kanban assignees --json`. The output is the
/// union of profiles configured on the host (`~/.hermes/profiles/`)
/// and any names appearing in the live board's `assignee` column —
/// covers the case where a profile was renamed but historical tasks
/// still reference the old name.
///
/// **Wire shape (verified against Hermes `v2026.8.31`,
/// `hermes_cli/kanban_db.py::known_assignees`):** each entry is
/// `{"name": str, "on_disk": bool, "counts": {status: n}}` — archived
/// rows are excluded from `counts` by the query itself. There is no
/// `profile` / `active` / `total` shape at any shipped version; the old
/// Scarf keys were invented, so every decode silently fell through to a
/// text-table parse of the human output (which produced all-zero counts
/// and a phantom `NAME` row from the header).
public struct HermesKanbanAssignee: Sendable, Equatable, Identifiable, Codable {
    public var id: String { profile }
    /// The assignee/profile name (`name` on the wire).
    public let profile: String
    /// Whether a profile directory exists on the host for this name.
    /// `false` means the name only appears on tasks (renamed or removed
    /// profile), so assigning new work to it is probably a mistake.
    public let onDisk: Bool
    /// Raw per-status counts, exactly as Hermes grouped them. Kept whole
    /// so a status Scarf doesn't know about yet still totals correctly.
    public let counts: [String: Int]

    /// Non-terminal work assigned to this profile. Mirrors
    /// `HermesKanbanStats.activeCount` so the two never disagree.
    public var activeCount: Int {
        HermesKanbanAssignee.activeStatuses
            .map { counts[$0] ?? 0 }
            .reduce(0, +)
    }

    /// Every non-archived task assigned to this profile (`known_assignees`
    /// already excludes archived rows).
    public var totalCount: Int {
        counts.values.reduce(0, +)
    }

    static let activeStatuses = ["triage", "todo", "ready", "running", "blocked", "scheduled", "review"]

    public init(profile: String, onDisk: Bool = true, counts: [String: Int] = [:]) {
        self.profile = profile
        self.onDisk = onDisk
        self.counts = counts
    }

    enum CodingKeys: String, CodingKey {
        case name
        case onDisk = "on_disk"
        case counts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.profile = try c.decode(String.self, forKey: .name)
        self.onDisk = try c.decodeIfPresent(Bool.self, forKey: .onDisk) ?? false
        self.counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profile, forKey: .name)
        try c.encode(onDisk, forKey: .onDisk)
        try c.encode(counts, forKey: .counts)
    }
}
