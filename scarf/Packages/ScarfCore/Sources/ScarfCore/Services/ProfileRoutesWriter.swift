import Foundation

/// Direct-YAML writer for the `profile_routes` list-of-maps block.
///
/// `hermes config set` stringifies structured values, and this block is a
/// *sequence of mappings* — the one shape neither `GatewayConfigWriter.setList`
/// (scalar bullets) nor `.setMap` (flat `key: value` rows) can emit. Same
/// surgical contract as those two: bytes outside the target block are
/// preserved, an empty list removes the key, and the file's line-ending
/// flavor round-trips.
///
/// **Where it writes.** Hermes prefers a top-level `profile_routes:` and only
/// falls back to `gateway.profile_routes:` (gateway/config.py:1356-1360), so
/// the writer edits whichever form is live (`HermesProfileRoutes.location`).
/// Writing the nested form while a top-level list exists would leave the user
/// staring at edits Hermes ignores.
///
/// **Nothing Hermes wrote is dropped.** Keys inside a rule that Scarf doesn't
/// model (including ones with nested bodies) ride along in
/// `HermesProfileRoute.extraLines` and are re-emitted verbatim.
public enum ProfileRoutesWriter {

    /// Rewrite the live `profile_routes` block.
    ///
    /// - Returns: updated YAML, or `nil` when the host is pre-v0.19 (the key
    ///   didn't exist yet) or a rule is structurally incomplete (Hermes
    ///   silently drops rules missing `platform` or `profile`, so Scarf
    ///   refuses to write one).
    public static func setProfileRoutes(
        in yaml: String,
        routes: [HermesProfileRoute],
        location: HermesProfileRoutes.Location,
        capabilities: HermesCapabilities
    ) -> String? {
        guard capabilities.hasGatewayProfileRoutes else { return nil }
        // The live block is in a shape this writer won't rewrite — refuse
        // rather than write a form Hermes would ignore.
        guard location != .unsupported else { return nil }
        for route in routes {
            guard !route.platform.trimmingCharacters(in: .whitespaces).isEmpty,
                  !route.profile.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
        }

        let usesCRLF = yaml.contains("\r\n")
        let normalized = usesCRLF ? yaml.replacingOccurrences(of: "\r\n", with: "\n") : yaml
        guard let result = setLF(in: normalized, routes: routes, location: location) else { return nil }
        return usesCRLF ? result.replacingOccurrences(of: "\n", with: "\r\n") : result
    }

    private static func setLF(
        in yaml: String,
        routes: [HermesProfileRoute],
        location: HermesProfileRoutes.Location
    ) -> String? {
        // Clearing the list must clear BOTH forms: dropping only the live
        // top-level block would resurrect a shadowed `gateway.profile_routes`
        // the user believes they just deleted.
        if routes.isEmpty {
            var out = removeBlock(in: yaml, section: nil)
            out = removeBlock(in: out, section: "gateway")
            return out
        }

        // `.absent` means "no live block anywhere" — write the nested form,
        // which is what `hermes config set gateway.profile_routes` would use.
        let section: String? = (location == .topLevel) ? nil : "gateway"
        let keyIndent = (section == nil) ? 0 : 2
        let body = render(routes: routes, keyIndent: keyIndent)

        var lines = yaml.components(separatedBy: "\n")
        if let block = ProfileRoutesYAML.locate(lines: lines, section: section, key: "profile_routes") {
            let tail = Array(lines[block.bodyRange.upperBound...])
            lines = Array(lines[..<block.keyIndex]) + body + tail
            return lines.joined(separator: "\n")
        }

        // Key missing. For the nested form, splice into an existing
        // `gateway:` section if there is one; otherwise append a scaffold.
        if section == nil {
            return appendBlock(to: yaml, body: body)
        }
        if let insertAfter = lastBodyLine(of: "gateway", in: lines) {
            lines = Array(lines[...insertAfter]) + body + Array(lines[(insertAfter + 1)...])
            return lines.joined(separator: "\n")
        }
        // Appending a second top-level `gateway:` when the file already has
        // an INLINE one (`gateway: {multiplex_profiles: true}`) would let
        // PyYAML's last-wins duplicate-key rule silently delete the original
        // mapping. Leave the file untouched instead.
        if hasInlineSection("gateway", in: lines) { return nil }
        return appendBlock(to: yaml, body: ["gateway:"] + body)
    }

    // MARK: - Rendering

    /// Render `profile_routes:` + its rule items at the given key indent.
    static func render(routes: [HermesProfileRoute], keyIndent: Int) -> [String] {
        let itemIndent = keyIndent + 2
        let contentIndent = itemIndent + 2
        var out = ["\(spaces(keyIndent))profile_routes:"]
        for route in routes {
            var rows: [String] = []
            if !route.name.isEmpty {
                rows.append("name: \(quoted(route.name))")
            }
            rows.append("platform: \(quoted(route.platform))")
            // Ids are ALWAYS quoted: Discord/Telegram ids are digit strings
            // and Hermes compares them with `!=` against string source ids
            // (profile_routing.py:96-101) — an unquoted `123` would load as
            // an int and never match.
            if !route.guildID.isEmpty { rows.append("guild_id: \(quotedID(route.guildID))") }
            if !route.chatID.isEmpty { rows.append("chat_id: \(quotedID(route.chatID))") }
            if !route.threadID.isEmpty { rows.append("thread_id: \(quotedID(route.threadID))") }
            rows.append("profile: \(quoted(route.profile))")
            // Only write `enabled` when it carries information: `false`, or
            // an explicit `true` the file already had. Hermes defaults it to
            // true (profile_routing.py:60).
            if !route.enabled {
                rows.append("enabled: false")
            } else if route.enabledIsExplicit {
                rows.append("enabled: true")
            }
            rows.append(contentsOf: route.extraLines)

            for (idx, row) in rows.enumerated() {
                if idx == 0 {
                    out.append("\(spaces(itemIndent))- \(row)")
                } else {
                    out.append(row.isEmpty ? "" : "\(spaces(contentIndent))\(row)")
                }
            }
        }
        return out
    }

    // MARK: - Block surgery

    private static func removeBlock(in yaml: String, section: String?) -> String {
        let lines = yaml.components(separatedBy: "\n")
        guard let block = ProfileRoutesYAML.locate(lines: lines, section: section, key: "profile_routes") else {
            return yaml
        }
        let kept = Array(lines[..<block.keyIndex]) + Array(lines[block.bodyRange.upperBound...])
        return kept.joined(separator: "\n")
    }

    /// Index of the last line belonging to top-level `<section>:`, or nil
    /// when the section is absent.
    private static func lastBodyLine(of section: String, in lines: [String]) -> Int? {
        guard let headerIdx = lines.firstIndex(where: { line in
            guard ProfileRoutesYAML.indentOf(line) == 0 else { return false }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\(section):") else { return false }
            let rest = trimmed.dropFirst(section.count + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty || rest.hasPrefix("#")
        }) else { return nil }

        var last = headerIdx
        var i = headerIdx + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { i += 1; continue }
            if ProfileRoutesYAML.indentOf(line) < 2 { break }
            last = i
            i += 1
        }
        return last
    }

    private static func appendBlock(to yaml: String, body: [String]) -> String {
        var trimmed = yaml
        while trimmed.hasSuffix("\n\n") { trimmed.removeLast() }
        if !trimmed.isEmpty && !trimmed.hasSuffix("\n") { trimmed.append("\n") }
        var lines: [String] = []
        if !trimmed.isEmpty { lines.append("") }
        lines.append(contentsOf: body)
        lines.append("")
        return trimmed + lines.joined(separator: "\n")
    }

    // MARK: - Scalars

    private static func spaces(_ n: Int) -> String { String(repeating: " ", count: n) }

    /// True when top-level `<section>:` exists but carries an inline value
    /// (flow mapping or scalar) instead of an indented block body.
    private static func hasInlineSection(_ section: String, in lines: [String]) -> Bool {
        for line in lines {
            guard ProfileRoutesYAML.indentOf(line) == 0 else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\(section):") else { continue }
            let rest = trimmed.dropFirst(section.count + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty && !rest.hasPrefix("#") { return true }
        }
        return false
    }

    /// Single-quote unconditionally — platform ids are safe bare words, but
    /// quoting is never wrong and keeps every value a string.
    private static func quotedID(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// Quote only when the value would otherwise change meaning (mirrors
    /// `GatewayConfigWriter`'s rule), so ordinary names stay readable.
    private static func quoted(_ raw: String) -> String {
        if raw.isEmpty { return "''" }
        let needsQuoting = raw.contains(":")
            || raw.contains("#")
            || raw.contains("&")
            || raw.contains("*")
            || raw.contains(">")
            || raw.contains("|")
            || raw.contains("{")
            || raw.contains("[")
            || raw.contains(",")
            || raw.first == "@"
            || raw.first == "-"
            || raw.first == "?"
            || raw.first == "!"
            || raw.first == "%"
            || raw.first == " "
            || raw.last == " "
            || raw.first == "\""
            || raw.first == "'"
            || Double(raw) != nil
            || ["true", "false", "null", "yes", "no", "on", "off", "~"].contains(raw.lowercased())
        if !needsQuoting { return raw }
        return "'\(raw.replacingOccurrences(of: "'", with: "''"))'"
    }
}
