import Foundation

struct HermesToolset: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    let icon: String
    var enabled: Bool
}

struct HermesToolPlatform: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let displayName: String
    let icon: String
}

enum KnownPlatforms {
    static let cli = HermesToolPlatform(name: "cli", displayName: "CLI", icon: "terminal")
    static let all: [HermesToolPlatform] = [
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
    ]

    static func icon(for platform: String) -> String {
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
        default: return "bubble.left"
        }
    }
}
