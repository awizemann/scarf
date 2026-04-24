import Foundation

/// Scarf-owned sidecar mapping Hermes session IDs to the Scarf
/// project path a chat was started for. Written on session create
/// when Scarf spawns `hermes acp` with a project-scoped cwd; read
/// by the per-project Sessions tab.
///
/// Hermes's own `state.db` has no `cwd` column on the sessions
/// table — the cwd is passed at runtime via ACP but not persisted
/// on its side. This sidecar is how we recover the attribution
/// without requiring an upstream schema change.
///
/// Stored at `~/.hermes/scarf/session_project_map.json`. Forward-
/// compatible: if Hermes ever gains a canonical `cwd` column, Scarf
/// can prefer that and fall back to this file for pre-upgrade
/// sessions. Missing file → empty map (nothing attributed yet).
///
/// Promoted to ScarfCore in M9 #4.2 so iOS can use the same record
/// type — ScarfGo's project-scoped chat writes here over SFTP.
public struct SessionProjectMap: Codable, Sendable {
    public var mappings: [String: String]
    public var updatedAt: String?

    public init(mappings: [String: String] = [:], updatedAt: String? = nil) {
        self.mappings = mappings
        self.updatedAt = updatedAt
    }

    /// Current time in ISO-8601 format, suitable for the
    /// `updatedAt` field. Matches the format used elsewhere in
    /// Scarf (e.g. `TemplateLock.installedAt`) so tooling that
    /// greps across .json files sees consistent timestamps.
    public static func nowISO8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
