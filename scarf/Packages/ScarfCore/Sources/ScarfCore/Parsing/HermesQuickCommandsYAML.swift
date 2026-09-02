import Foundation

/// Shared reader for the `quick_commands` section of `config.yaml`.
///
/// One parser for both surfaces (the Mac Quick Commands editor and the
/// iOS slash-menu projection in `RichChatViewModel`), so the two can never
/// disagree on the tricky part: a command NAME may itself contain literal
/// dots (`v1.2_deploy`, written via the escaped-key path). In the flattened
/// dotted paths `parseNestedYAML` produces, that name reads as
/// `quick_commands.v1.2_deploy.command` — a naive
/// `split(separator: ".", maxSplits: 2)` chops it into name "v1" +
/// field "2_deploy.command" and both drops the real entry and fabricates a
/// bogus one. Peel the known `.type` / `.command` suffix off instead so
/// everything in between — dots included — is the name.
public enum HermesQuickCommandsYAML {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let type: String
        public let command: String

        public init(name: String, type: String, command: String) {
            self.name = name
            self.type = type
            self.command = command
        }
    }

    /// Parse every `quick_commands.<name>.{type,command}` entry from an
    /// already-parsed YAML bundle. Missing `type` defaults to "exec"
    /// (Hermes's only supported type today); no filtering — callers decide
    /// what to keep. Sorted by name for stable UI order.
    public static func entries(in parsed: ParsedYAML) -> [Entry] {
        var byName: [String: (type: String, command: String)] = [:]
        let prefix = "quick_commands."
        for (key, value) in parsed.values where key.hasPrefix(prefix) {
            let remainder = key.dropFirst(prefix.count)
            let name: Substring
            let field: String
            if remainder.hasSuffix(".type") {
                field = "type"
                name = remainder.dropLast(".type".count)
            } else if remainder.hasSuffix(".command") {
                field = "command"
                name = remainder.dropLast(".command".count)
            } else {
                continue
            }
            guard !name.isEmpty else { continue }
            var existing = byName[String(name)] ?? (type: "exec", command: "")
            let stripped = HermesYAML.stripYAMLQuotes(value)
            if field == "type" { existing.type = stripped }
            if field == "command" { existing.command = stripped }
            byName[String(name)] = existing
        }
        return byName
            .map { Entry(name: $0.key, type: $0.value.type, command: $0.value.command) }
            .sorted { $0.name < $1.name }
    }

    /// Convenience: parse straight from YAML text.
    public static func entries(inYAML yaml: String) -> [Entry] {
        entries(in: HermesYAML.parseNestedYAML(yaml))
    }
}
