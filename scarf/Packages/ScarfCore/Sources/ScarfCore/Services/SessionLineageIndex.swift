import Foundation

/// Memory of the rotated compression chains Scarf has listed, so a lookup
/// keyed by a chain's tip id can fall back to the ids before it.
///
/// Every Hermes listing shows a rotated chain under its live TIP id
/// (`_project_compression_tips`, hermes_state_sessions.py:1028-1065 @
/// v2026.9.24), and `HermesDataService` does the same. But Scarf's project
/// attribution sidecar is keyed by the id a chat STARTED with — the chain's
/// root — and the resume paths (Mac chat, iOS chat) only carry a session id
/// string. Without this, resuming a chain from any list lost its project:
/// the respawned `hermes acp` ran in the home directory instead of the
/// project, dropping AGENTS.md and project tools.
///
/// `HermesDataService` records each chain it projects; readers
/// (`SessionAttributionService.projectPath(for:)`) consult it when the
/// direct lookup misses. It is in-memory only — the same rows are recorded
/// again on the next list load — and holds nothing but session ids.
public final class SessionLineageIndex: @unchecked Sendable {
    public static let shared = SessionLineageIndex()

    private let lock = NSLock()
    /// "<server id>|<session id>" → the chain, root first, tip last.
    private var chains: [String: [String]] = [:]

    init() {}

    private static func key(_ server: ServerID, _ sessionID: String) -> String {
        "\(server)|\(sessionID)"
    }

    /// Remember `lineage` (root first, tip last) under every id in it.
    public func record(server: ServerID, lineage: [String]) {
        guard lineage.count > 1 else { return }
        lock.lock()
        defer { lock.unlock() }
        for id in lineage {
            chains[Self.key(server, id)] = lineage
        }
    }

    /// The other ids of the chain `sessionID` belongs to, nearest first
    /// (walking from `sessionID` back toward the root, then any later
    /// segments). Empty when Scarf has not listed a chain containing it.
    public func relatedIds(server: ServerID, sessionID: String) -> [String] {
        lock.lock()
        let chain = chains[Self.key(server, sessionID)] ?? []
        lock.unlock()
        guard let index = chain.firstIndex(of: sessionID) else { return [] }
        return Array(chain[..<index].reversed()) + Array(chain[(index + 1)...])
    }
}
