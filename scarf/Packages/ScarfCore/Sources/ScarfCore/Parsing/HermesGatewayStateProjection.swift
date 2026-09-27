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
    public static func effectiveRecord(ownData: Data?, rootData: Data?, profile: String?) -> Data? {
        guard let profile, profile != "default",
              let rootData,
              let root = try? JSONSerialization.jsonObject(with: rootData) as? [String: Any],
              servedProfiles(in: root).contains(profile)
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
