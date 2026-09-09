import Foundation

/// Hermes v0.13 added cross-platform recipient allowlists to the Messaging
/// Gateway. Each platform stores the list under a different YAML key
/// depending on the platform's primary noun for "addressable destination":
///
/// - **`allowed_channels`** — Slack, Mattermost, Discord
/// - **`allowed_chats`** — Telegram, DingTalk
/// - **`allowed_rooms`** — Matrix
///
/// `GatewayAllowlistKind` encodes the (platform → key) mapping plus a few
/// presentation hints (placeholder strings, singular noun) so the allowlist
/// editor can render the right copy without the per-platform setup view
/// needing to know the YAML shape.
public enum GatewayAllowlistKind: String, Sendable, Equatable {
    case channels   // -> allowed_channels
    case chats      // -> allowed_chats
    case rooms      // -> allowed_rooms

    /// YAML scalar key segment under top-level `<platform>.<key>`.
    public var yamlKey: String {
        switch self {
        case .channels: return "allowed_channels"
        case .chats:    return "allowed_chats"
        case .rooms:    return "allowed_rooms"
        }
    }

    /// Placeholder copy for the editor's "add row" text field. Picks the
    /// most common identifier shape per platform family — Slack channel IDs
    /// for `channels`, Telegram username/numeric for `chats`, Matrix room
    /// IDs for `rooms`. Users can paste in any platform-specific format the
    /// gateway accepts; this is a hint, not validation.
    public var inputPlaceholder: String {
        switch self {
        case .channels: return "C0123ABCD or #channel-name"
        case .chats:    return "@username or 12345678"
        case .rooms:    return "!RoomId:matrix.org"
        }
    }

    /// Singular noun for prose surfaces ("Add a channel", "1 chat allowed",
    /// "0 rooms"). Capitalization is the caller's responsibility.
    public var noun: String {
        switch self {
        case .channels: return "channel"
        case .chats:    return "chat"
        case .rooms:    return "room"
        }
    }

    /// Plural noun for headings + counts.
    public var pluralNoun: String {
        switch self {
        case .channels: return "channels"
        case .chats:    return "chats"
        case .rooms:    return "rooms"
        }
    }

    /// Map a Hermes platform identifier to the allowlist kind it supports.
    /// Returns `nil` for every platform that gates access by some other
    /// mechanism — which is most of them.
    ///
    /// `whatsapp` is intentionally excluded: it gates *senders* via
    /// `allow_from` / `group_allow_from` (active only under
    /// `dm_policy: allowlist` / `group_policy: allowlist`), not an
    /// `allowed_chats` list. Writing `whatsapp.allowed_chats` is a silent
    /// no-op — Hermes never reads it (verified against v0.17
    /// `gateway/platforms/whatsapp.py`). Proper `allow_from` support belongs in
    /// the WhatsApp setup form, not this generic chat-id editor.
    ///
    /// `google_chat` is intentionally excluded: the adapter never reads
    /// `allowed_channels` at any Hermes version — access is gated via the
    /// `GOOGLE_CHAT_ALLOWED_USERS` env var (plugins/platforms/google_chat/
    /// adapter.py), so a channels allowlist would be a silent no-op.
    ///
    /// **`discord` is a real `.channels` platform** (v0.21.1 audit B4,
    /// closing the KNOWN GAP that stood here from the v0.20.4 audit).
    /// `plugins/platforms/discord/adapter.py:4620-4622` at tag `v2026.9.7`
    /// reads `allowed_channels` (config key or `DISCORD_ALLOWED_CHANNELS`)
    /// and `:5675-5677` enforces it as a hard whitelist — identical at
    /// v2026.8.31, so this is a pre-existing Scarf gap, not a v0.21.1
    /// change. The gap was left open because no Discord setup view wired
    /// `GatewayBehaviorSection`; `DiscordSetupView` now does, so the mapping
    /// reaches a real editor. `HermesConfig+YAML`'s
    /// `gatewayAllowlistPlatforms` loop gained `discord` in the same change —
    /// without it the allowlist would save and then read back empty.
    ///
    /// **The other nine platforms added to `KnownPlatforms` in the same
    /// sweep stay `nil`, each verified at tag `v2026.9.7`:** `sms`
    /// (`allowed_users_env="SMS_ALLOWED_USERS"`), `irc`
    /// (`extra.allowed_users`), `photon` (`allowed_users_env=
    /// "PHOTON_ALLOWED_USERS"`), `wecom` and `weixin`
    /// (`allow_from`/`group_allow_from`, the WhatsApp shape), `bluebubbles`,
    /// `qqbot` and `api_server` (no `allowed_*` recipient list at all), and
    /// `msgraph_webhook` (`allowed_source_cidrs` — a network ACL, not a
    /// destination list). Only `dingtalk` among them has a destination
    /// allowlist, and its `.chats` mapping already existed here; it was
    /// simply unreachable until `dingtalk` joined the roster.
    ///
    /// LINE has an `allowed_rooms` concept too, but it is
    /// **environment-variable-only** (never exposed via `config.yaml`) —
    /// deliberately excluded; don't re-add it thinking it's a gap.
    public static func kind(for platform: String) -> GatewayAllowlistKind? {
        switch platform {
        case "slack", "mattermost", "discord": return .channels
        case "telegram", "dingtalk":          return .chats
        case "matrix":                        return .rooms
        default: return nil
        }
    }
}
