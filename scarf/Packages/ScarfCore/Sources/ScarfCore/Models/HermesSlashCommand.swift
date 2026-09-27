import Foundation

/// A slash command available in chat. See `Source` for where each one
/// comes from.
public struct HermesSlashCommand: Identifiable, Sendable, Equatable {
    /// Where this command came from. Drives the slash-menu badge and the
    /// chat view model's invocation path (literal-send vs client-side
    /// expansion vs non-interruptive flag).
    public enum Source: Sendable, Equatable {
        /// Advertised by the ACP server via `available_commands_update`.
        /// Sent to the agent as the literal slash text.
        case acp
        // No `quickCommand` source: Hermes's ACP adapter never runs
        // `quick_commands` (see `RichChatViewModel.acpCommands`), so the
        // chat menu does not offer them.
        /// Project-scoped, Scarf-managed command at
        /// `<project>/.scarf/slash-commands/<name>.md`. Scarf intercepts
        /// the invocation, expands `{{argument}}` substitution against the
        /// command's body, and sends the result as a normal user prompt
        /// (the agent never sees the slash trigger). Added in v2.5.
        case projectScoped
        /// ACP-native commands that don't interrupt the current turn —
        /// `/steer` is the flagship case. The chat UI keeps the
        /// "agent working" indicator on; the guidance applies after the
        /// next tool call. Added in v2.5 alongside Hermes v2026.4.23.
        case acpNonInterruptive
        /// ACP-native commands Hermes always supports but only advertises
        /// inside an active session via `available_commands_update`.
        /// Surfacing a small static fallback pre-session lets the slash
        /// menu offer discoverable affordances like `/new` even before
        /// the user has opened a session. Once a session starts, the
        /// ACP-advertised version takes over (deduped by name in
        /// `availableCommands`). Introduced alongside Hermes v0.13.
        case alwaysAvailable
    }

    public var id: String { name }
    public let name: String
    public let description: String
    public let argumentHint: String?
    public let source: Source

    public init(
        name: String,
        description: String,
        argumentHint: String?,
        source: Source
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.source = source
    }
}
