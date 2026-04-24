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
struct SessionProjectMap: Codable, Sendable {
    /// session-id → absolute-project-path. Both strings are opaque
    /// from this file's perspective; the service validates project
    /// paths against the live registry when building the reverse
    /// lookup used by the Sessions tab, so stale entries for
    /// removed projects are ignored at read time without needing a
    /// write-side cleanup.
    var mappings: [String: String]

    /// ISO-8601 timestamp of the most recent write. Informational
    /// only — not used for any decision logic. Useful when debugging
    /// a stale sidecar ("when was this last updated?").
    var updatedAt: String?

    init(mappings: [String: String] = [:], updatedAt: String? = nil) {
        self.mappings = mappings
        self.updatedAt = updatedAt
    }

    /// Current time in ISO-8601 format, suitable for the
    /// `updatedAt` field. Matches the format used elsewhere in
    /// Scarf (e.g. `TemplateLock.installedAt`) so tooling that
    /// greps across .json files sees consistent timestamps.
    static func nowISO8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
