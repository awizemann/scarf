import Foundation

public struct HermesToolset: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let icon: String
    public var enabled: Bool

    public init(
        name: String,
        description: String,
        icon: String,
        enabled: Bool
    ) {
        self.name = name
        self.description = description
        self.icon = icon
        self.enabled = enabled
    }
}

public struct HermesToolPlatform: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let icon: String

    public init(
        name: String,
        displayName: String,
        icon: String
    ) {
        self.name = name
        self.displayName = displayName
        self.icon = icon
    }
}

public enum KnownPlatforms {
    public static let cli = HermesToolPlatform(name: "cli", displayName: "CLI", icon: "terminal")
    public static let all: [HermesToolPlatform] = [
        cli,
        HermesToolPlatform(name: "telegram", displayName: "Telegram", icon: "paperplane"),
        HermesToolPlatform(name: "discord", displayName: "Discord", icon: "bubble.left.and.bubble.right"),
        HermesToolPlatform(name: "slack", displayName: "Slack", icon: "number"),
        HermesToolPlatform(name: "whatsapp", displayName: "WhatsApp", icon: "phone.bubble"),
        HermesToolPlatform(name: "signal", displayName: "Signal", icon: "lock.shield"),
        HermesToolPlatform(name: "email", displayName: "Email", icon: "envelope"),
        HermesToolPlatform(name: "homeassistant", displayName: "Home Assistant", icon: "house"),
        HermesToolPlatform(name: "webhook", displayName: "Webhook", icon: "arrow.up.right.square"),
        HermesToolPlatform(name: "matrix", displayName: "Matrix", icon: "lock.rectangle.stack"),
        HermesToolPlatform(name: "feishu", displayName: "Feishu", icon: "message.badge.circle"),
        HermesToolPlatform(name: "mattermost", displayName: "Mattermost", icon: "bubble.left.and.exclamationmark.bubble.right"),
        HermesToolPlatform(name: "imessage", displayName: "iMessage", icon: "message.fill"),
        // -- v0.12 additions ---------------------------------------------
        // Yuanbao is a native gateway adapter (18th platform); Microsoft
        // Teams ships as a plugin (19th). PlatformDetail surfaces the
        // distinction in the setup copy. Names match Hermes's gateway
        // platform identifiers — Teams is `teams` (plugins/platforms/teams/
        // adapter.py), not `microsoft-teams`.
        HermesToolPlatform(name: "yuanbao", displayName: "Yuanbao 元宝", icon: "bubble.left.and.bubble.right.fill"),
        HermesToolPlatform(name: "teams", displayName: "Microsoft Teams", icon: "person.2.fill"),
        // -- v0.13 additions ---------------------------------------------
        // Google Chat is the 20th gateway platform. Setup runs through
        // `hermes setup` rather than per-field forms because the auth
        // dance is OAuth-style and lives outside Scarf. Identifier is
        // `google_chat` (snake_case, per plugins/platforms/google_chat/
        // adapter.py) — earlier Scarf releases wrongly used `google-chat`.
        HermesToolPlatform(name: "google_chat", displayName: "Google Chat", icon: "bubble.left.fill"),
        // -- v0.14 additions ---------------------------------------------
        // LINE Messaging API (21st platform, first-class native adapter)
        // and SimpleX Chat (22nd platform, talks to a local
        // `simplex-chat` daemon in WebSocket mode). Identifiers match
        // Hermes's gateway platform names verbatim.
        HermesToolPlatform(name: "line", displayName: "LINE", icon: "bubble.left.and.text.bubble.right"),
        HermesToolPlatform(name: "simplex", displayName: "SimpleX Chat", icon: "lock.shield.fill"),
        // -- v0.15 additions ---------------------------------------------
        // ntfy (23rd platform) — pub/sub push via an ntfy.sh-compatible
        // server. Outbound-capable with an optional separate publish
        // topic; auth is an optional bearer token or `user:pass` Basic.
        // Identifier matches Hermes's gateway platform name verbatim.
        HermesToolPlatform(name: "ntfy", displayName: "ntfy", icon: "bell.badge"),
        // -- v0.17 additions ---------------------------------------------
        // WhatsApp Business Cloud API (25th platform) — Meta's hosted webhook
        // path, distinct from the older `whatsapp` web-bridge. iMessage via
        // Photon (24th) is intentionally not surfaced yet (moving protocol).
        HermesToolPlatform(name: "whatsapp_cloud", displayName: "WhatsApp Cloud", icon: "phone.bubble.fill"),
        // -- v0.20 additions ---------------------------------------------
        // Buzz — Block's Nostr-based messenger (plugins/platforms/buzz/).
        // User-gated via `allowed_users` (hex pubkeys / npubs), so it has
        // no GatewayAllowlistKind mapping.
        HermesToolPlatform(name: "buzz", displayName: "Buzz", icon: "bolt.horizontal.circle"),
    ]

    public static func icon(for platform: String) -> String {
        switch platform {
        case "cli": return "terminal"
        case "telegram": return "paperplane"
        case "discord": return "bubble.left.and.bubble.right"
        case "slack": return "number"
        case "whatsapp": return "phone.bubble"
        case "signal": return "lock.shield"
        case "email": return "envelope"
        case "homeassistant": return "house"
        case "webhook": return "arrow.up.right.square"
        case "matrix": return "lock.rectangle.stack"
        case "feishu": return "message.badge.circle"
        case "mattermost": return "bubble.left.and.exclamationmark.bubble.right"
        case "imessage": return "message.fill"
        case "yuanbao": return "bubble.left.and.bubble.right.fill"
        // Legacy hyphenated spellings accepted for callers still holding
        // pre-fix identifiers (Scarf < v0.20 parity used them wrongly).
        case "teams", "microsoft-teams": return "person.2.fill"
        case "google_chat", "google-chat", "googlechat": return "bubble.left.fill"
        case "line": return "bubble.left.and.text.bubble.right"
        case "simplex": return "lock.shield.fill"
        case "ntfy": return "bell.badge"
        case "whatsapp_cloud": return "phone.bubble.fill"
        case "buzz": return "bolt.horizontal.circle"
        default: return "bubble.left"
        }
    }
}
