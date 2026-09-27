import Foundation

/// Deleting a conversation that is a rotated compression chain.
///
/// Every list shows such a chain as ONE row under its tip id
/// (`HermesSession.lineageIds`), but `hermes sessions delete` removes one
/// session row: `SessionDB.delete_session` cascades delegate children only
/// and ORPHANS compression children (`parent_session_id = NULL`)
/// (hermes_state_sessions.py:1531-1577 @ v2026.9.24). Deleting just the tip
/// left the earlier segments behind, and the list then showed the
/// conversation again under the previous segment. So both delete surfaces
/// delete every segment, one `sessions delete --yes -- <id>` each.
///
/// Order is tip first. A failure then stops the run with the earlier
/// segments intact and still chained, so the conversation reappears as a
/// shorter chain the user can delete again — never as orphaned fragments
/// (deleting a root first would orphan its continuation into a separate,
/// headless conversation).
public enum SessionChainDelete {

    public struct Outcome: Sendable, Equatable {
        /// Ids Hermes deleted, in the order they were deleted.
        public let deleted: [String]
        /// The id whose delete failed (and its exit code); nil when every
        /// segment was deleted.
        public let failed: (id: String, exitCode: Int32)?

        public init(deleted: [String], failed: (id: String, exitCode: Int32)?) {
            self.deleted = deleted
            self.failed = failed
        }

        public static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.deleted == rhs.deleted
                && lhs.failed?.id == rhs.failed?.id
                && lhs.failed?.exitCode == rhs.failed?.exitCode
        }
    }

    /// The ids to delete for a row, tip first. An ordinary session is just
    /// its own id.
    public static func deletionOrder(lineage: [String], rowId: String) -> [String] {
        var seen = Set<String>()
        let ids = (lineage.isEmpty ? [rowId] : lineage).filter { !$0.isEmpty && seen.insert($0).inserted }
        return Array(ids.reversed())
    }

    /// Delete `ids` in order through `delete` (which returns the CLI's
    /// exit code), stopping at the first failure. Blocking — call it off
    /// the main actor.
    public static func run(_ ids: [String], delete: (String) -> Int32) -> Outcome {
        var deleted: [String] = []
        for id in ids {
            let code = delete(id)
            guard code == 0 else { return Outcome(deleted: deleted, failed: (id, code)) }
            deleted.append(id)
        }
        return Outcome(deleted: deleted, failed: nil)
    }
}
