import Foundation

/// Direct YAML editor for top-level `<platform>.allowed_<kind>:` list blocks.
/// Hermes v0.16 reads gateway allowlists from top-level platform sections
/// (`slack.allowed_channels`, `telegram.allowed_chats`, …) — NOT from
/// `gateway.platforms.<platform>.*`. `hermes config set` stringifies arrays
/// (the same gotcha that forced Home Assistant's watch lists to stay
/// read-only), so the Messaging Gateway editor sidesteps the CLI for these
/// keys by editing `~/.hermes/config.yaml` directly.
///
/// **Pure-function `setList`** is the heart of the editor — it splits the
/// YAML into lines, finds (or creates) the targeted block, and splices the
/// new items in while preserving every byte outside the block. The async
/// `saveList` wrapper wires it through `ServerContext.readText` /
/// `writeText`, so the same code path works on `.local` and `.ssh` servers
/// — local goes through `LocalTransport`, remote round-trips via SCP.
///
/// **Merge, don't clobber.** When the top-level `<platform>:` section already
/// exists (e.g. it holds `slack.reply_to_mode` or `busy_ack_enabled`), the
/// allowlist key is spliced in alongside its siblings, which stay
/// byte-for-byte. Only when the section is entirely absent do we append a
/// fresh `<platform>:` scaffold.
///
/// **Scalar fields don't go through here.** `busy_ack_enabled`,
/// `gateway_restart_notification`, and `slash_command_notice_ttl_seconds`
/// are scalars that `hermes config set` handles cleanly — `GatewayBehaviorViewModel`
/// routes those through `PlatformSetupHelpers.saveForm` like every other
/// platform toggle.
///
/// **Why not use a real YAML library?** Same answer as everywhere else in
/// Scarf: zero external dependencies. The Hermes config flavor is a tightly
/// scoped subset (indent-based blocks, scalar-or-list values, no anchors /
/// aliases / flow style), and the targeted edit doesn't need to understand
/// the full grammar — only "find this block, replace it, preserve the rest".
public enum GatewayConfigWriter {

    /// Insert or replace the top-level `<platform>.<key>:` block in the YAML,
    /// preserving everything else byte-for-byte.
    ///
    /// - When `items` is empty, the block (and only the block — siblings
    ///   stay) is removed from the YAML if present, and the function is a
    ///   no-op if the block was already absent.
    /// - When the top-level `<platform>:` section exists but the `<key>:`
    ///   leaf is missing, the new block is spliced into the existing section
    ///   alongside any sibling keys (which stay byte-for-byte).
    /// - When the `<platform>:` section is absent and `items` is non-empty,
    ///   the function appends a `<platform>:` scaffold at the end of the
    ///   file. This keeps the function idempotent on round-trip but means
    ///   the new block is appended rather than spliced into the middle of
    ///   the file — preserving the surrounding YAML byte-for-byte.
    /// - When the block is present, its bullet rows are replaced with the
    ///   new items at the same indent. Items containing YAML-special
    ///   characters (`:` `#` `@` or leading whitespace) are single-quoted
    ///   defensively.
    public static func setList(
        in yaml: String,
        platform: String,
        key: String,
        items: [String]
    ) -> String {
        let keyIndent = 2   // `<platform>:\n  <key>:`
        let itemIndent = 4  // `<platform>:\n  <key>:\n    - item`

        let lines = yaml.components(separatedBy: "\n")
        let trimmedItems = items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Locate `  <key>:` whose parent is the top-level `<platform>:` section.
        let location = locateBlock(
            in: lines,
            platform: platform,
            key: key
        )

        switch location {
        case .found(let blockRange):
            return replaceBlock(
                in: lines,
                blockRange: blockRange,
                key: key,
                items: trimmedItems,
                keyIndent: keyIndent,
                itemIndent: itemIndent
            )
        case .platformPresentKeyMissing(let insertAfter):
            if trimmedItems.isEmpty {
                // No-op: empty target, no existing block.
                return yaml
            }
            return spliceNewKey(
                lines: lines,
                insertAfterLineIndex: insertAfter,
                key: key,
                items: trimmedItems,
                keyIndent: keyIndent,
                itemIndent: itemIndent
            )
        case .platformMissing:
            if trimmedItems.isEmpty {
                // Nothing to write, no existing block.
                return yaml
            }
            return appendScaffold(
                yaml: yaml,
                platform: platform,
                key: key,
                items: trimmedItems
            )
        }
    }

    /// Insert or replace a nested `key: value` MAP block under a top-level
    /// section — same surgical contract as `setList` (byte-for-byte outside
    /// the block, key removed entirely when `pairs` is empty), but the block
    /// body is `    <mapKey>: <value>` rows instead of bullets. Used by the
    /// v0.20 `agent.reasoning_overrides` editor (`hermes config set` cannot
    /// write dicts). Map keys containing YAML structure characters (`:`,
    /// `#`, leading specials) are single-quoted; pair order is preserved as
    /// given.
    public static func setMap(
        in yaml: String,
        section: String,
        key: String,
        pairs: [(key: String, value: String)]
    ) -> String {
        let keyIndent = 2
        let entryIndent = 4

        let lines = yaml.components(separatedBy: "\n")
        let trimmedPairs = pairs.filter {
            !$0.key.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }

        func entryRows() -> [String] {
            trimmedPairs.map {
                "\(spaces(entryIndent))\(yamlQuoteIfNeeded($0.key)): \(yamlQuoteIfNeeded($0.value))"
            }
        }

        switch locateBlock(in: lines, platform: section, key: key) {
        case .found(let blockRange):
            var newLines = Array(lines.prefix(blockRange.lowerBound))
            if !trimmedPairs.isEmpty {
                newLines.append("\(spaces(keyIndent))\(key):")
                newLines.append(contentsOf: entryRows())
            }
            let tailStart = blockRange.upperBound + 1
            if tailStart < lines.count {
                newLines.append(contentsOf: lines.suffix(from: tailStart))
            }
            return newLines.joined(separator: "\n")
        case .platformPresentKeyMissing(let insertAfter):
            if trimmedPairs.isEmpty { return yaml }
            var newLines = Array(lines.prefix(insertAfter + 1))
            newLines.append("\(spaces(keyIndent))\(key):")
            newLines.append(contentsOf: entryRows())
            if insertAfter + 1 < lines.count {
                newLines.append(contentsOf: lines.suffix(from: insertAfter + 1))
            }
            return newLines.joined(separator: "\n")
        case .platformMissing:
            if trimmedPairs.isEmpty { return yaml }
            var trimmed = yaml
            while trimmed.hasSuffix("\n\n") { trimmed.removeLast() }
            if !trimmed.isEmpty && !trimmed.hasSuffix("\n") { trimmed.append("\n") }
            var newLines: [String] = []
            if !trimmed.isEmpty { newLines.append("") }
            newLines.append("\(section):")
            newLines.append("  \(key):")
            newLines.append(contentsOf: entryRows())
            newLines.append("")
            return trimmed + newLines.joined(separator: "\n")
        }
    }

    /// Async wrapper that reads, mutates, writes via the given context.
    /// Returns `false` on read or write failure.
    ///
    /// The actual I/O happens via `ServerContext.readText` / `writeText`,
    /// which are `nonisolated` — safe to call from `MainActor` for the
    /// short config.yaml writes the platform setup forms run. For remote
    /// hosts the call rounds through SCP under `Task.detached` upstream
    /// (per Swift 6 concurrency rules in `~/.claude/CLAUDE.md`).
    public static func saveList(
        context: ServerContext,
        platform: String,
        key: String,
        items: [String]
    ) -> Bool {
        let path = context.paths.configYAML
        let existing = context.readText(path) ?? ""
        let updated = setList(in: existing, platform: platform, key: key, items: items)
        if updated == existing { return true }   // no-op: already correct
        return context.writeText(path, content: updated)
    }

    // MARK: - Internals

    /// Result of locating the targeted block in the YAML line array.
    private enum BlockLocation {
        /// Block found; the closed range covers the header line + all bullet
        /// rows attributed to it. Replacing this slice with the new block
        /// completes the edit.
        case found(ClosedRange<Int>)
        /// The top-level `<platform>:` section exists, but the leaf `<key>:`
        /// is absent under it. The associated value is the line index after
        /// which the new key should be inserted (last line in the platform's
        /// block, or the platform header itself if the platform's body is
        /// empty).
        case platformPresentKeyMissing(insertAfter: Int)
        /// The top-level `<platform>:` section is missing entirely. The whole
        /// scaffold needs to be appended.
        case platformMissing
    }

    private static func locateBlock(
        in lines: [String],
        platform: String,
        key: String
    ) -> BlockLocation {
        // Walk top-to-bottom looking for `<platform>:` at indent 0.
        guard let platformIdx = firstIndex(
            of: lines,
            headerLineEqualTo: "\(platform):",
            indent: 0
        ) else {
            return .platformMissing
        }

        // Inside the platform block, find `<key>:` at indent 2, OR the end
        // of the platform's body if the key is missing.
        var keyIdx: Int?
        var lastBodyIdx = platformIdx
        var i = platformIdx + 1
        while i < lines.count {
            let line = lines[i]
            let indent = leadingSpaces(line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            if indent < 2 {
                // Out of the platform's block (next top-level section).
                break
            }
            if indent == 2 && trimmed == "\(key):" {
                keyIdx = i
                break
            }
            lastBodyIdx = i
            i += 1
        }

        guard let keyIdx else {
            return .platformPresentKeyMissing(insertAfter: lastBodyIdx)
        }

        // Walk down the bullet rows until we leave the block (indent shrinks
        // below the bullet indent OR we hit a sibling key at indent 2).
        var endIdx = keyIdx
        var j = keyIdx + 1
        while j < lines.count {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                j += 1
                continue
            }
            let indent = leadingSpaces(line)
            // Block-style YAML allows bullets at the same indent as their
            // parent key; tolerate 2-space `- item` rows alongside the
            // canonical 4-space ones.
            let isBullet = trimmed.hasPrefix("- ")
            if isBullet && (indent == 4 || indent == 2) {
                endIdx = j
                j += 1
                continue
            }
            // Anything not a bullet at indent ≤ 2 ends the block.
            if indent <= 2 {
                break
            }
            // Indent > 4 with no bullet — unusual but tolerate (e.g. inline
            // continuation). Treat as still in the block and advance.
            endIdx = j
            j += 1
        }

        return .found(keyIdx...endIdx)
    }

    private static func replaceBlock(
        in lines: [String],
        blockRange: ClosedRange<Int>,
        key: String,
        items: [String],
        keyIndent: Int,
        itemIndent: Int
    ) -> String {
        var newLines = Array(lines.prefix(blockRange.lowerBound))
        if !items.isEmpty {
            newLines.append("\(spaces(keyIndent))\(key):")
            for item in items {
                newLines.append("\(spaces(itemIndent))- \(yamlQuoteIfNeeded(item))")
            }
        }
        // Drop the old block but keep everything after it.
        let tailStart = blockRange.upperBound + 1
        if tailStart < lines.count {
            newLines.append(contentsOf: lines.suffix(from: tailStart))
        }
        return newLines.joined(separator: "\n")
    }

    private static func spliceNewKey(
        lines: [String],
        insertAfterLineIndex: Int,
        key: String,
        items: [String],
        keyIndent: Int,
        itemIndent: Int
    ) -> String {
        var newLines = Array(lines.prefix(insertAfterLineIndex + 1))
        newLines.append("\(spaces(keyIndent))\(key):")
        for item in items {
            newLines.append("\(spaces(itemIndent))- \(yamlQuoteIfNeeded(item))")
        }
        if insertAfterLineIndex + 1 < lines.count {
            newLines.append(contentsOf: lines.suffix(from: insertAfterLineIndex + 1))
        }
        return newLines.joined(separator: "\n")
    }

    private static func appendScaffold(
        yaml: String,
        platform: String,
        key: String,
        items: [String]
    ) -> String {
        var trimmed = yaml
        // Ensure exactly one trailing newline before the appended block,
        // so the scaffold sits on its own line cleanly.
        while trimmed.hasSuffix("\n\n") {
            trimmed.removeLast()
        }
        if !trimmed.isEmpty && !trimmed.hasSuffix("\n") {
            trimmed.append("\n")
        }
        var lines: [String] = []
        if !trimmed.isEmpty {
            lines.append("")  // blank separator
        }
        lines.append("\(platform):")
        lines.append("  \(key):")
        for item in items {
            lines.append("    - \(yamlQuoteIfNeeded(item))")
        }
        lines.append("")  // trailing newline so subsequent edits append cleanly
        return trimmed + lines.joined(separator: "\n")
    }

    // MARK: - YAML scanning helpers

    private static func leadingSpaces(_ line: String) -> Int {
        var n = 0
        for c in line {
            if c == " " { n += 1 } else { break }
        }
        return n
    }

    /// Find the first line whose trimmed content equals `header` AND whose
    /// leading-space count equals `indent`. Comment-only and blank lines
    /// are skipped. Returns the line's index or `nil`.
    private static func firstIndex(
        of lines: [String],
        headerLineEqualTo header: String,
        indent: Int
    ) -> Int? {
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if leadingSpaces(line) == indent && trimmed == header {
                return i
            }
        }
        return nil
    }

    private static func spaces(_ n: Int) -> String {
        String(repeating: " ", count: n)
    }

    /// Quote a YAML scalar if it contains characters that the parser would
    /// otherwise interpret as structure (colon, hash, leading at-sign, etc.).
    /// Plain alphanumeric IDs (the common case for Slack channel IDs and
    /// Telegram numeric chat IDs) are emitted unquoted.
    private static func yamlQuoteIfNeeded(_ raw: String) -> String {
        if raw.isEmpty { return "''" }
        let needsQuoting = raw.contains(":")
            || raw.contains("#")
            || raw.contains("&")
            || raw.contains("*")
            || raw.contains(">")
            || raw.contains("|")
            || raw.first == "@"
            || raw.first == "-"
            || raw.first == " "
            || raw.last == " "
            || raw.first == "\""
            || raw.first == "'"
        if !needsQuoting { return raw }
        // Single-quote, escaping any embedded single quotes by doubling.
        let escaped = raw.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }
}
