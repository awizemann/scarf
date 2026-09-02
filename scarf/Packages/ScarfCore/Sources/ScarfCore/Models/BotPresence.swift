import Foundation

/// Whether a bot's ACP conversation is open right now, and whether it is
/// working.
///
/// This is a **projection of state Scarf already holds** — the live
/// `BotConversationViewModel`'s phase, its ACP connection, and the rich chat's
/// `isAgentWorking` — not a poll. Scarf has exactly one live conversation at a
/// time (`BotsViewModel.conversation`), so at most one roster row is ever
/// anything but ``offline``. There is no gateway presence API here and none is
/// wanted: inventing one would report bots as "online" that this window has no
/// process for.
public enum BotPresence: Sendable, Equatable {
    /// No conversation for this bot in this window.
    case offline
    /// Resolving the canonical chat, creating it, or the ACP channel is not
    /// up yet.
    case connecting
    /// Live channel, agent idle.
    case connected
    /// Live channel, the agent is producing a reply.
    case streaming

    public var isLive: Bool { self != .offline }

    /// Short label for the roster badge.
    public var label: String {
        switch self {
        case .offline: return ""
        case .connecting: return "connecting"
        case .connected: return "open"
        case .streaming: return "replying"
        }
    }

    /// Spoken form — VoiceOver reads the row, not the dot.
    public var accessibilityDescription: String {
        switch self {
        case .offline: return ""
        case .connecting: return "conversation connecting"
        case .connected: return "conversation open"
        case .streaming: return "replying now"
        }
    }

    /// The one mapping, pure so it can be pinned by tests without a subprocess.
    ///
    /// - Parameters:
    ///   - isCurrentConversation: does the window's single live conversation
    ///     belong to this bot?
    ///   - isResolving: the conversation is resolving or creating its chat.
    ///   - isFailed: the conversation ended in a failure — deliberately
    ///     ``offline``, not an error presence: a failed open holds no process,
    ///     and the detail pane already carries the message. A roster dot that
    ///     said "live" for a dead channel would be the lie this indicator
    ///     exists to prevent.
    ///   - isConnected: the ACP channel is up.
    ///   - isAgentWorking: the agent is mid-reply.
    public static func resolve(
        isCurrentConversation: Bool,
        isResolving: Bool,
        isFailed: Bool,
        isConnected: Bool,
        isAgentWorking: Bool
    ) -> BotPresence {
        guard isCurrentConversation, !isFailed else { return .offline }
        if isConnected { return isAgentWorking ? .streaming : .connected }
        return isResolving ? .connecting : .offline
    }
}

/// The roster's activity line for one bot: when its Bot Chat last moved, and
/// the one-line preview of the conversation.
public struct BotActivity: Sendable, Equatable {
    /// Timestamp of the most recent message in the live session. `nil` when
    /// the chat exists but holds no messages yet.
    public let lastMessageAt: Date?
    /// The carrier-aware preview (see ``SessionPreviewSQL``), already shaped
    /// to one line. Empty means "nothing worth showing", never an error.
    public let preview: String

    public init(lastMessageAt: Date?, preview: String) {
        self.lastMessageAt = lastMessageAt
        self.preview = preview
    }
}
