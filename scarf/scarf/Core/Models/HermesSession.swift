import Foundation

struct HermesSession: Identifiable, Sendable {
    let id: String
    let source: String
    let userId: String?
    let model: String?
    let title: String?
    let parentSessionId: String?
    let startedAt: Date?
    let endedAt: Date?
    let endReason: String?
    let messageCount: Int
    let toolCallCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let estimatedCostUSD: Double?

    var totalTokens: Int { inputTokens + outputTokens }

    var duration: TimeInterval? {
        guard let start = startedAt, let end = endedAt else { return nil }
        return end.timeIntervalSince(start)
    }

    var displayTitle: String {
        title ?? id
    }

    var sourceIcon: String {
        switch source {
        case "cli": return "terminal"
        case "telegram": return "paperplane"
        case "discord": return "bubble.left.and.bubble.right"
        case "slack": return "number"
        case "email": return "envelope"
        default: return "bubble.left"
        }
    }
}
