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
        default: return "bubble.left"
        }
    }
}
