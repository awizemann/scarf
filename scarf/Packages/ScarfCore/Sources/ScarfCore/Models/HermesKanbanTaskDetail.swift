import Foundation

/// Output of `hermes kanban show <id> --json`. Wraps a task with its
/// comment and event trail. Loaded on-demand
/// when the user opens the inspector pane; the board itself only carries
/// the lightweight `HermesKanbanTask` rows.
public struct HermesKanbanTaskDetail: Sendable, Equatable, Codable {
    public let task: HermesKanbanTask
    public let comments: [HermesKanbanComment]
    public let events: [HermesKanbanEvent]
    // NOTE: `_cmd_show`'s JSON envelope (`hermes_cli/kanban.py:492-498`,
    // v2026.9.7) carries exactly task / latest_summary / parents / children /
    // comments / events / runs — and never has carried anything else. Decode
    // paths for an envelope-level `diagnostics` sibling and for
    // `parent_results` were modelled here defensively and are deleted:
    // `parent_results` exists only as `kanban_db.parent_results` (:4060), a
    // helper the worker CONTEXT builder uses (`_ctx_parent_results` :3692), so
    // it never reaches any `--json` envelope. Diagnostics come from
    // `kanban diagnostics --json`; upstream parent ids come from `parents`.

    public init(
        task: HermesKanbanTask,
        comments: [HermesKanbanComment] = [],
        events: [HermesKanbanEvent] = []
    ) {
        self.task = task
        self.comments = comments
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case task
        case comments
        case events
    }

    public init(from decoder: any Decoder) throws {
        // Hermes emits `kanban show --json` either as a nested
        // {task: {...}, comments: [...], events: [...]} object or
        // as a flat task object with extra `comments`/`events`
        // keys at top level. Try the nested form first; fall
        // back to top-level decode.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.decode(HermesKanbanTask.self, forKey: .task) {
            self.task = nested
        } else {
            let single = try decoder.singleValueContainer()
            self.task = try single.decode(HermesKanbanTask.self)
        }
        // Each element decodes on its own: one malformed row used to take the
        // whole array down with it through a single `try?`, which is how
        // every comment vanished while comment ids were still required.
        let taskId = self.task.id
        let wireComments = (try? container.decodeIfPresent(
            LossyKanbanList<HermesKanbanComment>.self, forKey: .comments))?.elements ?? []
        let wireEvents = (try? container.decodeIfPresent(
            LossyKanbanList<HermesKanbanEvent>.self, forKey: .events))?.elements ?? []
        self.comments = Self.withStableIds(wireComments, id: \.id) {
            $0.withIdentity(id: $1, taskId: taskId)
        }
        self.events = Self.withStableIds(wireEvents, id: \.id) {
            $0.withIdentity(id: $1, taskId: taskId)
        }
    }

    /// Give every row a unique, stable id.
    ///
    /// `kanban show --json` sends comments and events WITHOUT their row ids
    /// (`hermes_cli/kanban.py:495-496` @ `v2026.9.24`), so they all decode
    /// as 0 and a SwiftUI `ForEach` over them has duplicate identities.
    /// Both lists are append-only and come back in a fixed order
    /// (`list_comments` sorts `created_at ASC`, `list_events`
    /// `created_at ASC, id ASC`, `hermes_cli/kanban_db.py:1792-1793`,
    /// `:1923-1924`), so the 1-based position is stable across re-fetches:
    /// a new comment only ever adds a new last position. Wire ids are kept
    /// when every row has a distinct one (a Hermes that starts sending them).
    static func withStableIds<Row>(
        _ rows: [Row],
        id: (Row) -> Int,
        assign: (Row, Int) -> Row
    ) -> [Row] {
        let wireIds = rows.map(id)
        let allDistinct = Set(wireIds).count == rows.count && !wireIds.contains(0)
        return rows.enumerated().map { index, row in
            assign(row, allDistinct ? wireIds[index] : index + 1)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(task, forKey: .task)
        try c.encode(comments, forKey: .comments)
        try c.encode(events, forKey: .events)
    }
}

/// A JSON array decoded one element at a time: an element that fails to
/// decode is skipped instead of failing the whole array.
struct LossyKanbanList<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                out.append(element)
            } else {
                // Consume the bad element so the loop moves on. `Skipped`
                // never reads the decoder, so this decode cannot fail.
                _ = try? container.decode(Skipped.self)
            }
        }
        self.elements = out
    }

    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}
