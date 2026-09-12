import Foundation

/// Scalar-level YAML emission rules, shared by every config.yaml writer.
///
/// **Why one place.** Hermes wraps its config.yaml load in a bare
/// `except Exception` that logs "Failed to process config.yaml — falling
/// back to .env / gateway.json values." and CONTINUES
/// (`gateway/config.py:775-791` at `v2026.9.7`), so a single byte Scarf
/// emits wrong does not fail loudly — it silently discards the user's
/// ENTIRE config.yaml layer. Two writers with two quoting routines is two
/// chances to get that wrong, and P10 proved it: `GatewayConfigWriter`
/// quoted its map KEYS and `HermesFileService.replaceOrInsertSubMap` did
/// not, so a user-typed MCP `env:` / `headers:` key containing `{`, `[`,
/// `: `, a tab or `*` made PyYAML raise and a leading `#` commented the
/// whole mapping out.
///
/// Everything here is a pure function over a single scalar. Block
/// structure (indents, comment preservation, refusals) stays with the
/// writer that owns the file shape.
public enum YAMLScalar {

    /// True when `s` carries a CR or LF anywhere.
    ///
    /// Scanned over unicode SCALARS on purpose: Swift's `String.contains`
    /// works on grapheme clusters, and `"\r\n"` is a SINGLE cluster — so
    /// `"a\r\nb".contains("\n")` is `false`, and the naive check waved a
    /// Windows-style line break straight through into a YAML row.
    public static func containsLineBreak(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    /// True when `s` carries a character no single-line YAML scalar should
    /// have to represent: a tab, a line break, or any other C0/C1 control
    /// (including DEL, NEL and the Unicode line/paragraph separators).
    ///
    /// This is the **refusal** predicate, not an emission rule. Round-3
    /// decision 6: a control character in a user-typed scalar is a visible
    /// editor validation error in the same shape as
    /// `MCPServerEditorViewModel.duplicateKey`, not a silent reshape — a tab
    /// pasted into a route Name is a paste accident, and double-quoting it
    /// away means the value the user reads back is not the value they see in
    /// the field. The writers below still handle one safely (a hand-edited
    /// file can carry anything), so this gates the EDITOR, not the emitter.
    ///
    /// `allowingLineBreaks` is for the one field that is deliberately
    /// multi-line — a bot's Role/`description`, which Hermes itself
    /// round-trips through `yaml.safe_dump` and which
    /// ``doubleQuoted(_:)`` represents losslessly.
    ///
    /// Scanned over unicode SCALARS for the same reason
    /// ``containsLineBreak(_:)`` is: `"\r\n"` is one grapheme cluster.
    public static func containsControlCharacter(
        _ s: String,
        allowingLineBreaks: Bool = false
    ) -> Bool {
        s.unicodeScalars.contains { scalar in
            if allowingLineBreaks, scalar == "\n" || scalar == "\r" { return false }
            return scalar.value < 0x20
                || scalar.value == 0x7F
                || (scalar.value >= 0x80 && scalar.value <= 0x9F)
                || scalar.value == 0x2028
                || scalar.value == 0x2029
        }
    }

    /// PyYAML's simple-key length limit: a `key: value` mapping key is a
    /// "simple key", and the scanner refuses one whose token runs more than
    /// 1024 characters before the `:` — `self.index - key.index > 1024`,
    /// where `index` counts PYTHON characters, i.e. unicode code points —
    /// raises `ScannerError` (`yaml/scanner.py:283-291`, the comment at
    /// `:91`). Quoting does not help: the limit is measured over the EMITTED
    /// token, so the two quote characters count toward it.
    ///
    /// A refused document is not a refused key. `load_config` discards the
    /// whole config.yaml layer on a parse error and falls back to `.env`
    /// (`gateway/config.py:775-791` @ `v2026.9.7`), so one over-long env
    /// name silently unsets every setting in the file.
    public static let simpleKeyLimit = 1024

    /// True when `key`, once emitted by ``quoteIfNeeded(_:)``, would run past
    /// ``simpleKeyLimit`` and make PyYAML refuse the document.
    ///
    /// Measured on the emitted form, because that is the token PyYAML
    /// scans: an unquoted 1024-scalar key loads, the same key quoted is
    /// 1026 and does not. Verified against PyYAML 6.0.3 locally — bare 1024
    /// OK / 1025 refused, `'…'` with 1022 inside OK / 1023 refused.
    ///
    /// Unicode SCALARS, not bytes and not grapheme clusters: PyYAML's
    /// `index` counts Python characters, i.e. unicode code points, so
    /// `e` + U+0301 spends TWO of the budget while Swift's `String.count`
    /// sees one Character. 600 `e\u{301}` pairs are 600 Swift Characters
    /// and 1200 PyYAML characters — `.count` passed them and PyYAML
    /// refused the document. Same for an emoji ZWJ sequence, which is one
    /// Character and five-plus scalars.
    public static func exceedsSimpleKeyLimit(_ key: String) -> Bool {
        quoteIfNeeded(key).unicodeScalars.count > simpleKeyLimit
    }

    /// The Unicode byte-order mark, which YAML permits at the start of a
    /// document and which no Foundation character set trims: it is not in
    /// `.whitespaces` and not in `.whitespacesAndNewlines`, exactly as `\r`
    /// was not before P10. A BOM left in place defeats every
    /// `trimmed == "slack:"` header match, and a missed header makes a
    /// writer append a SECOND top-level section — which PyYAML resolves
    /// last-wins, silently dropping the original section's siblings.
    public static let bom = "\u{FEFF}"

    /// `s` without a leading BOM. Strip once, at the reader/writer
    /// boundary; writers restore it so the file stays byte-for-byte.
    public static func strippingBOM(_ s: String) -> String {
        s.hasPrefix(bom) ? String(s.dropFirst()) : s
    }

    /// True when PyYAML's implicit resolvers would load this plain scalar
    /// as something OTHER than a string — null, bool, int, float or
    /// timestamp.
    ///
    /// Verified against PyYAML 6 as the value half of a mapping: `~` and
    /// `null` load as `None`, `on`/`yes` as `True`, `0`/`007`/`0x1F` as
    /// `0`/`7`/`31`, `.inf` as a float, `2026-09-09` as a `datetime.date`.
    /// The same happens to a KEY, which is worse: `{"on": …}` becomes
    /// `{True: …}` and no Hermes reader will ever find it again.
    ///
    /// Patterns mirror `yaml/resolver.py`'s implicit-resolver table. Bare
    /// `y` / `n` are deliberately absent — PyYAML does NOT resolve those as
    /// bools (they stay strings), which is why `ssl_verify: y` is a path.
    public static func resolvesToNonString(_ s: String) -> Bool {
        if s.isEmpty { return true }                       // empty plain scalar = null
        if resolvesToBool(s) { return true }
        for pattern in implicitResolverPatterns {
            if pattern.firstMatch(
                in: s,
                options: [],
                range: NSRange(s.startIndex..., in: s)
            ) != nil {
                return true
            }
        }
        return false
    }

    /// True when PyYAML's implicit resolvers load this plain scalar as a
    /// `bool` — its resolver set exactly, so no bare `y` / `n`.
    ///
    /// Split out of ``resolvesToNonString(_:)`` because "retyped" and
    /// "retyped to a bool" are different questions. A writer only needs the
    /// first (quote it either way). A READER of a bool-ish key needs the
    /// second: Hermes's `_parse_boolish` honours a real `bool` but falls
    /// back to its default for an `int`, so `enabled: false` and
    /// `enabled: 0` mean opposite things on the host.
    public static func resolvesToBool(_ s: String) -> Bool {
        guard let pattern = boolResolverPattern else { return false }
        return pattern.firstMatch(
            in: s, options: [], range: NSRange(s.startIndex..., in: s)
        ) != nil
    }

    /// Quote a YAML scalar if emitting it bare would change what PyYAML
    /// loads. Beyond `:` `#` and the block indicators, this covers the
    /// YAML 1.2 flow indicators (`[ ] { } ,`), the leading-position
    /// indicators (`! % \` ? & * @ -`) and — since P19 — every plain
    /// spelling an implicit resolver would retype (see
    /// ``resolvesToNonString(_:)``). Plain alphanumeric identifiers (the
    /// common case for Slack channel IDs) are still emitted unquoted;
    /// a PURELY numeric id is now quoted, which Hermes reads identically
    /// because every allowlist consumer coerces with `str(...)`
    /// (`plugins/platforms/telegram/adapter.py:5019-5026`,
    /// `plugins/platforms/slack/adapter.py:5960-5973` at `v2026.9.7`).
    ///
    /// A value carrying a literal newline or a control character cannot be
    /// represented on one row as a plain or single-quoted scalar. The
    /// EDITORS refuse those up front (round-3 decision 6; see
    /// ``containsControlCharacter(_:allowingLineBreaks:)``), because a
    /// silent reshape is a value the user cannot see — but a hand-edited
    /// file can carry anything, so this still emits a correct
    /// double-quoted scalar rather than a broken document.
    public static func quoteIfNeeded(_ raw: String) -> String {
        if raw.isEmpty { return "''" }
        if containsLineBreak(raw) || containsUnrepresentableControl(raw) {
            // Double quotes are the only YAML style with escapes, and
            // therefore the only single-line form that can carry a line
            // break or a control character at all. A raw C0/C1 control is
            // refused by PyYAML's READER — "unacceptable character #x0001:
            // special characters are not allowed" — in EVERY quoting style,
            // single quotes included, so this arm is not optional (verified
            // against PyYAML 6.0.3). A TAB is deliberately not in that set:
            // it is legal raw inside both quote styles and only illegal in
            // a plain scalar, which ``quoteIfNeeded`` already quotes.
            return doubleQuoted(raw)
        }
        let anywhere: Set<Character> = [":", "#", "&", "*", ">", "|", "[", "]", "{", "}", ","]
        let leading: Set<Character> = ["@", "-", " ", "\"", "'", "!", "%", "`", "?", "="]
        let needsQuoting = raw.contains(where: { anywhere.contains($0) })
            || raw.first.map { leading.contains($0) } ?? false
            || raw.last == " "
            || raw.contains("\t")
            || resolvesToNonString(raw)
        if !needsQuoting { return raw }
        // Single-quote, escaping any embedded single quotes by doubling.
        // `HermesYAML.stripYAMLQuotes` / `normalizedScalar` UN-double on the
        // way back in — an asymmetric pair here grew one `'` per save.
        return singleQuoted(raw)
    }

    /// Single-quoted form, escaping an embedded `'` by doubling — YAML's one
    /// escape in this style.
    ///
    /// Exposed so a writer with an ALWAYS-quote policy (`ProfileRoutesWriter`
    /// quotes platform ids unconditionally, because Hermes compares them
    /// with `!=` against string source ids and an unquoted `123` would load
    /// as an int) can reuse the emission instead of hand-rolling
    /// `"'\(raw)'"` — which loses the doubling and breaks on any value
    /// carrying a quote.
    public static func singleQuoted(_ raw: String) -> String {
        "'\(raw.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// True when `s` carries a character PyYAML's reader rejects in ANY
    /// quoting style and which therefore has to be escaped: the C0 controls
    /// except tab/CR/LF, DEL, the C1 block, and the Unicode line/paragraph
    /// separators.
    private static func containsUnrepresentableControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            if scalar == "\t" { return false }
            return scalar.value < 0x20
                || scalar.value == 0x7F
                || (scalar.value >= 0x80 && scalar.value <= 0x9F)
                || scalar.value == 0x2028
                || scalar.value == 0x2029
        }
    }

    /// Double-quoted form with every escape YAML requires, including line
    /// breaks and control characters.
    ///
    /// **Why nothing else will do** (lifted here from
    /// `HermesBotProfileYAML.requiresDoubleQuoting`, which P32 deleted). A
    /// single-quoted scalar escapes exactly one thing — `''` for a literal
    /// quote — and has no escape for a line break at all, so emitting
    /// `'line1<LF>line2'` with a REAL newline produces a *multi-line flow
    /// scalar*, which fails two ways against PyYAML 6.0.3: (1) line folding
    /// turns every interior newline into a space, and because Scarf re-reads
    /// the file before the next save, the mangled form is what gets
    /// persisted — cumulative and invisible; (2) a line that is exactly
    /// `---` or `...` — ordinary in pasted prose or markdown — terminates
    /// the document mid-scalar and PyYAML raises on the whole file.
    ///
    /// Lossless in both directions: ``unquote(_:)`` reverses it (and so do
    /// `HermesFileService.unquote` / `HermesBotProfileYAML.unquote`, which are
    /// one-line forwarders over it), and so does PyYAML.
    public static func doubleQuoted(_ raw: String) -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            // `\t`, which is also how PyYAML's own writer spells a tab in a
            // double-quoted scalar (`yaml.safe_dump("a\tb")` → `"a\\tb"`,
            // probed against PyYAML 6).
            case "\t": out += "\\t"
            default:
                // A raw control character makes PyYAML's reader refuse the
                // whole document, so it is escaped here rather than passed
                // through. A TAB has a dedicated YAML escape and takes it
                // (the `< 0x20` arm below would otherwise spell it `\x09`,
                // which is legal but reads as a mystery byte in a
                // hand-inspected config.yaml); every other C0/C1 control
                // has no mnemonic and goes out as `\xNN` / `\uNNNN`.
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else if (scalar.value >= 0x80 && scalar.value <= 0x9F)
                    || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - The one decoder

    /// The inverse of ``quoteIfNeeded(_:)`` / ``singleQuoted(_:)`` /
    /// ``doubleQuoted(_:)`` — decode one flow scalar the way PyYAML does.
    ///
    /// **Why it lives here.** P19's rule is that a quote-escaping writer
    /// needs its reader un-escaping in the same place, and P32 proved the
    /// cost of forgetting: `ProfileRoutesWriter` moved onto
    /// ``quoteIfNeeded(_:)`` (which escapes `\\`, `\n`, `\xNN`) while its
    /// reader still went through `HermesYAML.stripYAMLQuotes`, which hands a
    /// double-quoted BODY back verbatim — so a route name containing a
    /// backslash came back doubled and grew one `\` per save. This is the
    /// single decoder every Scarf-written scalar is read back through — and
    /// P41 is what made that claim TRUE rather than aspirational.
    /// `HermesFileService.unquote` and `HermesBotProfileYAML.unquote` are
    /// thin forwarders over it; the MCP emitter behind the first of those is
    /// ``quoteIfNeeded(_:)`` itself since P41; and the two config.yaml
    /// blocks Scarf writes through `PowerSettingsWriter` —
    /// `agent.reasoning_overrides` (`setReasoningOverrides`, KEYS and
    /// values, via `GatewayConfigWriter.setMapChecked`) and
    /// `model_catalog.excluded_providers` (`setExcludedProviders`, via
    /// `setListChecked`) — reach this decoder through
    /// `HermesYAML.scarfWrittenMapPaths` / `scarfWrittenListPaths`. One
    /// escape table, not three.
    ///
    /// `HermesYAML.stripYAMLQuotes` is deliberately NOT folded in: it reads
    /// arbitrary HERMES-written config.yaml values, where widening the rule
    /// would change the meaning of every unrelated `\` in the file. That is
    /// why those two blocks are a per-KEY opt-in inside `parseNestedYAML`
    /// rather than a change to `stripYAMLQuotes`, and why
    /// `gateway.multiplex_profile_allowlist` — which the round-4 finding
    /// listed as a third Scarf-written block, but which Scarf only READS —
    /// is NOT opted in. See the opt-in's own doc for that walk.
    ///
    /// Anything that is not a quoted flow scalar comes back unchanged. An
    /// escape Scarf never emits — and a malformed `\xNN` / `\uNNNN`, whose
    /// body must be hex DIGITS (`UInt32("+9", radix: 16)` is 9, so a signed
    /// body would otherwise decode to a tab) — is passed through verbatim
    /// rather than half-decoded.
    public static func unquote(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if raw.first == "'" && raw.last == "'" {
            // Single-quoted YAML has exactly one escape: `''` is a quote.
            return String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        guard raw.first == "\"" && raw.last == "\"" else { return raw }
        let body = Array(raw.dropFirst().dropLast())
        var out = ""
        var i = 0
        /// `count` hex digits at `i`, or `nil` (leaving `i` put) when the
        /// run is short, not all hex digits, or not a Unicode scalar.
        func hex(_ count: Int) -> String? {
            guard i + count <= body.count else { return nil }
            let digits = String(body[i..<(i + count)])
            guard digits.allSatisfy(\.isHexDigit),
                  let value = UInt32(digits, radix: 16),
                  let scalar = Unicode.Scalar(value) else { return nil }
            i += count
            return String(Character(scalar))
        }
        while i < body.count {
            let c = body[i]
            i += 1
            guard c == "\\" else { out.append(c); continue }
            // A trailing lone backslash is emitted as itself.
            guard i < body.count else { out.append("\\"); break }
            let esc = body[i]
            i += 1
            switch esc {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "0": out.append("\0")
            case "a": out.append("\u{07}")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "v": out.append("\u{0B}")
            case "e": out.append("\u{1B}")
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "/": out.append("/")
            // The rest of PyYAML's `ESCAPE_REPLACEMENTS`. Hermes's own writer
            // does NOT produce these — `atomic_yaml_write` passes
            // `allow_unicode=True` (`utils.py:271` @ `v2026.9.7`), which sends
            // U+0085 / U+00A0 / U+2028 / U+2029 out RAW inside single quotes
            // (probed against PyYAML 6, not reasoned about) — and neither does
            // `doubleQuoted`, which spells them `\uNNNN`. They are here
            // because PyYAML's READER accepts them, so a hand-edited
            // config.yaml can carry them and this claims to decode "the way
            // PyYAML does".
            case "N": out.append("\u{85}")
            case "_": out.append("\u{A0}")
            case "L": out.append("\u{2028}")
            case "P": out.append("\u{2029}")
            case "x": out.append(hex(2) ?? "\\x")
            case "u": out.append(hex(4) ?? "\\u")
            case "U": out.append(hex(8) ?? "\\U")
            default:
                // Not one of ours: keep the bytes as written. PyYAML would
                // RAISE here, so a Hermes-written file cannot reach it.
                out.append("\\")
                out.append(esc)
            }
        }
        return out
    }

    // MARK: - Implicit resolvers

    /// PyYAML's bool resolver — its set exactly; no bare y/n.
    private static let boolResolverPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)$"#
    )

    /// Anchored mirrors of PyYAML's implicit-resolver regexes (null, int,
    /// float, timestamp, merge and value keys). Compiled once. The bool
    /// resolver lives in ``boolResolverPattern`` so readers can ask about it
    /// separately; ``resolvesToNonString(_:)`` consults both.
    private static let implicitResolverPatterns: [NSRegularExpression] = {
        let sources = [
            // null
            #"^(?:~|null|Null|NULL)$"#,
            // int: binary, octal (leading zero), decimal, hex, sexagesimal
            #"^[-+]?0b[0-1_]+$"#,
            #"^[-+]?0[0-7_]+$"#,
            #"^[-+]?(?:0|[1-9][0-9_]*)$"#,
            #"^[-+]?0x[0-9a-fA-F_]+$"#,
            #"^[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+$"#,
            // float — the mantissa MUST carry a `.`, exactly as in PyYAML's
            // own resolver: `1e3` and even `1e+3` are plain STRINGS to
            // PyYAML, only `1.0e+3` is a float. Over-matching here would
            // quote values that never needed it.
            #"^[-+]?[0-9][0-9_]*\.[0-9_]*(?:[eE][-+]?[0-9]+)?$"#,
            #"^\.[0-9][0-9_]*(?:[eE][-+]?[0-9]+)?$"#,
            #"^[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*$"#,
            #"^[-+]?\.(?:inf|Inf|INF)$"#,
            #"^\.(?:nan|NaN|NAN)$"#,
            // timestamp (date, and the full date-time form)
            #"^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$"#,
            #"^[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?(?:[Tt]|[ \t]+)[0-9][0-9]?:[0-9][0-9]:[0-9][0-9](?:\.[0-9]*)?(?:[ \t]*(?:Z|[-+][0-9][0-9]?(?::[0-9][0-9])?))?$"#,
            // merge / value keys
            #"^<<$"#,
            #"^=$"#
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()
}
