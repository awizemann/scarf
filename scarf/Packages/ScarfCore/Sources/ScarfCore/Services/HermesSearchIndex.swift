import Foundation

/// The `messages_fts` bookkeeping contract Scarf reads out of
/// `state_meta`, in one place.
///
/// Everything here is DETECTED, never version-gated (charter C4): the
/// keys are ordinary rows in an ordinary table, so a host that has them
/// is a host that behaves this way regardless of what
/// `hermes --version` says, and a host that lacks them runs the exact
/// SQL Scarf ran before this file existed.
public enum HermesFTSIndex {

    /// Hermes v0.21.1 (`v2026.9.7`) stopped tokenizing whole tool
    /// payloads: for `messages` rows with `role = 'tool'` the FTS
    /// triggers index only `substr(content, 1, 8192)`
    /// (`FTS_TOOL_CONTENT_PREFIX_CHARS`, `hermes_state_common.py:224`,
    /// used by `_fts_indexed_content_sql` at `:227-234`). Tool results
    /// are routinely multi-megabyte machine output and tokenizing them
    /// held SQLite's single writer lock for the whole write.
    ///
    /// The consequence for a reader: a term that occurs ONLY past the
    /// 8192nd character of a tool result is invisible to `MATCH`.
    public static let toolContentPrefixChars = 8_192

    /// `state_meta` key carrying the message id below which tool rows
    /// keep their pre-v0.21.1 FULL-content token stream
    /// (`FTS_TOOL_FULL_CONTENT_HIGH_WATER_KEY`,
    /// `hermes_state_common.py:225`). The migration stamps it once with
    /// `MAX(messages.id)` and never moves it
    /// (`hermes_state_schema.py:269-273`, guarded by a marker-presence
    /// check at `:292-295`), so rows at or below it were indexed whole
    /// and only rows ABOVE it are prefix-truncated.
    ///
    /// Absent ⇒ the host never ran the bounded-tool migration ⇒ every
    /// tool row is fully indexed and no fallback is warranted.
    public static let toolFullContentHighWaterKey = "fts_tool_full_content_high_water"

    /// `state_meta` keys for a DEFERRED FTS rebuild. Contract, verbatim
    /// from `hermes_state_common.py:536-545`: `fts_rebuild_high_water`
    /// (H) is the highest id present when the index was dropped,
    /// `fts_rebuild_progress` (P) is the highest id the chunked backfill
    /// has re-indexed, and a row is in the index iff `id <= P OR id > H`.
    /// Rows in `(P, H]` are simply not there yet.
    ///
    /// **Both keys are deleted together when the rebuild completes**
    /// (`_CLEAR_REBUILD_MARKERS_SQL`, `hermes_state_schema.py:124`), so
    /// their mere presence — not a comparison against a version — is the
    /// "a rebuild is pending" signal. These keys are much older than
    /// v0.21.1: they first appear at `v2026.7.30`.
    public static let rebuildHighWaterKey = "fts_rebuild_high_water"
    public static let rebuildProgressKey = "fts_rebuild_progress"

    /// How many candidate rows one LIKE-fallback pass may READ. The
    /// fallback exists to recover hits past the 8 KB prefix, which means
    /// it necessarily reads whole multi-megabyte tool payloads — so it
    /// is bounded by rows examined, newest-first, rather than left to
    /// run until it has filled the result limit. See
    /// `HermesDataService.searchMessages`.
    public static let fallbackScanBudget = 400

    /// Upper bound on the number of AND-ed `LIKE` terms one fallback
    /// query carries, so a pasted paragraph can't turn into a 200-clause
    /// statement.
    public static let fallbackMaxTerms = 8
}

/// What the `messages_fts` index can currently answer for, as read from
/// `state_meta`. Surfaced so search can tell the user its results are
/// knowingly partial rather than silently under-return.
public struct HermesSearchIndexStatus: Sendable, Equatable {

    /// A chunked FTS backfill is pending: message ids in
    /// `(rebuildProgress, rebuildHighWater]` are not in the index at
    /// all, so `MATCH` under-returns until it finishes.
    public var isRebuilding: Bool

    /// Ids covered so far by the pending backfill (`P`), when known.
    public var rebuildProgress: Int?

    /// Highest id awaiting the pending backfill (`H`), when known.
    public var rebuildHighWater: Int?

    /// The host bounds tool-row indexing to the first
    /// `HermesFTSIndex.toolContentPrefixChars` characters above this id.
    /// `nil` on every host that never ran the v0.21.1 migration.
    public var toolPrefixHighWater: Int?

    public init(
        isRebuilding: Bool = false,
        rebuildProgress: Int? = nil,
        rebuildHighWater: Int? = nil,
        toolPrefixHighWater: Int? = nil
    ) {
        self.isRebuilding = isRebuilding
        self.rebuildProgress = rebuildProgress
        self.rebuildHighWater = rebuildHighWater
        self.toolPrefixHighWater = toolPrefixHighWater
    }

    /// Fraction of the pending backfill already done, when both markers
    /// are readable. `nil` when the span is unknown or degenerate — a
    /// progress bar that lies is worse than a plain "rebuilding" note.
    public var rebuildFraction: Double? {
        guard isRebuilding, let p = rebuildProgress, let h = rebuildHighWater, h > 0, p >= 0, p <= h else {
            return nil
        }
        return Double(p) / Double(h)
    }
}
