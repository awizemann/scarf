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
    public static func parseNestedYAML(_ rawYAML: String) -> ParsedYAML {
        // A leading U+FEFF is in NEITHER `.whitespaces` nor
        // `.whitespacesAndNewlines` (exactly as `\r` was not), so it stayed
        // glued to the first line and the file's FIRST top-level section —
        // `agent:`, `slack:`, whatever sorts first — parsed as a key named
        // "\u{FEFF}agent" whose whole subtree was then invisible. Strip it
        // once, here, at the reader boundary.
        let yaml = YAMLScalar.strippingBOM(rawYAML)
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
        // Where the most recent plain/quoted scalar landed, so folded
        // continuation lines can be JOINED back onto it instead of dropped.
        // PyYAML wraps long plain and single-quoted scalars at ~80 columns;
        // reading only the first physical line silently truncates the value
        // (a quick-command shell pipeline losing its trailing guard was the
        // worst case). YAML folding joins a single line break as one space.
        var lastScalarPath: String?
        var lastScalarParent: (path: String, key: String)?

        func currentPath(joinedWith child: String? = nil) -> String {
            var parts = stack.map(\.name)
            if let child { parts.append(child) }
            return parts.joined(separator: ".")
        }

        // CRLF: split on "\n" leaves a trailing "\r" on every line, and
        // `.whitespaces` does NOT contain it — so `slack:\r` failed the
        // `key: value` separator scan (the char after the colon was "\r",
        // not a space or end-of-line) and EVERY section header in a CRLF
        // config.yaml was silently dropped, taking its whole subtree with
        // it. Strip it per line; the parser has no other use for it.
        let rawLines = yaml.components(separatedBy: "\n")
        for rawLine in rawLines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            // Skip comment-only and blank lines but preserve indent semantics.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count
            let isListItem = trimmed.hasPrefix("- ")

            // Folded/continued scalar line (see `lastScalarIndent`) — not a
            // key, not a list item, and must not touch the stack. Join it
            // onto the scalar it continues (single space, per YAML line
            // folding) so an ~80-column PyYAML wrap never truncates the
            // value. A continuation can freely contain `key: value` text —
            // in real YAML a key line can never sit deeper than the sibling
            // scalar before it (see the `lastScalarIndent` note above), so
            // this cannot swallow a genuine nested block body.
            if !isListItem, let last = lastScalarIndent, indent > last {
                if let path = lastScalarPath {
                    let joined = (values[path].map { $0.isEmpty ? trimmed : $0 + " " + trimmed }) ?? trimmed
                    values[path] = joined
                    if let parent = lastScalarParent {
                        // Re-strip quotes on the FULL value: a quoted scalar
                        // folded across lines only closes its quote on the
                        // last continuation line.
                        maps[parent.path, default: [:]][parent.key] = stripYAMLQuotes(joined)
                    }
                }
                continue
            }

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
                lastScalarPath = nil
                lastScalarParent = nil
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
                // Plain (unquoted) key. YAML's `key: value` separator is a
                // colon followed by whitespace (or end-of-line); a colon NOT
                // followed by whitespace is part of the key itself — PyYAML
                // emits Ollama-style ids like `llama3:8b: high` unquoted.
                // Splitting at the first bare colon used to shear that into
                // key "llama3" + value "8b: high".
                guard let colonIdx = plainKeySeparatorIndex(in: trimmed) else { continue }
                key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                afterColon = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            }

            let path = currentPath(joinedWith: key)
            lastScalarIndent = indent
            lastScalarPath = nil
            lastScalarParent = nil

            if afterColon.isEmpty || isBlockScalarHeader(afterColon)
                || afterColon.hasPrefix("#") {
                // Section header or empty-valued key — push onto stack so
                // children nest.
                //
                // `#` — a section header carrying only a trailing comment
                // (`agent:  # note`) still opens a block.
                //
                // `|`/`>` plus any chomping or explicit-indent indicator
                // (`|-`, `|+`, `>-`, `>+`, `|2`, `|2-`) opens a block
                // SCALAR. Only bare `|` / `>` were recognised before, so a
                // `system_prompt: |-` header was read as the VALUE and every
                // deeper body line was then folded onto it — the key came
                // back as the literal string "|- role: assistant tone: dry".
                // Children legitimately sit deeper, so the continuation
                // guard is disarmed until the next scalar.
                // PyYAML is LAST-WINS on a duplicate key, so a file that
                // already carries the same block twice (which is exactly
                // what the pre-P19 writers produced on a BOM'd config) must
                // render the SECOND block's list, not the two concatenated.
                // Scalars were already last-wins by assignment; bullets
                // appended. Drop the earlier block's items as this one opens.
                lists.removeValue(forKey: path)
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
            lastScalarPath = path

            // Also record as a map entry under the parent so blocks like
            // `terminal.docker_env` are accessible as `[String: String]`
            // without a separate scan.
            if !stack.isEmpty {
                let parentPath = currentPath()
                maps[parentPath, default: [:]][key] = stripYAMLQuotes(afterColon)
                lastScalarParent = (path: parentPath, key: key)
            }
        }
        return ParsedYAML(values: values, lists: lists, maps: maps)
    }

    /// True when `afterColon` is a YAML block-scalar header: `|` or `>`
    /// optionally followed by an explicit indentation indicator (a single
    /// digit 1-9) and/or a chomping indicator (`-` or `+`), in either
    /// order, and then nothing but an optional `# comment`.
    private static func isBlockScalarHeader(_ afterColon: String) -> Bool {
        guard let first = afterColon.first, first == "|" || first == ">" else { return false }
        var rest = Substring(afterColon.dropFirst())
        if let hash = rest.firstIndex(of: "#") { rest = rest[rest.startIndex..<hash] }
        let body = rest.trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return true }
        guard body.count <= 2 else { return false }
        var sawDigit = false
        var sawChomp = false
        for ch in body {
            if ch.isNumber && ch != "0" {
                if sawDigit { return false }
                sawDigit = true
            } else if ch == "-" || ch == "+" {
                if sawChomp { return false }
                sawChomp = true
            } else {
                return false
            }
        }
        return true
    }

    /// Index of the `key: value` separator colon in a trimmed plain-key
    /// line: the first colon followed by whitespace or end-of-line. Colons
    /// with a non-space successor are part of the key (`llama3:8b: high`).
    private static func plainKeySeparatorIndex(in trimmed: String) -> String.Index? {
        var i = trimmed.startIndex
        while i < trimmed.endIndex {
            if trimmed[i] == ":" {
                let next = trimmed.index(after: i)
                if next == trimmed.endIndex || trimmed[next] == " " || trimmed[next] == "\t" {
                    return i
                }
            }
            i = trimmed.index(after: i)
        }
        return nil
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
    /// A plain scalar reduced to the value PyYAML would have loaded:
    /// surrounding quotes removed and a trailing ` # comment` dropped.
    ///
    /// `parseNestedYAML` stores everything after `key: ` verbatim, so
    /// `enabled: false  # was true` arrives as `false  # was true` and
    /// `"false"` arrives with its quotes. Both are legal YAML for the
    /// scalar `false`, and both used to miss every typed reader's
    /// comparison — silently flipping a TRUE-by-default key back on, or
    /// defaulting an int. Use this before any typed comparison of a
    /// scalar; do NOT use it for free-form text where `#` can be part of
    /// the value (a prompt, a path, a colour).
    ///
    /// A comment is only recognised after whitespace (`a#b` is the value
    /// `a#b`, per YAML), and inside quotes nothing is a comment: for a
    /// quoted scalar the quoted span wins and any trailing text is
    /// discarded.
    public static func normalizedScalar(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote = trimmed.first, quote == "'" || quote == "\"" {
            // `closingQuoteIndex` skips a DOUBLED `''`, which is YAML's only
            // escape inside a single-quoted scalar and the one the writers
            // emit. `firstIndex(of:)` stopped at the first half of the pair,
            // so `'it''s'` read back as `it` — and the surviving half then
            // re-doubled on the next save.
            let body = trimmed.dropFirst()
            if let close = closingQuoteIndex(in: body, quote: quote) {
                let inner = String(body[body.startIndex..<close])
                return quote == "'"
                    ? inner.replacingOccurrences(of: "''", with: "'")
                    : inner
            }
        }
        var out = trimmed
        var i = out.startIndex
        while let hash = out[i...].firstIndex(of: "#") {
            if hash == out.startIndex {
                out = ""
                break
            }
            let before = out[out.index(before: hash)]
            if before == " " || before == "\t" {
                out = String(out[out.startIndex..<hash])
                break
            }
            i = out.index(after: hash)
            if i >= out.endIndex { break }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hermes's boolish token sets, applied to a RAW config.yaml scalar.
    /// `nil` = key absent, or a value in neither set (Hermes falls back to
    /// its own default there rather than guessing).
    ///
    /// Truthy `{1, true, yes, on}` / falsy `{0, false, no, off}` are
    /// `_TRUTHY_STRINGS` / `_FALSY_STRINGS` (`gateway/config.py:25-26`,
    /// v2026.9.7) as read by `_bool_token` (:29-32) — which does
    /// `str(value).strip().lower()`, hence `normalizedScalar` here (the raw
    /// parse keeps `true  # on` verbatim, and no literal comparison would
    /// ever match it). The same vocabulary is what PyYAML has already turned
    /// into real bools before any per-key reader runs, so this is the ONE
    /// boolean spelling in config.yaml — there is no per-key variant.
    public static func boolishValue(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        let v = normalizedScalar(raw).lowercased()
        if ["true", "1", "yes", "on"].contains(v) { return true }
        if ["false", "0", "no", "off"].contains(v) { return false }
        return nil
    }

    /// Strip one layer of surrounding quotes, reversing the writers' escape.
    ///
    /// The single-quoted un-doubling is load-bearing: the writers escape an
    /// embedded `'` by doubling it (YAML's only single-quote escape), and a
    /// reader that does not undo that grows one quote per save —
    /// `#it's` → `'#it''s'` → read back as `#it''s` → `'#it''''s'`, at which
    /// point PyYAML genuinely loads `#it''s` and the value on disk has
    /// CHANGED. `splitFlowEntry` and the quoted-key scan already un-doubled;
    /// these two readers were the asymmetric pair.
    public static func stripYAMLQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if first == "'" && last == "'" {
            return String(s.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        if first == "\"" && last == "\"" {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
