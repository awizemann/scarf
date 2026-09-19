import Foundation
import CryptoKit

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
    /// Paths whose LEAF key literally contains a `.` — a flat dotted key
    /// (`slack.enabled: true`) rather than a nesting of `slack:` +
    /// `enabled:`. PyYAML keeps such a key as an INDEPENDENT top-level key
    /// of the mapping, so it is NOT evidence that a `slack:` block exists.
    /// Round-6 P57 surfaced it from the parser's internals for
    /// ``HermesPlatformSharedKeys/bridgeSourcePrefix(platform:in:)``, which
    /// has to answer Hermes's `isinstance(section, dict)`
    /// (`gateway/config_loader.py:171-180` @ `v2026.9.7`) and was reading a
    /// flat `slack.enabled:` line as a block.
    public var dottedLiteralPaths: Set<String>

    /// For each ``dottedLiteralPaths`` member, how many enclosing BLOCK keys
    /// it sat under — 0 for a dotted key written at the top level, 1 for one
    /// written inside a single block, and so on.
    ///
    /// The depth is what says whether the dot CROSSES a section's boundary.
    /// `slack.enabled: true` at the top level (depth 0) is PyYAML's
    /// independent key `"slack.enabled"` and no `slack` dict exists; but
    /// `slack:` + `  a.b:` (depth 1) is `{"slack": {"a.b": …}}`, which IS a
    /// `slack` dict and which `platform_section` reads as the top-level
    /// block. The path alone cannot tell the two apart — both are the string
    /// `slack.a.b`-shaped prefix match — so the parser records the depth it
    /// alone knows. Round-6 P57b.
    public var dottedLiteralParentDepths: [String: Int]

    public init(
        values: [String: String] = [:],
        lists: [String: [String]] = [:],
        maps: [String: [String: String]] = [:],
        dottedLiteralPaths: Set<String> = [],
        dottedLiteralParentDepths: [String: Int] = [:]
    ) {
        self.values = values
        self.lists = lists
        self.maps = maps
        self.dottedLiteralPaths = dottedLiteralPaths
        self.dottedLiteralParentDepths = dottedLiteralParentDepths
    }
}

/// Entry points for Hermes-flavored YAML parsing. Stateless, pure
/// functions — no Foundation types that differ cross-platform.
public enum HermesYAML {
    /// The ONLY characters this parser may trim off a YAML token: SPACE and
    /// TAB. Round-5 decision 14.
    ///
    /// Foundation's `.whitespaces` is *Unicode* `Zs` plus tab, so it also
    /// contains U+00A0, U+1680, U+2000…U+200A, U+202F, U+205F and U+3000.
    /// PyYAML's scanner does not: its whitespace is `'\0 \t\r\n\x85  '`
    /// (`yaml/scanner.py`), and everything in the `Zs` list above is ORDINARY
    /// CONTENT to it — part of the plain scalar, the key, or the flow entry.
    /// Verified against PyYAML 6.0.3, every case loading cleanly and KEEPING
    /// the character:
    ///
    /// ```text
    /// model: gpt\u{A0}          -> {'model': 'gpt\xa0'}
    /// model: \u{A0}gpt          -> {'model': '\xa0gpt'}
    /// model: gpt\u{3000}        -> {'model': 'gpt　'}
    /// model: gpt\u{2009}        -> {'model': 'gpt '}
    /// model: gpt\u{1680}        -> {'model': 'gpt '}
    /// mo\u{A0}del: x            -> {'mo\xa0del': 'x'}
    /// model\u{A0}: x            -> {'model\xa0': 'x'}
    /// - a\u{A0}                 -> ['a\xa0']
    /// xs: [a\u{A0}, \u{A0}b]    -> ['a\xa0', '\xa0b']
    /// m: {k: v\u{A0}}           -> {'k': 'v\xa0'}
    /// model: gpt                -> {'model': 'gpt'}      (plain spaces DO go)
    /// ```
    ///
    /// The consequence of trimming them anyway was a silent edit of the
    /// user's file: `yaml.safe_dump` emits such a value BARE, so a value
    /// Hermes wrote rendered short in Scarf, and the next save persisted the
    /// trimmed form over the one the agent was actually using.
    ///
    /// TAB stays in the set although PyYAML refuses one in every position
    /// this parser would trim it from (`model: gpt\t` and `model:\tgpt` are
    /// both `ScannerError`, 6.0.3): such a document does not load at all —
    /// `load_config` discards the whole config.yaml layer
    /// (`gateway/config.py:775-791` @ `v2026.9.7`) — so trimming it decides
    /// nothing, and keeping it matches ``plainKeySeparatorIndex``'s existing
    /// note.
    ///
    /// Two characters go the OTHER way and are deliberately left alone:
    /// PyYAML treats NEL (U+0085) and U+2028 as LINE BREAKS and strips them,
    /// while neither is in `.whitespaces` — so this set is no worse than the
    /// one it replaces, and no Scarf writer emits either bare
    /// (``YAMLScalar/quoteIfNeeded`` quotes and escapes them).
    ///
    /// This is a PARSER rule. It is NOT the rule for a value NORMALISER that
    /// models a Python `.strip()` — ``normalizedScalar(_:)`` (and
    /// `HermesReasoningEffort.normalizedLevel`) keep the wider trim on
    /// purpose, because the Hermes readers they mirror call `.strip()` on the
    /// loaded string and Python's `str.strip()` DOES remove U+00A0 and the
    /// rest of the `Zs` block. See ``normalizedScalar(_:)``.
    static let yamlWhitespace = CharacterSet(charactersIn: " \t")

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
        var dottedLiteralParentDepths: [String: Int] = [:]
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
        // A `|` / `>` block scalar owns every following line indented deeper
        // than its key, VERBATIM — no comment skip, no list-item test, no
        // `key: value` scan. P57b: the header used to open a stack frame like
        // an empty section, so the body was parsed as YAML. Hermes's own docs
        // tell users to hand-edit `~/.hermes/config.yaml` with
        // `agent:\n  system_prompt: |` over a body full of `#####` and `- `
        // lines (`optional-skills/security/godmode/SKILL.md:136-148` @
        // `v2026.9.7`), and `agent.personalities.<name>.system_prompt` — which
        // ``HermesPersonalities/entries(fromConfigYAML:)`` reads — is the same
        // shape. The value was lost entirely and the body left phantom
        // `lists[…]` / `values[…]` entries behind it.
        var pendingBlock: PendingBlockScalar?
        func closePendingBlock() {
            guard let pending = pendingBlock else { return }
            pendingBlock = nil
            let rendered = pending.rendered
            values[pending.path] = rendered
            if let parentPath = pending.parentPath {
                // A block scalar is never quoted and never carries a trailing
                // comment, so neither decoder runs on it — the body IS the
                // value, which is the whole point of the style.
                maps[parentPath, default: [:]][pending.key] = rendered
            }
        }

        // `components(separatedBy:)` yields a PHANTOM final "" for a
        // document that ends with its terminating newline. Outside a block
        // scalar it is skipped as blank and costs nothing; INSIDE one it is
        // appended as a body line, so a `+`-chomped scalar counts it as a
        // trailing blank and grows one spurious newline (`|+` over "a\n"
        // rendered "a\n\n" where PyYAML says "a\n"). Drop it at the source.
        var rawLines = yaml.components(separatedBy: "\n")
        if yaml.hasSuffix("\n") { rawLines.removeLast() }
        for rawLine in rawLines {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

            if var pending = pendingBlock {
                let lineIndent = line.prefix(while: { $0 == " " }).count
                let isBlank = line.trimmingCharacters(in: yamlWhitespace).isEmpty
                if isBlank || lineIndent > pending.keyIndent {
                    if !isBlank, pending.bodyIndent == nil {
                        // "The indentation of the first non-empty line", or the
                        // explicit indicator counted from the KEY's column.
                        pending.bodyIndent = pending.explicitIndent.map { pending.keyIndent + $0 }
                            ?? lineIndent
                    }
                    if let strip = pending.bodyIndent {
                        pending.lines.append(String(line.dropFirst(min(strip, line.count))))
                    } else {
                        // A blank line before the body's indent is known is a
                        // blank line, whatever spaces it carries.
                        pending.lines.append("")
                    }
                    pendingBlock = pending
                    continue
                }
                closePendingBlock()
            }
            // Blank lines are skipped but preserve indent semantics.
            let trimmed = line.trimmingCharacters(in: yamlWhitespace)
            if trimmed.isEmpty { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            // Folded/continued scalar line (see `lastScalarIndent`) — not a
            // key, not a list item, and must not touch the stack. Join it
            // onto the scalar it continues (single space, per YAML line
            // folding) so an ~80-column PyYAML wrap never truncates the
            // value. A continuation can freely contain `key: value` text —
            // in real YAML a key line can never sit deeper than the sibling
            // scalar before it (see the `lastScalarIndent` note above), so
            // this cannot swallow a genuine nested block body.
            //
            // P57: this test runs ABOVE the comment skip and ABOVE the
            // list-item test, because `yaml.dump` folds at column 80 with no
            // `width=` override (`utils.atomic_yaml_write` →
            // `yaml.dump(…, Dumper=IndentDumper, default_flow_style=False,
            // sort_keys=False, allow_unicode=True)`, `utils.py:262-271` @
            // `v2026.9.7`) and a fold point lands wherever the spaces are —
            // routinely leaving a continuation line that BEGINS with `- ` or
            // `#`. Below the two guards, `- ` was read as a list item (value
            // truncated, plus a phantom `lists[…]` entry at the enclosing
            // path) and `#` was dropped as a comment (value truncated, and a
            // single-quoted fold additionally lost its closing quote, so
            // `normalizedScalar` kept the dangling `'` and then cut the text
            // at the ` #` it could now see). Found with a PyYAML 6.0.3
            // oracle over a corpus of folded `yaml.dump` documents; the run's
            // counts are in the P57 section of the v0.21.1 decisions note.
            //
            // The `#` arm is NARROWER than the `- ` arm, and the emitter is
            // the reason: PyYAML never emits a PLAIN scalar whose
            // continuation begins with `#` (a `#` after a space forces a
            // quoting style — pinned by
            // `HermesP57FoldedContinuationTests.theEmitterNeverFoldsAPlainScalarOntoAHashLine`,
            // which re-measures it against the live emitter),
            // so a deeper `#` line can only be scalar CONTENT when the
            // scalar accumulated so far is an UNCLOSED quoted scalar.
            // Otherwise it is a genuine indented comment, which PyYAML
            // discards (`gateway:\n  port: 8080\n      # c\n  host: local`
            // loads as `{'gateway': {'port': 8080, 'host': 'local'}}`), and
            // so does the comment skip below.
            if let last = lastScalarIndent, indent > last,
               !trimmed.hasPrefix("#")
                   || (lastScalarPath.map { isOpenQuotedScalar(values[$0] ?? "") } ?? false) {
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

            // Skip comment-only lines (a continuation that reached here is a
            // real comment — see the P57 note above).
            if trimmed.hasPrefix("#") { continue }

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
                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: yamlWhitespace)
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
                afterColon = String(span.afterColon).trimmingCharacters(in: yamlWhitespace)
            } else {
                // Plain (unquoted) key. YAML's `key: value` separator is a
                // colon followed by whitespace (or end-of-line); a colon NOT
                // followed by whitespace is part of the key itself — PyYAML
                // emits Ollama-style ids like `llama3:8b: high` unquoted.
                // Splitting at the first bare colon used to shear that into
                // key "llama3" + value "8b: high".
                key = rawKeySpan.trimmingCharacters(in: yamlWhitespace)
                afterColon = String(span.afterColon).trimmingCharacters(in: yamlWhitespace)
            }

            let path = currentPath(joinedWith: key)
            if key.contains(".") {
                dottedLiteralPaths.insert(path)
                // `stack.count` is the number of enclosing block keys, which
                // is exactly the nesting depth the dot has to cross to be
                // evidence against a section. Counting components of the
                // parent STRING would be wrong the moment a dotted key is
                // itself opened as a header.
                dottedLiteralParentDepths[path] = stack.count
            }
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
                if let header = blockScalarHeader(afterColon) {
                    pendingBlock = PendingBlockScalar(
                        path: path,
                        parentPath: stack.isEmpty ? nil : currentPath(),
                        key: key,
                        keyIndent: indent,
                        folded: header.folded,
                        chomp: header.chomp,
                        explicitIndent: header.indent)
                    lastScalarIndent = nil
                    continue
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
                   .trimmingCharacters(in: yamlWhitespace)
                   .isEmpty
                   || afterColon[afterColon.index(after: close)...]
                       .trimmingCharacters(in: yamlWhitespace)
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
                   .trimmingCharacters(in: yamlWhitespace)
                   .isEmpty
                   || afterColon[afterColon.index(after: close)...]
                       .trimmingCharacters(in: yamlWhitespace)
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
        closePendingBlock()
        return ParsedYAML(values: values, lists: lists, maps: maps,
                          dottedLiteralPaths: dottedLiteralPaths,
                          dottedLiteralParentDepths: dottedLiteralParentDepths)
    }

    /// True when `text` opens a quoted scalar that has not closed yet — the
    /// one shape in which a continuation line beginning with `#` is CONTENT
    /// rather than a comment. `yaml.dump` quotes any scalar carrying a `#`
    /// after a space, so a folded `#` continuation always sits inside an
    /// open quote; a plain scalar never has one. Round-6 P57.
    static func isOpenQuotedScalar(_ text: String) -> Bool {
        guard let quote = text.first, quote == "'" || quote == "\"" else { return false }
        return closingQuoteIndex(in: text.dropFirst(), quote: quote) == nil
    }

    /// A `|` / `>` block scalar being accumulated by ``parseNestedYAML(_:)``.
    ///
    /// Chomping and folding follow PyYAML 6.0.3, probed rather than reasoned
    /// about (the fixtures are in `HermesP57bBlockScalarTests`):
    ///
    ///   - CLIP (no indicator) — trailing empty lines dropped, ONE final
    ///     newline kept, and none at all when the content is empty;
    ///   - STRIP (`-`) — no trailing newline;
    ///   - KEEP (`+`) — every trailing empty line survives as a newline.
    ///
    /// Folding (`>`) joins a single break between two lines at the base
    /// indent with a SPACE; `n` breaks (i.e. `n-1` blank lines) become `n-1`
    /// newlines; and a break on either side of a MORE-indented line stays a
    /// newline, which is YAML's escape hatch for keeping verse inside a
    /// folded scalar.
    struct PendingBlockScalar {
        let path: String
        let parentPath: String?
        let key: String
        /// Column of the KEY line — every deeper line belongs to the body.
        let keyIndent: Int
        let folded: Bool
        /// `-` strip, `+` keep, `nil` clip.
        let chomp: Character?
        /// Explicit indentation indicator, counted from ``keyIndent``.
        let explicitIndent: Int?
        /// Detected on the first non-empty body line unless explicit.
        var bodyIndent: Int?
        /// Body lines with ``bodyIndent`` removed, blank lines as `""`.
        var lines: [String] = []

        var rendered: String {
            var content = lines
            var trailingBlanks = 0
            while content.last?.isEmpty == true {
                content.removeLast()
                trailingBlanks += 1
            }
            let body = folded ? Self.fold(content) : content.joined(separator: "\n")
            switch chomp {
            case "-": return body
            case "+": return body + String(repeating: "\n", count: trailingBlanks + (body.isEmpty ? 0 : 1))
            default:  return body.isEmpty ? "" : body + "\n"
            }
        }

        private static func fold(_ content: [String]) -> String {
            var out = ""
            var breaks = 0
            var started = false
            var previousWasMoreIndented = false
            for line in content {
                if line.isEmpty { breaks += 1; continue }
                let moreIndented = line.first == " " || line.first == "\t"
                if !started {
                    // Leading blank lines are newlines, not folds.
                    out += String(repeating: "\n", count: breaks)
                } else if breaks > 0 {
                    out += String(repeating: "\n", count: breaks)
                } else {
                    out += (previousWasMoreIndented || moreIndented) ? "\n" : " "
                }
                out += line
                started = true
                previousWasMoreIndented = moreIndented
                breaks = 0
            }
            return out
        }
    }

    /// ``isBlockScalarHeader(_:)``'s parse, kept beside it so the two cannot
    /// disagree about what a header is.
    static func blockScalarHeader(_ afterColon: String) -> (folded: Bool, chomp: Character?, indent: Int?)? {
        guard isBlockScalarHeader(afterColon), let first = afterColon.first else { return nil }
        var rest = Substring(afterColon.dropFirst())
        if let hash = rest.firstIndex(of: "#") { rest = rest[rest.startIndex..<hash] }
        var chomp: Character?
        var indent: Int?
        for ch in rest.trimmingCharacters(in: yamlWhitespace) {
            if ch == "-" || ch == "+" { chomp = ch } else if let d = ch.wholeNumberValue { indent = d }
        }
        return (folded: first == ">", chomp: chomp, indent: indent)
    }

    /// True when `afterColon` is a YAML block-scalar header: `|` or `>`
    /// optionally followed by an explicit indentation indicator (a single
    /// digit 1-9) and/or a chomping indicator (`-` or `+`), in either
    /// order, and then nothing but an optional `# comment`.
    private static func isBlockScalarHeader(_ afterColon: String) -> Bool {
        guard let first = afterColon.first, first == "|" || first == ">" else { return false }
        var rest = Substring(afterColon.dropFirst())
        if let hash = rest.firstIndex(of: "#") { rest = rest[rest.startIndex..<hash] }
        let body = rest.trimmingCharacters(in: yamlWhitespace)
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
        let body = inner.trimmingCharacters(in: yamlWhitespace)
        if body.isEmpty { return [:] }
        if body.contains("{") || body.contains("[") { return nil }
        var result: [String: String] = [:]
        for part in splitFlowEntries(body) {
            let entry = part.trimmingCharacters(in: yamlWhitespace)
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
            let raw = part.trimmingCharacters(in: yamlWhitespace)
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
            let rest = body[body.index(after: close)...].trimmingCharacters(in: yamlWhitespace)
            guard rest.hasPrefix(":") else { return nil }
            let value = String(rest.dropFirst()).trimmingCharacters(in: yamlWhitespace)
            return (key, decode(value))
        }
        guard let colon = entry.firstIndex(of: ":") else { return nil }
        let key = String(entry[entry.startIndex..<colon]).trimmingCharacters(in: yamlWhitespace)
        let value = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: yamlWhitespace)
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
    ///
    /// **Round-5 decision 14: this one keeps the WIDE trim, and that is not
    /// an oversight.** ``yamlWhitespace`` narrowed the PARSER because PyYAML
    /// keeps U+00A0 and friends inside a scalar. This function is not the
    /// parser: it is the last step before a TYPED comparison, and every
    /// Hermes reader on the other side of that comparison calls Python's
    /// `.strip()` on the loaded string — `_bool_token`'s
    /// `str(value).strip().lower()` (`gateway/config.py:31` @
    /// `v2026.9.7`, the caller of ``boolishValue(_:)``),
    /// `_normalize_approval_mode`'s `mode.strip().lower()`
    /// (`tools/approval_context.py:207`) and `parse_reasoning_effort`'s
    /// `str(effort).strip().lower()` (`hermes_constants.py:884`). Python's
    /// `str.strip()` removes all 29 characters for which `c.isspace()` is
    /// true, U+00A0, U+1680, U+2000…U+200A, U+2028, U+2029, U+202F, U+205F
    /// and U+3000 among them — so `agent.reasoning_effort: high\u{A0}` reads
    /// as `high` to Hermes, and narrowing here would make Scarf claim the
    /// host ignores a value it honours. Parser trims and `.strip()` mirrors
    /// answer to different sources; do not unify them.
    public static func normalizedScalar(_ s: String) -> String {
        normalizedScalarCore(s, decodeEscapes: false)
    }

    /// ``normalizedScalar(_:)`` with the DOUBLE-quoted body's backslash
    /// escapes decoded — the Python `str` PyYAML actually loaded, before any
    /// `.strip()`.
    ///
    /// `normalizedScalar` hands a double-quoted body back VERBATIM because
    /// its other caller is about to RE-EMIT the value, and re-emitting a
    /// decoded body would change the file. A reader that is about to TYPE the
    /// value needs the opposite: `yaml.dump({"k": "true\t"})` emits
    /// `k: "true\t"` (PyYAML 6.0.3, probed), whose body is the seven
    /// characters `t r u e \ t` — so a verbatim compare recognises nothing
    /// and a true-by-default key reads ON for a host that has it OFF. The
    /// escape table is ``YAMLScalar/unquote(_:)``'s, the one PyYAML's own
    /// `ESCAPE_REPLACEMENTS` is mirrored in; there is not a second one.
    /// Round-6 P57b.
    ///
    /// Single-quoted bodies have no escapes but `''`, which
    /// ``normalizedScalar(_:)`` already undoubles, so this differs from it
    /// only inside double quotes.
    public static func unquotedScalar(_ s: String) -> String {
        normalizedScalarCore(s, decodeEscapes: true)
    }

    private static func normalizedScalarCore(_ s: String, decodeEscapes: Bool) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let quote = trimmed.first, quote == "'" || quote == "\"" {
            // `closingQuoteIndex` skips a DOUBLED `''`, which is YAML's only
            // escape inside a single-quoted scalar and the one the writers
            // emit. `firstIndex(of:)` stopped at the first half of the pair,
            // so `'it''s'` read back as `it` — and the surviving half then
            // re-doubled on the next save.
            //
            // It also skips a `\X` pair inside a DOUBLE-quoted span, so the
            // body handed to `YAMLScalar.unquote` below is the same span
            // PyYAML closed and re-wrapping it in `"` is lossless.
            let body = trimmed.dropFirst()
            if let close = closingQuoteIndex(in: body, quote: quote) {
                let inner = String(body[body.startIndex..<close])
                if quote == "'" {
                    return inner.replacingOccurrences(of: "''", with: "'")
                }
                return decodeEscapes ? YAMLScalar.unquote("\"" + inner + "\"") : inner
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
        // P57: the trim runs AFTER unquoting. `_bool_token` strips the STRING
        // PyYAML handed it, and for a quoted scalar that string is the quoted
        // BODY — so `require_mention: " false"` is `false` to Hermes while a
        // verbatim body compare recognised nothing and fell to the caller's
        // default. P41b's `HermesApprovalMode.normalize` lesson, two readers
        // over. The OUTER trim in `normalizedScalar` is unaffected.
        let v = strippedScalar(raw).lowercased()
        if ["true", "1", "yes", "on"].contains(v) { return true }
        if ["false", "0", "no", "off"].contains(v) { return false }
        // P57: PyYAML types a BARE scalar before any Hermes reader sees it,
        // and `str(int)` of the result is what `_bool_token` compares — so
        // `01`, `+1`, `0x1` and `0b1` are all the token `"1"` (truthy) and
        // `00`, `-0`, `0x0`, `0b0` are all `"0"` (falsy), none of which a
        // literal word compare matches. A QUOTED spelling is a `str` and
        // stays unrecognised, which is why this is gated on the raw scalar
        // being bare (`isQuotedScalar`), exactly as
        // ``mattermostRequireMention(configScalar:)`` gates its own int pass.
        if !isQuotedScalar(raw) { return pyYAMLIntBoolToken(strippedScalar(raw)) }
        return nil
    }

    /// ``normalizedScalar(_:)`` plus Python's `str.strip()` applied INSIDE the
    /// quotes — the exact input every Hermes boolish/typed reader compares.
    ///
    /// `_bool_token` is `str(value).strip().lower()`
    /// (`gateway/config.py:29-32` @ `v2026.9.7`) over the object PyYAML
    /// loaded, so for `k: " false"` the object is the `str` `" false"` and
    /// the token is `false`. ``normalizedScalar(_:)`` alone trims OUTSIDE the
    /// quotes and hands back the body verbatim, which is right for a value
    /// Scarf is going to re-emit and wrong for one it is about to TYPE.
    /// Round-6 P57.
    ///
    /// The trim is `.whitespacesAndNewlines` and deliberately not
    /// ``yamlWhitespace``: round-5 decision 14's invariant is that a PARSER
    /// trim and a `.strip()` MIRROR answer to different sources, and
    /// `str.strip()` removes all 29 characters for which `c.isspace()` holds,
    /// U+00A0 and the `Zs` block included.
    public static func strippedScalar(_ s: String) -> String {
        // P57b: ``unquotedScalar(_:)``, not ``normalizedScalar(_:)``. Python
        // strips the DECODED string; `"false\t"` is six characters plus a tab
        // to PyYAML and eight literal ones to a verbatim body compare, and
        // `yaml.dump` really does emit that spelling.
        unquotedScalar(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the scalar as written is QUOTED — i.e. a Python `str` to
    /// PyYAML, which no implicit resolver (bool or int) ever touches.
    static func isQuotedScalar(_ raw: String) -> Bool {
        guard let first = raw.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
        return first == "\'" || first == "\""
    }

    /// `_bool_token`'s answer for a BARE scalar PyYAML's `int` resolver
    /// claims: `true` for the value 1, `false` for 0, `nil` for anything
    /// else (including every other integer, whose `str()` is in neither
    /// token set, and every scalar the resolver leaves a string).
    ///
    /// Only 0 and 1 matter because `str(int)` is what is compared: `str(2)`
    /// is `"2"`, `str(-1)` is `"-1"`. A leading `+` is dropped by `str()`,
    /// a leading `-` is not — so `+1` is truthy and `-1` is unrecognised,
    /// while `-0` is `"0"` and falsy. Round-6 P57, on P53b's resolver port.
    static func pyYAMLIntBoolToken(_ scalar: String) -> Bool? {
        guard let isZero = pyYAMLIntIsZero(scalar) else { return nil }
        if isZero { return false }
        var body = Substring(scalar)
        if body.first == "-" { return nil }   // `str(-n)` keeps the sign
        if body.first == "+" { body = body.dropFirst() }
        let radix: Int
        let digits: Substring
        if body.hasPrefix("0b") { radix = 2; digits = body.dropFirst(2) }
        else if body.hasPrefix("0x") { radix = 16; digits = body.dropFirst(2) }
        else if body.first == "0", body.count > 1 { radix = 8; digits = body.dropFirst() }
        else { radix = 10; digits = body }
        // The sexagesimal alternative (`1:30`) cannot reach 1 — its first
        // group is `[1-9]` and it carries at least one `:XX` group, so the
        // value is at least 60 — and `Int(_:radix:)` rejects the colon here,
        // which is the same answer.
        guard let value = Int(digits.filter { $0 != "_" }, radix: radix) else { return nil }
        return value == 1 ? true : nil
    }

    // MARK: - Mattermost's own boolean vocabulary

    /// Hermes's mattermost falsy set. **Three words, not four** — `off` is
    /// NOT in it (`plugins/platforms/mattermost/adapter.py:504-505` @
    /// `v2026.9.7`:
    /// `str(self._extra_or_env("require_mention", …, "true")).lower() not in
    /// {"false", "0", "no"}`), while slack, discord and telegram all spell
    /// theirs `{"false", "0", "no", "off"}`. It is the ONE platform whose
    /// vocabulary differs, and the difference is load-bearing on the `.env`
    /// side, where no YAML resolver stands between the user's text and that
    /// comparison.
    static let mattermostFalsy: Set<String> = ["false", "0", "no"]

    /// The YAML 1.1 spellings PyYAML's bool resolver actually matches. Case
    /// is significant: `yes`/`Yes`/`YES` resolve, `yEs` does not and stays a
    /// string. Bare `y` / `n` are NOT in the resolver's regex either, whatever
    /// the YAML 1.1 spec says.
    static let pyYAMLTrue: Set<String> = ["yes", "Yes", "YES", "true", "True", "TRUE", "on", "On", "ON"]
    private static let pyYAMLFalse: Set<String> = ["no", "No", "NO", "false", "False", "FALSE", "off", "Off", "OFF"]

    /// `mattermost.require_mention` as read from a config.yaml scalar.
    ///
    /// This is ``boolishValue(_:)``'s job for every other key and it is the
    /// WRONG function here, twice over: its falsy set contains `off`, and it
    /// answers `nil` for anything outside its two lists, where Hermes answers
    /// TRUE for anything outside three words.
    ///
    /// The chain the value actually travels, which is what this mirrors:
    /// PyYAML loads the scalar into a Python object, `_extra_or_env` hands
    /// that object back untouched (`adapter.py:491-494`), and `str(...)` then
    /// stringifies it before the comparison at `:504-505`. So:
    ///
    ///   - a QUOTED scalar is a Python `str` and never a bool — `"OFF"` is
    ///     the string `OFF`, which is not one of the three words, so it is
    ///     **true**; bare `off` resolves to `False`, stringifies to `"false"`
    ///     and is **false**. The quotes are the whole difference;
    ///   - a bare bool spelling becomes `True`/`False` → `"true"`/`"false"`;
    ///   - an integer becomes `str(int)`, so `0` is false and `1`, `2`, `-1`
    ///     are true;
    ///   - anything else is its own text, true unless it IS one of the three.
    ///
    /// This is the same species of exception ``HermesConfig`` documents for
    /// `display.busy_ack_enabled` — a key whose effective vocabulary is not
    /// the universal boolish set because of what happens between the YAML and
    /// the comparison. Round-6 P53.
    ///
    /// - Returns: `nil` when the key is absent, so the caller can fall back
    ///   to `.env` (config.yaml wins where it is set — `adapter.py:491-494`).
    public static func mattermostRequireMention(configScalar raw: String?) -> Bool? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let quoted = (trimmed.first == "'" || trimmed.first == "\"")
        if !quoted {
            if pyYAMLTrue.contains(trimmed) { return true }
            if pyYAMLFalse.contains(trimmed) { return false }
            // `str()` of a Python int drops a leading `+` and any `_`
            // separators; only the value `0` stringifies to a falsy word.
            if let asInt = pyYAMLIntIsZero(trimmed) { return !asInt }
        }
        // A quoted scalar, or a plain one PyYAML leaves as text: compare the
        // STRING, which is what `str()` returns unchanged.
        return !mattermostFalsy.contains(normalizedScalar(trimmed).lowercased())
    }

    /// Whether a bare scalar is an integer to PyYAML's `int` resolver AND
    /// that integer is zero — `nil` when the resolver leaves it a string.
    ///
    /// `Int(_:)` is not that resolver. Round-6 P53b: `0x0` and `0b0` load as
    /// the int `0` (falsy to Hermes's three-word compare) while `Int("0x0")`
    /// is nil, so both fell through to the STRING compare and read TRUE — the
    /// inversion this whole reader exists to prevent. `0_0` and `0x_0` did
    /// the same via the `_` separators.
    ///
    /// The resolver, verbatim (`yaml/resolver.py`, the `tag:yaml.org,2002:int`
    /// pattern), is five alternatives after an optional sign: `0b[0-1_]+`,
    /// `0[0-7_]+` (octal — note there is NO `0o` form, so `0o0` really does
    /// stay a string and really is TRUE), `0|[1-9][0-9_]*`, `0x[0-9a-fA-F_]+`,
    /// and the sexagesimal `[1-9][0-9_]*(:[0-5]?[0-9])+`. The last cannot be
    /// zero, and every non-zero value is true under BOTH readings, so only
    /// the zero answer is load-bearing here.
    static func pyYAMLIntIsZero(_ scalar: String) -> Bool? {
        var body = Substring(scalar)
        if body.first == "+" || body.first == "-" { body = body.dropFirst() }
        func digitsAreZero(_ rest: Substring, of set: Set<Character>) -> Bool? {
            guard !rest.isEmpty else { return nil }
            var sawDigit = false
            for c in rest {
                if c == "_" { continue }
                guard set.contains(c) else { return nil }
                sawDigit = true
                if c != "0" { return false }
            }
            return sawDigit ? true : nil
        }
        if body.hasPrefix("0b") || body.hasPrefix("0B") {
            // PyYAML's pattern is lower-case `0b` only.
            guard body.hasPrefix("0b") else { return nil }
            return digitsAreZero(body.dropFirst(2), of: ["0", "1"])
        }
        if body.hasPrefix("0x") || body.hasPrefix("0X") {
            guard body.hasPrefix("0x") else { return nil }
            return digitsAreZero(body.dropFirst(2), of: Set("0123456789abcdefABCDEF"))
        }
        if body.first == "0", body.count > 1 {
            // Octal `0[0-7_]+`. The leading `0` is itself a digit, so an
            // all-underscore tail (`0_`) is still the value zero — which is
            // what `int("0_".replace("_", ""), 8)` gives.
            let tail = body.dropFirst()
            guard tail.allSatisfy({ Set("01234567_").contains($0) }) else { return nil }
            return !tail.contains(where: { $0 != "0" && $0 != "_" })
        }
        if body == "0" { return true }
        // `[1-9][0-9_]*` — never zero — and the sexagesimal form. Anything
        // that is an integer here is non-zero; anything else is a string,
        // and the string compare is the right answer for both.
        guard let first = body.first, first.isASCII, first.isNumber, first != "0" else { return nil }
        guard body.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "_" || $0 == ":" })
        else { return nil }
        return false
    }

    /// `MATTERMOST_REQUIRE_MENTION` as read from `.env`.
    ///
    /// No YAML resolver stands here — `get_scoped_secret`
    /// (`gateway/platforms/_shared.py:17-30`) returns the raw string, and
    /// `str()` leaves it alone — so the rule is the bare three-word set. An
    /// ABSENT key is the adapter's `"true"` default; an EMPTY one is the
    /// empty string, which is not one of the three words and is therefore
    /// **true** (`get_scoped_secret` returns `val if val is not None else
    /// default`, so `""` is a value, not a miss).
    ///
    /// `PlatformSetupHelpers.parseEnvBool` is a truthy ALLOWLIST and was the
    /// wrong shape for this key in both directions: it read `off`, `y` and
    /// `maybe` as false where Hermes reads all three as true.
    public static func mattermostRequireMention(envValue raw: String?) -> Bool {
        guard let raw else { return true }
        return !mattermostFalsy.contains(raw.lowercased())
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

    /// Stable hash of every parsed key under `tts` — global `tts.speed`,
    /// every named `tts.providers.<name>.*` (command/plugin providers Scarf
    /// has no typed field for), and everything the typed ``VoiceSettings``
    /// TTS fields already read — so a cache keyed off it invalidates on ANY
    /// `tts.*` edit, not just the handful of keys
    /// `HermesSpeechService.voiceFingerprint(provider:voice:)` models.
    ///
    /// **Deterministic, not `hashValue`.** Swift's `Hashable.hashValue` is
    /// randomized per process (`Hasher` seeds from a random value at
    /// launch) — the SAME config would fingerprint differently between two
    /// runs of the app, which would invalidate the on-disk TTS cache on
    /// every relaunch. This walks the three `ParsedYAML` dictionaries,
    /// keeps only `tts` and `tts.*` keys, serializes each into a
    /// single deterministic line, SORTS the lines (so key encounter order —
    /// which varies with the file's own layout — can't change the digest),
    /// and hashes the joined result with SHA-256. Sorting also makes the
    /// hash independent of which of `values`/`lists`/`maps` a given leaf
    /// happened to land in.
    public static func ttsSectionFingerprint(
        values: [String: String], lists: [String: [String]], maps: [String: [String: String]]
    ) -> String {
        func isTTSKey(_ key: String) -> Bool {
            key == "tts" || key.hasPrefix("tts.")
        }
        var lines: [String] = []
        for (key, value) in values where isTTSKey(key) {
            lines.append("v:\(key)=\(value)")
        }
        for (key, list) in lists where isTTSKey(key) {
            lines.append("l:\(key)=\(list.joined(separator: ","))")
        }
        for (key, map) in maps where isTTSKey(key) {
            let sortedPairs = map.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            lines.append("m:\(key)={\(sortedPairs)}")
        }
        lines.sort()
        let material = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
