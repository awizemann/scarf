import Foundation

/// One entry in the `hermes curator list-archived` output. Decoded
/// tolerantly via `decodeIfPresent` so a stripped-down host (or a future
/// Hermes that drops one of the optional columns) doesn't crash the view.
///
/// Only `name` is required — every other field is optional and the
/// computed `*Label` accessors render `"—"` for missing values.
public struct HermesCuratorArchivedSkill: Sendable, Equatable, Identifiable, Codable {
    public var id: String { name }
    public let name: String
    public let category: String?
    public let archivedAt: String?
    public let reason: String?
    public let sizeBytes: Int?
    public let path: String?

    public init(
        name: String,
        category: String? = nil,
        archivedAt: String? = nil,
        reason: String? = nil,
        sizeBytes: Int? = nil,
        path: String? = nil
    ) {
        self.name = name
        self.category = category
        self.archivedAt = archivedAt
        self.reason = reason
        self.sizeBytes = sizeBytes
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case category
        case archivedAt = "archived_at"
        case reason
        case sizeBytes = "size_bytes"
        case path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.category = try c.decodeIfPresent(String.self, forKey: .category)
        self.archivedAt = try c.decodeIfPresent(String.self, forKey: .archivedAt)
        self.reason = try c.decodeIfPresent(String.self, forKey: .reason)
        self.sizeBytes = try c.decodeIfPresent(Int.self, forKey: .sizeBytes)
        self.path = try c.decodeIfPresent(String.self, forKey: .path)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try c.encodeIfPresent(path, forKey: .path)
    }

    /// "4.4 KB" / "1.2 MB" / "—" for nil. Uses the SI byte formatter so
    /// the labels match what Finder shows.
    public var sizeLabel: String {
        guard let bytes = sizeBytes else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// `2026-04-22` (ISO date prefix) / "—". Hermes returns full ISO
    /// timestamps with seconds + Z; the date prefix is what the user
    /// actually wants in the archived list.
    public var archivedAtLabel: String {
        guard let iso = archivedAt, !iso.isEmpty else { return "—" }
        // Trim to date prefix if it looks like a full ISO timestamp.
        if let tIdx = iso.firstIndex(of: "T") {
            return String(iso[..<tIdx])
        }
        return iso
    }
}

/// One skill a `hermes curator prune` run would bulk-archive — an
/// agent-created skill idle for at least the chosen threshold. Archiving is
/// reversible (Restore), so this is a tidy-up, not a deletion.
public struct CuratorPruneCandidate: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let idleDays: Int

    public init(name: String, idleDays: Int) {
        self.name = name
        self.idleDays = idleDays
    }

    /// "idle 412d" — compact right-aligned column for the confirm sheet.
    public var idleLabel: String { "idle \(idleDays)d" }
}

/// Result of `hermes curator prune [--days N] --dry-run` — the agent-created
/// skills idle ≥ `days` that a real prune would **bulk-archive** (reversibly;
/// it is NOT a disk deletion). Parsed from the CLI's text output
/// (`curator: N skill(s) idle >= Nd:` then `  <name> idle Nd` rows); Hermes
/// has no `--json` for this verb. `days` is threaded through from the request.
public struct CuratorPruneSummary: Sendable, Equatable {
    public let candidates: [CuratorPruneCandidate]
    public let days: Int
    public var count: Int { candidates.count }

    public init(candidates: [CuratorPruneCandidate], days: Int) {
        self.candidates = candidates
        self.days = days
    }
}

/// One archived skill a `hermes curator purge [--days N] --dry-run` run
/// would **permanently delete** (disk removal, not archival — see
/// `CuratorPruneCandidate` for the reversible archive-only preview).
/// Parsed from the CLI's `  <name>` indented rows under the "Archived
/// skills older than Nd:" header.
public struct CuratorPurgeCandidate: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// Result of `hermes curator purge [--days N] [--dry-run] [-y]`. `days` is
/// the effective TTL threshold Hermes reports; `purgedCount` is non-nil only
/// for a completed (non-dry-run) purge — `"curator: purged N archived
/// skill(s). Ledger entries recorded."` — and stays nil for a dry-run
/// preview or a disabled/cancelled response. `disabledReason` carries the
/// "purge disabled (curator.archive_ttl_days is 0)" message verbatim so the
/// UI can explain why nothing happened instead of showing a bare empty list.
public struct CuratorPurgeSummary: Sendable, Equatable {
    public let candidates: [CuratorPurgeCandidate]
    public let days: Int?
    public let purgedCount: Int?
    public let disabledReason: String?

    public init(
        candidates: [CuratorPurgeCandidate],
        days: Int?,
        purgedCount: Int? = nil,
        disabledReason: String? = nil
    ) {
        self.candidates = candidates
        self.days = days
        self.purgedCount = purgedCount
        self.disabledReason = disabledReason
    }

    public var count: Int { candidates.count }
}

/// One row of `hermes curator ledger [--skill N] [--limit N]` — a single
/// mutation the curator/agent/user made to a skill, newest first. Hermes
/// prints a fixed-width table (`hermes_cli/curator.py:539`, `_cmd_ledger`):
///
///     id             when         actor    action       skill
///     ab12cd34ef56   2026-08-18   curator  archive      old-helper
///     …              …            agent    absorb       scratch-pad  → absorbed into 'notes'
///     …              …            user     rollback     old-helper   → rollback of ab12cd34ef56
///
/// `absorbedInto` / `rollbackTarget` are populated only when the row carries
/// the corresponding `→ …` suffix; both nil is the common case.
public struct HermesCuratorLedgerEntry: Sendable, Equatable, Identifiable {
    public var id: String { entryID }
    public let entryID: String
    public let whenLabel: String
    public let actor: String
    public let action: String
    public let skill: String
    public let absorbedInto: String?
    public let rollbackTarget: String?

    public init(
        entryID: String,
        whenLabel: String,
        actor: String,
        action: String,
        skill: String,
        absorbedInto: String? = nil,
        rollbackTarget: String? = nil
    ) {
        self.entryID = entryID
        self.whenLabel = whenLabel
        self.actor = actor
        self.action = action
        self.skill = skill
        self.absorbedInto = absorbedInto
        self.rollbackTarget = rollbackTarget
    }

    /// Whether `hermes curator rollback <entryID>` is a meaningful action on
    /// this row. Every entry has a valid target — even a prior rollback can
    /// itself be rolled back — so this is currently always true, but kept as
    /// a computed property so a future non-revertible action kind (if Hermes
    /// ever adds one) has a single place to opt out.
    public var isRollbackable: Bool { !entryID.isEmpty }
}

/// Result of `hermes curator rollback <entry_id> [-y]` for the single-
/// mutation form (`hermes_cli/curator.py:660`, `_cmd_rollback`). The bare
/// (no `entry_id`) whole-tree snapshot-restore form is unchanged by v0.20.4
/// and isn't modeled here — Scarf doesn't wire that surface yet.
public struct CuratorEntryRollbackResult: Sendable, Equatable {
    public let entryID: String
    public let action: String?
    public let skill: String?
    public let actor: String?
    public let whenLabel: String?
    public let filesTouched: Int?
    /// `true` when Hermes printed "curator: <message>" (success channel);
    /// `false` for "curator: rollback failed — <message>". `message` carries
    /// the trailing text either way for display.
    public let succeeded: Bool
    public let message: String?

    public init(
        entryID: String,
        action: String? = nil,
        skill: String? = nil,
        actor: String? = nil,
        whenLabel: String? = nil,
        filesTouched: Int? = nil,
        succeeded: Bool,
        message: String? = nil
    ) {
        self.entryID = entryID
        self.action = action
        self.skill = skill
        self.actor = actor
        self.whenLabel = whenLabel
        self.filesTouched = filesTouched
        self.succeeded = succeeded
        self.message = message
    }
}
