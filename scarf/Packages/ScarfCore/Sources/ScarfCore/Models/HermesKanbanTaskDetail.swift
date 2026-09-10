import Foundation

/// Output of `hermes kanban show <id> --json`. Wraps a task with its full
/// audit trail: comments + events + parent results. Loaded on-demand
/// when the user opens the inspector pane; the board itself only carries
/// the lightweight `HermesKanbanTask` rows.
public struct HermesKanbanTaskDetail: Sendable, Equatable, Codable {
    public let task: HermesKanbanTask
    public let comments: [HermesKanbanComment]
    public let events: [HermesKanbanEvent]
    /// Parent-task results keyed by parent task id. Hermes hands these
    /// to the worker as upstream context; surfacing them in the
    /// inspector is useful for understanding why a task started.
    public let parentResults: [String: String]
    // NOTE: an envelope-level `diagnostics` sibling was modelled here
    // defensively; `_cmd_show`'s JSON envelope
    // (`hermes_cli/kanban.py:493-498`, v2026.9.7) carries only task /
    // latest_summary / parents / children / comments / events / runs, and
    // never has. Diagnostics come from `kanban diagnostics --json`.

    public init(
        task: HermesKanbanTask,
        comments: [HermesKanbanComment] = [],
        events: [HermesKanbanEvent] = [],
        parentResults: [String: String] = [:]
    ) {
        self.task = task
        self.comments = comments
        self.events = events
        self.parentResults = parentResults
    }

    enum CodingKeys: String, CodingKey {
        case task
        case comments
        case events
        case parentResults = "parent_results"
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
        self.parentResults = (try? container.decodeIfPresent([String: String].self, forKey: .parentResults)) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(task, forKey: .task)
        try c.encode(comments, forKey: .comments)
        try c.encode(events, forKey: .events)
        try c.encode(parentResults, forKey: .parentResults)
    }
}
