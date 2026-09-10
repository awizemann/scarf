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
        self.comments = (try? container.decodeIfPresent([HermesKanbanComment].self, forKey: .comments)) ?? []
        self.events = (try? container.decodeIfPresent([HermesKanbanEvent].self, forKey: .events)) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(task, forKey: .task)
        try c.encode(comments, forKey: .comments)
        try c.encode(events, forKey: .events)
    }
}
