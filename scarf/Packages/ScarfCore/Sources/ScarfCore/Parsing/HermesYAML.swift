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
    /// The dotted paths whose scalars SCARF ITSELF writes, and which are
    /// therefore decoded with ``YAMLScalar/unquote(_:)`` — the writers'
    /// own inverse — rather than with ``stripYAMLQuotes(_:)``.
    ///
    /// **Round-4 decision 10.** `YAMLScalar.unquote`'s doc called itself
    /// "the single decoder every Scarf-written scalar is read back
    /// through", and for these blocks it was not true: they are emitted by
    /// `PowerSettingsWriter` through `YAMLScalar.quoteIfNeeded` (which
    /// escapes `\\`, `\n`, `\xNN`, `\uNNNN` inside double quotes) and read
    /// back through `stripYAMLQuotes`, which hands a double-quoted BODY
    /// back verbatim — so a pattern containing a backslash came back
    /// doubled and grew one `\` per save, exactly the defect P32 found in
    /// `ProfileRoutesWriter`.
    ///
    /// **Per-KEY, not global.** `stripYAMLQuotes` stays the rule everywhere
    /// else on purpose: it reads arbitrary HERMES-written config.yaml
    /// values, where widening the escape table would change the meaning of
    /// every unrelated `\` in the file. Opt a path in only when Scarf is
    /// the writer.
    ///
    /// Writers, cited:
    /// * `agent.reasoning_overrides` — `PowerSettingsWriter
    ///   .setReasoningOverrides(in:pairs:capabilities:)` →
    ///   `GatewayConfigWriter.setMapChecked`, which puts BOTH the key and
    ///   the value through `YAMLScalar.quoteIfNeeded`. Hence the map arm
    ///   below decodes both halves.
    /// * `model_catalog.excluded_providers` — `PowerSettingsWriter
    ///   .setExcludedProviders(in:providers:capabilities:)` →
    ///   `GatewayConfigWriter.setListChecked`.
    ///
    /// **`gateway.multiplex_profile_allowlist` is deliberately NOT here.**
    /// The round-4 finding listed it as a third Scarf-written block; it is
    /// not one. Scarf READS it (`HermesConfig+YAML.multiplexProfileAllowlist`,
    /// and `SettingsViewModel.multiplexProfileAllowlistWarning` on top of
    /// that) and writes only the sibling BOOL `multiplex_profiles`, through
    /// `hermes config set` — a repo-wide grep for the key finds no writer at
    /// either spelling. Opting a Hermes-written-only list into the wider
    /// escape table is the exact widening the paragraph above refuses. If a
    /// writer ever lands, add both spellings here in the same commit.
    static let scarfWrittenMapPaths: Set<String> = ["agent.reasoning_overrides"]
    static let scarfWrittenListPaths: Set<String> = ["model_catalog.excluded_providers"]

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
        /// Every path this walk has already WRITTEN — a section header it
        /// opened, a flow map or flow list it parsed, or a scalar it assigned.
        /// The last-wins purge below fires only on a path already in here,
        /// which is what "this key appears twice" actually means. Recording
        /// only the HEADERS was P37's own bug: the flow-list branch wrote
        /// `lists[path]` and `continue`d without recording, so a later block
        /// header at the same path read as a first open, the purge was
        /// skipped, and `toolsets: [a]` + `toolsets:\n  - b` concatenated.
        var writtenPaths: Set<String> = []
        /// Paths whose LEAF key literally contains a `.` — a flat dotted key
        /// (`gateway.enabled: true`) rather than a nesting of `gateway:` +
        /// `enabled:`. PyYAML keeps such a key as an INDEPENDENT top-level
        /// key alongside a `gateway:` mapping (probed:
        /// `{"gateway": {"port": 2}, "gateway.enabled": true}` for a file with
        /// two `gateway:` blocks and a `gateway.enabled` line between them),
        /// so the last-wins purge must never sweep it just because it shares
        /// the `gateway.` prefix. P37 already caught the FIRST-open case; the
        /// re-open case was still wrong.
        var dottedLiteralPaths: Set<String> = []
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
                        // last continuation line. Decision 10's opt-in
                        // applies here too — the same key must not decode
                        // one way folded and another way on one line.
                        maps[parent.path, default: [:]][parent.key] =
                            scarfWrittenMapPaths.contains(parent.path)
                            ? YAMLScalar.unquote(joined)
                            : stripYAMLQuotes(joined)
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
                let path = currentPath()
                guard !path.isEmpty else { continue }
                // Decision 10: a list Scarf itself writes is decoded with
                // the writers' own inverse — see `scarfWrittenListPaths`.
                let stripped = scarfWrittenListPaths.contains(path)
                    ? YAMLScalar.unquote(item)
                    : stripYAMLQuotes(item)
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
            guard let span = blockKeySpan(in: trimmed) else { continue }
            let rawKeySpan = String(span.key)
            if let quote = rawKeySpan.first, quote == "'" || quote == "\"" {
                var raw = String(rawKeySpan.dropFirst().dropLast())
                if quote == "'" {
                    raw = raw.replacingOccurrences(of: "''", with: "'")
                }
                // Decision 10, the KEY half. A single-quoted key is already
                // fully decoded above (`''` is that style's ONE escape); a
                // DOUBLE-quoted one was taken verbatim, so a key Scarf wrote
                // through `YAMLScalar.quoteIfNeeded` — which escapes `\\`,
                // `\n` and `\xNN`/`\uNNNN` — came back with its escapes
                // intact and grew one `\` per save. Re-decode it with the
                // writers' own inverse, but ONLY under a path Scarf writes
                // (`scarfWrittenMapPaths`), because the same token under a
                // Hermes-written block must keep reading as it always has.
                if quote == "\"", scarfWrittenMapPaths.contains(currentPath()) {
                    key = YAMLScalar.unquote("\"" + raw + "\"")
                } else {
                    key = raw
                }
                afterColon = String(span.afterColon).trimmingCharacters(in: .whitespaces)
            } else {
                // Plain (unquoted) key. YAML's `key: value` separator is a
                // colon followed by whitespace (or end-of-line); a colon NOT
                // followed by whitespace is part of the key itself — PyYAML
                // emits Ollama-style ids like `llama3:8b: high` unquoted.
                // Splitting at the first bare colon used to shear that into
                // key "llama3" + value "8b: high".
                key = rawKeySpan.trimmingCharacters(in: .whitespaces)
                afterColon = String(span.afterColon).trimmingCharacters(in: .whitespaces)
            }

            let path = currentPath(joinedWith: key)
            if key.contains(".") { dottedLiteralPaths.insert(path) }
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
                //
                // P32: last-wins is a property of the whole MAPPING, not of
                // the keys that happen to be repeated. PyYAML replaces the
                // first block outright, so a sibling that appears ONLY in
                // the first block is gone on the host — Scarf kept it and
                // rendered a value Hermes does not have. Purge the earlier
                // block's descendants (`values` and `maps` as well as
                // `lists`) as the second one opens.
                //
                // P37: only on a path already WRITTEN, which `writtenPaths`
                // decides — the purge used to run on EVERY header, and the
                // comment said it was a no-op on a fresh one. It was not: a
                // flat dotted key (`gateway.enabled: true`, which PyYAML
                // keeps as a key of its own ALONGSIDE a `gateway:` mapping)
                // matches the `gateway.` descendant prefix, so the FIRST
                // opening of `gateway:` deleted it.
                //
                // P38: the purge dropped the earlier block's DESCENDANTS but
                // not the block's own `values[path]` / `maps[path]`, so
                // `HermesConfig+YAML.sharedPlatformScalar`'s
                // `maps[section]?[key]` fallback still read the FIRST
                // `slack:` block's `require_mention` on a file with two of
                // them. And the descendant sweep still ate a flat dotted
                // sibling on the re-open — see `dottedLiteralPaths`.
                if !writtenPaths.insert(path).inserted {
                    lists.removeValue(forKey: path)
                    values.removeValue(forKey: path)
                    maps.removeValue(forKey: path)
                    let staleDescendant = path + "."
                    for key in values.keys
                    where key.hasPrefix(staleDescendant) && !dottedLiteralPaths.contains(key) {
                        values.removeValue(forKey: key)
                    }
                    for key in maps.keys
                    where key.hasPrefix(staleDescendant) && !dottedLiteralPaths.contains(key) {
                        maps.removeValue(forKey: key)
                    }
                    for key in lists.keys
                    where key.hasPrefix(staleDescendant) && !dottedLiteralPaths.contains(key) {
                        lists.removeValue(forKey: key)
                    }
                }
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
                maps[path] = parseFlatFlowMap(inner, unquoting: scarfWrittenMapPaths.contains(path)) ?? [:]
                writtenPaths.insert(path)
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
                lists[path] = parseFlatFlowList(inner, unquoting: scarfWrittenListPaths.contains(path))
                writtenPaths.insert(path)
                continue
            }

            values[path] = afterColon
            writtenPaths.insert(path)
            lastScalarPath = path

            // Also record as a map entry under the parent so blocks like
            // `terminal.docker_env` are accessible as `[String: String]`
            // without a separate scan.
            if !stack.isEmpty {
                let parentPath = currentPath()
                // Decision 10, the VALUE half — see `scarfWrittenMapPaths`.
                maps[parentPath, default: [:]][key] = scarfWrittenMapPaths.contains(parentPath)
                    ? YAMLScalar.unquote(afterColon)
                    : stripYAMLQuotes(afterColon)
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
    /// line: the first colon followed by a SPACE or end-of-line. Colons
    /// with any other successor are part of the key (`llama3:8b: high`).
    ///
    /// A space, not "whitespace": PyYAML's scanner refuses a TAB after the
    /// value indicator (`k:\tv`, and `k:\t` alone, are both ScannerError;
    /// 6.0.3), so a tab-separated line is not a row Hermes can load — it is
    /// a document Hermes discards whole (`gateway/config.py:775-791` @
    /// `v2026.9.7`). Reading it as a row was P42c's finding.
    ///
    /// Public so every reader that has to decide "is this line a `key:`
    /// row, and where does the key end?" uses ONE rule — the parser here,
    /// `GatewayConfigWriter.flowPairSeparatorIndex`'s block-style sibling,
    /// and `PlatformsViewModel.computeConfiguredPlatforms`. A plain
    /// `firstIndex(of: ":")` disagrees with all three on a key that
    /// contains a colon.
    public static func plainKeySeparatorIndex(in trimmed: String) -> String.Index? {
        var i = trimmed.startIndex
        while i < trimmed.endIndex {
            if trimmed[i] == ":" {
                let next = trimmed.index(after: i)
                // Space or end of line only — a TAB after the value
                // indicator is a PyYAML ScannerError even for a plain key
                // (`k:\tv`, and `k:\t` alone; PyYAML 6.0.3), so `k:\tv` is
                // not a row, it is a document Hermes cannot load.
                if next == trimmed.endIndex || trimmed[next] == " " {
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
    ///
    /// `unquoting` is decision 10's per-key opt-in, threaded down from the
    /// PATH. P46 finding 7: the flow arms decoded with `stripYAMLQuotes`
    /// unconditionally, so `excluded_providers: ["c\x41d"]` came back as the
    /// literal `c\x41d` while the block form of the same key came back as
    /// `cAd` — one key, two answers, decided by which shape the host's
    /// config.yaml happened to use.
    private static func parseFlatFlowMap(_ inner: String, unquoting: Bool = false) -> [String: String]? {
        let body = inner.trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return [:] }
        if body.contains("{") || body.contains("[") { return nil }
        var result: [String: String] = [:]
        for part in splitFlowEntries(body) {
            let entry = part.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty { continue }
            guard let (k, v) = splitFlowEntry(entry, unquoting: unquoting), !k.isEmpty, !v.isEmpty else { return nil }
            result[k] = v
        }
        return result
    }

    /// Parse the inside of a single-line flow list (`"work", 'personal', x`)
    /// into trimmed, quote-stripped items. Handles both quoted and bare
    /// entries and arbitrary internal spacing; empty entries (from `[]` or a
    /// stray trailing comma) are dropped. Shared by `parseNestedYAML`'s
    /// inline-array handling and `ProjectSkillsScanner.parseTrustedProjectDirs`.
    /// `unquoting` is decision 10's per-key opt-in — see ``parseFlatFlowMap``.
    /// It defaults to false so the one external caller
    /// (`ProjectSkillsScanner.parseTrustedProjectDirs`, a key Scarf does not
    /// write through ``YAMLScalar``) keeps the rule that applies everywhere else.
    ///
    /// P46b: the split is QUOTE-AWARE. A bare `inner.split(separator: ",")`
    /// cut inside a quoted scalar, so PyYAML's one-item `["a,b"]` came back
    /// as the two items `"a` and `b"` — and, once ``stripYAMLQuotes`` had
    /// eaten the stray quotes, as the plausible-looking `["a", "b"]` that
    /// nothing downstream could tell from a real pair. Verified against
    /// PyYAML 6.0.3. P46 made the flow path authoritative for decision 10's
    /// `unquote` opt-in, which is what makes a comma inside a quoted entry
    /// reachable in practice.
    public static func parseFlatFlowList(_ inner: String, unquoting: Bool = false) -> [String] {
        splitFlowEntries(inner).compactMap { part in
            let raw = part.trimmingCharacters(in: .whitespaces)
            let value = unquoting ? YAMLScalar.unquote(raw) : stripYAMLQuotes(raw)
            return value.isEmpty ? nil : value
        }
    }

    /// Split flow content on the commas that are actually SEPARATORS — i.e.
    /// not the ones inside a quoted scalar.
    ///
    /// The quote scan is ``closingQuoteIndex``, the same one
    /// ``splitFlowEntry`` uses for a quoted KEY, so `'a,b'` (single-quoted,
    /// `''` doubling) and `"a\",b"` (double-quoted, backslash escapes) are
    /// both one entry here and one entry to PyYAML. An UNCLOSED quote is not
    /// an error this function may invent: the scan falls through to the end
    /// of the content and the remainder is one entry, which leaves the
    /// caller's own validation (`parseFlatFlowMap` returning nil, or
    /// `stripYAMLQuotes` keeping the stray quote) to decide, exactly as
    /// before.
    ///
    /// A quote only OPENS a scalar where a scalar can BEGIN — at the start
    /// of the content, after a `,` (a new entry) or after a `:` (a map
    /// entry's value). Everywhere else it is an ordinary character in a
    /// plain scalar, the way YAML reads it: PyYAML 6.0.3 loads `[a'b, c]` as
    /// two PLAIN scalars, `["a'b", "c"]`, so an apostrophe inside a bare word
    /// must not swallow the separator after it — and `{a: "x,y"}` must still
    /// have its value quoted, which is why "start of an entry" alone is the
    /// wrong test.
    ///
    /// Empty entries survive as empty substrings; both callers drop them.
    static func splitFlowEntries(_ inner: String) -> [Substring] {
        var out: [Substring] = []
        var start = inner.startIndex
        var i = inner.startIndex
        var previousSignificant: Character?
        while i < inner.endIndex {
            let c = inner[i]
            let opensScalar = previousSignificant == nil
                || previousSignificant == ","
                || previousSignificant == ":"
            if opensScalar, c == "'" || c == "\"" {
                let body = inner[inner.index(after: i)...]
                guard let close = closingQuoteIndex(in: body, quote: c) else { break }
                i = inner.index(after: close)
                previousSignificant = c
                continue
            }
            if c == "," {
                out.append(inner[start..<i])
                i = inner.index(after: i)
                start = i
                previousSignificant = ","
                continue
            }
            if c != " ", c != "\t" { previousSignificant = c }
            i = inner.index(after: i)
        }
        out.append(inner[start...])
        return out
    }

    /// Split one `key: value` flow entry, honoring a quoted key that may
    /// contain colons (`'llama3:8b': high`).
    /// `unquoting` is decision 10's per-key opt-in — see ``parseFlatFlowMap``.
    /// A DOUBLE-quoted key under an opted-in path is decoded the way the
    /// block-form key path decodes it (`YAMLScalar.unquote` over the
    /// re-quoted body), which is what makes `{"a\tb": high}` and its block
    /// spelling agree.
    private static func splitFlowEntry(_ entry: String, unquoting: Bool = false) -> (String, String)? {
        func decode(_ raw: String) -> String {
            unquoting ? YAMLScalar.unquote(raw) : stripYAMLQuotes(raw)
        }
        if let quote = entry.first, quote == "'" || quote == "\"" {
            let body = entry.dropFirst()
            guard let close = closingQuoteIndex(in: body, quote: quote) else { return nil }
            var key = String(body[body.startIndex..<close])
            if quote == "'" {
                key = key.replacingOccurrences(of: "''", with: "'")
            } else if unquoting {
                key = YAMLScalar.unquote("\"" + key + "\"")
            }
            let rest = body[body.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix(":") else { return nil }
            let value = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            return (key, decode(value))
        }
        guard let colon = entry.firstIndex(of: ":") else { return nil }
        let key = String(entry[entry.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, decode(value))
    }

    /// Index of the closing quote in `body` (which starts just AFTER the
    /// opening quote). Single-quoted YAML escapes an embedded quote by
    /// doubling (`''`), so skip doubled pairs; DOUBLE-quoted YAML escapes
    /// with a backslash (`\\"`, and `\\\\` for the backslash itself), so skip
    /// the character after any backslash.
    ///
    /// P41b: the double-quoted half was missing, and it is the style
    /// ``YAMLScalar/doubleQuoted(_:)`` emits for a key carrying a control
    /// character — a key that also contains a `"` came back with its span
    /// cut at the escaped quote, the `rest.hasPrefix(":")` guard then failed,
    /// and `parseNestedYAML` DROPPED the row. Under
    /// `agent.reasoning_overrides` that row then vanished from the editor
    /// and the next `setReasoningOverrides` save deleted it from the file.
    private static func closingQuoteIndex(in body: Substring, quote: Character) -> Substring.Index? {
        var i = body.startIndex
        while i < body.endIndex {
            if quote == "\"", body[i] == "\\" {
                // `\X` is one escape token: skip the backslash AND whatever
                // follows it, so an escaped quote does not close the span.
                // A trailing lone backslash falls off the end and the scan
                // returns nil, which callers read as "not a quoted key".
                let next = body.index(after: i)
                if next == body.endIndex { return nil }
                i = body.index(after: next)
                continue
            }
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

    /// Split a block-style `key: value` line (already trimmed of indentation)
    /// into the key's RAW span — quotes included, exactly as written — and
    /// everything after the separator colon. Returns nil when the line is not
    /// a `key: value` row at all.
    ///
    /// The one block-style key scanner in the repo. `parseNestedYAML` uses it
    /// and so does `HermesFileService`'s MCP-entry reader, which used to split
    /// on `trimmed.firstIndex(of: ":")` with no quote awareness: an env or
    /// header name containing a colon was WRITTEN correctly (`'A: B': v`, via
    /// ``YAMLScalar/quoteIfNeeded(_:)``) and read back as the key `'A` with the
    /// value `B': v`, which the next save then persisted.
    ///
    /// A quoted key ends at its closing quote, and the colon after it must be
    /// followed by a SPACE or end the line: PyYAML's parser demands a
    /// space after the value indicator whenever the key is not plain, so
    /// `'a':b` raises `ParserError` while `'a': b` and `'a':` both load
    /// (verified against PyYAML 6.0.3). Accepting `'a':b` here meant reading
    /// a row Hermes cannot load at all. A TAB is NOT a space, on either side
    /// of the colon — P41b accepted one "for symmetry with the plain arm",
    /// but the plain arm was wrong too: `'q':\tv`, `"q":\tv`, `plain:\tv`,
    /// a bare `'q':\t` and `'q'\t: v` are every one of them ScannerError
    /// (6.0.3), while `'q' : v` loads. Spaces only, both arms. A PLAIN key
    /// ends at the first colon followed by a space or end-of-line, per
    /// ``plainKeySeparatorIndex(in:)`` — there a colon with a non-space
    /// successor belongs to the key (`llama3:8b: high`).
    public static func blockKeySpan(
        in trimmed: String
    ) -> (key: Substring, afterColon: Substring)? {
        if let quote = trimmed.first, quote == "'" || quote == "\"" {
            let body = trimmed.dropFirst()
            guard let close = closingQuoteIndex(in: body, quote: quote) else { return nil }
            let afterQuote = body.index(after: close)
            let rest = body[afterQuote...].drop(while: { $0 == " " })
            guard rest.first == ":" else { return nil }
            let afterColon = rest.dropFirst()
            // PyYAML: after a non-plain key the `:` needs a SPACE or the end
            // of the line. `'a':b` is a ParserError, not a row.
            //
            // A TAB is not a space here. PyYAML's scanner refuses a tab in
            // this position outright — `'q':\tv`, `"q":\tv` and even a bare
            // `'q':\t` are all ScannerError ("found character '\t' that
            // cannot start any token"), verified against PyYAML 6.0.3 — so a
            // tab-separated row is one Hermes cannot load at all, and
            // accepting it meant Scarf displayed a row that makes Hermes
            // discard the whole config.yaml layer
            // (`gateway/config.py:775-791` @ `v2026.9.7`). Same for a tab
            // BEFORE the colon: `'q'\t: v` is a ScannerError too, while
            // `'q' : v` loads — hence spaces only on both sides.
            if let next = afterColon.first, next != " " { return nil }
            return (trimmed[trimmed.startIndex..<afterQuote], afterColon)
        }
        guard let colonIdx = plainKeySeparatorIndex(in: trimmed) else { return nil }
        return (
            trimmed[trimmed.startIndex..<colonIdx],
            trimmed[trimmed.index(after: colonIdx)...]
        )
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
