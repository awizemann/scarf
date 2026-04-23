import Foundation

/// Parsed YAML result bundle. Flat dotted-path keys point at the
/// three value shapes we care about (scalars, bullet lists, maps).
///
/// **Scope note.** This is NOT a full YAML-spec parser. It handles
/// the subset used by Hermes's `config.yaml`: indent-based block
/// nesting, string/int/bool/float scalars, `- item` bullet lists,
/// and one level of nested `key: value` maps. Anchors, aliases,
/// multi-line scalars (`|` / `>` block scalars), flow-style `[ ]` /
/// `{ }` literals, tags — none of those are supported. That covers
/// 100% of what the current Hermes config actually uses.
///
/// The original implementation lived in the Mac app's
/// `HermesFileService`. Ported into ScarfCore in M6 so iOS can read
/// `config.yaml` through the same parser without having to pull in a
/// third-party YAML dependency.
public struct ParsedYAML: Sendable {
    /// Scalar key-value pairs at any indent level →
    /// `values["section.key"] = "..."`.
    public var values: [String: String]
    /// Bullet-list items attached to a parent key →
    /// `lists["section.key"] = [...]`.
    public var lists: [String: [String]]
    /// Nested `key: value` maps captured under a section header →
    /// `maps["section"] = [key: value, ...]`.
    public var maps: [String: [String: String]]

    public init(
        values: [String: String] = [:],
        lists: [String: [String]] = [:],
        maps: [String: [String: String]] = [:]
    ) {
        self.values = values
        self.lists = lists
        self.maps = maps
    }
}

/// Entry points for Hermes-flavored YAML parsing. Stateless, pure
/// functions — no Foundation types that differ cross-platform.
public enum HermesYAML {
    /// Parse a YAML string into a `ParsedYAML` bundle.
    public static func parseNestedYAML(_ yaml: String) -> ParsedYAML {
        var values: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var maps: [String: [String: String]] = [:]
        // Path stack: each entry is (indent, name). Pop when indent shrinks.
        var stack: [(indent: Int, name: String)] = []

        func currentPath(joinedWith child: String? = nil) -> String {
            var parts = stack.map(\.name)
            if let child { parts.append(child) }
            return parts.joined(separator: ".")
        }

        let rawLines = yaml.components(separatedBy: "\n")
        for line in rawLines {
            // Skip comment-only and blank lines but preserve indent semantics.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count
            let isListItem = trimmed.hasPrefix("- ")

            // Pop stack entries with indent >= current indent.
            // Exception: a list item at the same indent as its parent key is
            // valid block-style YAML ("toolsets:\n- hermes-cli") — keep the
            // parent so the item is attributed to it.
            while let top = stack.last {
                let shouldPop: Bool
                if isListItem && top.indent == indent {
                    shouldPop = false
                } else {
                    shouldPop = top.indent >= indent
                }
                if shouldPop { stack.removeLast() } else { break }
            }

            if isListItem {
                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let stripped = stripYAMLQuotes(item)
                let path = currentPath()
                guard !path.isEmpty else { continue }
                lists[path, default: []].append(stripped)
                continue
            }

            // Key-value or section line.
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let afterColon = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

            let path = currentPath(joinedWith: key)

            if afterColon.isEmpty || afterColon == "|" || afterColon == ">" {
                // Section header or empty-valued key — push onto stack so children nest.
                stack.append((indent: indent, name: key))
                continue
            }

            // Inline `{}` / `[]` literals → treat as empty.
            if afterColon == "{}" {
                values[path] = ""
                maps[path] = [:]
                continue
            }
            if afterColon == "[]" {
                values[path] = ""
                lists[path] = []
                continue
            }

            values[path] = afterColon

            // Also record as a map entry under the parent so blocks like
            // `terminal.docker_env` are accessible as `[String: String]`
            // without a separate scan.
            if !stack.isEmpty {
                let parentPath = currentPath()
                maps[parentPath, default: [:]][key] = stripYAMLQuotes(afterColon)
            }
        }
        return ParsedYAML(values: values, lists: lists, maps: maps)
    }

    /// Strip a single layer of surrounding single or double quotes from a YAML scalar.
    public static func stripYAMLQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
