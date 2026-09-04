import Testing
import Foundation
@testable import ScarfCore

/// S2 (t-a2c169f0): the security mediums of the P7 projects audit, tested
/// as ATTACKS rather than as options — each case is the specific thing an
/// agent with write access to the project folder could do before the fix.
@Suite struct ProjectsS2SecurityTests {

    static func withTempHome(_ body: (ServerContext, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-s2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try body(ServerContext.local(home: home), home)
    }

    // MARK: - M4: absurd project roots

    @Test func filesystemRootIsRefusedAsAProjectRoot() {
        let refusal = ProjectRootPolicy.refusal(
            for: "/", hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
        )
        #expect(refusal == .filesystemRoot)
    }

    @Test func homeDirectoryIsRefusedAsAProjectRoot() {
        let refusal = ProjectRootPolicy.refusal(
            for: "/Users/x", hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
        )
        #expect(refusal == .homeDirectory("/Users/x"))
    }

    /// The registration-side half of what makes containment mean something:
    /// a root ABOVE `~/.hermes` puts `.env`, `state.db` and `projects.json`
    /// "inside the project", so every widget path check and every uninstall
    /// containment check says yes to them.
    @Test func aRootContainingTheHermesHomeIsRefused() {
        let refusal = ProjectRootPolicy.refusal(
            for: "/Users/x/work", hermesHome: "/Users/x/work/nested/.hermes", userHome: "/Users/x"
        )
        #expect(refusal == .containsHermesHome(
            root: "/Users/x/work", hermesHome: "/Users/x/work/nested/.hermes"
        ))
    }

    /// The trailing-slash / dot-segment spellings of an absurd root are the
    /// same absurd root — normalized before the compare, like everywhere
    /// else in this surface.
    @Test func absurdRootsAreRefusedInEverySpelling() {
        #expect(ProjectRootPolicy.refusal(
            for: "/Users/x/", hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
        ) == .homeDirectory("/Users/x"))
        #expect(ProjectRootPolicy.refusal(
            for: "/Users/x/./projects/..", hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
        ) == .homeDirectory("/Users/x"))
    }

    @Test func systemDirectoriesAreRefusedButTheirChildrenAreNot() {
        #expect(ProjectRootPolicy.refusal(
            for: "/etc", hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
        ) == .systemDirectory("/etc"))
        #expect(ProjectRootPolicy.refusal(
            for: "/usr/local/src/thing", hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
        ) == nil)
    }

    /// The policy must never become the reason a real project won't
    /// register: an ordinary folder, including one INSIDE the Hermes home
    /// (which every test home is), is fine.
    @Test func ordinaryProjectRootsAreAccepted() {
        #expect(ProjectRootPolicy.refusal(
            for: "/Users/x/code/scarf", hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
        ) == nil)
        #expect(ProjectRootPolicy.refusal(
            for: "/Users/x/.hermes/projects/site", hermesHome: "/Users/x/.hermes", userHome: "/Users/x"
        ) == nil)
    }

    /// A remote context has no local home to compare against — guessing
    /// with `NSHomeDirectory()` would answer a question about the wrong
    /// machine and refuse legitimate remote roots.
    @Test func remoteContextsSkipTheUserHomeCheck() {
        #expect(ProjectRootPolicy.refusal(
            for: "/home/deploy", hermesHome: "/home/deploy/.hermes", userHome: nil
        ) == .containsHermesHome(root: "/home/deploy", hermesHome: "/home/deploy/.hermes"))
        #expect(ProjectRootPolicy.refusal(
            for: "/home/deploy/site", hermesHome: "/home/deploy/.hermes", userHome: nil
        ) == nil)
    }

    // MARK: - M5: slash-command names

    /// `name` is frontmatter the agent writes, and it does not have to match
    /// the filename. `delete(named:)` builds a path from it.
    @Test func aSlashCommandWithATraversingNameIsNotLoaded() {
        let raw = """
        ---
        name: ../../../.hermes/scarf/projects
        description: innocuous
        ---
        body
        """
        #expect(ProjectSlashCommandService.parse(raw, sourcePath: "/p/.scarf/slash-commands/ok.md") == nil)
    }

    @Test func aSlashCommandWithASlashOrSpaceInItsNameIsNotLoaded() {
        for bad in ["a/b", "has space", "Upper", "-leading", ""] {
            let raw = """
            ---
            name: \(bad)
            description: d
            ---
            body
            """
            #expect(
                ProjectSlashCommandService.parse(raw, sourcePath: "/p/x.md") == nil,
                "name \"\(bad)\" should not load"
            )
        }
    }

    @Test func wellFormedSlashCommandsStillLoad() {
        let raw = """
        ---
        name: deploy-site
        description: ship it
        ---
        body here
        """
        let parsed = ProjectSlashCommandService.parse(raw, sourcePath: "/p/x.md")
        #expect(parsed?.name == "deploy-site")
    }

    @Test func deletingByATraversingNameThrowsInsteadOfBuildingThePath() throws {
        try Self.withTempHome { ctx, home in
            let service = ProjectSlashCommandService(context: ctx)
            let victim = home.appendingPathComponent("victim.md")
            try Data("keep me".utf8).write(to: victim)
            #expect(throws: ProjectSlashCommandService.ServiceError.self) {
                try service.delete(named: "../../../victim", at: home.path + "/proj")
            }
            #expect(FileManager.default.fileExists(atPath: victim.path))
        }
    }

    // MARK: - M3: grant authenticity

    /// THE ATTACK. `miniapp_grants.json` is agent-writable and the manifest
    /// fingerprint a grant records is computable by whoever wrote the
    /// manifest — so before signing, an agent could hand itself every
    /// sensitive permission and the launcher's trust-on-first-use check
    /// would pass with no sheet.
    @Test func aHandWrittenGrantIsNotHonoured() throws {
        try Self.withTempHome { ctx, _ in
            let path = ctx.paths.miniAppGrantsJSON
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            let forged = """
            {"version":1,"grants":[{"projectId":"p","miniAppId":"evil",
            "permissions":["prompt","file:read"],"decidedAt":"2026-09-04T00:00:00Z",
            "manifestFingerprint":"whatever-the-agent-computed"}]}
            """
            try Data(forged.utf8).write(to: URL(fileURLWithPath: path))

            let store = MiniAppGrantStore(context: ctx)
            #expect(store.grantedPermissions(projectId: "p", miniAppId: "evil").isEmpty)
            #expect(store.hasDecision(projectId: "p", miniAppId: "evil") == false)
            #expect(store.hasDecision(
                projectId: "p", miniAppId: "evil", matching: "whatever-the-agent-computed"
            ) == false)
        }
    }

    /// Editing a REAL grant is the same attack with fewer steps: widen the
    /// permissions on a row Scarf signed and the tag no longer covers it.
    @Test func aTamperedGrantIsDropped() throws {
        try Self.withTempHome { ctx, _ in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(
                projectId: "p", miniAppId: "a", permissions: [.store], manifestFingerprint: "fp"
            )
            #expect(store.grantedPermissions(projectId: "p", miniAppId: "a") == [.store])

            let url = URL(fileURLWithPath: ctx.paths.miniAppGrantsJSON)
            let text = try String(contentsOf: url, encoding: .utf8)
            let widened = text.replacingOccurrences(
                of: "\"store\"", with: "\"store\",\n        \"file:read\""
            )
            #expect(widened != text)
            try Data(widened.utf8).write(to: url)

            #expect(store.grantedPermissions(projectId: "p", miniAppId: "a").isEmpty)
        }
    }

    /// Swapping the fingerprint is the interesting tamper: it is the field
    /// the trust-on-first-use gate reads, and it is the one an agent can
    /// compute for a manifest it just rewrote.
    @Test func swappingTheFingerprintOnASignedGrantDropsIt() throws {
        try Self.withTempHome { ctx, _ in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(
                projectId: "p", miniAppId: "a", permissions: [.store], manifestFingerprint: "old-fp"
            )
            let url = URL(fileURLWithPath: ctx.paths.miniAppGrantsJSON)
            let text = try String(contentsOf: url, encoding: .utf8)
            try Data(text.replacingOccurrences(of: "old-fp", with: "new-fp").utf8).write(to: url)

            #expect(store.hasDecision(projectId: "p", miniAppId: "a", matching: "new-fp") == false)
            #expect(store.grantedPermissions(projectId: "p", miniAppId: "a").isEmpty)
        }
    }

    /// The fix must not break the thing it protects: Scarf's own writes
    /// verify, and honest rows survive a forged one sitting beside them.
    @Test func scarfsOwnGrantsVerifyAndSurviveAForgedNeighbour() throws {
        try Self.withTempHome { ctx, _ in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(
                projectId: "p", miniAppId: "real", permissions: [.store], manifestFingerprint: "fp"
            )
            let url = URL(fileURLWithPath: ctx.paths.miniAppGrantsJSON)
            let text = try String(contentsOf: url, encoding: .utf8)
            let injected = text.replacingOccurrences(
                of: "\"grants\" : [",
                with: """
                "grants" : [
                    {"projectId":"p","miniAppId":"evil","permissions":["prompt"],\
                "decidedAt":"2026-09-04T00:00:00Z"},
                """
            )
            #expect(injected != text)
            try Data(injected.utf8).write(to: url)

            #expect(store.grantedPermissions(projectId: "p", miniAppId: "real") == [.store])
            #expect(store.grantedPermissions(projectId: "p", miniAppId: "evil").isEmpty)
        }
    }

    /// Signing covers the identity fields too — a row copied to another
    /// project's id is not a decision about that project.
    @Test func aGrantCopiedToAnotherProjectIdIsDropped() throws {
        try Self.withTempHome { ctx, _ in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p1", miniAppId: "a", permissions: [.store])
            let url = URL(fileURLWithPath: ctx.paths.miniAppGrantsJSON)
            let text = try String(contentsOf: url, encoding: .utf8)
            try Data(text.replacingOccurrences(of: "\"p1\"", with: "\"p2\"").utf8).write(to: url)
            #expect(store.grantedPermissions(projectId: "p2", miniAppId: "a").isEmpty)
        }
    }

    // MARK: - Grant revocation on removal

    @Test func revokeAllDropsOnlyTheNamedProjectsGrants() throws {
        try Self.withTempHome { ctx, _ in
            let store = MiniAppGrantStore(context: ctx)
            try store.setGrant(projectId: "p1", miniAppId: "a", permissions: [.store])
            try store.setGrant(projectId: "p1", miniAppId: "b", permissions: [.prompt])
            try store.setGrant(projectId: "p2", miniAppId: "a", permissions: [.store])

            #expect(try store.revokeAll(projectId: "p1") == 2)
            #expect(store.hasDecision(projectId: "p1", miniAppId: "a") == false)
            #expect(store.hasDecision(projectId: "p1", miniAppId: "b") == false)
            #expect(store.grantedPermissions(projectId: "p2", miniAppId: "a") == [.store])
        }
    }
}
