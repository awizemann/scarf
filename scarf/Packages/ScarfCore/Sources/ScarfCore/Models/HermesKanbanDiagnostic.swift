import Foundation

/// One active distress signal from Hermes's Kanban diagnostics engine.
///
/// **Where it comes from.** `hermes kanban diagnostics --json` — and ONLY
/// there. No task-, run-, or `show`-envelope JSON has ever carried a
/// `diagnostics` key (`_TASK_DICT_FIELDS` / `_SHOW_RUN_FIELDS`,
/// `hermes_cli/kanban_output.py:18-33` at v2026.9.7), so Scarf fetches the
/// board-wide list once per board load and merges it by task id.
///
/// **Wire shape** is `Diagnostic.to_dict()` — a plain `dataclasses.asdict`
/// of `kanban_diagnostics.py:48-64`: `kind`, `severity`, `title`, `detail`,
/// `actions`, `first_seen_at`, `last_seen_at`, `count`, `run_id`, `data`.
/// Timestamps are Unix integer seconds. `actions` and `data` are not
/// decoded — nothing in Scarf renders them yet, and decoding a free-form
/// `data` payload would only invite a decode failure.
///
/// **Forward compat:** `kind` and `severity` stay `String`s so a future
/// Hermes rule (or a new severity tier) can't break the decode.
public struct HermesKanbanDiagnostic: Sendable, Equatable, Identifiable, Codable {
    /// Synthetic id — not on the wire. Hermes mints no per-diagnostic id,
    /// so this exists only to let SwiftUI `ForEach` over an array.
    public let id: UUID
    /// Rule code, e.g. `repeated_failures`. Compared case-insensitively
    /// through `KanbanDiagnosticKind.from(_:)`.
    public let kind: String
    /// `warning` | `error` | `critical` (`SEVERITY_ORDER`,
    /// `kanban_diagnostics.py:20`). Hermes is authoritative here — Scarf
    /// no longer infers severity from `kind`.
    public let severity: String
    /// One-line human summary Hermes composed for this signal. This is the
    /// user-facing label; the raw `kind` is a fallback when it's empty.
    public let title: String
    /// Multi-line elaboration, including the recovery hint.
    public let detail: String
    /// How many occurrences the rule folded into this signal.
    public let count: Int
    /// Unix seconds, normalized to ISO-8601 so consumers see one type —
    /// same pattern as `HermesKanbanTask.decodeFlexibleTimestamp`.
    public let firstSeenAt: String?
    public let lastSeenAt: String?
    /// Set when the signal is scoped to one run; `nil` = task-wide.
    public let runId: Int?

    public init(
        kind: String,
        severity: String = "warning",
        title: String = "",
        detail: String = "",
        count: Int = 1,
        firstSeenAt: String? = nil,
        lastSeenAt: String? = nil,
        runId: Int? = nil
    ) {
        self.id = UUID()
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.count = count
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.runId = runId
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case severity
        case title
        case detail
        case count
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case runId = "run_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        self.severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? "warning"
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        self.count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
        self.firstSeenAt = Self.decodeTimestamp(c, forKey: .firstSeenAt)
        self.lastSeenAt = Self.decodeTimestamp(c, forKey: .lastSeenAt)
        self.runId = try c.decodeIfPresent(Int.self, forKey: .runId)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(severity, forKey: .severity)
        try c.encode(title, forKey: .title)
        try c.encode(detail, forKey: .detail)
        try c.encode(count, forKey: .count)
        try c.encodeIfPresent(firstSeenAt, forKey: .firstSeenAt)
        try c.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try c.encodeIfPresent(runId, forKey: .runId)
    }

    public static func == (lhs: HermesKanbanDiagnostic, rhs: HermesKanbanDiagnostic) -> Bool {
        // Compare on wire fields, not the synthetic id — round-trip
        // decoding mints fresh ids.
        lhs.kind == rhs.kind
            && lhs.severity == rhs.severity
            && lhs.title == rhs.title
            && lhs.detail == rhs.detail
            && lhs.count == rhs.count
            && lhs.firstSeenAt == rhs.firstSeenAt
            && lhs.lastSeenAt == rhs.lastSeenAt
            && lhs.runId == rhs.runId
    }

    /// Label for a badge: Hermes's own `title`, falling back to the raw
    /// `kind` when a rule left it empty.
    public var displayLabel: String {
        title.isEmpty ? kind : title
    }

    /// Hermes emits `first_seen_at` / `last_seen_at` as Unix integer
    /// seconds (`0` for "unset" — normalized to nil so no UI renders 1970).
    private static func decodeTimestamp(
        _ c: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        guard c.contains(key) else { return nil }
        if let unix = try? c.decodeIfPresent(Double.self, forKey: key) {
            guard unix > 0 else { return nil }
            return isoFormatter.string(from: Date(timeIntervalSince1970: unix))
        }
        return (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Typed mirror

/// Typed view of `HermesKanbanDiagnostic.kind`, mirroring the rules in
/// `hermes_cli/kanban_diagnostics.py` at v2026.9.7 (the canonical list is
/// its `DIAGNOSTIC_KINDS` tuple). Used only to pick a glyph — severity and
/// label come off the wire.
///
/// `unknown` is the fallback for any rule a future Hermes adds.
public enum KanbanDiagnosticKind: String, Sendable, CaseIterable {
    case hallucinatedCards = "hallucinated_cards"
    case triageAuxUnavailable = "triage_aux_unavailable"
    case prosePhantomRefs = "prose_phantom_refs"
    case repeatedFailures = "repeated_failures"
    case repeatedCrashes = "repeated_crashes"
    case reviewDependencyDeadlock = "review_dependency_deadlock"
    case stuckInBlocked = "stuck_in_blocked"
    case blockUnblockCycling = "block_unblock_cycling"
    case strandedInReady = "stranded_in_ready"
    case unknown

    /// Map a wire string (case-insensitive) to a typed kind. Unknown
    /// values fall through to `.unknown`; callers still render the wire
    /// `title` verbatim.
    public static func from(_ raw: String) -> KanbanDiagnosticKind {
        KanbanDiagnosticKind(rawValue: raw.lowercased()) ?? .unknown
    }

    /// SF Symbol rendered alongside the diagnostic.
    public var glyphName: String {
        switch self {
        case .hallucinatedCards:        return "questionmark.folder"
        case .triageAuxUnavailable:     return "bolt.slash"
        case .prosePhantomRefs:         return "text.badge.xmark"
        case .repeatedFailures:         return "exclamationmark.arrow.circlepath"
        case .repeatedCrashes:          return "bolt.trianglebadge.exclamationmark"
        case .reviewDependencyDeadlock: return "arrow.triangle.branch"
        case .stuckInBlocked:           return "nosign"
        case .blockUnblockCycling:      return "arrow.triangle.2.circlepath"
        case .strandedInReady:          return "clock.badge.exclamationmark"
        case .unknown:                  return "stethoscope"
        }
    }
}

/// Wire severity tiers (`SEVERITY_ORDER`, `kanban_diagnostics.py:20`).
public enum KanbanDiagnosticSeverity: String, Sendable, CaseIterable {
    case warning
    case error
    case critical

    /// Anything Hermes ships that Scarf doesn't know maps to `.warning`
    /// so an unknown tier is never rendered as the loudest one.
    public static func from(_ raw: String) -> KanbanDiagnosticSeverity {
        KanbanDiagnosticSeverity(rawValue: raw.lowercased()) ?? .warning
    }
}

// MARK: - `kanban diagnostics --json` envelope

/// One element of `hermes kanban diagnostics --json`:
/// `{"task_id": …, "title": …, "status": …, "assignee": …,
///   "diagnostics": [Diagnostic, …]}` (`hermes_cli/kanban.py:678-681`,
/// v2026.9.7). `title` / `status` / `assignee` are absent when the task row
/// vanished between the two queries, hence all-optional.
public struct HermesKanbanDiagnosticsEntry: Sendable, Equatable, Decodable {
    public let taskId: String
    public let diagnostics: [HermesKanbanDiagnostic]

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case diagnostics
    }

    public init(taskId: String, diagnostics: [HermesKanbanDiagnostic]) {
        self.taskId = taskId
        self.diagnostics = diagnostics
    }
}
