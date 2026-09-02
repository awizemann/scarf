import Testing
import Foundation
@testable import ScarfCore

/// Coverage for the per-machine mini-app permission grant store. Runs
/// against a fresh temp Hermes home so it never touches the real
/// `~/.hermes/scarf/miniapp_grants.json`.
@Suite struct MiniAppGrantStoreTests {

    static func withTempHome(_ body: (ServerContext) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-grants-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try body(ServerContext.local(home: home))
    }

    @Test func emptyWhenNoDecision() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            #expect(store.grantedPermissions(projectId: "p", miniAppId: "a").isEmpty)
            #expect(store.hasDecision(projectId: "p", miniAppId: "a") == false)
        }
    }

    @Test func setThenReadRoundTrips() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p", miniAppId: "a", permissions: [.store, .prompt, .query("kanban.tasks")])
            let granted = store.grantedPermissions(projectId: "p", miniAppId: "a")
            #expect(granted == [.store, .prompt, .query("kanban.tasks")])
            #expect(store.hasDecision(projectId: "p", miniAppId: "a"))
        }
    }

    @Test func upsertReplacesPriorDecision() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p", miniAppId: "a", permissions: [.store, .prompt])
            try store.setGrant(projectId: "p", miniAppId: "a", permissions: [.store])
            #expect(store.grantedPermissions(projectId: "p", miniAppId: "a") == [.store])
            #expect(store.allGrants().filter { $0.miniAppId == "a" }.count == 1)
        }
    }

    @Test func emptyApprovalIsADistinctDecision() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p", miniAppId: "a", permissions: [])
            #expect(store.grantedPermissions(projectId: "p", miniAppId: "a").isEmpty)
            #expect(store.hasDecision(projectId: "p", miniAppId: "a"))  // decided "nothing", not "never"
        }
    }

    @Test func revokeForgetsDecision() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p", miniAppId: "a", permissions: [.store])
            try store.revoke(projectId: "p", miniAppId: "a")
            #expect(store.hasDecision(projectId: "p", miniAppId: "a") == false)
        }
    }

    @Test func grantsAreScopedByProjectAndMiniApp() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p1", miniAppId: "a", permissions: [.store])
            try store.setGrant(projectId: "p2", miniAppId: "a", permissions: [.prompt])
            #expect(store.grantedPermissions(projectId: "p1", miniAppId: "a") == [.store])
            #expect(store.grantedPermissions(projectId: "p2", miniAppId: "a") == [.prompt])
            #expect(store.grantedPermissions(projectId: "p1", miniAppId: "b").isEmpty)
        }
    }

    // MARK: - Content-bound TOFU

    private func manifest(
        permissions: [MiniAppPermission],
        entry: String = "index.html",
        name: String = "Burndown",
        version: String = "1.0.0"
    ) -> MiniAppManifest {
        MiniAppManifest(id: "a", name: name, version: version, entry: entry, permissions: permissions, generated: true)
    }

    /// The grant is reusable only for the manifest it was made about.
    @Test func decisionMatchesOnlyItsOwnManifestFingerprint() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            let approved = manifest(permissions: [.store])
            try store.setGrant(
                projectId: "p", miniAppId: "a",
                permissions: [.store],
                manifestFingerprint: approved.securityFingerprint
            )
            #expect(store.hasDecision(projectId: "p", miniAppId: "a", matching: approved.securityFingerprint))
        }
    }

    /// The attack this closes: an agent-writable mini-app rewrites its own
    /// `miniapp.json` to ask for more, and must NOT inherit the old grant.
    @Test func addedPermissionInvalidatesThePriorDecision() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            let approved = manifest(permissions: [.store])
            try store.setGrant(
                projectId: "p", miniAppId: "a",
                permissions: [.store],
                manifestFingerprint: approved.securityFingerprint
            )
            let escalated = manifest(permissions: [.store, .net, .fileRead])
            #expect(store.hasDecision(projectId: "p", miniAppId: "a", matching: escalated.securityFingerprint) == false)
            // …but the decision still EXISTS, so the sheet can seed itself
            // with what the user previously said rather than resetting.
            #expect(store.hasDecision(projectId: "p", miniAppId: "a"))
            #expect(store.grantedPermissions(projectId: "p", miniAppId: "a") == [.store])
        }
    }

    /// Repointing `entry` also invalidates: the grant was handed to a
    /// specific document.
    @Test func changedEntryInvalidatesThePriorDecision() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            let approved = manifest(permissions: [.store])
            try store.setGrant(
                projectId: "p", miniAppId: "a",
                permissions: [.store],
                manifestFingerprint: approved.securityFingerprint
            )
            let repointed = manifest(permissions: [.store], entry: "admin.html")
            #expect(store.hasDecision(projectId: "p", miniAppId: "a", matching: repointed.securityFingerprint) == false)
        }
    }

    /// Cosmetic manifest churn (name, version) does NOT re-prompt — that's
    /// the reason the fingerprint covers the security-relevant fields rather
    /// than hashing the whole file. Re-prompting on every edit trains the
    /// user to click through the sheet.
    @Test func cosmeticManifestChurnKeepsThePriorDecision() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            let approved = manifest(permissions: [.store])
            try store.setGrant(
                projectId: "p", miniAppId: "a",
                permissions: [.store],
                manifestFingerprint: approved.securityFingerprint
            )
            let renamed = manifest(permissions: [.store], name: "Burndown v2", version: "1.4.2")
            #expect(store.hasDecision(projectId: "p", miniAppId: "a", matching: renamed.securityFingerprint))
        }
    }

    /// Permission ORDER in the manifest is not a security change.
    @Test func permissionOrderDoesNotChangeTheFingerprint() {
        let a = manifest(permissions: [.store, .events, .query("kanban.tasks")])
        let b = manifest(permissions: [.query("kanban.tasks"), .store, .events])
        #expect(a.securityFingerprint == b.securityFingerprint)
    }

    /// An unknown (this-build-unrecognized) permission still perturbs the
    /// fingerprint — the raw strings are hashed, not the parsed cases.
    @Test func unknownPermissionStillPerturbsTheFingerprint() {
        let a = manifest(permissions: [.store])
        let b = manifest(permissions: [.store, .unknown("future:thing")])
        #expect(a.securityFingerprint != b.securityFingerprint)
    }

    /// A grant written before fingerprinting shipped is not treated as a
    /// decision about today's manifest — one re-review, seeded.
    @Test func legacyGrantWithoutFingerprintRequiresReReview() throws {
        try Self.withTempHome { ctx in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p", miniAppId: "a", permissions: [.store])
            #expect(store.hasDecision(projectId: "p", miniAppId: "a"))
            #expect(store.hasDecision(
                projectId: "p", miniAppId: "a",
                matching: manifest(permissions: [.store]).securityFingerprint
            ) == false)
        }
    }
}
