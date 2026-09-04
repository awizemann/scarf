import Foundation
import Testing
@testable import ScarfCore

/// F1 — the re-audit fix batch. Each test names the attack or the waste it
/// closes, because the shapes here are all ones that LOOKED closed after
/// the previous round.
@Suite struct ProjectsF1HardeningTests {

    // MARK: - SEC-H1: the containment anchor is not movable

    private static func tempProject() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-f1-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(
            atPath: root + "/.scarf/miniapps", withIntermediateDirectories: true
        )
        return root
    }

    /// THE ATTACK. Every previous check — lexical containment, `O_NOFOLLOW`,
    /// the `F_GETPATH` re-check on the open descriptor — asked "is the file
    /// inside the base?" and re-derived the base each time. The base is
    /// `<root>/.scarf/miniapps/<id>`, which the agent can write, so it can
    /// replace THAT with a symlink to somewhere else: containment then
    /// relocates wholesale and every check agrees the secret is contained.
    /// The fd was never the weak part; the thing it was compared against
    /// was.
    @Test func symlinkedMiniAppBaseIsRefusedAtMount() throws {
        let root = try Self.tempProject()
        let secrets = root + "/elsewhere"
        try FileManager.default.createDirectory(atPath: secrets, withIntermediateDirectories: true)
        try Data("token".utf8).write(to: URL(fileURLWithPath: secrets + "/auth.json"))

        // The mini-app's own directory IS the link.
        let base = root + "/.scarf/miniapps/evil"
        try FileManager.default.createSymbolicLink(
            atPath: base, withDestinationPath: secrets
        )

        // Anchoring refuses, and says the base is not where it claims.
        let anchored = MiniAppAssetResolver.anchor(baseDirectory: base)
        guard case .failure(let refusal) = anchored else {
            Issue.record("a symlinked mini-app base was accepted as an anchor")
            return
        }
        if case .relocatedBase = refusal {} else {
            Issue.record("expected .relocatedBase, got \(refusal)")
        }

        // …and every read through it refuses, rather than serving the file
        // that is genuinely sitting inside the relocated directory.
        #expect(MiniAppAssetResolver.readContainedFile(
            requestPath: "auth.json", baseDirectory: base, maxBytes: 4096
        ) == .failure(.notContained))
        #expect(MiniAppAssetResolver.containedFilePath(
            requestPath: "auth.json", baseDirectory: base
        ) == nil)
    }

    /// A symlinked INTERMEDIATE component is the same attack one level up
    /// — `.scarf/miniapps` swapped rather than the id directory.
    @Test func symlinkedIntermediateComponentIsRefused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-f1-\(UUID().uuidString)", isDirectory: true).path
        let elsewhere = root + "/elsewhere/evil"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root + "/.scarf", withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: URL(fileURLWithPath: elsewhere + "/index.html"))
        try FileManager.default.createSymbolicLink(
            atPath: root + "/.scarf/miniapps", withDestinationPath: root + "/elsewhere"
        )
        let base = root + "/.scarf/miniapps/evil"
        if case .success = MiniAppAssetResolver.anchor(baseDirectory: base) {
            Issue.record("a symlinked intermediate component was accepted")
        }
    }

    /// The honest case must keep working, including under macOS's own
    /// `/tmp` → `/private/tmp` prefix link — both sides resolve it.
    @Test func honestMiniAppBaseStillAnchorsAndServes() throws {
        let root = try Self.tempProject()
        let base = root + "/.scarf/miniapps/good"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: URL(fileURLWithPath: base + "/index.html"))

        guard case .success(let anchor) = MiniAppAssetResolver.anchor(baseDirectory: base) else {
            Issue.record("an honest mini-app base was refused")
            return
        }
        let read = MiniAppAssetResolver.readContainedFile(
            requestPath: "/index.html", anchor: anchor, maxBytes: 4096
        )
        #expect((try? read.get())?.data == Data("<html></html>".utf8))
    }

    /// The anchor also re-runs the root policy: a row rewritten to the home
    /// directory yields a base that is perfectly contained and completely
    /// meaningless.
    @Test func inadmissibleProjectRootCannotAnchor() {
        let home = NSHomeDirectory()
        let refusal = MiniAppAssetResolver.anchor(
            baseDirectory: home + "/.scarf/miniapps/x"
        )
        if case .failure(let reason) = refusal {
            if case .inadmissibleRoot = reason {} else {
                Issue.record("expected .inadmissibleRoot, got \(reason)")
            }
        } else {
            Issue.record("a mini-app base under the home directory anchored")
        }
    }

    /// A remote base has no local answer to give, and answering anyway
    /// would describe a different machine's filesystem.
    @Test func remoteBaseRefusesToAnchor() {
        let ctx = ServerContext(
            id: UUID(), displayName: "box", kind: .ssh(SSHConfig(host: "a.example", user: "u"))
        )
        if case .failure(.notLocal) = MiniAppAssetResolver.anchor(
            baseDirectory: "/srv/p/.scarf/miniapps/x", context: ctx
        ) {} else {
            Issue.record("a remote mini-app base anchored locally")
        }
    }

    // MARK: - SEC-M3: a consent record the asker can write is not consent

    @Test func poisonedImageConsentRecordIsIgnored() {
        let suite = "com.scarf.tests.f1.imagehost.\(UUID().uuidString)"
        let store = ImageHostConsentStore(
            suiteName: suite, testServiceSuffix: "f1-\(UUID().uuidString)"
        )
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let url = URL(string: "https://beacon.example/p.png?d=leak")!
        // THE ATTACK: `defaults write <bundle> …allowedHosts.<path> -array
        // beacon.example`. UserDefaults is "the app's own container", which
        // is not the same as out of the agent's reach — it has a terminal.
        UserDefaults(suiteName: suite)?.set(
            ["beacon.example"], forKey: "com.scarf.imageWidget.allowedHosts./p/one"
        )
        #expect(store.isAllowed(url: url, projectId: "/p/one") == false)

        // A forged record in the RIGHT SHAPE (host + a made-up tag) is no
        // better off — the tag is the thing, and only Scarf can mint it.
        UserDefaults(suiteName: suite)?.set(
            ["beacon.example\u{1F}Zm9yZ2Vk"], forKey: "com.scarf.imageWidget.allowedHosts./p/one"
        )
        #expect(store.isAllowed(url: url, projectId: "/p/one") == false)

        // The real thing still works, and a legitimate write drops the
        // poisoned neighbours rather than carrying them forward.
        UserDefaults(suiteName: suite)?.set(
            ["beacon.example\u{1F}Zm9yZ2Vk", "evil.example"],
            forKey: "com.scarf.imageWidget.allowedHosts./p/one"
        )
        store.allow(url: URL(string: "https://good.example/x.png")!, projectId: "/p/one")
        #expect(store.allowedHosts(projectId: "/p/one") == ["good.example"])
        #expect(store.isAllowed(url: url, projectId: "/p/one") == false)
    }

    /// A tag is bound to its project: lifting one project's record into
    /// another's key doesn't carry the consent with it.
    @Test func consentTagDoesNotTransferBetweenProjects() {
        let suite = "com.scarf.tests.f1.imagehost.\(UUID().uuidString)"
        let store = ImageHostConsentStore(
            suiteName: suite, testServiceSuffix: "f1-\(UUID().uuidString)"
        )
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let url = URL(string: "https://beacon.example/p.png")!
        store.allow(url: url, projectId: "/p/one")
        let record = UserDefaults(suiteName: suite)?
            .stringArray(forKey: "com.scarf.imageWidget.allowedHosts./p/one") ?? []
        #expect(record.count == 1)
        UserDefaults(suiteName: suite)?.set(
            record, forKey: "com.scarf.imageWidget.allowedHosts./p/two"
        )
        #expect(store.isAllowed(url: url, projectId: "/p/one"))
        #expect(store.isAllowed(url: url, projectId: "/p/two") == false)
    }

    // MARK: - SEC-L6: nil and "" are different decisions

    /// A grant with NO fingerprint (pre-fingerprint, "re-ask") and one made
    /// about the empty-string fingerprint shared a payload, so either row's
    /// tag verified the other.
    @Test func absentFingerprintDoesNotSharePayloadWithEmptyOne() throws {
        let absent = MiniAppGrant(
            projectId: "p", miniAppId: "a", permissions: ["store"],
            decidedAt: "d", manifestFingerprint: nil
        )
        let empty = MiniAppGrant(
            projectId: "p", miniAppId: "a", permissions: ["store"],
            decidedAt: "d", manifestFingerprint: ""
        )
        #expect(
            try MiniAppGrantSigner.canonicalPayload(for: absent)
                != MiniAppGrantSigner.canonicalPayload(for: empty)
        )

        let signer = MiniAppGrantSigner(testServiceSuffix: "f1-\(UUID().uuidString)")
        var signed = absent
        signed.signature = try signer.signedTag(for: signed)
        var swapped = empty
        swapped.signature = signed.signature
        #expect(signer.isAuthentic(signed))
        #expect(signer.isAuthentic(swapped) == false)
    }

    // MARK: - SEC-M2: the legacy FNV window closes on READ

    /// The window used to close only when a user re-saved the field in the
    /// Configuration sheet — i.e. never, for a secret that works. Reading
    /// it is the event that actually happens: mint the SHA-256-bound item,
    /// repoint `config.json`, delete the legacy item.
    @Test func legacyRefIsReMintedOnReadAndTheLegacyItemIsGone() throws {
        let projectPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-f1-cfg-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(
            atPath: projectPath + "/.scarf", withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: projectPath) }
        let configPath = projectPath + "/.scarf/config.json"

        let suffix = "f1-\(UUID().uuidString)"
        let keychain = ProjectConfigKeychain(testServiceSuffix: suffix)
        // A legacy item, exactly as one minted before the SHA-256 binding:
        // `<fieldKey>:<8-hex FNV of the path>`.
        let legacy = TemplateKeychainRef(
            service: "com.scarf.template.acme-widget",
            account: "apiKey:" + TemplateKeychainRef.legacyShortHash(of: projectPath)
        )
        #expect(LegacyKeychainRefMigrator.isLegacy(legacy))
        #expect(legacy.belongs(toProjectPath: projectPath))
        try keychain.set(ref: legacy, secret: Data("s3cret".utf8))
        defer { try? keychain.delete(ref: legacy) }

        try Data("""
        {"schemaVersion":2,"templateId":"acme/widget","values":{"apiKey":"\(legacy.uri)",\
        "other":"kept"},"hand-written":"survives","updatedAt":"x"}
        """.utf8).write(to: URL(fileURLWithPath: configPath))

        let migrator = LegacyKeychainRefMigrator(transport: LocalTransport(), keychain: keychain)
        let fresh = try #require(migrator.migrate(
            ref: legacy, secret: Data("s3cret".utf8),
            projectPath: projectPath, configPath: configPath
        ))
        defer { try? keychain.delete(ref: fresh) }

        // The new item is the SHA-256 form, holds the same secret, and
        // still belongs to this project.
        #expect(fresh.projectPathHash?.count == TemplateKeychainRef.bindingHashLength)
        #expect(try keychain.get(ref: fresh) == Data("s3cret".utf8))
        #expect(fresh.belongs(toProjectPath: projectPath))
        // The legacy item is GONE — which is the point: nothing is left for
        // a chosen-preimage collision to reach.
        #expect(try keychain.get(ref: legacy) == nil)

        // config.json points at the new ref, and everything else survived
        // the guarded rewrite.
        let rewritten = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: configPath))
        )
        guard case .object(let root) = rewritten,
              case .object(let values)? = root["values"] else {
            Issue.record("config.json did not survive as an object"); return
        }
        #expect(values["apiKey"] == .string(fresh.uri))
        #expect(values["other"] == .string("kept"))
        #expect(root["hand-written"] == .string("survives"))
    }

    /// A modern ref is not touched, and a migration that can't repoint the
    /// config must NOT delete the legacy item — the secret would be gone
    /// for a migration nobody asked for.
    @Test func migrationIsANoOpForModernRefsAndKeepsTheLegacyItemOnFailure() throws {
        let suffix = "f1-\(UUID().uuidString)"
        let keychain = ProjectConfigKeychain(testServiceSuffix: suffix)
        let migrator = LegacyKeychainRefMigrator(transport: LocalTransport(), keychain: keychain)

        let modern = TemplateKeychainRef.make(
            templateSlug: "acme-widget", fieldKey: "apiKey", projectPath: "/p/one"
        )
        #expect(migrator.migrate(
            ref: modern, secret: Data("x".utf8),
            projectPath: "/p/one", configPath: "/nonexistent/.scarf/config.json"
        ) == nil)

        // Legacy ref, but the config names it nowhere (here: no config at
        // all) — the repoint fails, so nothing is deleted.
        let legacy = TemplateKeychainRef(
            service: "com.scarf.template.acme-widget",
            account: "apiKey:" + TemplateKeychainRef.legacyShortHash(of: "/p/one")
        )
        try keychain.set(ref: legacy, secret: Data("keepme".utf8))
        defer { try? keychain.delete(ref: legacy) }
        #expect(migrator.migrate(
            ref: legacy, secret: Data("keepme".utf8),
            projectPath: "/p/one", configPath: "/nonexistent/.scarf/config.json"
        ) == nil)
        #expect(try keychain.get(ref: legacy) == Data("keepme".utf8))
        try? keychain.delete(ref: TemplateKeychainRef.make(
            templateSlug: "acme-widget", fieldKey: "apiKey", projectPath: "/p/one"
        ))
    }

    // MARK: - Detached payload domain separation

    /// A tag minted for an image-host record must never verify as a grant
    /// tag, whatever the two payloads happen to spell.
    @Test func detachedTagsAreDomainSeparatedFromGrantTags() throws {
        let signer = MiniAppGrantSigner(testServiceSuffix: "f1-\(UUID().uuidString)")
        let grant = MiniAppGrant(
            projectId: "p", miniAppId: "a", permissions: ["store"], decidedAt: "d"
        )
        let grantPayload = try MiniAppGrantSigner.canonicalPayload(for: grant)
        let grantTag = try signer.signedTag(for: grant)
        #expect(signer.isValidTag(grantTag, forPayload: grantPayload) == false)
        let detached = signer.tag(forPayload: grantPayload)
        #expect(detached != grantTag)
    }
}
