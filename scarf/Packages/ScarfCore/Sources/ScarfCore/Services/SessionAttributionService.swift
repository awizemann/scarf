import Foundation
#if canImport(os)
import os
#endif

/// Owns the sidecar that attributes Hermes session IDs to Scarf
/// project paths. Promoted to ScarfCore in M9 #4.2 so ScarfGo can
/// write project attributions over SFTP — the whole service is
/// transport-based, so Mac and iOS share the same code path.
///
/// File: `~/.hermes/scarf/session_project_map.json` (resolved via
/// `HermesPathSet.sessionProjectMap`).
///
/// Thread safety: all public methods are `nonisolated` and each
/// performs a single read-modify-write cycle that's atomic on
/// disk. Concurrent writers (two Scarf windows on the same
/// `~/.hermes`) are safe at the file level — last write wins —
/// but the in-memory read in one window may lag until that window
/// reloads.
public struct SessionAttributionService: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "SessionAttributionService")
    #endif

    public let context: ServerContext

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    // MARK: - Read

    /// Load the current sidecar contents. Missing file or unparseable
    /// JSON returns an empty map — the sidecar is a convenience
    /// index, not a source of truth for anything load-bearing.
    public nonisolated func load() -> SessionProjectMap {
        let path = context.paths.sessionProjectMap
        let transport = context.makeTransport()
        guard transport.fileExists(path) else {
            return SessionProjectMap()
        }
        do {
            let data = try transport.readFile(path)
            return try JSONDecoder().decode(SessionProjectMap.self, from: data)
        } catch {
            #if canImport(os)
            Self.logger.warning("session-project-map parse failed at \(path, privacy: .public): \(error.localizedDescription, privacy: .public); returning empty map")
            #endif
            return SessionProjectMap()
        }
    }

    /// Look up the project path a given session was attributed to.
    /// Returns nil for unattributed sessions.
    public nonisolated func projectPath(for sessionID: String) -> String? {
        load().mappings[sessionID]
    }

    /// Reverse lookup: every session ID attributed to the given
    /// project path.
    public nonisolated func sessionIDs(forProject projectPath: String) -> Set<String> {
        let map = load()
        return Set(map.mappings.filter { $0.value == projectPath }.keys)
    }

    // MARK: - Write

    /// Record that `sessionID` was created under the given project
    /// path. Idempotent.
    public nonisolated func attribute(sessionID: String, toProjectPath projectPath: String) {
        var map = load()
        if map.mappings[sessionID] == projectPath {
            return
        }
        map.mappings[sessionID] = projectPath
        map.updatedAt = SessionProjectMap.nowISO8601()
        persist(map)
    }

    /// Remove a mapping. Exposed for future "detach from project"
    /// UIs and tests; today's Mac + iOS call sites don't invoke it
    /// because Hermes owns session lifecycle.
    public nonisolated func forget(sessionID: String) {
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
            #if canImport(os)
            Self.logger.error("failed to persist session-project-map at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }
}
