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
        // Indent of the most recent scalar `key: value` line at the current
        // level, or nil right after a section header opened a block.
        //
        // PyYAML line-folds long scalars: `hermes peer add --note "<long
        // text>"` round-trips through `_save_peers` as a quoted scalar
        // whose continuation lines sit at a DEEPER indent than the key.
        // Those continuations are not keys, but they can contain `key:
        // value` text — a note mentioning "url: http://decoy" parsed as a
        // sibling `url` and (PyYAML sorts keys, so `note` is dumped before
        // `url`) overwrote the peer's real URL in the UI.
        //
        // In real YAML a key line can never be indented deeper than the
        // sibling scalar before it — that requires a parent with an empty
        // value, which is a section header, which resets this to nil. So
        // "deeper than the last scalar" is an unambiguous continuation.
        var lastScalarIndent: Int?

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

            // Folded/continued scalar line (see `lastScalarIndent`) — not a
            // key, not a list item, and must not touch the stack.
            if !isListItem, let last = lastScalarIndent, indent > last { continue }

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
                lastScalarIndent = nil
                continue
            }

            // Key-value or section line. Quoted keys (`'llama3:8b': high`)
            // may contain colons, so a naive first-colon split would cut
            // inside the quotes — scan past the closing quote first.
            // Written by v0.20's reasoning-overrides editor; plain keys
            // take the original path.
            let key: String
            let afterColon: String
            if let quote = trimmed.first, quote == "'" || quote == "\"" {
                let body = trimmed.dropFirst()
                guard let close = closingQuoteIndex(in: body, quote: quote) else { continue }
                var raw = String(body[body.startIndex..<close])
                if quote == "'" {
                    raw = raw.replacingOccurrences(of: "''", with: "'")
                }
                let rest = body[body.index(after: close)...].trimmingCharacters(in: .whitespaces)
                guard rest.hasPrefix(":") else { continue }
                key = raw
                afterColon = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
                key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                afterColon = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            }

            let path = currentPath(joinedWith: key)
            lastScalarIndent = indent

            if afterColon.isEmpty || afterColon == "|" || afterColon == ">"
                || afterColon.hasPrefix("#") {
                // `#` — a section header carrying only a trailing comment
                // (`agent:  # note`) still opens a block.
                // Section header or empty-valued key — push onto stack so children nest.
                // Children legitimately sit deeper, so the continuation
                // guard is disarmed until the next scalar.
                stack.append((indent: indent, name: key))
                lastScalarIndent = nil
                continue
            }

            // Inline flow dict `{...}` → parse flat scalar entries so
            // hand-written flow content (`reasoning_overrides: {a: low}`)
            // is visible in the UI instead of silently active. Nested or
            // exotic flow values fall back to an EMPTY map (the direct-YAML
            // writers still replace the line, so nothing is retained
            // silently). A trailing `# comment` after the brace is allowed.
            if afterColon.hasPrefix("{"),
               let close = afterColon.lastIndex(of: "}"),
               afterColon[afterColon.index(after: close)...]
                   .trimmingCharacters(in: .whitespaces)
                   .isEmpty
                   || afterColon[afterColon.index(after: close)...]
                       .trimmingCharacters(in: .whitespaces)
                       .hasPrefix("#") {
                let inner = String(afterColon[afterColon.index(after: afterColon.startIndex)..<close])
                values[path] = ""
                maps[path] = parseFlatFlowMap(inner) ?? [:]
                continue
            }
            // Inline flow list `[...]` (`["work", "personal"]`, `[]`) →
            // parse into a bullet-equivalent `[String]` rather than falling
            // through to the scalar `values[path]` branch below, which would
            // read a valid flow list as a malformed scalar. Mirrors the flow
            // dict handling above; a trailing `# comment` after the bracket
            // is allowed. Reused by `ProjectSkillsScanner.parseTrustedProjectDirs`
            // for the same inline-array shape.
            if afterColon.hasPrefix("["),
               let close = afterColon.lastIndex(of: "]"),
               afterColon[afterColon.index(after: close)...]
                   .trimmingCharacters(in: .whitespaces)
                   .isEmpty
                   || afterColon[afterColon.index(after: close)...]
                       .trimmingCharacters(in: .whitespaces)
                       .hasPrefix("#") {
                let inner = String(afterColon[afterColon.index(after: afterColon.startIndex)..<close])
                values[path] = ""
                lists[path] = parseFlatFlowList(inner)
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

    /// Parse the inside of a single-line flow dict (`a: low, 'b:c': high`)
    /// into a flat scalar map. Returns `[:]` for empty content and `nil`
    /// when the content is nested/exotic (embedded `{`/`[`, or an entry
    /// that doesn't split into `key: value`) — callers treat nil as empty.
    private static func parseFlatFlowMap(_ inner: String) -> [String: String]? {
        let body = inner.trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return [:] }
        if body.contains("{") || body.contains("[") { return nil }
        var result: [String: String] = [:]
        for part in body.split(separator: ",") {
            let entry = part.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty { continue }
            guard let (k, v) = splitFlowEntry(entry), !k.isEmpty, !v.isEmpty else { return nil }
            result[k] = v
        }
        return result
    }

    /// Parse the inside of a single-line flow list (`"work", 'personal', x`)
    /// into trimmed, quote-stripped items. Handles both quoted and bare
    /// entries and arbitrary internal spacing; empty entries (from `[]` or a
    /// stray trailing comma) are dropped. Shared by `parseNestedYAML`'s
    /// inline-array handling and `ProjectSkillsScanner.parseTrustedProjectDirs`.
    public static func parseFlatFlowList(_ inner: String) -> [String] {
        inner.split(separator: ",").compactMap { part in
            let value = stripYAMLQuotes(part.trimmingCharacters(in: .whitespaces))
            return value.isEmpty ? nil : value
        }
    }

    /// Split one `key: value` flow entry, honoring a quoted key that may
    /// contain colons (`'llama3:8b': high`).
    private static func splitFlowEntry(_ entry: String) -> (String, String)? {
        if let quote = entry.first, quote == "'" || quote == "\"" {
            let body = entry.dropFirst()
            guard let close = closingQuoteIndex(in: body, quote: quote) else { return nil }
            var key = String(body[body.startIndex..<close])
            if quote == "'" { key = key.replacingOccurrences(of: "''", with: "'") }
            let rest = body[body.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix(":") else { return nil }
            let value = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (key, stripYAMLQuotes(value))
        }
        guard let colon = entry.firstIndex(of: ":") else { return nil }
        let key = String(entry[entry.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, stripYAMLQuotes(value))
    }

    /// Index of the closing quote in `body` (which starts just AFTER the
    /// opening quote). Single-quoted YAML escapes an embedded quote by
    /// doubling (`''`), so skip doubled pairs.
    private static func closingQuoteIndex(in body: Substring, quote: Character) -> Substring.Index? {
        var i = body.startIndex
        while i < body.endIndex {
            if body[i] == quote {
                let next = body.index(after: i)
                if quote == "'", next < body.endIndex, body[next] == quote {
                    i = body.index(after: next)   // escaped '' — keep going
                    continue
                }
                return i
            }
            i = body.index(after: i)
        }
        return nil
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
