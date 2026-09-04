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

    /// Per-session last-write stamp (`sessionID` → ISO-8601), the recency
    /// signal pruning needs. Additive and optional: files written before
    /// t-3b855719 have none, and an entry with no stamp is simply treated
    /// as the oldest thing in the file.
    ///
    /// It exists because the sidecar is capped at 1 MB and had NO pruning —
    /// a long-lived install grows one mapping per session forever until it
    /// crosses the cap, at which point every read returns empty and the
    /// whole attribution history reads as "nothing attributed". Dropping
    /// the oldest entries costs the Sessions tab an old chat's project
    /// label; hitting the cap costs all of them.
    public var touched: [String: String]?

    /// Top-level keys this build does not model, carried verbatim through
    /// decode → edit → encode (P8 DI-L3).
    ///
    /// Every write here is a whole-file read-modify-write that re-encodes
    /// from this model, so before this existed a single attribution write
    /// from an older Scarf silently deleted whatever a newer one had added
    /// — and the file is agent-writable besides. Same contract
    /// `ProjectEntry.extra` and `ProjectRegistry.extra` keep.
    public var extra: [String: JSONValue]

    public init(
        mappings: [String: String] = [:],
        updatedAt: String? = nil,
        touched: [String: String]? = nil,
        extra: [String: JSONValue] = [:]
    ) {
        self.mappings = mappings
        self.updatedAt = updatedAt
        self.touched = touched
        self.extra = extra
    }

    // MARK: - Codable (unknown-key preserving)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mappings, updatedAt, touched
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mappings = try c.decodeIfPresent([String: String].self, forKey: .mappings) ?? [:]
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        self.touched = try c.decodeIfPresent([String: String].self, forKey: .touched)

        let known = Set(CodingKeys.allCases.map(\.rawValue))
        var extras: [String: JSONValue] = [:]
        if let raw = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in raw.allKeys where !known.contains(key.stringValue) {
                if let value = try? raw.decode(JSONValue.self, forKey: key) {
                    extras[key.stringValue] = value
                }
            }
        }
        self.extra = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mappings, forKey: .mappings)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(touched, forKey: .touched)

        var raw = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in extra {
            try raw.encode(value, forKey: AnyCodingKey(stringValue: key))
        }
    }

    /// The most a sidecar may hold. Chosen so the encoded file stays an
    /// order of magnitude under `SessionAttributionService.maxSidecarBytes`
    /// even with long project paths (~200 bytes per entry incl. its stamp).
    public static let maxMappings = 2_000

    /// Drop the least-recently-written mappings until at most
    /// ``maxMappings`` remain. Entries with no stamp go first (they predate
    /// the stamp, so they are by construction the oldest); ties break on
    /// the session id so the result is deterministic and two windows
    /// pruning the same file agree.
    public mutating func prune(limit: Int = SessionProjectMap.maxMappings) {
        guard mappings.count > limit else { return }
        let stamps = touched ?? [:]
        let survivors = mappings.keys
            .sorted { lhs, rhs in
                let l = stamps[lhs] ?? ""
                let r = stamps[rhs] ?? ""
                if l != r { return l > r }   // newest first
                return lhs < rhs
            }
            .prefix(limit)
        let keep = Set(survivors)
        mappings = mappings.filter { keep.contains($0.key) }
        touched = stamps.filter { keep.contains($0.key) }
    }

    /// Current time in ISO-8601 format, suitable for the
    /// `updatedAt` field. Matches the format used elsewhere in
    /// Scarf (e.g. `TemplateLock.installedAt`) so tooling that
    /// greps across .json files sees consistent timestamps.
    public static func nowISO8601() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
