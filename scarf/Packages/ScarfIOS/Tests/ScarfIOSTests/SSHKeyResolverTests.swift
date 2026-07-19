#if canImport(Security)

import Testing
import Foundation
import ScarfCore
@testable import ScarfIOS

/// Coverage for the gh#133 fix: runtime SSH connections must use the key
/// stored for THE server entry they belong to, not whichever key sorts
/// first in the Keychain. Uses ScarfCore's in-memory stores — the
/// resolver's core is protocol-typed precisely for this.
@Suite struct SSHKeyResolverTests {

    private func bundle(_ tag: String) -> SSHKeyBundle {
        SSHKeyBundle(
            privateKeyPEM: "PEM-\(tag)",
            publicKeyOpenSSH: "ssh-ed25519 AAAA\(tag) scarf-test",
            comment: tag,
            createdAt: "2026-07-18T00:00:00Z"
        )
    }

    /// Deterministic ServerIDs so we control lexicographic order:
    /// `lowID` sorts before `highID`.
    private let lowID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let highID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!

    @Test func resolvesTheMatchingEntrysKey_notTheFirstSortedKey() async throws {
        let keys = InMemorySSHKeyStore()
        let configs = InMemoryIOSServerConfigStore()

        // A stale entry whose id sorts FIRST — the singleton load()
        // would always return this one's key (the gh#133 failure).
        try await configs.save(
            IOSServerConfig(host: "old.example", user: "alan", displayName: "Old"),
            id: lowID
        )
        try await keys.save(bundle("stale"), for: lowID)

        // The entry the user is actually connecting to.
        try await configs.save(
            IOSServerConfig(host: "100.68.160.25", user: "alan", displayName: "Mini"),
            id: highID
        )
        try await keys.save(bundle("current"), for: highID)

        let resolved = try await SSHKeyResolver.key(
            for: SSHConfig(host: "100.68.160.25", user: "alan"),
            keyStore: keys,
            configStore: configs
        )
        #expect(resolved.comment == "current")
    }

    @Test func normalizesDefaultPortAndUser() async throws {
        let keys = InMemorySSHKeyStore()
        let configs = InMemoryIOSServerConfigStore()

        // Entry saved with explicit defaults; config carries nils.
        try await configs.save(
            IOSServerConfig(host: "mini.local", user: "root", port: 22, displayName: "Mini"),
            id: highID
        )
        try await keys.save(bundle("mini"), for: highID)

        let resolved = try await SSHKeyResolver.key(
            for: SSHConfig(host: "mini.local"),
            keyStore: keys,
            configStore: configs
        )
        #expect(resolved.comment == "mini")
    }

    @Test func remoteHomeDifferenceStillMatches() async throws {
        // A #120 profile switch rewrites SSHConfig.remoteHome on the
        // same server — the key must not change with the profile.
        let keys = InMemorySSHKeyStore()
        let configs = InMemoryIOSServerConfigStore()
        try await configs.save(
            IOSServerConfig(host: "mini.local", user: "alan", displayName: "Mini"),
            id: highID
        )
        try await keys.save(bundle("mini"), for: highID)

        let resolved = try await SSHKeyResolver.key(
            for: SSHConfig(host: "mini.local", user: "alan", remoteHome: "~/.hermes/profiles/work"),
            keyStore: keys,
            configStore: configs
        )
        #expect(resolved.comment == "mini")
    }

    @Test func fallsBackToSingletonWhenNoEntryMatches() async throws {
        // Pre-M9 shape: a key exists under a migration-minted random id
        // with NO matching config entry. The resolver must keep those
        // installs working via the legacy first-sorted pick.
        let keys = InMemorySSHKeyStore()
        let configs = InMemoryIOSServerConfigStore()
        try await keys.save(bundle("legacy"), for: lowID)

        let resolved = try await SSHKeyResolver.key(
            for: SSHConfig(host: "mini.local", user: "alan"),
            keyStore: keys,
            configStore: configs
        )
        #expect(resolved.comment == "legacy")
    }

    @Test func fallsBackWhenMatchingEntryHasNoStoredKey() async throws {
        let keys = InMemorySSHKeyStore()
        let configs = InMemoryIOSServerConfigStore()
        try await configs.save(
            IOSServerConfig(host: "mini.local", user: "alan", displayName: "Mini"),
            id: highID
        )
        // Key for the matching entry is missing; only a foreign key exists.
        try await keys.save(bundle("other"), for: lowID)

        let resolved = try await SSHKeyResolver.key(
            for: SSHConfig(host: "mini.local", user: "alan"),
            keyStore: keys,
            configStore: configs
        )
        #expect(resolved.comment == "other")
    }

    @Test func throwsWhenNothingIsStored() async throws {
        let keys = InMemorySSHKeyStore()
        let configs = InMemoryIOSServerConfigStore()
        await #expect(throws: SSHKeyStoreError.self) {
            _ = try await SSHKeyResolver.key(
                for: SSHConfig(host: "mini.local"),
                keyStore: keys,
                configStore: configs
            )
        }
    }
}

#endif // canImport(Security)
