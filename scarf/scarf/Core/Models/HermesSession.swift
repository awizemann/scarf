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
    let reasoningTokens: Int
    let actualCostUSD: Double?
    let costStatus: String?
    let billingProvider: String?

    var totalTokens: Int { inputTokens + outputTokens + reasoningTokens }

    var displayCostUSD: Double? { actualCostUSD ?? estimatedCostUSD }

    var costIsActual: Bool { actualCostUSD != nil }

    var duration: TimeInterval? {
        guard let start = startedAt, let end = endedAt else { return nil }
        return end.timeIntervalSince(start)
    }

    var displayTitle: String {
        title ?? id
    }

    var sourceIcon: String {
        KnownPlatforms.icon(for: source)
    }

    func withTitle(_ newTitle: String) -> HermesSession {
        HermesSession(
            id: id, source: source, userId: userId, model: model,
            title: newTitle, parentSessionId: parentSessionId,
            startedAt: startedAt, endedAt: endedAt, endReason: endReason,
            messageCount: messageCount, toolCallCount: toolCallCount,
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens,
            estimatedCostUSD: estimatedCostUSD, reasoningTokens: reasoningTokens,
            actualCostUSD: actualCostUSD, costStatus: costStatus,
            billingProvider: billingProvider
        )
    }
}
