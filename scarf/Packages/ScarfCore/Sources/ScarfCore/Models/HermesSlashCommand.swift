import Foundation

/// A slash command available in chat. Sourced either from the ACP server
/// (`available_commands_update`) or from user-defined `quick_commands` in
/// `config.yaml`.
public struct HermesSlashCommand: Identifiable, Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case acp
        case quickCommand
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
