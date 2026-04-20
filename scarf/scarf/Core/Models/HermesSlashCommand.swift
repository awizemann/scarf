import Foundation

/// A slash command available in chat. Sourced either from the ACP server
/// (`available_commands_update`) or from user-defined `quick_commands` in
/// `config.yaml`.
struct HermesSlashCommand: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case acp
        case quickCommand
    }

    var id: String { name }
    let name: String
    let description: String
    let argumentHint: String?
    let source: Source
}
