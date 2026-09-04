import Foundation

/// The one reader for `<project>/.scarf/manifest.json`'s template identity,
/// and the one place that knows the **sentinel manifest** rule.
///
/// `KanbanTenantResolver` mints a minimal manifest for a bare project just to
/// carry `kanbanTenant`; its `id`/`version` are placeholders (`scarf/<name>`,
/// `0.0.0`), not a real installed template, and every surface that shows
/// template identity has to suppress them. That rule used to be re-implemented
/// per reader — drift here means a bare project starts claiming to be a
/// template in one surface and not another.
///
/// A lightweight JSON projection rather than the full manifest type on
/// purpose: the Codable manifest lives in the Mac app target, and ScarfCore
/// reads only the fields it needs (same pattern as `KanbanTenantReader`).
public enum ProjectManifestProjection {
    /// Placeholder `id` prefix and `version` written by `KanbanTenantResolver`
    /// when it mints a manifest for a project that has no template.
    public static let sentinelIDPrefix = "scarf/"
    public static let sentinelVersion = "0.0.0"

    /// Is this manifest identity a minted placeholder rather than a real
    /// installed template?
    public static func isSentinel(id: String, version: String) -> Bool {
        id.hasPrefix(sentinelIDPrefix) && version == sentinelVersion
    }

    /// `(id, version)` from raw `manifest.json` bytes — `nil` when the file
    /// doesn't parse or carries the sentinel identity.
    public static func templateInfo(from data: Data) -> (id: String, version: String)? {
        struct Projection: Decodable { let id: String; let version: String }
        guard let p = try? JSONDecoder().decode(Projection.self, from: data) else { return nil }
        if isSentinel(id: p.id, version: p.version) { return nil }
        return (p.id, p.version)
    }
}
