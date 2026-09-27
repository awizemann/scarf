import Foundation

/// Pure block-splice logic for Scarf's managed regions inside
/// `~/.hermes/.env`. Each registered project that has at least one
/// resolved secret carries one block, bounded by:
///
/// ```
/// # scarf-secrets:begin <slug>
/// SCARF_<UPPER_SLUG>_<UPPER_FIELDKEY>=<value>
/// ...
/// # scarf-secrets:end <slug>
/// ```
///
/// The Mac wraps this in `KeychainEnvMirror` (Keychain-aware, atomic
/// write, mode-0600 enforcement). This file handles only the marker
/// contract + key naming + splice — logic that's testable in isolation
/// against an in-memory string and shared across hosts.
///
/// **Why `~/.hermes/.env`.** Hermes's cron scheduler reloads that file
/// fresh on every tick (cron/scheduler.py:897-903), so values become
/// available to the agent's tool-invoked subprocesses (terminal,
/// code_exec) without any Hermes-side change. Per-project `.env` is
/// not loaded at cron time today, hence we mirror into the global
/// file with namespaced keys.
///
/// **Marker contract is load-bearing.** Both markers carry the slug on
/// the same line so a multi-project file is parsed deterministically
/// and one project's edits can't disturb another's block.
public enum SecretsEnvBlock {

    /// Stable across releases — entries on disk reference these
    /// strings and a marker change would orphan every existing block.
    public static let beginMarkerPrefix = "# scarf-secrets:begin "
    public static let endMarkerPrefix = "# scarf-secrets:end "

    // MARK: - Key naming

    /// Build the env-var name for a (slug, fieldKey) pair. Uppercases,
    /// replaces every non-alphanumeric character with `_`, prefixes
    /// `SCARF_`. Stable: rotating a value writes to the same key.
    public static func envKeyName(slug: String, fieldKey: String) -> String {
        "SCARF_" + sanitize(slug) + "_" + sanitize(fieldKey)
    }

    private static func sanitize(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            let c = Character(scalar)
            let isAlpha = ("A"..."Z").contains(c) || ("a"..."z").contains(c)
            let isDigit = ("0"..."9").contains(c)
            if isAlpha || isDigit {
                out.append(Character(scalar.properties.uppercaseMapping))
            } else {
                out.append("_")
            }
        }
        // Collapse runs of underscores so `foo--bar` doesn't become
        // `FOO__BAR` (two underscores trips dotenv parsers more often
        // than one). Trim leading/trailing underscores too.
        while out.contains("__") {
            out = out.replacingOccurrences(of: "__", with: "_")
        }
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        return out.isEmpty ? "UNNAMED" : out
    }

    // MARK: - Block render

    /// Render the bounded block for a single project. Empty `entries`
    /// produces an empty string — callers should treat that as
    /// "remove the project's block" rather than "write an empty
    /// block." `entries` are emitted in stable sort order so two
    /// runs with the same input produce byte-identical output.
    public static func renderBlock(
        slug: String,
        entries: [(key: String, value: String)]
    ) -> String {
        guard !entries.isEmpty else { return "" }
        let sorted = entries.sorted { $0.key < $1.key }
        var lines: [String] = []
        lines.append(beginMarkerPrefix + slug)
        for entry in sorted {
            lines.append("\(entry.key)=\(escape(entry.value))")
        }
        lines.append(endMarkerPrefix + slug)
        return lines.joined(separator: "\n")
    }

    /// Quote a value so Hermes reads back exactly these bytes.
    ///
    /// Hermes loads `.env` with python-dotenv's parser and then expands
    /// `${NAME}` / `${NAME:-default}` in EVERY value, whatever its quoting
    /// (`hermes_cli/env_loader.py:265-310` @ v2026.9.24: `DotEnv(...,
    /// interpolate=False).parse()`, then `parse_variables(value)`). So:
    ///
    /// - Double quotes, escaping `\` and `"` — the form Hermes's own writer
    ///   uses (`_quote_env_value`, `hermes_cli/config.py:2557-2565`) and one
    ///   python-dotenv 1.2.2 parses (`parser.py`: `"((?:\\"|[^"])*)"`,
    ///   decoding `\\ \" \n \r …`). The shell-style `'foo'\''bar'` this
    ///   used before is a dotenv parse error, and dotenv drops the whole
    ///   line, so the secret was simply missing.
    /// - Line breaks as `\n` / `\r`, so a value never spans lines of the
    ///   marker-delimited block.
    /// - `${` as `${:-$}{`. python-dotenv has no escape for `$`; the only
    ///   way to keep a literal `${` through `parse_variables` is to make it
    ///   the OUTPUT of a variable: `${:-$}` is the variable with an empty
    ///   name (never set — no environment variable can have one) whose
    ///   default is `$`, and the `{` after it is literal text. A bare `$`
    ///   not followed by `{` is never expanded and stays as is.
    /// - A trailing `\` as `${:-\}`, for the reason given below.
    ///
    /// Plain tokens (letters, digits, `-_./:@+=,` …) are written unquoted,
    /// exactly as before, so an unchanged secret keeps its bytes on disk
    /// and the launch reconciler's no-op-when-unchanged check still holds.
    static func escape(_ value: String) -> String {
        // Control characters too: dotenv strips an unquoted value's ends,
        // and U+001C…U+001F count as whitespace to Python.
        let needsQuoting = value.contains(where: { c in
            c.isWhitespace || c == "#" || c == "$" || c == "\"" || c == "'" || c == "\\"
        }) || value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        if !needsQuoting { return value }
        // Scalar by scalar: `String.replacingOccurrences` treats `\r\n` as
        // one character and would turn a CRLF into a lone `\n`.
        var scalars = Array(value.unicodeScalars)
        // Trailing backslashes can't be written as `\\`: dotenv's quoted
        // pattern reads the second one plus the closing quote as `\"` and
        // the line fails to parse. Each becomes `${:-\}` (the same
        // empty-name variable, defaulting to one backslash).
        var trailingBackslashes = 0
        while scalars.last == "\\" {
            scalars.removeLast()
            trailingBackslashes += 1
        }
        var escaped = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            switch scalar {
            case "\\": escaped.append(contentsOf: "\\\\".unicodeScalars)
            case "\"": escaped.append(contentsOf: "\\\"".unicodeScalars)
            case "\n": escaped.append(contentsOf: "\\n".unicodeScalars)
            case "\r": escaped.append(contentsOf: "\\r".unicodeScalars)
            case "$" where index + 1 < scalars.count && scalars[index + 1] == "{":
                escaped.append(contentsOf: "${:-$}".unicodeScalars)
            default: escaped.append(scalar)
            }
        }
        for _ in 0..<trailingBackslashes {
            escaped.append(contentsOf: "${:-\\}".unicodeScalars)
        }
        return "\"" + String(escaped) + "\""
    }

    // MARK: - Splice

    /// Splice `block` (already-rendered, with markers) into `existing`
    /// for the named `slug`. Three cases:
    /// 1. `existing` already has a `# scarf-secrets:begin <slug>` /
    ///    `# scarf-secrets:end <slug>` pair → replace the inclusive
    ///    region. Other slugs' blocks are preserved byte-identically.
    /// 2. `existing` has no block for this slug → append after a
    ///    blank line at the end of file.
    /// 3. `block` is empty → behave like `removeBlock`.
    ///
    /// Idempotent: feeding the output of one call back through
    /// `applyBlock` with the same inputs produces the same string.
    public static func applyBlock(
        _ block: String,
        forSlug slug: String,
        to existing: String
    ) -> String {
        if block.isEmpty {
            return removeBlock(forSlug: slug, from: existing)
        }
        if let region = blockRange(forSlug: slug, in: existing) {
            // Replace the inclusive region. `blockRange` covers the
            // begin marker line through the end marker line plus any
            // trailing newline so `removeBlock` doesn't leave a
            // dangling blank line — but for `applyBlock`, we need to
            // re-emit that trailing newline so a round-trip
            // (mirror→read→mirror with identical entries) produces
            // byte-identical output. Without this, the second mirror
            // would write a file shorter by one newline byte and
            // bump the file's mtime, breaking the
            // no-op-when-unchanged contract that the launch
            // reconciler relies on.
            let before = String(existing[existing.startIndex..<region.lowerBound])
            let after = String(existing[region.upperBound..<existing.endIndex])
            // Restore a trailing newline only when the consumed region
            // had one (i.e., the block wasn't at end-of-string with
            // no terminating newline).
            let consumedTrailingNewline = region.upperBound > existing.startIndex
                && existing[existing.index(before: region.upperBound)] == "\n"
            let separator = consumedTrailingNewline ? "\n" : ""
            return before + block + separator + after
        }
        // Append at end of file, separated from preceding content by
        // a blank line. Empty-or-whitespace files just become the
        // block plus a trailing newline.
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return block + "\n"
        }
        let normalized = trimmingRightNewlines(existing)
        return normalized + "\n\n" + block + "\n"
    }

    /// Strip the bounded block for `slug` from `existing`. No-op when
    /// absent. Preserves all other slugs' blocks and user-authored
    /// content byte-identically.
    public static func removeBlock(forSlug slug: String, from existing: String) -> String {
        guard let region = blockRange(forSlug: slug, in: existing) else {
            return existing
        }
        let before = String(existing[existing.startIndex..<region.lowerBound])
        let after = String(existing[region.upperBound..<existing.endIndex])
        // Collapse the blank line we may have inserted at append time
        // so repeated install/uninstall cycles don't accumulate
        // blank lines. Specifically: if `before` ends in `\n\n` and
        // `after` starts with `\n`, drop one of the newlines.
        var trimmedBefore = before
        var trimmedAfter = after
        if trimmedBefore.hasSuffix("\n\n") && trimmedAfter.hasPrefix("\n") {
            trimmedAfter.removeFirst()
        } else if trimmedBefore.hasSuffix("\n\n") {
            trimmedBefore.removeLast()
        }
        return trimmedBefore + trimmedAfter
    }

    // MARK: - Range scan

    /// Locate the inclusive character range covering one project's
    /// block, including a trailing newline if present so removal
    /// doesn't leave a dangling empty line. Returns nil when the
    /// block isn't present.
    private static func blockRange(
        forSlug slug: String,
        in existing: String
    ) -> Range<String.Index>? {
        let beginLine = beginMarkerPrefix + slug
        let endLine = endMarkerPrefix + slug
        // Match begin marker as a full line — guard against false
        // positives where a slug is a prefix of another slug
        // (e.g. "foo" vs "foo-bar"). Require the marker to be
        // followed immediately by `\n` or end-of-string.
        guard let beginRange = lineRange(of: beginLine, in: existing) else {
            return nil
        }
        // Search for the matching end marker AFTER the begin range —
        // can't use a leading-anchor scan because there may be other
        // slugs' end markers between begin and the matching end.
        let searchStart = beginRange.upperBound
        guard let endRange = lineRange(of: endLine, in: existing, startingAt: searchStart) else {
            return nil
        }
        // Include a trailing newline if the file has one immediately
        // after the end marker — keeps the file shape clean across
        // remove operations.
        var upper = endRange.upperBound
        if upper < existing.endIndex, existing[upper] == "\n" {
            upper = existing.index(after: upper)
        }
        return beginRange.lowerBound..<upper
    }

    /// Find a substring that appears as a complete line — bounded by
    /// start-of-string or `\n` on the left and `\n` or end-of-string
    /// on the right. Returns the range of the substring itself, not
    /// including any surrounding newlines.
    private static func lineRange(
        of needle: String,
        in haystack: String,
        startingAt start: String.Index? = nil
    ) -> Range<String.Index>? {
        var searchStart = start ?? haystack.startIndex
        while searchStart <= haystack.endIndex {
            guard let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) else {
                return nil
            }
            let leftOK = range.lowerBound == haystack.startIndex
                || haystack[haystack.index(before: range.lowerBound)] == "\n"
            let rightOK = range.upperBound == haystack.endIndex
                || haystack[range.upperBound] == "\n"
            if leftOK && rightOK {
                return range
            }
            // Advance past this false positive and keep searching.
            searchStart = range.upperBound
        }
        return nil
    }

    private static func trimmingRightNewlines(_ s: String) -> String {
        var result = s
        while let last = result.last, last.isNewline {
            result.removeLast()
        }
        return result
    }
}
