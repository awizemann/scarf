import Foundation
#if canImport(os)
import os
#endif

/// One persisted permission decision: which surfaces the user approved for
/// a given mini-app in a given project, and when.
public struct MiniAppGrant: Codable, Sendable, Hashable {
    public var projectId: String
    public var miniAppId: String
    /// `MiniAppPermission` raw values the user approved.
    public var permissions: [String]
    public var decidedAt: String
    /// `MiniAppManifest.securityFingerprint` at the moment of the decision —
    /// what the user was actually shown. `nil` for grants written before
    /// fingerprinting shipped, which is treated as "not a decision about
    /// today's manifest" (→ re-review, seeded with this grant).
    public var manifestFingerprint: String?

    public init(
        projectId: String,
        miniAppId: String,
        permissions: [String],
        decidedAt: String,
        manifestFingerprint: String? = nil
    ) {
        self.projectId = projectId
        self.miniAppId = miniAppId
        self.permissions = permissions
        self.decidedAt = decidedAt
        self.manifestFingerprint = manifestFingerprint
    }
}

/// Per-machine store of mini-app permission grants at
/// `~/.hermes/scarf/miniapp_grants.json`. Scarf-owned, transport-based.
///
/// The trust boundary's persistence: `MiniAppBridgeDispatcher` is
/// constructed from `grantedPermissions(projectId:miniAppId:)`, so a
/// surface only works after the user approved it here. Grants are keyed by
/// (projectId, miniAppId) and live OUTSIDE the portable project record on
/// purpose — see `HermesPathSet.miniAppGrantsJSON`.
public struct MiniAppGrantStore: Sendable {
    #if canImport(os)
    private static let logger = Logger(subsystem: "com.scarf", category: "MiniAppGrantStore")
    #endif

    public static let maxBytes = 4 * 1024 * 1024

    public let context: ServerContext

    public nonisolated init(context: ServerContext = .local) {
        self.context = context
    }

    /// The permission set the user approved for this mini-app, or empty
    /// (default-deny) when no decision is on record. Unknown raw values
    /// decode to `.unknown` and stay denied at preflight.
    public nonisolated func grantedPermissions(projectId: String, miniAppId: String) -> Set<MiniAppPermission> {
        guard let grant = load().first(where: { $0.projectId == projectId && $0.miniAppId == miniAppId }) else {
            return []
        }
        return Set(grant.permissions.map { MiniAppPermission(rawValue: $0) })
    }

    /// Record (upsert) the user's decision. An empty set is a meaningful
    /// "approved nothing" record (distinct from "never decided"), so it is
    /// persisted rather than dropped.
    public nonisolated func setGrant(
        projectId: String,
        miniAppId: String,
        permissions: Set<MiniAppPermission>,
        manifestFingerprint: String? = nil
    ) throws {
        try mutate { grants in
            grants.removeAll { $0.projectId == projectId && $0.miniAppId == miniAppId }
            grants.append(MiniAppGrant(
                projectId: projectId,
                miniAppId: miniAppId,
                permissions: permissions.map(\.rawValue).sorted(),
                decidedAt: Self.iso8601.string(from: Date()),
                manifestFingerprint: manifestFingerprint
            ))
            return true
        }
    }

    /// Forget a mini-app's grant entirely (back to default-deny / "never
    /// decided"). No-op when none exists.
    public nonisolated func revoke(projectId: String, miniAppId: String) throws {
        try mutate { grants in
            let before = grants.count
            grants.removeAll { $0.projectId == projectId && $0.miniAppId == miniAppId }
            return grants.count != before
        }
    }

    /// Whether a decision is on record (used to decide whether to show the
    /// preview sheet before first run).
    public nonisolated func hasDecision(projectId: String, miniAppId: String) -> Bool {
        load().contains { $0.projectId == projectId && $0.miniAppId == miniAppId }
    }

    /// Whether the recorded decision was made about **this** manifest —
    /// i.e. a decision exists AND its `manifestFingerprint` matches
    /// `fingerprint`.
    ///
    /// The trust-on-first-use key is `(projectId, miniAppId, fingerprint)`,
    /// not `(projectId, miniAppId)`: a mini-app directory is agent-writable,
    /// so an app the user approved for `store` alone can rewrite its own
    /// `miniapp.json` to also request `net` and `file:read` and — under the
    /// old key — would have silently run with whatever the launcher looked
    /// up. Now the permission sheet reappears whenever the security-relevant
    /// manifest fields change. Pre-fingerprint grants (`nil`) also fail this
    /// check, so those get exactly one re-review, seeded with the prior
    /// answer, rather than being trusted blindly.
    public nonisolated func hasDecision(
        projectId: String,
        miniAppId: String,
        matching fingerprint: String
    ) -> Bool {
        guard let grant = load().first(where: { $0.projectId == projectId && $0.miniAppId == miniAppId }) else {
            return false
        }
        return grant.manifestFingerprint == fingerprint
    }

    public nonisolated func allGrants() -> [MiniAppGrant] { load() }

    // MARK: - Private I/O

    /// Read-only view. A file we can't read reads as "no decisions on
    /// record", which is default-DENY and therefore the safe direction for
    /// every read — but it is a lie about the file, which is exactly why
    /// `mutate` re-inspects rather than trusting this.
    private nonisolated func load() -> [MiniAppGrant] {
        inspect().grants
    }

    private nonisolated func store() -> GuardedJSONStore {
        GuardedJSONStore(transport: context.makeTransport(), label: "miniapp_grants.json")
    }

    /// One read: the grants AND the state of the bytes behind them.
    private nonisolated func inspect() -> (grants: [MiniAppGrant], inspection: GuardedJSONStore.Inspection) {
        let (inspection, envelope) = store().inspectDecoding(
            Envelope.self, at: context.paths.miniAppGrantsJSON, maxBytes: Self.maxBytes
        )
        return (envelope?.grants ?? [], inspection)
    }

    /// THE GRANTS CHOKEPOINT. Every write to `miniapp_grants.json` is a
    /// whole-file read-modify-write, and the old shape was
    /// `try? decode ?? []` + full replace — so ONE failed read (an SSH
    /// blip, an SFTP timeout on iOS) silently converted every recorded
    /// permission decision into an empty file on the next grant. Now the
    /// read and the write share one inspection, and a stat-confirmed,
    /// twice-failed read REFUSES the write instead of publishing the
    /// emptiness it invented.
    ///
    /// Bytes that are present but undecodable are quarantined by
    /// `GuardedJSONStore` and then rebuilt from empty rather than refused
    /// forever — the same call `ProjectStore` makes for `project.json`.
    /// Grants are re-grantable (the permission sheet reappears, seeded
    /// default-deny) and the original bytes survive in the quarantine copy;
    /// `projects.json` refuses instead because its rows exist nowhere else.
    ///
    /// - Parameter body: mutates the grants in place and returns whether
    ///   anything actually changed. `false` writes nothing.
    private nonisolated func mutate(_ body: (inout [MiniAppGrant]) -> Bool) throws {
        let (loaded, inspection) = inspect()
        var grants = loaded
        guard body(&grants) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, grants: grants))
        try store().write(data, to: context.paths.miniAppGrantsJSON, after: inspection)
    }

    private struct Envelope: Codable, Sendable {
        var version: Int
        var grants: [MiniAppGrant]
    }

    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()
}
