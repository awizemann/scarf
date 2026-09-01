import Foundation

/// Reads the `bot_peers:` registry out of a raw `config.yaml`.
///
/// Shape written by `hermes peer add` (`_save_peers` → PyYAML dump):
///
/// ```yaml
/// bot_peers:
///   spark:
///     url: http://spark.lan:8377
///     note: homelab box
///   cloud:
///     url: https://hermes.example.com
/// ```
///
/// `note` is optional (omitted entirely when `--note` wasn't given).
/// Hand-written flow style (`spark: {url: ..., note: ...}`) is picked up
/// too, since `HermesYAML` records both block and flow maps under the
/// same `maps` path.
///
/// **No key is ever read.** The peer's `API_SERVER_KEY` lives in
/// `~/.hermes/.env`, not here, and Scarf does not go looking for it.
public enum HermesBotPeersYAML {
    static let sectionKey = "bot_peers"

    /// Parse the registry, sorted by name (matching `peer list`'s
    /// `sorted(peers)` ordering so Scarf's list and the CLI's agree).
    ///
    /// Entries without a usable `url` are dropped: `_resolve_peer_target`
    /// refuses them too ("No peer named …"), so showing one would offer
    /// actions that can only fail.
    public static func parse(yaml: String) -> [HermesBotPeer] {
        let parsed = HermesYAML.parseNestedYAML(yaml)
        let prefix = sectionKey + "."
        var peers: [HermesBotPeer] = []

        for (path, entry) in parsed.maps {
            guard path.hasPrefix(prefix) else { continue }
            let name = String(path.dropFirst(prefix.count))
            // Peer names can't contain dots (`_PEER_NAME_RE`), so a
            // remaining dot means this is a deeper path, not a peer.
            guard !name.isEmpty, !name.contains(".") else { continue }

            let url = (entry["url"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { continue }
            let note = (entry["note"] ?? "").trimmingCharacters(in: .whitespaces)
            peers.append(HermesBotPeer(name: name, url: url, note: note))
        }

        return peers.sorted { $0.name < $1.name }
    }
}
