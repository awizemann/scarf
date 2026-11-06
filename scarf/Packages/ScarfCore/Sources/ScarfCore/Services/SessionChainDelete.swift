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
        /// Hermes's own explanation for the failed delete
        /// (`failureReason(from:)`); nil when nothing failed or the CLI
        /// printed nothing usable.
        public let failureReason: String?

        public init(deleted: [String], failed: (id: String, exitCode: Int32)?, failureReason: String? = nil) {
            self.deleted = deleted
            self.failed = failed
            self.failureReason = failureReason
        }

        /// The failed delete was Hermes saying it has no such session.
        public var failedBecauseNoSession: Bool {
            failed != nil && failureReason?.hasPrefix(HermesSessionsCLI.noSessionPrefix) == true
        }

        public static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.deleted == rhs.deleted
                && lhs.failed?.id == rhs.failed?.id
                && lhs.failed?.exitCode == rhs.failed?.exitCode
                && lhs.failureReason == rhs.failureReason
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
        run(ids, deleteReporting: { (exitCode: delete($0), output: "") })
    }

    /// How long Hermes gets to let go of a session whose turn was just
    /// cancelled, before its refusal stands (attempts, seconds between them).
    public nonisolated static let turnUnwindRetries = (attempts: 8, delay: 2.0 as TimeInterval)

    /// Hermes refusing because a turn hasn't ended yet, the one refusal that
    /// time cures (`_cmd_delete`, hermes_cli/sessions_cmd.py:646,654 @ v0.22.5;
    /// v2026.9.24 has neither). "No session" and a turn lost across a gateway
    /// restart (:651) stay as they are however long we wait.
    public static func isTurnStillUnwinding(_ output: String) -> Bool {
        output.contains("Cannot delete active session") || output.contains("queued or running turn")
    }

    /// Hermes has no such session (`_not_found`, sessions_cmd.py:49-51 on both
    /// tags). The quote keeps "No session database at …" out.
    public static func isNoSession(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.hasPrefix(HermesSessionsCLI.noSessionPrefix) }
    }

    /// One segment's delete, tried again while a turn the caller just stopped
    /// unwinds. Nothing stopped, or any other refusal: one attempt, so it is
    /// reported at once. Blocking.
    public static func retrying(
        afterStoppingTurns stopped: Bool,
        delay: TimeInterval = turnUnwindRetries.delay,
        _ delete: () -> (exitCode: Int32, output: String)
    ) -> (exitCode: Int32, output: String) {
        var result = delete()
        guard stopped else { return result }
        var attempt = 1
        while attempt < turnUnwindRetries.attempts, result.exitCode != 0, isTurnStillUnwinding(result.output) {
            Thread.sleep(forTimeInterval: delay)
            result = delete()
            attempt += 1
        }
        return result
    }

    /// `run(_:delete:)` for a `delete` that also hands back the CLI's
    /// combined output, so the failure carries Hermes's own reason
    /// (`Outcome.failureReason`).
    public static func run(
        _ ids: [String],
        deleteReporting delete: (String) -> (exitCode: Int32, output: String)
    ) -> Outcome {
        var deleted: [String] = []
        for id in ids {
            let result = delete(id)
            guard result.exitCode == 0 else {
                // On v0.22.5 deleting one segment of a gateway-local
                // conversation deletes all of it (hermes_state_sessions.py:1753-1755,
                // hermes_state_local.py:185-190), so the next segment is
                // already gone: that is done, not "Deleted 1 of N".
                if !deleted.isEmpty, isNoSession(result.output) {
                    deleted.append(id)
                    continue
                }
                return Outcome(
                    deleted: deleted,
                    failed: (id, result.exitCode),
                    failureReason: failureReason(from: result.output)
                )
            }
            deleted.append(id)
        }
        return Outcome(deleted: deleted, failed: nil)
    }

    /// The line of a failed `hermes sessions delete`'s output worth showing.
    ///
    /// Hermes prints its refusals and exits 1 (`_cmd_delete`,
    /// hermes_cli/sessions_cmd.py:645-660 @ v0.22.5):
    /// `Cannot delete active session: …` (v0.21.6+),
    /// `Cannot delete session '<id>': it has a queued or running turn. …` and
    /// `Cannot delete session '<id>': a turn was lost across a gateway
    /// restart. …` (v0.22.3+). That line wins when present — anything
    /// printed before or after it (a pinned-session warning) is noise.
    /// Otherwise the last non-empty line, which is how any host's failure
    /// (an older host, a traceback's final line) gets shown. Nil when the
    /// CLI said nothing, so the caller falls back to the exit code instead
    /// of presenting an empty reason.
    public static func failureReason(from output: String) -> String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last(where: { $0.hasPrefix("Cannot delete") }) ?? lines.last
    }
}
