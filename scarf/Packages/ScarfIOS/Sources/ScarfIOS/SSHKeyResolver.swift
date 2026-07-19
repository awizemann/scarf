// Gated like `KeychainSSHKeyStore` — the convenience entry point
// constructs the Keychain-backed store, which needs Security.framework.
// The injectable core is protocol-typed and platform-neutral.
#if canImport(Security)

import Foundation
import ScarfCore

/// Resolves which stored SSH key a *runtime* connection should use.
///
/// Onboarding stores one key per server entry (`SSHKeyStore.save(_:for:)`,
/// keyed by the entry's `ServerID`), but the runtime key providers
/// historically fetched via the singleton `load()`, which returns the key
/// of whichever `ServerID` sorts first among ALL Keychain items — items
/// that survive app reinstalls and can arrive via iCloud Keychain sync
/// (issue #52). On any device holding more than one key, every SSH
/// connect could therefore authenticate with a *different entry's*
/// private key: the host rejects the offer and Citadel surfaces
/// `SSHClientError.allAuthenticationOptionsFailed` ("error 4"), while
/// onboarding's Test Connection — which uses the just-generated
/// in-memory bundle — passes (gh#133).
///
/// This resolver maps the connection's `SSHConfig` back to the server
/// entry it was built from and loads THAT entry's key, falling back to
/// the legacy singleton pick only when no entry matches (pre-M9 installs
/// whose one key lives under a migration-minted random id).
public enum SSHKeyResolver {
    /// Production entry point — Keychain + UserDefaults backed.
    public static func key(for config: SSHConfig) async throws -> SSHKeyBundle {
        try await key(
            for: config,
            keyStore: KeychainSSHKeyStore(),
            configStore: UserDefaultsIOSServerConfigStore()
        )
    }

    /// Protocol-typed core, injectable for tests.
    ///
    /// Matching is on `(host, port, user)` — exactly the fields
    /// `IOSServerConfig.toServerContext(id:)` copies into `SSHConfig`.
    /// `remoteHome` is deliberately excluded: a profile switch (#120)
    /// rewrites it on the same server, and the key doesn't change with
    /// the profile. Port and user are normalized the same way the
    /// connect path normalizes them (`nil` → 22 / "root"), so an entry
    /// saved with an explicit `22` still matches a config carrying `nil`.
    static func key(
        for config: SSHConfig,
        keyStore: any SSHKeyStore,
        configStore: any IOSServerConfigStore
    ) async throws -> SSHKeyBundle {
        let entries = (try? await configStore.listAll()) ?? [:]
        let matchingIDs = entries
            .filter { _, entry in
                entry.host == config.host
                    && (entry.port ?? 22) == (config.port ?? 22)
                    && (entry.user ?? "root") == (config.user ?? "root")
            }
            .keys
            .sorted { $0.uuidString < $1.uuidString }
        for id in matchingIDs {
            if let key = try? await keyStore.load(for: id) {
                return key
            }
        }
        // No per-entry key found. Pre-M9 single-server installs keep
        // their one key under a random id minted by the v1→v2 Keychain
        // migration, which only the singleton pick can find — same
        // behavior those installs had before this resolver existed.
        if let legacy = try await keyStore.load() {
            return legacy
        }
        throw SSHKeyStoreError.backendFailure(
            message: "No SSH key stored for \(config.host) — re-run onboarding for this server.",
            osStatus: nil
        )
    }
}

#endif // canImport(Security)
