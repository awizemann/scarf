import Foundation
import CryptoKit

/// On-disk manifest for a mini-app — `miniapp.json` at the root of a
/// mini-app directory (`<project>/.scarf/miniapps/<id>/`).
///
/// A mini-app is a small web surface (HTML/CSS/JS) rendered inside Scarf
/// over a narrow, versioned JS bridge (`window.scarf`). It is a project
/// facet: shipped via `.scarftemplate`, dropped into the project, or
/// generated on the fly by the agent. See the Mini-App Bridge Contract.
///
/// ```json
/// { "id": "kanban-burndown", "name": "Burndown", "version": "1.0.0",
///   "entry": "index.html", "minBridgeVersion": "1.0",
///   "permissions": ["query:kanban.tasks", "prompt", "events", "store"],
///   "panelHint": { "preferredWidth": 420, "placement": "panel" },
///   "generated": false }
/// ```
///
/// Decoding is lenient: only `id` + `name` are required; `entry` defaults
/// to `index.html`, `permissions` to `[]` (default-deny), `generated` to
/// `false`, `minBridgeVersion` to `"1.0"`. Unknown keys are ignored so the
/// format can grow without invalidating existing manifests.
public struct MiniAppManifest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    /// Relative entry document inside the mini-app dir.
    public var entry: String
    /// Minimum `window.scarf` bridge version the mini-app needs; checked at
    /// mount (`scarf.version`). Mismatch → host loads degraded or refuses.
    public var minBridgeVersion: String
    /// Declared bridge surfaces (default-deny — see `MiniAppPermission`).
    public var permissions: [MiniAppPermission]
    public var panelHint: PanelHint?
    /// `true` for agent-written mini-apps — stricter permission defaults
    /// (no `net`, no `file:write`) until the user explicitly elevates.
    public var generated: Bool

    /// Layout hint for the cockpit panel host. Advisory only.
    public struct PanelHint: Codable, Sendable, Hashable {
        public var preferredWidth: Double?
        public var placement: String?

        public init(preferredWidth: Double? = nil, placement: String? = nil) {
            self.preferredWidth = preferredWidth
            self.placement = placement
        }
    }

    public init(
        id: String,
        name: String,
        version: String = "1.0.0",
        entry: String = "index.html",
        minBridgeVersion: String = "1.0",
        permissions: [MiniAppPermission] = [],
        panelHint: PanelHint? = nil,
        generated: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.entry = entry
        self.minBridgeVersion = minBridgeVersion
        self.permissions = permissions
        self.panelHint = panelHint
        self.generated = generated
    }

    /// Stable fingerprint of the security-relevant half of `miniapp.json` —
    /// what a permission grant is actually a decision *about*.
    ///
    /// Persisted alongside a `MiniAppGrant` so a trust-on-first-use decision
    /// is bound to content, not just to `(projectId, miniAppId)`: a
    /// mini-app that rewrites its own manifest to request `net` +
    /// `file:read` (agent-generated apps are rewritten routinely, and the
    /// directory is agent-writable) can no longer inherit the grant the user
    /// gave the previous version. A changed fingerprint sends the launch
    /// flow back through the permission sheet, seeded with the prior answer.
    ///
    /// **Why not a hash of the whole `miniapp.json` (or the whole app).**
    /// The mini-app's *code* changes constantly and legitimately — that is
    /// the point of an agent-built app — and `name`/`version`/`panelHint`
    /// churn with it. Re-prompting on every cosmetic edit trains the user to
    /// click "Approve" without reading, which destroys the value of the
    /// sheet; and hashing the HTML/JS would make the prompt fire on every
    /// single iteration. The grant authorizes *surfaces*, so the fingerprint
    /// covers exactly the fields that determine them: the declared
    /// permissions, the `entry` document the grant is handed to, and the
    /// `minBridgeVersion` gate. Raw permission strings are used (not the
    /// parsed cases) so an unknown-today permission still perturbs the hash.
    public var securityFingerprint: String {
        let material = ([
            "v1",
            "entry=" + entry,
            "minBridge=" + minBridgeVersion
        ] + permissions.map { "perm=" + $0.rawValue }.sorted()).joined(separator: "\n")
        return Self.sha256Hex(material)
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Codable (lenient)

    private enum CodingKeys: String, CodingKey {
        case id, name, version, entry, minBridgeVersion, permissions, panelHint, generated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        self.entry = try c.decodeIfPresent(String.self, forKey: .entry) ?? "index.html"
        self.minBridgeVersion = try c.decodeIfPresent(String.self, forKey: .minBridgeVersion) ?? "1.0"
        self.permissions = try c.decodeIfPresent([MiniAppPermission].self, forKey: .permissions) ?? []
        self.panelHint = try c.decodeIfPresent(PanelHint.self, forKey: .panelHint)
        self.generated = try c.decodeIfPresent(Bool.self, forKey: .generated) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encode(entry, forKey: .entry)
        try c.encode(minBridgeVersion, forKey: .minBridgeVersion)
        try c.encode(permissions, forKey: .permissions)
        try c.encodeIfPresent(panelHint, forKey: .panelHint)
        try c.encode(generated, forKey: .generated)
    }
}
