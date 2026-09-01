import Foundation

/// One entry of the `bot_peers:` map in `config.yaml` — another Hermes
/// gateway this machine can message bot-to-bot (`hermes peer`, v0.21+).
///
/// **Deliberately keyless.** Hermes stores a peer's `API_SERVER_KEY` in
/// `~/.hermes/.env` as `HERMES_PEER_<NAME>_KEY` (or a profile-scoped
/// secret store), *not* in `config.yaml`. Scarf models only what
/// `config.yaml` holds, so a peer's credential can never reach a Scarf
/// view, log line or crash report by accident. The env-var *name* is
/// derivable (`keyEnvName`) and is safe to show; the value is not read.
public struct HermesBotPeer: Identifiable, Sendable, Equatable, Hashable {
    /// Registry key — a lowercase slug (`^[a-z0-9][a-z0-9_-]{0,63}$` per
    /// `hermes_cli/subcommands/peer.py::_PEER_NAME_RE`).
    public let name: String
    /// Gateway base URL (`http(s)://host:port`), stored without a
    /// trailing slash by `peer add`.
    public let url: String
    /// Optional human description. Empty when the key is absent.
    public let note: String

    public var id: String { name }

    public init(name: String, url: String, note: String = "") {
        self.name = name
        self.url = url
        self.note = note
    }

    /// The `.env` variable Hermes looks the peer's key up under. Port of
    /// `_peer_key_env`: uppercase, `-` → `_`. Shown as guidance ("set
    /// this in ~/.hermes/.env"), never resolved to a value.
    public var keyEnvName: String {
        "HERMES_PEER_\(name.uppercased().replacingOccurrences(of: "-", with: "_"))_KEY"
    }
}
