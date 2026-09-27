import Foundation

/// Which `gateway_state.json` describes a profile, and what its platforms are.
///
/// A named profile served by the default profile's multiplexer (the normal
/// v0.21.x topology) writes NO runtime record of its own. Its platform states
/// live in the ROOT home's `gateway_state.json`, under `<profile>:<platform>`
/// keys (`gateway/run_adapters.py:1182` @ v2026.9.24), and the root record
/// lists the profile in `served_profiles` (`gateway/status.py:1098` @
/// v2026.9.24, present since v2026.6.19). Hermes reads it back the same way:
/// `multiplexer_liveness_for_profile` returns the root record and
/// `profile_platforms_from_multiplexer` re-keys the prefixed entries to bare
/// platform names, adding the default listener's `api_server` / `webhook`
/// mirrors (`gateway/status.py:1259-1331` @ v2026.9.24).
///
/// This is schema detection, not a version gate (charter C1): a host whose
/// root record has no `served_profiles` naming the profile — every host below
/// v2026.6.19, and any profile that runs its own gateway — keeps reading the
/// profile's own file exactly as before.
public enum HermesGatewayStateProjection {

    /// `SHARED_LISTENER_MIRROR_PLATFORMS` (`gateway/config.py:290` @ v2026.9.24).
    static let mirrorPlatforms = ["api_server", "webhook"]
    /// States a default-listener entry must be in to be mirrored
    /// (`shared_listener_mirror_platforms`, `gateway/status.py:1308`).
    static let liveMirrorStates: Set<String> = ["connected", "connecting", "retrying"]

    /// The profiles a root record says it serves (`served_profiles`).
    public static func servedProfiles(in root: [String: Any]) -> [String] {
        (root["served_profiles"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// Whether the root multiplexer serves `profile`: the record's
    /// `served_profiles` when it has the key, else `configDerived()`.
    ///
    /// Hermes does the same (`multiplexer_liveness_for_profile`,
    /// `gateway/status.py:1283-1287` → `named_profile_served_by_running_multiplexer`,
    /// `hermes_cli/gateway.py:3672-3687` @ v2026.9.24): only a record WITHOUT
    /// the key falls through to config. An empty list is an authoritative
    /// "serves nobody else". The multiplexer writes the key once its
    /// secondary profiles are up (`gateway/run_adapters.py:940-950`), so a
    /// record without it is one written just before that, or by an older
    /// writer. `configDerived` is evaluated only in that case — it costs a
    /// config read and a process probe.
    public static func serves(
        profile: String, root: [String: Any], configDerived: () -> Bool
    ) -> Bool {
        guard profile != "default" else { return false }
        if root["served_profiles"] is [Any] { return servedProfiles(in: root).contains(profile) }
        return configDerived()
    }

    /// Hermes' config-derived answer for a root record with no
    /// `served_profiles`: the DEFAULT profile's `config.yaml` explicitly opts
    /// in to multiplexing (`explicit_multiplex_flag`,
    /// `hermes_cli/gateway_multiplex_mode.py:53-76` @ v2026.9.24) and the
    /// default profile's gateway is alive. An unset key never counts ("the
    /// gateway settled it at boot; a CLI process must not guess it on").
    ///
    /// `false` below ``HermesCapabilities/hasMultiplexByDefault`` (v0.21.4,
    /// where `explicit_multiplex_flag` landed), so an older host reads exactly
    /// as before. v0.21.2 and v0.21.3 had an earlier config fallback of their
    /// own (a truthy flag, the env override, the allowlist, the root
    /// `gateway.pid`); those hosts knowingly keep the old "not served" answer
    /// rather than a second approximation. `GATEWAY_MULTIPLEX_PROFILES` in
    /// the asking process's environment also counts for Hermes; Scarf can't
    /// see the gateway's environment and doesn't model it.
    ///
    /// Both inputs are closures and are evaluated in order, only as far as
    /// needed: an older host reads no config and runs no probe.
    public static func configDerivedServes(
        capabilities: HermesCapabilities,
        rootConfigYAML: () -> String?,
        rootGatewayIsLive: () -> Bool
    ) -> Bool {
        guard capabilities.hasMultiplexByDefault,
              let yaml = rootConfigYAML(),
              explicitMultiplexFlag(configYAML: yaml) == true
        else { return false }
        return rootGatewayIsLive()
    }

    /// `explicit_multiplex_flag` over one config file: `nil` when neither
    /// `multiplex_profiles` nor `gateway.multiplex_profiles` carries a value
    /// (top-level wins when not null); an explicit boolish false is `false`;
    /// any other value is `true` — Hermes' `_bool_token` falls back to True
    /// for an unrecognised string, and `bool(value)` for any other type.
    static func explicitMultiplexFlag(configYAML: String) -> Bool? {
        let routes = ProfileRoutesYAML.parse(configYAML)
        guard routes.multiplexIsSet else { return nil }
        return !routes.multiplexIsExplicitFalse
    }

    /// The `platforms` map a served `profile` gets from the root record —
    /// `profile_platforms_from_multiplexer`. Its own `<profile>:` entries win
    /// over a mirrored default listener entry of the same name.
    public static func platforms(forServedProfile profile: String, in root: [String: Any]) -> [String: Any] {
        guard let plats = root["platforms"] as? [String: Any] else { return [:] }
        var result: [String: Any] = [:]
        if profile != "default" {
            for name in mirrorPlatforms {
                guard var entry = plats[name] as? [String: Any],
                      let state = entry["state"] as? String,
                      liveMirrorStates.contains(state) else { continue }
                entry.removeValue(forKey: "listener_base")
                entry["mirrored_from"] = "default"
                result[name] = entry
            }
        }
        let prefix = profile + ":"
        for (key, value) in plats where key.hasPrefix(prefix) {
            guard let entry = value as? [String: Any] else { continue }
            result[String(key.dropFirst(prefix.count))] = entry
        }
        return result
    }

    /// The runtime record that describes `profile`, as JSON data.
    ///
    /// - `profile` nil (the default/root home): `ownData` unchanged.
    /// - The root record serves `profile`: the root record with its
    ///   `platforms` replaced by the profile's projection — unless the
    ///   profile's own file is at least as recent, which means the profile has
    ///   since started a gateway of its own and the root's roster is stale.
    /// - Otherwise: `ownData` unchanged.
    ///
    /// `configDerived` is ``serves(profile:root:configDerived:)``'s fallback
    /// for a root record with no `served_profiles` key.
    public static func effectiveRecord(
        ownData: Data?, rootData: Data?, profile: String?,
        configDerived: () -> Bool = { false }
    ) -> Data? {
        guard let profile, profile != "default",
              let rootData,
              let root = try? JSONSerialization.jsonObject(with: rootData) as? [String: Any],
              serves(profile: profile, root: root, configDerived: configDerived)
        else { return ownData }
        if let ownData,
           let own = try? JSONSerialization.jsonObject(with: ownData) as? [String: Any],
           let ownUpdated = own["updated_at"] as? String,
           ownUpdated >= (root["updated_at"] as? String ?? "") {
            return ownData
        }
        var projected = root
        projected["platforms"] = platforms(forServedProfile: profile, in: root)
        return (try? JSONSerialization.data(withJSONObject: projected)) ?? ownData
    }
}
