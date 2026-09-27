import Foundation

/// How Hermes reads `auth.json` under a named profile, mirrored for Scarf's
/// read-only views of it (Credential Pools, Nous sign-in state, the Nous
/// model catalog's bearer token).
///
/// A named profile's home is `<root>/profiles/<name>`, and its own
/// `auth.json` is not the whole story. Hermes falls back to the ROOT
/// `<root>/auth.json`, per provider, when the profile has nothing for it
/// (S06-F3):
/// - `credential_pool.<provider>`: the root entries are used when the
///   profile has zero entries for that provider ("profile wins when it has
///   ANY entries") — `read_credential_pool`, `hermes_cli/auth.py:870-893`
///   @ v2026.9.24. Landed in hermes-agent 33bf5f6292, first released at
///   v2026.5.7 (0.13.0).
/// - `providers.<provider>` (OAuth state such as Nous): the root state is
///   used when the profile has none — `_load_provider_state`,
///   `auth.py:755-766` @ v2026.9.24. At v2026.5.16 (0.14.0) that function
///   still read the profile only; the fallback is present at v2026.5.28
///   (0.15.0).
///
/// Without this, a user who signed in on the default profile and switched
/// Scarf to another profile saw empty pools and "Sign in to Nous Portal",
/// while chats in that profile ran on the root credentials.
///
/// `active_provider` is NOT merged: Hermes reads it from the profile's own
/// file (`get_active_provider`, `auth.py:1070-1072`).
public enum HermesAuthFallback {

    /// The root `auth.json` Hermes falls back to for `home`, or `nil` when
    /// there is none to consult: `home` is not a named-profile home, or the
    /// host predates both fallbacks. Unknown version (`.empty`) → `nil`, so
    /// an undetected host reads exactly the file it read before.
    public static func rootAuthJSONPath(
        forHome home: String,
        capabilities: HermesCapabilities
    ) -> String? {
        guard capabilities.hasProfileAuthPoolFallback,
              HermesProfileScope.isProfileHome(home)
        else { return nil }
        return HermesProfileScope.rootHome(forHome: home) + "/auth.json"
    }

    /// The result of layering the root file under the profile's.
    public struct Merged: Sendable, Equatable {
        /// The merged `auth.json` as JSON bytes, or `nil` when neither file
        /// parsed as a JSON object (callers treat that as "no auth.json").
        public let data: Data?
        /// Providers whose `credential_pool` entries came from the root file.
        public let inheritedPools: Set<String>
        /// Providers whose `providers.<name>` state came from the root file.
        public let inheritedProviders: Set<String>
    }

    /// Merge `root` under `profile` following Hermes's per-provider rules.
    ///
    /// - A pool provider is taken from the root only when the profile has no
    ///   non-empty list for it AND the root has a non-empty list.
    /// - A `providers.<name>` entry is taken from the root only when the
    ///   profile has no dict for it, and only when `includeProviderState`
    ///   (the host is at the 0.15.0 floor for that half).
    ///
    /// With no root data (or none that parses) this returns the profile
    /// bytes unchanged and empty inherited sets.
    public static func merge(
        profile: Data?,
        root: Data?,
        includeProviderState: Bool
    ) -> Merged {
        let profileObject = profile.flatMap(jsonObject)
        guard let rootObject = root.flatMap(jsonObject) else {
            return Merged(data: profile, inheritedPools: [], inheritedProviders: [])
        }
        var merged = profileObject ?? [:]
        var inheritedPools: Set<String> = []
        var inheritedProviders: Set<String> = []

        var pool = merged["credential_pool"] as? [String: Any] ?? [:]
        for (provider, entries) in rootObject["credential_pool"] as? [String: Any] ?? [:] {
            guard let rootList = entries as? [Any], !rootList.isEmpty else { continue }
            if let existing = pool[provider] as? [Any], !existing.isEmpty { continue }
            pool[provider] = rootList
            inheritedPools.insert(provider)
        }
        if !inheritedPools.isEmpty { merged["credential_pool"] = pool }

        if includeProviderState {
            var providers = merged["providers"] as? [String: Any] ?? [:]
            for (provider, state) in rootObject["providers"] as? [String: Any] ?? [:] {
                guard let rootState = state as? [String: Any] else { continue }
                if providers[provider] is [String: Any] { continue }
                providers[provider] = rootState
                inheritedProviders.insert(provider)
            }
            if !inheritedProviders.isEmpty { merged["providers"] = providers }
        }

        guard !inheritedPools.isEmpty || !inheritedProviders.isEmpty else {
            return Merged(data: profile, inheritedPools: [], inheritedProviders: [])
        }
        let data = try? JSONSerialization.data(withJSONObject: merged)
        return Merged(data: data, inheritedPools: inheritedPools, inheritedProviders: inheritedProviders)
    }

    /// Read the profile's `auth.json` and, where Hermes would, the root one,
    /// and merge them. Blocking file I/O through `transport` — call off the
    /// main actor (charter C10).
    public static func load(
        authJSONPath: String,
        home: String,
        capabilities: HermesCapabilities,
        transport: any ServerTransport
    ) -> Merged {
        let profile = try? transport.readFile(authJSONPath)
        guard let rootPath = rootAuthJSONPath(forHome: home, capabilities: capabilities),
              rootPath != authJSONPath,
              let root = try? transport.readFile(rootPath)
        else {
            return Merged(data: profile, inheritedPools: [], inheritedProviders: [])
        }
        return merge(
            profile: profile,
            root: root,
            includeProviderState: capabilities.hasProfileAuthProviderStateFallback
        )
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
