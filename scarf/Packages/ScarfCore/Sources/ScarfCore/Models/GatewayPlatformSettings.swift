import Foundation

/// Per-platform Messaging Gateway settings introduced in Hermes v0.13.
/// Bundles the allowlist (the platform-appropriate flavor of
/// `allowed_channels` / `allowed_chats` / `allowed_rooms`) and the
/// `gateway_restart_notification` toggle.
///
/// **Stale-doc fix (v0.20.4 audit, Tier 3 #4): keys live TOP-LEVEL, not
/// under `gateway.platforms.<platform>.*`.** Source-verified (v0.16+) as
/// `<platform>.<key>` — e.g. `discord.allowed_channels`,
/// `slack.allowed_channels`, `telegram.allowed_chats`. The doc comments
/// below previously claimed the `gateway.platforms.<platform>.*` path;
/// that block is a dead/legacy shape Hermes never reads from. See the
/// actual parsing logic in `HermesConfig+YAML.swift` (`gatewayAllowlistPlatforms`
/// loop, which already used the correct top-level prefix — only these doc
/// comments were wrong).
///
/// **Two doc corrections and one dead field, v0.21.1 audit B5:**
/// - `busy_ack_enabled` is **not** a per-platform key. Hermes reads only the
///   GLOBAL `display.busy_ack_enabled` (bridged to
///   `HERMES_GATEWAY_BUSY_ACK_ENABLED` by `gateway/run.py`), which is why
///   `GatewayBehaviorViewModel` has written the global key since the v0.21
///   sweep. `busyAckEnabled` here is kept only to round-trip a
///   `<platform>.busy_ack_enabled` key a user may already have in their
///   file; nothing in Hermes reads it.
/// - `slash_command_notice_ttl_seconds` **exists nowhere in Hermes**, at
///   either tag. The field was removed rather than kept "for round-trip":
///   it modelled a key no Hermes version has ever defined, read or written,
///   and nothing in Scarf wrote it either.
/// - `gateway_restart_notification`'s upstream default is **`True`**
///   (`gateway/config.py:393` `PlatformConfig` at tag `v2026.9.7`, identical
///   at v2026.8.31), not `false`. See the field doc below.
///
/// The struct carries all three list fields so a single shape fits every
/// platform; only the field matching `GatewayAllowlistKind.kind(for:)` is
/// surfaced in the editor for a given platform. The other two stay empty
/// and round-trip through the YAML parser unchanged.
///
/// **Allowlist-kind mapping (see `GatewayAllowlistKind.kind(for:)`).**
/// Slack/Mattermost/Discord → `.channels`; Telegram/DingTalk → `.chats`;
/// Matrix → `.rooms`. WhatsApp and Google Chat are deliberately excluded —
/// both gate access through other mechanisms (`allow_from`/
/// `group_allow_from` for WhatsApp, `GOOGLE_CHAT_ALLOWED_USERS` for Google
/// Chat), so an `allowed_*` list would be a silent no-op for them. LINE has
/// an `allowed_rooms` concept too, but it's **environment-variable-only**
/// (never exposed via `config.yaml`) — deliberately excluded from this
/// Swift mapping; don't re-add it thinking it's a gap.
///
/// **Defaults track Hermes.** `busyAckEnabled = true`,
/// `gatewayRestartNotification = true`. An "all-default" instance therefore
/// produces no `gateway:` block in YAML — see `HermesConfig+YAML` parsing
/// logic which only inserts an entry into `gatewayPlatforms` when at least
/// one of these keys is present in the file.
public struct GatewayPlatformSettings: Sendable, Equatable {
    /// `<platform>.allowed_channels` (top-level) — Slack, Mattermost,
    /// Discord. Empty when the platform doesn't use channels.
    public var allowedChannels: [String]
    /// `<platform>.allowed_chats` (top-level) — Telegram, DingTalk.
    /// Empty when the platform doesn't use chats.
    public var allowedChats: [String]
    /// `<platform>.allowed_rooms` (top-level) — Matrix.
    /// Empty when the platform doesn't use rooms.
    public var allowedRooms: [String]
    /// `<platform>.busy_ack_enabled` (top-level) — **read by nothing**.
    /// Hermes's only busy-ack switch is the global
    /// `display.busy_ack_enabled`; this field exists solely so a
    /// hand-written per-platform key survives a load/save round-trip.
    /// Default `true`, matching the global default.
    public var busyAckEnabled: Bool
    /// `<platform>.gateway_restart_notification` (top-level) — the
    /// "♻️ Gateway online/restarted" ping.
    ///
    /// **Default `true`, matching Hermes** (`gateway/config.py:393`,
    /// `PlatformConfig.gateway_restart_notification: bool = True`, identical
    /// at v2026.8.31 and v2026.9.7). Scarf defaulted this to `false`, so an
    /// unset key rendered the toggle OFF while the host was pinging — and
    /// one save then wrote `false`, silently turning off a notification the
    /// user had never disabled. The parser reads it through
    /// `boolTrueDefault`, so an absent key is `true` and only an explicit
    /// falsy spelling (`false`/`0`/`no`/`off`) turns it off.
    public var gatewayRestartNotification: Bool

    public init(
        allowedChannels: [String] = [],
        allowedChats: [String] = [],
        allowedRooms: [String] = [],
        busyAckEnabled: Bool = true,
        gatewayRestartNotification: Bool = true
    ) {
        self.allowedChannels = allowedChannels
        self.allowedChats = allowedChats
        self.allowedRooms = allowedRooms
        self.busyAckEnabled = busyAckEnabled
        self.gatewayRestartNotification = gatewayRestartNotification
    }

    /// All-default instance. `HermesConfig.empty` initializes
    /// `gatewayPlatforms: [:]` so this is rarely used directly; provided
    /// for symmetry with the other settings types.
    public static let empty = GatewayPlatformSettings()

    /// The list field matching this allowlist kind, or `nil` for
    /// platforms without an allowlist surface.
    public func items(for kind: GatewayAllowlistKind) -> [String] {
        switch kind {
        case .channels: return allowedChannels
        case .chats:    return allowedChats
        case .rooms:    return allowedRooms
        }
    }
}
