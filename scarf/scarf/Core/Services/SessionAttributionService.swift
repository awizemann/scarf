import Foundation
import os
import ScarfCore

/// Owns the sidecar that attributes Hermes session IDs to Scarf
/// project paths. The `cwd` passed to `hermes acp` at session
/// creation is ephemeral from Hermes's perspective (not written to
/// `state.db`), so Scarf keeps this Scarf-owned record parallel to
/// Hermes's session store.
///
/// File: `~/.hermes/scarf/session_project_map.json` (resolved via
/// `HermesPathSet.sessionProjectMap`).
///
/// Thread safety: all public methods are `nonisolated` and each
/// performs a single read-modify-write cycle that's atomic on
/// disk. Concurrent writers (two Scarf windows on the same
/// `~/.hermes`) are safe at the file level — last write wins —
/// but the in-memory read in one window may lag until that window
/// reloads. Acceptable for v2.3's scale; revisit if multi-window
/// cross-talk becomes a problem.
struct SessionAttributionService: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "SessionAttributionService")

    let context: ServerContext

    nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Read

    /// Load the current sidecar contents. Missing file or unparseable
    /// JSON returns an empty map — the sidecar is a convenience
    /// index, not a source of truth for anything load-bearing.
    nonisolated func load() -> SessionProjectMap {
        let path = context.paths.sessionProjectMap
        let transport = context.makeTransport()
        guard transport.fileExists(path) else {
            return SessionProjectMap()
        }
        do {
            let data = try transport.readFile(path)
            return try JSONDecoder().decode(SessionProjectMap.self, from: data)
        } catch {
            Self.logger.warning("session-project-map parse failed at \(path, privacy: .public): \(error.localizedDescription, privacy: .public); returning empty map")
            return SessionProjectMap()
        }
    }

    /// Look up the project path a given session was attributed to.
    /// Returns nil for unattributed sessions (CLI-started, or
    /// started before v2.3) — those surface in the global Sessions
    /// sidebar unchanged and don't appear in any project's Sessions
    /// tab.
    nonisolated func projectPath(for sessionID: String) -> String? {
        load().mappings[sessionID]
    }

    /// Reverse lookup: every session ID attributed to the given
    /// project path. Used by the per-project Sessions tab to filter
    /// the global session list. Comparison is exact-string; the
    /// registry stores absolute paths and we write absolute paths,
    /// so no normalisation is needed in practice.
    nonisolated func sessionIDs(forProject projectPath: String) -> Set<String> {
        let map = load()
        return Set(map.mappings.filter { $0.value == projectPath }.keys)
    }

    // MARK: - Write

    /// Record that `sessionID` was created under the given project
    /// path. Idempotent — repeated calls for the same pair are no-
    /// ops. Replacing an existing mapping (session moved to a
    /// different project) is legal but expected to be rare; the
    /// caller decides when that's correct.
    nonisolated func attribute(sessionID: String, toProjectPath projectPath: String) {
        var map = load()
        if map.mappings[sessionID] == projectPath {
            return
        }
        map.mappings[sessionID] = projectPath
        map.updatedAt = SessionProjectMap.nowISO8601()
        persist(map)
    }

    /// Remove a mapping. Called in v2.3's Sessions-tab code path is
    /// minimal — we don't currently prune on session delete because
    /// Hermes owns session lifecycle and we don't observe deletes.
    /// Exposed for future roadmap items (e.g. explicit "detach
    /// from project" action) and tests.
    nonisolated func forget(sessionID: String) {
        var map = load()
        guard map.mappings.removeValue(forKey: sessionID) != nil else { return }
        map.updatedAt = SessionProjectMap.nowISO8601()
        persist(map)
    }

    // MARK: - Private

    private func persist(_ map: SessionProjectMap) {
        let path = context.paths.sessionProjectMap
        let transport = context.makeTransport()
        let dir = context.paths.scarfDir
        do {
            if !transport.fileExists(dir) {
                try transport.createDirectory(dir)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(map)
            try transport.writeFile(path, data: data)
        } catch {
            Self.logger.error("failed to persist session-project-map at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
