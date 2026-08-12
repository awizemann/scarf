import Foundation

/// Reader for the `profile_routes` block — a **list of maps**, the one shape
/// `HermesYAML.parseNestedYAML` deliberately doesn't model (it flattens
/// bullets into `[String]`). Rather than teach the flat parser sequences of
/// mappings, this scanner walks the block directly and hands back typed
/// rules plus every unmodeled line verbatim.
///
/// Source of truth: hermes-agent tag v2026.8.3 —
/// `gateway/config.py:1356-1360` (which form wins), `gateway/config.py:1345-1352`
/// (`multiplex_profiles` precedence), `gateway/profile_routing.py`
/// (rule fields).
public enum ProfileRoutesYAML {

    /// Keys Scarf models. Everything else in a rule is preserved verbatim.
    private static let knownKeys: Set<String> = [
        "name", "platform", "profile", "guild_id", "chat_id", "thread_id", "enabled",
    ]

    /// Parse `config.yaml` into the routes block Hermes would actually use.
    ///
    /// Precedence mirrors `gateway/config.py`: a top-level `profile_routes:`
    /// wins, but only when it parses to an actual list — a bare
    /// `profile_routes:` header with no items is `None` to PyYAML, so Hermes
    /// falls through to the nested `gateway.profile_routes:` form.
    public static func parse(_ yaml: String) -> HermesProfileRoutes {
        let lines = yaml
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        let multiplex = parseMultiplex(yaml)

        func result(_ routes: [HermesProfileRoute], _ location: HermesProfileRoutes.Location) -> HermesProfileRoutes {
            HermesProfileRoutes(
                routes: routes,
                location: location,
                multiplexProfiles: multiplex.value,
                multiplexIsTopLevel: multiplex.isTopLevel
            )
        }

        // A populated flow list is live for Hermes but outside this scanner's
        // grammar — report it rather than editing some other form whose edits
        // Hermes would then ignore.
        if hasPopulatedFlowList(lines: lines, section: nil) {
            return result([], .unsupported)
        }

        let topBlock = locate(lines: lines, section: nil, key: "profile_routes")
        if let topBlock, let routes = routes(from: topBlock, lines: lines) {
            return result(routes, .topLevel)
        }
        // The top-level form isn't a list, so Hermes reads the nested one.
        if hasPopulatedFlowList(lines: lines, section: "gateway") {
            return result([], .unsupported)
        }
        if let block = locate(lines: lines, section: "gateway", key: "profile_routes"),
           let routes = routes(from: block, lines: lines) {
            return result(routes, .gateway)
        }
        return result([], .absent)
    }

    /// `multiplex_profiles` — top-level form wins over `gateway.multiplex_profiles`,
    /// matching gateway/config.py:1345-1352.
    private static func parseMultiplex(_ yaml: String) -> (value: Bool, isTopLevel: Bool) {
        let values = HermesYAML.parseNestedYAML(yaml).values
        let topLevel = values["multiplex_profiles"]
        let raw = topLevel ?? values["gateway.multiplex_profiles"]
        let value = HermesYAML.stripYAMLQuotes(raw ?? "").lowercased() == "true"
        return (value, topLevel != nil)
    }

    /// True when `profile_routes` is written as a NON-empty flow list
    /// (`profile_routes: [{name: a, …}]`). PyYAML reads that as a real list,
    /// so it's live — but rewriting it safely is outside this scanner's
    /// grammar, so callers go read-only instead of writing a form Hermes
    /// wouldn't read. `[]` is excluded: an empty flow list carries no data
    /// and is handled by the normal path.
    static func hasPopulatedFlowList(lines: [String], section: String?) -> Bool {
        let keyIndent = section == nil ? 0 : 2
        var inSection = section == nil
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = indentOf(line)
            if let section {
                if indent == 0 { inSection = isHeader(line, named: section) }
                if !inSection { continue }
            }
            guard indent == keyIndent, trimmed.hasPrefix("profile_routes:") else { continue }
            let rest = trimmed.dropFirst("profile_routes:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard rest.hasPrefix("[") else { return false }
            return rest.prefix(while: { $0 != "#" }).trimmingCharacters(in: .whitespaces) != "[]"
        }
        return false
    }

    // MARK: - Block location

    /// A located `profile_routes` block.
    struct Block {
        /// Index of the `profile_routes:` line.
        let keyIndex: Int
        /// Indent of that line.
        let keyIndent: Int
        /// Body line range (may be empty).
        let bodyRange: Range<Int>
        /// True when the value was written inline as an empty flow list (`[]`).
        let isInlineEmptyList: Bool
    }

    /// Locate `key:` either at the top level (`section == nil`) or as a child
    /// of a top-level `section:`. Returns nil when absent.
    static func locate(lines: [String], section: String?, key: String) -> Block? {
        var searchStart = 0
        var keyIndent = 0

        if let section {
            guard let sectionIdx = lines.firstIndex(where: { line in
                indentOf(line) == 0 && isHeader(line, named: section)
            }) else { return nil }
            searchStart = sectionIdx + 1
            keyIndent = 2
        }

        var keyIndex: Int?
        var inlineEmpty = false
        var i = searchStart
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }
            let indent = indentOf(line)
            if section != nil && indent < keyIndent { break }  // left the section
            if indent == keyIndent, trimmed.hasPrefix("\(key):") {
                let rest = trimmed.dropFirst(key.count + 1)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.isEmpty || rest.hasPrefix("#") {
                    keyIndex = i
                } else if rest.hasPrefix("[") {
                    // Flow list. `[]` is an empty-but-present list (Hermes
                    // sees a list and stops there); a populated flow list is
                    // outside this scanner's grammar — treat it as "not a
                    // block we can safely own" by returning nil so the caller
                    // falls through rather than clobbering it.
                    let body = rest.prefix(while: { $0 != "#" }).trimmingCharacters(in: .whitespaces)
                    guard body == "[]" else { return nil }
                    keyIndex = i
                    inlineEmpty = true
                } else {
                    // Some other scalar (`profile_routes: null`) — not a list.
                    return nil
                }
                break
            }
            i += 1
        }

        guard let keyIndex else { return nil }
        if inlineEmpty {
            return Block(keyIndex: keyIndex, keyIndent: keyIndent, bodyRange: keyIndex + 1..<keyIndex + 1, isInlineEmptyList: true)
        }

        // Body: every following line that belongs to the block. Bullets are
        // allowed at the key's own indent (block-style YAML) or deeper.
        var end = keyIndex + 1
        var j = keyIndex + 1
        while j < lines.count {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { j += 1; continue }
            let indent = indentOf(line)
            if indent > keyIndent || (indent == keyIndent && trimmed.hasPrefix("- ")) {
                j += 1
                end = j
                continue
            }
            break
        }
        return Block(keyIndex: keyIndex, keyIndent: keyIndent, bodyRange: keyIndex + 1..<end, isInlineEmptyList: false)
    }

    // MARK: - Rule parsing

    /// Parse the located block's body into rules. Returns nil when the block
    /// has a body that isn't a sequence (so the caller leaves it alone).
    private static func routes(from block: Block, lines: [String]) -> [HermesProfileRoute]? {
        if block.isInlineEmptyList { return [] }

        // Split the body into per-item line groups.
        var items: [[String]] = []
        var current: [String] = []
        // Only a bullet at the SEQUENCE's own indent starts a new rule — a
        // deeper `- x` belongs to a nested list inside the current rule
        // (e.g. an unmodeled key whose value is a list).
        var sequenceIndent: Int?
        /// Comments seen before the first bullet, attached to the first rule.
        var pendingComments: [String] = []
        for idx in block.bodyRange {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = indentOf(line)
            let isBullet = trimmed.hasPrefix("- ") || trimmed == "-"
            if trimmed.hasPrefix("#") {
                // Comments ride along in the enclosing rule's verbatim lines
                // so a rewrite never eats the operator's notes. Comments
                // sitting between the `profile_routes:` header and the first
                // bullet are held over and attached to the first rule — they
                // move a little, but they survive.
                if sequenceIndent == nil { pendingComments.append(line) } else { current.append(line) }
                continue
            }
            if isBullet && (sequenceIndent == nil || indent == sequenceIndent) {
                sequenceIndent = indent
                if !current.isEmpty { items.append(current) }
                current = [line] + pendingComments
                pendingComments = []
            } else {
                guard sequenceIndent != nil else {
                    // Content before any bullet — this is a mapping, not a
                    // sequence. Refuse to own the block.
                    return nil
                }
                current.append(line)
            }
        }
        if !current.isEmpty { items.append(current) }
        // A block header with no bullets at all is `None` to PyYAML, not a
        // list — Hermes falls through to the other form, so we do too.
        if items.isEmpty { return nil }

        return items.map(rule(fromItem:))
    }

    private static func rule(fromItem itemLines: [String]) -> HermesProfileRoute {
        // The dash line carries the first key inline: `  - name: foo`. Its
        // content column is where every sibling key of that map sits.
        let dashLine = itemLines[0]
        let dashIndent = indentOf(dashLine)
        let dashTrimmed = dashLine.trimmingCharacters(in: .whitespaces)
        let firstContent = dashTrimmed == "-"
            ? ""
            : String(dashTrimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        let baseIndent = dashIndent + 2

        // Normalize to (indent, trimmed-content) pairs.
        var entries: [(indent: Int, text: String, raw: String)] = []
        if !firstContent.isEmpty {
            entries.append((baseIndent, firstContent, spaces(baseIndent) + firstContent))
        }
        for line in itemLines.dropFirst() {
            entries.append((indentOf(line), line.trimmingCharacters(in: .whitespaces), line))
        }

        var route = HermesProfileRoute()
        var extras: [String] = []
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            // Only a line at the map's own indent can be one of its keys.
            guard entry.indent == baseIndent,
                  let colon = entry.text.firstIndex(of: ":") else {
                extras.append(dedent(entry.raw, by: baseIndent))
                i += 1
                continue
            }
            let key = String(entry.text[entry.text.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
            let rawValue = String(entry.text[entry.text.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            let hasNestedBody = (i + 1 < entries.count) && entries[i + 1].indent > baseIndent

            guard knownKeys.contains(key), !(rawValue.isEmpty && hasNestedBody) else {
                // Unknown key (or a known key carrying a nested body Scarf
                // can't model) — keep it and its whole body verbatim.
                extras.append(dedent(entry.raw, by: baseIndent))
                var j = i + 1
                while j < entries.count && entries[j].indent > baseIndent {
                    extras.append(dedent(entries[j].raw, by: baseIndent))
                    j += 1
                }
                i = j
                continue
            }

            let value = HermesYAML.stripYAMLQuotes(
                rawValue.hasPrefix("#") ? "" : rawValue
            )
            switch key {
            case "name": route.name = value
            case "platform": route.platform = value
            case "profile": route.profile = value
            case "guild_id": route.guildID = value
            case "chat_id": route.chatID = value
            case "thread_id": route.threadID = value
            case "enabled":
                route.enabled = value.lowercased() != "false"
                route.enabledIsExplicit = true
            default: break
            }
            i += 1
        }
        route.extraLines = extras
        return route
    }

    // MARK: - Helpers

    static func indentOf(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func isHeader(_ line: String, named name: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\(name):") else { return false }
        let rest = trimmed.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty || rest.hasPrefix("#")
    }

    private static func dedent(_ line: String, by amount: Int) -> String {
        let indent = indentOf(line)
        let drop = min(indent, amount)
        return String(line.dropFirst(drop))
    }

    private static func spaces(_ n: Int) -> String { String(repeating: " ", count: n) }
}
