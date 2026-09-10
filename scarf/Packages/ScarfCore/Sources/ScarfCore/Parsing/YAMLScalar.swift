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
    /// A value carrying a literal newline cannot be represented on one row
    /// at all; callers reject those before reaching here, and as a last
    /// resort this escapes the value double-quoted rather than emitting a
    /// broken document.
    public static func quoteIfNeeded(_ raw: String) -> String {
        if raw.isEmpty { return "''" }
        if containsLineBreak(raw) {
            // Double quotes are the only YAML style that can carry an
            // escaped line break inline.
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
        let escaped = raw.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    /// Double-quoted form with every escape YAML requires, including line
    /// breaks. Lossless: `HermesFileService.unescapeYAMLDoubleQuoted`
    /// reverses it.
    public static func doubleQuoted(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    // MARK: - Implicit resolvers

    /// Anchored mirrors of PyYAML's implicit-resolver regexes (null, bool,
    /// int, float, timestamp, merge and value keys). Compiled once.
    private static let implicitResolverPatterns: [NSRegularExpression] = {
        let sources = [
            // null
            #"^(?:~|null|Null|NULL)$"#,
            // bool — PyYAML's set exactly; no bare y/n.
            #"^(?:yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)$"#,
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
