import Foundation

/// Pure-Swift YAML readers for SKILL.md frontmatter.
///
/// - `parseConfigKeys(_:)` — the config settings a skill declares under
///   `metadata.hermes.config` (`agent/skill_utils.py:666-689` @ v2026.9.24).
///   Hermes stores their values under `skills.config.<key>` in config.yaml.
///   It replaces the old `skill.yaml` → `required_config:` reader: no Hermes
///   version reads `skill.yaml` (S10-F3, blind re-audit).
/// - `parseV011Fields(_:)` — Hermes v2026.4.23+ SKILL.md frontmatter
///   reader. Extracts `allowed_tools`, `related_skills`, and
///   `dependencies` lists from the YAML block between `---` markers
///   at the top of a SKILL.md file. Used by `SkillsScanner` to populate
///   `HermesSkill`'s v0.11 fields so chip rows in the detail views
///   render correctly. Returns nil for fields that are absent or
///   empty (callers treat nil as "don't show this section").
///
/// Intentionally not a full YAML parser — Hermes skill manifests use a
/// very narrow subset of YAML. `parseV011Fields` reuses `HermesYAML`.
public enum SkillFrontmatterParser: Sendable {

    /// The lines between the leading `---` and the next `---`, or nil when
    /// the file has no frontmatter.
    static func frontmatterLines(_ content: String) -> [String]? {
        let lines = content.components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard lines.first == "---",
              let endIdx = lines.dropFirst().firstIndex(of: "---")
        else { return nil }
        return Array(lines[1..<endIdx])
    }

    /// The `key`s declared under `metadata.hermes.config` in SKILL.md
    /// frontmatter, in order, without duplicates. Mirrors
    /// `extract_skill_config_vars`: the value may be a list of maps or a
    /// single map, and an entry without both `key` and `description` is
    /// skipped. Empty on any malformation.
    public static func parseConfigKeys(_ content: String) -> [String] {
        guard let lines = frontmatterLines(content) else { return [] }
        var path: [(indent: Int, key: String)] = []
        var configIndent: Int?
        var entries: [[String: String]] = []
        var current: [String: String]?
        var itemIndent = -1

        func field(_ text: Substring) -> (String, String)? {
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let key = text[..<colon].trimmingCharacters(in: .whitespaces)
            let value = scalarValue(text[text.index(after: colon)...])
            return key.isEmpty ? nil : (key, value)
        }

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = raw.prefix(while: { $0 == " " }).count
            if let base = configIndent {
                let isItem = trimmed.hasPrefix("- ") || trimmed == "-"
                if indent > base || (indent == base && isItem) {
                    if isItem {
                        if let current { entries.append(current) }
                        current = [:]
                        itemIndent = indent
                        if let (k, v) = field(trimmed.dropFirst(1)) { current?[k] = v }
                    } else if current != nil, indent > itemIndent {
                        if let (k, v) = field(Substring(trimmed)) { current?[k] = v }
                    } else if current == nil {
                        // A single map rather than a list.
                        if entries.isEmpty { entries.append([:]) }
                        if let (k, v) = field(Substring(trimmed)) { entries[0][k] = v }
                    }
                    continue
                }
                break
            }
            guard let (key, value) = field(Substring(trimmed)), !trimmed.hasPrefix("- ") else { continue }
            while let last = path.last, last.indent >= indent { path.removeLast() }
            guard value.isEmpty else { continue }
            path.append((indent, key))
            if path.map(\.key) == ["metadata", "hermes", "config"] { configIndent = indent }
        }
        if let current { entries.append(current) }

        var keys: [String] = []
        for entry in entries {
            guard let key = entry["key"], !key.isEmpty,
                  let description = entry["description"], !description.isEmpty,
                  !keys.contains(key) else { continue }
            keys.append(key)
        }
        return keys
    }

    /// Parse Hermes v2026.4.23+ SKILL.md frontmatter for the v0.11
    /// fields. The frontmatter block is the YAML region between two
    /// `---` markers at the top of the file. Anything outside the
    /// markers is ignored. Returns nil-everything when the file has
    /// no frontmatter or no recognised fields — callers should hide
    /// the corresponding chip rows in that case.
    ///
    /// Caller pre-condition: `content` is the full SKILL.md text. We
    /// detect the frontmatter shape ourselves rather than requiring
    /// callers to pre-strip it.
    public static func parseV011Fields(
        _ content: String
    ) -> (allowedTools: [String]?, relatedSkills: [String]?, dependencies: [String]?) {
        guard let lines = frontmatterLines(content) else { return (nil, nil, nil) }
        let parsed = HermesYAML.parseNestedYAML(lines.joined(separator: "\n"))
        let allowed = parsed.lists["allowed_tools"]
        // `metadata.hermes.related_skills` first, then top level, as Hermes
        // reads it (`tools/skills_tool.py:613-617` @ v2026.9.24). Every
        // bundled skill that declares it uses the nested form.
        let related = nonEmptyList("metadata.hermes.related_skills", in: parsed)
            ?? nonEmptyList("related_skills", in: parsed)
        let deps = parsed.lists["dependencies"]
        return (
            allowedTools: (allowed?.isEmpty ?? true) ? nil : allowed,
            relatedSkills: (related?.isEmpty ?? true) ? nil : related,
            dependencies: (deps?.isEmpty ?? true) ? nil : deps
        )
    }

    /// A list value, or a comma-separated scalar (Hermes's `_parse_tags`
    /// accepts both); nil when absent or empty.
    static func nonEmptyList(_ path: String, in parsed: ParsedYAML) -> [String]? {
        if let list = parsed.lists[path], !list.isEmpty { return list }
        guard let scalar = parsed.values[path] else { return nil }
        let items = HermesYAML.stripYAMLQuotes(scalar)
            .split(separator: ",")
            .map { HermesYAML.stripYAMLQuotes($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    /// A block-scalar value with its quotes and any trailing `# comment`
    /// removed. Hermes's own template comments its keys
    /// (`config:   # Optional — …`, `website/docs/developer-guide/
    /// creating-skills.md:64` @ v2026.9.24), and PyYAML drops the comment.
    static func scalarValue(_ raw: Substring) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let quote = text.first, quote == "\"" || quote == "'" {
            let body = text.dropFirst()
            if let close = body.firstIndex(of: quote) { return String(body[..<close]) }
            return HermesYAML.stripYAMLQuotes(text)
        }
        if text.hasPrefix("#") { return "" }
        if let hash = text.range(of: " #") {
            return String(text[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}
