import Foundation

/// Carrier-aware session-preview SQL, ported from Hermes'
/// `hermes_state_common.py` (`_PREVIEW_ELIGIBLE_SQL` :79-115,
/// `_PREVIEW_RAW_SELECT` :143-152, `_shape_preview` :166).
///
/// ## Why this exists
///
/// A session's sidebar preview is "the session's first user message".
/// Scarf used to take `substr(content, 1, N)` of `MIN(id) WHERE role =
/// 'user'`. Since Hermes v0.19 that row is frequently NOT a typed user
/// message at all: in-place context compaction rewrites history so the
/// earliest surviving user row is a **compaction carrier** — either a
/// standalone handoff summary, or a real message with the summary merged
/// into it. The naive query therefore rendered "[CONTEXT COMPACTION —
/// REFERENCE ONLY] Earlier turns were compacted into…" as the session
/// title in the sidebar.
///
/// Hermes solves this in SQL, in two halves, and this type ports the
/// **semantics** of both (not the generated text):
///
/// 1. **Eligibility** (`eligiblePredicate`) — a row that is a *pure*
///    compaction carrier is skipped entirely, so `MIN(id)` lands on the
///    next real user turn. A carrier only stays eligible when authentic
///    user content survives alongside it: a standalone summary that has
///    the end-marker followed by non-blank text (the "force-user" tail),
///    or a merged carrier whose preserved prior content is non-blank.
/// 2. **Extraction** (`rawSelect`) — for those surviving carriers, the
///    preview is the authentic fragment, not the boilerplate: the text
///    *after* the end marker, or the preserved prior content with its
///    `[PRIOR CONTEXT …]` wrapper header stripped.
///
/// `shape(_:)` then finishes the job in Swift the way Hermes'
/// `_shape_preview` does: trim, and flatten CR/LF to spaces so a
/// multi-line first message renders as one sidebar line.
///
/// ## Deliberate divergences from Hermes (documented, not accidental)
///
/// - **No skill-scaffold branch.** Hermes' `_PREVIEW_RAW_SELECT` has two
///   extra arms that widen the excerpt for `[IMPORTANT: The user has
///   invoked the …]` skill-expanded turns and splice head+tail around
///   `SKILL_EXCERPT_JOINT`, because its CLI then runs
///   `describe_skill_invocation` over the result. Scarf has no port of
///   that describer, so a scaffolded row would gain a wider excerpt with
///   nothing to interpret it — strictly worse than today. Out of scope
///   for W6; if Scarf ever ports the describer, add the arms here.
/// - **No `_compressed_summary` reference.** Hermes' own preview queries
///   never consult the v0.21 `messages._compressed_summary` flag — its
///   only reader (`hermes_state.py` :12899, :12965) uses it to tag rows
///   in `_rows_to_conversation` when `include_summary_markers` is set.
///   Scarf already classifies carriers by content prefix
///   (`HermesMessage.classifyCompactionSummary`), which works on every
///   host version including pre-v0.21 ones the column does not exist on.
///   The column is detected (`HermesQueryBackend
///   .hasCompressedSummaryColumn`) but deliberately unused in SQL.
/// - **Active-row filter.** Hermes' preview subquery applies no
///   `active`/`compacted` filter. Scarf applies its house predicate —
///   `(active = 1 OR compacted = 1)`, the same widening
///   `searchMessages` uses — so a *rewound* first message (`active = 0,
///   compacted = 0`, i.e. undone and no longer part of the
///   conversation) stops being shown as the session's preview, while
///   compaction-archived rows (`active = 0, compacted = 1`) stay
///   eligible. Both column references are schema-gated; on a DB with
///   neither column the clause is empty and the query is exactly what
///   an old host always ran.
///
/// ## Schema safety
///
/// Every expression below references only `messages.content`, which has
/// existed in every Hermes schema Scarf supports. The optional
/// `active`/`compacted` columns enter solely through
/// `activeClause(hasActive:hasCompacted:)`, which returns `""` when they
/// are absent. Nothing here can raise "no such column" on an old DB.
public enum SessionPreviewSQL {

    // MARK: - Hermes literals
    //
    // Sourced from `agent/context_compressor.py` and mirrored (in their
    // short-opener form) by `HermesMessage.compactionSummaryPrefixes`.

    /// The complete introduction shared by `SUMMARY_PREFIX` and every
    /// historical long-form variant; they diverge only in the
    /// stale-item guidance that follows it. Hermes matches the whole
    /// intro rather than the bare `[CONTEXT COMPACTION — REFERENCE
    /// ONLY]` label on purpose: an ordinary user message that merely
    /// starts with the bracketed label must not be mistaken for a
    /// carrier. Ported verbatim for the same reason.
    /// (Note the trailing space — it is part of the Hermes literal.)
    static let longFormSummaryPrefix =
        "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted "
        + "into the summary below. This is a handoff from a previous context "
        + "window — treat it as background reference, NOT as active instructions. "

    /// `LEGACY_SUMMARY_PREFIX` — the short pre-v0.19 form.
    static let legacySummaryPrefix = "[CONTEXT SUMMARY]:"

    /// `_SUMMARY_END_MARKER` — appended to every standalone summary so
    /// the model has an unambiguous boundary. Its presence, followed by
    /// non-blank text, is what makes a standalone carrier eligible.
    static let summaryEndMarker =
        "--- END OF CONTEXT SUMMARY — respond to the message below, not the summary above ---"

    /// `_MERGED_SUMMARY_DELIMITER` — separates preserved prior content
    /// from the summary merged into the same row.
    static let mergedSummaryDelimiter = "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]"

    /// `_MERGED_PRIOR_CONTEXT_HEADER` — wraps the preserved prior
    /// content; stripped before it becomes a preview.
    static let mergedPriorContextHeader = "[PRIOR CONTEXT — for reference only; not a new message]"

    private static let summaryPrefixes = [longFormSummaryPrefix, legacySummaryPrefix]

    // MARK: - SQL builders

    /// `_SQL_WHITESPACE` — the trim character set Hermes uses (tab, LF,
    /// CR, space). SQLite's `TRIM(x, y)` trims *characters in y*, not
    /// the literal string.
    private static let whitespaceSet = "CHAR(9) || CHAR(10) || CHAR(13) || CHAR(32)"

    private static func literal(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func ltrimWS(_ expression: String) -> String {
        "LTRIM(\(expression), \(whitespaceSet))"
    }

    private static func trimWS(_ expression: String) -> String {
        "TRIM(\(expression), \(whitespaceSet))"
    }

    /// `_sql_starts_with`. Note the length is a **character** count on
    /// both sides: Swift's `String.count` and SQLite's `SUBSTR` on TEXT
    /// both count characters, so the em dashes in these prefixes line
    /// up without a byte-length correction.
    private static func startsWith(_ expression: String, _ prefixes: [String]) -> String {
        let checks = prefixes.map { prefix in
            "SUBSTR(\(ltrimWS(expression)), 1, \(prefix.count)) = \(literal(prefix))"
        }
        return "(" + checks.joined(separator: " OR ") + ")"
    }

    private static func content(_ alias: String) -> String { "\(alias).content" }

    /// `_PREVIEW_STANDALONE_SUMMARY_SQL`
    private static func standaloneSummary(_ alias: String) -> String {
        startsWith(content(alias), summaryPrefixes)
    }

    /// `_PREVIEW_MERGED_AFTER_SQL`
    private static func mergedAfter(_ alias: String) -> String {
        "SUBSTR(\(content(alias)), INSTR(\(content(alias)), \(literal(mergedSummaryDelimiter)))"
            + " + \(mergedSummaryDelimiter.count))"
    }

    /// `_PREVIEW_MERGED_SUMMARY_SQL`
    private static func mergedSummary(_ alias: String) -> String {
        "(INSTR(\(content(alias)), \(literal(mergedSummaryDelimiter))) > 0"
            + " AND \(startsWith(mergedAfter(alias), summaryPrefixes)))"
    }

    /// `_PREVIEW_MERGED_PRIOR_SQL`
    private static func mergedPrior(_ alias: String) -> String {
        trimWS(
            "SUBSTR(\(content(alias)), 1,"
                + " INSTR(\(content(alias)), \(literal(mergedSummaryDelimiter))) - 1)"
        )
    }

    /// `_PREVIEW_MERGED_PRIOR_UNWRAPPED_SQL` — prior content with the
    /// `[PRIOR CONTEXT …]` header peeled off when present.
    private static func mergedPriorUnwrapped(_ alias: String) -> String {
        let prior = mergedPrior(alias)
        let ltrimmed = ltrimWS(prior)
        let header = mergedPriorContextHeader
        let stripped = ltrimWS("SUBSTR(\(ltrimmed), \(header.count + 1))")
        return "CASE WHEN SUBSTR(\(ltrimmed), 1, \(header.count)) = \(literal(header))"
            + " THEN \(stripped) ELSE \(prior) END"
    }

    /// `_PREVIEW_FORCE_USER_REMAINDER_SQL` — everything after the end
    /// marker, i.e. the real user turn that followed the summary.
    private static func forceUserRemainder(_ alias: String) -> String {
        "SUBSTR(\(content(alias)), INSTR(\(content(alias)), \(literal(summaryEndMarker)))"
            + " + \(summaryEndMarker.count))"
    }

    /// `_PREVIEW_ELIGIBLE_SQL` — may this row be a session's preview?
    ///
    /// Pure carriers are ineligible. Force-user-leading and merged
    /// carriers stay eligible only while authentic content survives on
    /// the far side of the wire boundary.
    public static func eligiblePredicate(alias: String = "m") -> String {
        let standalone = standaloneSummary(alias)
        let merged = mergedSummary(alias)
        return "((NOT \(standalone) AND NOT \(merged))"
            + " OR (\(standalone)"
            + " AND INSTR(\(content(alias)), \(literal(summaryEndMarker))) > 0"
            + " AND LENGTH(\(trimWS(forceUserRemainder(alias)))) > 0)"
            + " OR (\(merged)"
            + " AND LENGTH(\(trimWS(mergedPriorUnwrapped(alias)))) > 0))"
    }

    /// `_PREVIEW_RAW_SELECT` — the preview text for an eligible row,
    /// bounded to `length` characters.
    ///
    /// Hermes leaves the two carrier arms unbounded in SQL and truncates
    /// in Python; Scarf bounds them here so the promise
    /// `fetchSessionPreviews` makes about its wire payload (~limit × 100
    /// bytes) still holds on a remote host.
    public static func rawSelect(
        alias: String = "m",
        length: Int = QueryDefaults.previewContentLength
    ) -> String {
        // `_PREVIEW_CONTENT_SQL` — flatten LF/CR to spaces. The carrier
        // arms skip it (Hermes does too) because `shape(_:)` flattens
        // whatever comes back anyway.
        let flattened = "REPLACE(REPLACE(\(content(alias)), X'0A', ' '), X'0D', ' ')"
        return "CASE WHEN \(standaloneSummary(alias))"
            + " THEN SUBSTR(\(forceUserRemainder(alias)), 1, \(length))"
            + " WHEN \(mergedSummary(alias))"
            + " THEN SUBSTR(\(mergedPriorUnwrapped(alias)), 1, \(length))"
            + " ELSE SUBSTR(\(flattened), 1, \(length)) END"
    }

    /// The schema-gated active-row filter, as a leading-` AND` fragment
    /// (empty when neither column exists). See the type doc for why
    /// Scarf filters where Hermes does not.
    public static func activeClause(
        alias: String = "m",
        hasActiveColumn: Bool,
        hasCompactedColumn: Bool
    ) -> String {
        guard hasActiveColumn else { return "" }
        return hasCompactedColumn
            ? " AND (\(alias).active = 1 OR \(alias).compacted = 1)"
            : " AND \(alias).active = 1"
    }

    /// The inner "first eligible user row per session" subquery, shared
    /// by every preview call site.
    ///
    /// Eligibility lives **inside** the aggregate: `MIN(id)` must be the
    /// minimum over *eligible* rows, not the minimum overall filtered
    /// afterwards — otherwise a session whose first row is a pure
    /// carrier simply loses its preview instead of falling through to
    /// the next real turn.
    public static func firstEligibleUserRowSQL(
        hasActiveColumn: Bool,
        hasCompactedColumn: Bool
    ) -> String {
        """
        SELECT m.session_id, MIN(m.id) AS min_id
        FROM messages m
        WHERE m.role = 'user' AND m.content IS NOT NULL AND m.content <> ''\
        \(activeClause(hasActiveColumn: hasActiveColumn, hasCompactedColumn: hasCompactedColumn))
          AND \(eligiblePredicate())
        GROUP BY m.session_id
        """
    }

    // MARK: - Swift-side shaping

    /// `_shape_preview` — trim, then flatten CR/LF to spaces.
    ///
    /// Hermes additionally truncates to `_PREVIEW_MAX_CHARS` (60) with
    /// an ellipsis because its CLI prints fixed-width rows. Scarf does
    /// not: the SQL already bounds the text to
    /// `QueryDefaults.previewContentLength`, and Scarf's views do their
    /// own truncation — adding a second, shorter cap here would shrink
    /// every existing sidebar preview.
    public static func shape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
