import Testing
import Foundation
@testable import ScarfCore

/// P8 batch G2. One suite per finding, each written as the ATTACK or the
/// FAILURE it closes rather than as a happy-path round-trip — the point of
/// every one of these fixes is what happens when something is hostile or
/// broken.
@Suite struct ProjectsG2HardeningTests {

    static func withTempHome(_ body: (ServerContext) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-g2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try body(ServerContext.local(home: home))
    }

    // MARK: - SEC-M2: HMAC permissions-field injectivity

    /// THE ATTACK. `query:sessions,store` is ONE permission. Under v1's
    /// comma-join it produced the same payload — and so the same valid tag
    /// — as the two-permission set `{query:sessions, store}`, and the
    /// launcher would then run the app with a `store` grant nobody
    /// approved. Length prefixes make the two payloads different.
    @Test func commaCarryingPermissionCannotCollideWithATwoPermissionSet() throws {
        let single = MiniAppGrant(
            projectId: "p", miniAppId: "a",
            permissions: ["query:sessions,store"],
            decidedAt: "2026-09-04T00:00:00Z", manifestFingerprint: "fp"
        )
        let pair = MiniAppGrant(
            projectId: "p", miniAppId: "a",
            permissions: ["query:sessions", "store"],
            decidedAt: "2026-09-04T00:00:00Z", manifestFingerprint: "fp"
        )
        // The comma-carrying single is refused outright...
        #expect(throws: MiniAppGrantSignerError.uninjectiveComponent("permission")) {
            _ = try MiniAppGrantSigner.canonicalPayload(for: single)
        }
        // ...and the pair still signs, length-prefixed.
        let pairPayload = try MiniAppGrantSigner.canonicalPayload(for: pair)
        #expect(pairPayload.contains("14:query:sessions,5:store"))
        #expect(pairPayload.hasPrefix("v2\u{1F}"))
    }

    /// The separator itself is structure, so no field may carry it —
    /// including the ones the old doc merely ASSERTED could not.
    @Test func separatorInAnyFieldIsRefused() throws {
        for grant in [
            MiniAppGrant(projectId: "p\u{1F}x", miniAppId: "a", permissions: [], decidedAt: "d"),
            MiniAppGrant(projectId: "p", miniAppId: "a\u{1F}x", permissions: [], decidedAt: "d"),
            MiniAppGrant(projectId: "p", miniAppId: "a", permissions: ["\u{1F}"], decidedAt: "d"),
            MiniAppGrant(projectId: "p", miniAppId: "a", permissions: [], decidedAt: "d\u{1F}"),
            MiniAppGrant(
                projectId: "p", miniAppId: "a", permissions: [], decidedAt: "d",
                manifestFingerprint: "f\u{1F}"
            ),
        ] {
            #expect(throws: (any Error).self) {
                _ = try MiniAppGrantSigner.canonicalPayload(for: grant)
            }
        }
    }

    /// A hostile row that somehow carries a signature is inauthentic
    /// without the key even being consulted: we refuse to sign such rows,
    /// so no tag we minted can exist for one.
    @Test func rowWithUninjectiveFieldIsNeverAuthentic() throws {
        let signer = MiniAppGrantSigner(testServiceSuffix: "g2-\(UUID().uuidString)")
        var grant = MiniAppGrant(
            projectId: "p", miniAppId: "a", permissions: ["store"], decidedAt: "d"
        )
        grant.signature = try signer.signedTag(for: grant)
        #expect(signer.isAuthentic(grant))
        var tampered = grant
        tampered.permissions = ["query:x,store"]
        #expect(signer.isAuthentic(tampered) == false)
    }

    /// v1 tags do not verify against the v2 payload — the deliberate,
    /// one-time re-ask the version bump buys.
    @Test func v1TagsAreInvalidUnderV2() throws {
        let suffix = "g2-\(UUID().uuidString)"
        let signer = MiniAppGrantSigner(testServiceSuffix: suffix)
        var grant = MiniAppGrant(
            projectId: "p", miniAppId: "a", permissions: ["store", "events"],
            decidedAt: "2026-09-04T00:00:00Z", manifestFingerprint: "fp"
        )
        // Reconstruct a v1 tag with the same key the signer holds.
        grant.signature = try signer.signedTag(for: grant)
        let v2Payload = try MiniAppGrantSigner.canonicalPayload(for: grant)
        let v1Payload = [
            "v1", grant.projectId, grant.miniAppId,
            grant.permissions.sorted().joined(separator: ","),
            grant.decidedAt, grant.manifestFingerprint ?? "",
        ].joined(separator: "\u{1F}")
        #expect(v1Payload != v2Payload)
    }

    // MARK: - DI-M3: signer unavailable REFUSES, it does not purge

    @Test func signerWithNoKeyRefusesTheWriteAndPreservesEveryRow() throws {
        try Self.withTempHome { ctx in
            let healthy = MiniAppGrantStore(context: ctx)
            try healthy.setGrant(projectId: "p1", miniAppId: "a", permissions: [.store])
            try healthy.setGrant(projectId: "p2", miniAppId: "b", permissions: [.events])
            #expect(healthy.allGrants().count == 2)

            let broken = MiniAppGrantStore(context: ctx, signerKeyUnavailable: true)
            // Reads still default-deny (the safe direction, and a recovery).
            #expect(broken.allGrants().isEmpty)
            // Writes REFUSE rather than publishing that emptiness.
            #expect(throws: MiniAppGrantSignerError.signingKeyUnavailable) {
                try broken.setGrant(projectId: "p3", miniAppId: "c", permissions: [.store])
            }
            #expect(throws: MiniAppGrantSignerError.signingKeyUnavailable) {
                try broken.revoke(projectId: "p1", miniAppId: "a")
            }
            #expect(throws: MiniAppGrantSignerError.signingKeyUnavailable) {
                _ = try broken.revokeAll(projectId: "p1")
            }
            // The file is untouched: a healthy signer still sees both rows.
            #expect(healthy.allGrants().count == 2)
            #expect(healthy.grantedPermissions(projectId: "p1", miniAppId: "a") == [.store])
        }
    }

    // MARK: - SEC-L4: consent-surface charset for `query:<kind>`

    @Test func queryKindsOutsideTheCharsetDemoteToUnknownAndStaySensitive() {
        for hostile in [
            "sessions\nApproved by Scarf",
            "kanban.tasks, and everything else",
            "SESSIONS",
            "\u{202E}sksat.nabnak",
            "",
            String(repeating: "a", count: 65),
        ] {
            let permission = MiniAppPermission(rawValue: "query:\(hostile)")
            #expect(permission.queryKind == nil, "\(hostile) should not parse as a query kind")
            #expect(permission.isSensitive)
        }
        #expect(MiniAppPermission(rawValue: "query:kanban.tasks").queryKind == "kanban.tasks")
        #expect(MiniAppPermission(rawValue: "query:insights.tokens").queryKind == "insights.tokens")
    }

    @Test func unknownPermissionSummaryIsSanitizedForDisplay() {
        let raw = "gimme\u{202E}\u{0007}\n everything"
        let summary = MiniAppPermission(rawValue: raw).summary
        #expect(summary.contains("\n") == false)
        #expect(summary.contains("\u{202E}") == false)
        // The round-trip value is still the original bytes.
        #expect(MiniAppPermission(rawValue: raw).rawValue == raw.trimmingCharacters(
            in: .whitespacesAndNewlines
        ))
    }

    // MARK: - DI-H2 / DI-L3: unknown-key preservation

    @Test func scarfProjectPreservesUnknownTopLevelKeys() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Demo",
          "rootPath": "/tmp/demo",
          "futureBinding": {"bots": ["alpha"]},
          "agentAnnotation": "do not delete me",
          "schemaVersion": 7
        }
        """
        var project = try JSONDecoder().decode(ScarfProject.self, from: Data(json.utf8))
        #expect(project.extra["agentAnnotation"] == .string("do not delete me"))
        #expect(project.extra["futureBinding"] != nil)
        // schemaVersion IS modelled, so it must not land in `extra`.
        #expect(project.extra["schemaVersion"] == nil)
        #expect(project.schemaVersion == 7)

        project.name = "Renamed"
        let round = try JSONDecoder().decode(
            ScarfProject.self, from: try JSONEncoder().encode(project)
        )
        #expect(round.name == "Renamed")
        #expect(round.extra["agentAnnotation"] == .string("do not delete me"))
        #expect(round.extra["futureBinding"] == .object(["bots": .array([.string("alpha")])]))
    }

    /// `extra` is excluded from identity, exactly as `ProjectEntry.uuid`
    /// and `ProjectEntry.extra` are — a key we don't understand appearing
    /// must not disturb selection or set membership.
    @Test func scarfProjectIdentityIgnoresUnknownKeys() {
        let id = UUID()
        let plain = ScarfProject(id: id, name: "A", rootPath: "/p")
        let annotated = ScarfProject(
            id: id, name: "A", rootPath: "/p",
            createdAt: plain.createdAt, updatedAt: plain.updatedAt,
            extra: ["x": .bool(true)]
        )
        #expect(plain == annotated)
        #expect(Set([plain, annotated]).count == 1)
    }

    @Test func sessionProjectMapPreservesUnknownTopLevelKeys() throws {
        let json = """
        {
          "mappings": {"s1": "/tmp/one"},
          "updatedAt": "2026-09-04T00:00:00Z",
          "newerScarfField": [1, 2, 3]
        }
        """
        var map = try JSONDecoder().decode(SessionProjectMap.self, from: Data(json.utf8))
        #expect(map.extra["newerScarfField"] == .array([.int(1), .int(2), .int(3)]))
        map.mappings["s2"] = "/tmp/two"
        let round = try JSONDecoder().decode(
            SessionProjectMap.self, from: try JSONEncoder().encode(map)
        )
        #expect(round.mappings.count == 2)
        #expect(round.extra["newerScarfField"] == .array([.int(1), .int(2), .int(3)]))
        #expect(round.updatedAt == "2026-09-04T00:00:00Z")
    }

    // MARK: - DI-M1 / DI-M2: quarantine parity + `.bak` ordering

    @Test func undecodableProjectRecordIsQuarantinedNotJustBackedUp() throws {
        try Self.withTempHome { ctx in
            QuarantineMemo.shared.reset()
            let root = ctx.paths.home + "/proj"
            let scarfDir = root + "/.scarf"
            try FileManager.default.createDirectory(
                atPath: scarfDir, withIntermediateDirectories: true
            )
            let recordPath = ProjectStore.recordPath(forProjectPath: root)
            let corrupt = Data("{ this is not json at all".utf8)
            try corrupt.write(to: URL(fileURLWithPath: recordPath))

            let store = ProjectStore(context: ctx)
            // Decode failure reads as ABSENT (the record is rebuildable)…
            #expect(store.load(projectPath: root) == nil)
            // …but the bytes are preserved in a quarantine copy.
            let copies = try FileManager.default.contentsOfDirectory(atPath: scarfDir)
                .filter { $0.hasPrefix("project.json.corrupt-") }
            #expect(copies.count == 1)
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: scarfDir + "/" + copies[0])) == corrupt
            )
        }
    }

    /// THE `.bak` ORDERING (DI-M2). A good record, then corruption, then a
    /// save: the `.bak` must still hold the GOOD record, because the
    /// corrupt bytes already live in the `.corrupt-` copy. Overwriting the
    /// `.bak` with them costs the user both copies.
    @Test func quarantineCycleLeavesTheGoodBakIntact() throws {
        try Self.withTempHome { ctx in
            QuarantineMemo.shared.reset()
            let root = ctx.paths.home + "/proj"
            try FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: true
            )
            let store = ProjectStore(context: ctx)
            var project = ScarfProject(name: "Good", rootPath: root)
            try store.save(project)
            project.name = "Good II"
            try store.save(project)   // now project.json.bak holds "Good"

            let recordPath = ProjectStore.recordPath(forProjectPath: root)
            let bakPath = recordPath + ".bak"
            let goodBak = try Data(contentsOf: URL(fileURLWithPath: bakPath))
            #expect(String(data: goodBak, encoding: .utf8)?.contains("\"Good\"") == true)

            // Corruption lands on the live file; the next save rebuilds.
            try Data("<<<not json>>>".utf8).write(to: URL(fileURLWithPath: recordPath))
            var rebuilt = ScarfProject(name: "Rebuilt", rootPath: root)
            rebuilt.updatedAt = Date()
            try store.save(rebuilt)

            #expect(try Data(contentsOf: URL(fileURLWithPath: bakPath)) == goodBak)
            let copies = try FileManager.default.contentsOfDirectory(atPath: root + "/.scarf")
                .filter { $0.hasPrefix("project.json.corrupt-") }
            #expect(copies.count == 1)
            #expect(store.load(projectPath: root)?.name == "Rebuilt")
        }
    }

    /// The same rule inside `GuardedJSONStore` itself, which every other
    /// sidecar goes through.
    @Test func guardedStoreDoesNotOverwriteBakWithQuarantinedBytes() throws {
        try Self.withTempHome { ctx in
            QuarantineMemo.shared.reset()
            let dir = ctx.paths.home + "/scarf"
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
            let path = dir + "/thing.json"
            let transport = ctx.makeTransport()
            let guarded = GuardedJSONStore(transport: transport, label: "thing.json")

            let good = Data(#"{"v":1}"#.utf8)
            try transport.writeFile(path + ".bak", data: good)
            let corrupt = Data("nope".utf8)
            try transport.writeFile(path, data: corrupt)

            let (inspection, value) = guarded.inspectDecoding(
                [String: Int].self, at: path, maxBytes: 1024
            )
            #expect(value == nil)
            guard case .quarantined = inspection.state else {
                Issue.record("expected quarantined, got \(inspection.state)")
                return
            }
            try guarded.write(Data(#"{"v":2}"#.utf8), to: path, after: inspection)
            #expect(try transport.readFile(path + ".bak") == good)
        }
    }

    // MARK: - SEC-L2: private mode follows the ORIGINAL basename

    @Test func backupAndQuarantineCopiesInheritPrivateMode() {
        #expect(TransportPrivateMode.shouldEnforce(for: "/h/.env"))
        #expect(TransportPrivateMode.shouldEnforce(for: "/h/.env.bak"))
        #expect(TransportPrivateMode.shouldEnforce(for: "/h/.env.corrupt-20260904T101112Z"))
        #expect(TransportPrivateMode.shouldEnforce(for: "/h/.env.bak.corrupt-20260904T101112Z"))
        #expect(TransportPrivateMode.shouldEnforce(for: "/h/auth.json.bak"))
        #expect(TransportPrivateMode.shouldEnforce(for: "/h/gh-tokens.json.corrupt-2026Z"))
        // Not a private file to begin with, copy or not.
        #expect(TransportPrivateMode.shouldEnforce(for: "/h/projects.json.bak") == false)
    }

    // MARK: - SEC-L1: `\A…\z`, not `^…$`

    @Test func slashCommandNameWithTrailingNewlineIsRejected() {
        #expect(ProjectSlashCommand.validateName("deploy") == nil)
        #expect(ProjectSlashCommand.validateName("deploy\n") != nil)
        #expect(ProjectSlashCommand.validateName("\ndeploy") != nil)
        #expect(ProjectSlashCommand.validateName("deploy\nrm-rf") != nil)
        #expect(ProjectSlashCommand.validateName("deploy\r\n") != nil)
    }

    // MARK: - SEC-M4: image beacon host gate

    @Test func imageHostConsentIsPerProjectPerHostAndDefaultsDenied() {
        let suite = "com.scarf.tests.imagehost.\(UUID().uuidString)"
        // Records are HMAC-tagged (F1 SEC-M3) with the machine key — route
        // it into a test-only Keychain service so this never touches the
        // user's real one.
        let store = ImageHostConsentStore(
            suiteName: suite, testServiceSuffix: "f1-\(UUID().uuidString)"
        )
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let url = URL(string: "https://beacon.example/p.png?d=leak")!
        #expect(store.isAllowed(url: url, projectId: "/p/one") == false)

        store.allow(url: url, projectId: "/p/one")
        #expect(store.isAllowed(url: url, projectId: "/p/one"))
        // Same host, different PATH — still allowed (the gate is per host).
        #expect(store.isAllowed(
            url: URL(string: "https://BEACON.example./other.png")!, projectId: "/p/one"
        ))
        // Different host — a fresh ask.
        #expect(store.isAllowed(
            url: URL(string: "https://other.example/p.png")!, projectId: "/p/one"
        ) == false)
        // Different project — a fresh ask.
        #expect(store.isAllowed(url: url, projectId: "/p/two") == false)

        store.revoke(host: "beacon.example", projectId: "/p/one")
        #expect(store.isAllowed(url: url, projectId: "/p/one") == false)
    }
}
