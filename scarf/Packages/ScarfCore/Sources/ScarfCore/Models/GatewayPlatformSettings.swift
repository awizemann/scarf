import Foundation

/// Per-platform Messaging Gateway settings introduced in Hermes v0.13. Bundles
/// the allowlist (the platform-appropriate flavor of `allowed_channels` /
/// `allowed_chats` / `allowed_rooms`) and three behavior toggles
/// (`busy_ack_enabled`, `gateway_restart_notification`,
/// `slash_command_notice_ttl_seconds`).
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
/// **Defaults track Hermes v0.13.** `busyAckEnabled = true`,
/// `gatewayRestartNotification = false`, `slashCommandNoticeTTLSeconds = 0`
/// (disabled). An "all-default" instance therefore produces no `gateway:`
/// block in YAML — see `HermesConfig+YAML` parsing logic which only inserts
/// an entry into `gatewayPlatforms` when at least one v0.13 key is present
/// in the file.
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
    /// `<platform>.busy_ack_enabled` (top-level). Default `true` — set
    /// to `false` to suppress per-message "agent is working…" acks.
    public var busyAckEnabled: Bool
    /// `<platform>.gateway_restart_notification` (top-level). Default
    /// `false` — set to `true` to post a "Gateway restarted" notice on boot.
    public var gatewayRestartNotification: Bool
    /// `<platform>.slash_command_notice_ttl_seconds` (top-level).
    /// Default `0` (disabled). Positive values auto-delete slash-command
    /// notices after N seconds.
    public var slashCommandNoticeTTLSeconds: Int

    public init(
        allowedChannels: [String] = [],
        allowedChats: [String] = [],
        allowedRooms: [String] = [],
        busyAckEnabled: Bool = true,
        gatewayRestartNotification: Bool = false,
        slashCommandNoticeTTLSeconds: Int = 0
    ) {
        self.allowedChannels = allowedChannels
        self.allowedChats = allowedChats
        self.allowedRooms = allowedRooms
        self.busyAckEnabled = busyAckEnabled
        self.gatewayRestartNotification = gatewayRestartNotification
        self.slashCommandNoticeTTLSeconds = slashCommandNoticeTTLSeconds
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
