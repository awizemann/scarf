import Foundation

/// Replaces `?` placeholders in a SQL string with SQLite-escaped
/// literal values, in order. Used by `RemoteSQLiteBackend` because
/// the `sqlite3` CLI doesn't accept `?`-bound parameters on the
/// command line — it would need stdin `.parameter set @name` dot-
/// commands, which require a multi-line script for every query and
/// add round-trip overhead with no upside for our use case.
///
/// **Trust model.** This is a literal-encoder for in-tree, trusted
/// callers — every current param source is either an integer (`limit`,
/// `before`, `since.timeIntervalSince1970`), a Hermes-internal ID
/// (UUID-shaped session/tool IDs that come back from the same DB), or
/// a search query that already passes through `sanitizeFTSQuery` in
/// HermesDataService. It is **NOT** a general SQL-injection defense.
/// Don't extend the data-service surface with methods that accept raw
/// untrusted user input as a `.text` param without first validating
/// upstream. The local backend skips inlining entirely (uses
/// `sqlite3_bind_*`) so this only affects the remote path.
///
/// Escape rules mirror SQLite's literal syntax:
/// * `.null` → `NULL`
/// * `.integer(n)` → `<n>` (no quoting)
/// * `.real(d)` → `%.17g`-formatted (round-trips Double via decimal)
/// * `.text(s)` → `'<s with single-quotes doubled>'`, with newlines split
///   out into `char(10)`/`char(13)` concatenation so a value can never
///   terminate the remote heredoc (see ``encodeText(_:)``)
/// * `.blob(d)` → `X'<hex>'`
public enum SQLValueInliner {

    /// Error thrown when a caller's `?` placeholder count doesn't match
    /// the number of `params` provided. This is a caller bug, but it's
    /// reachable from `RemoteSQLiteBackend.query`/`queryBatch`, which
    /// already sit inside `try`/catch — so throw a recoverable error
    /// rather than `fatalError`-crashing the whole app. (t-aud08)
    public enum InlineError: Error, Equatable {
        case placeholderParamMismatch(String)
    }

    /// Walk `sql`, replacing each `?` (outside SQL string literals) with
    /// the corresponding `params` entry's encoded form. Throws
    /// `InlineError.placeholderParamMismatch` if the placeholder count
    /// doesn't match `params.count`.
    ///
    /// `?` inside string literals (e.g. `WHERE name = '?'`) is preserved
    /// unchanged. We track quote state with a tiny scanner so existing
    /// SQL with literal `?` chars in strings doesn't get mis-bound.
    public static func inline(_ sql: String, params: [SQLValue]) throws -> String {
        var out = ""
        out.reserveCapacity(sql.count + params.count * 16)
        var paramIndex = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var i = sql.startIndex
        while i < sql.endIndex {
            let c = sql[i]
            if c == "'" && !inDoubleQuote {
                // Check for SQL's `''` escape (a doubled single-quote
                // INSIDE a string literal stays inside; we don't toggle
                // out). The next char being another `'` keeps us in.
                let next = sql.index(after: i)
                if inSingleQuote && next < sql.endIndex && sql[next] == "'" {
                    out.append("'")
                    out.append("'")
                    i = sql.index(after: next)
                    continue
                }
                inSingleQuote.toggle()
                out.append(c)
                i = sql.index(after: i)
                continue
            }
            if c == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                out.append(c)
                i = sql.index(after: i)
                continue
            }
            if c == "?" && !inSingleQuote && !inDoubleQuote {
                // Bind placeholder.
                if paramIndex >= params.count {
                    throw InlineError.placeholderParamMismatch(
                        "more `?` placeholders in SQL than provided params (\(params.count)). SQL: \(sql)"
                    )
                }
                out.append(encode(params[paramIndex]))
                paramIndex += 1
                i = sql.index(after: i)
                continue
            }
            out.append(c)
            i = sql.index(after: i)
        }
        if paramIndex != params.count {
            throw InlineError.placeholderParamMismatch(
                "\(params.count) params provided but only \(paramIndex) `?` placeholders consumed. SQL: \(sql)"
            )
        }
        return out
    }

    /// Encode a single value as a SQLite literal. Public so callers
    /// that build SQL strings by hand (rare — prefer `inline`) can
    /// reuse the same escape rules.
    public static func encode(_ value: SQLValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .integer(let n):
            return String(n)
        case .real(let d):
            // %.17g round-trips a Double precisely as a decimal.
            return String(format: "%.17g", d)
        case .text(let s):
            return encodeText(s)
        case .blob(let d):
            // SQLite blob literal: X'<hex>' (case-insensitive prefix).
            let hex = d.map { String(format: "%02x", $0) }.joined()
            return "X'\(hex)'"
        }
    }

    /// Encode a text value as a SQLite literal **that can never contain a
    /// raw newline**.
    ///
    /// `RemoteSQLiteBackend` ships the inlined SQL to the host inside a
    /// quoted heredoc (`<<'__SCARF_SQL__'`). Quoting the delimiter stops
    /// `$`/backtick expansion, but it does **not** stop a value from ending
    /// the heredoc: a param carrying `"\n__SCARF_SQL__\n<command>"` closes
    /// the document early and everything after it is executed by the remote
    /// shell. `HermesToolCall.callId` (attacker-influenced — it comes from
    /// whatever the model/provider wrote into `messages.tool_calls`) reaches
    /// `fetchToolResult(callId:)` as a `.text` param, so that chain was live.
    ///
    /// The fix ENCODES rather than rejects: newlines are replaced with
    /// `char(10)`/`char(13)` concatenation, which is byte-identical to
    /// SQLite and keeps legitimately multi-line params working (a pasted
    /// multi-line search query is the real one). The result is an
    /// expression, not a bare literal — valid everywhere a literal is, in
    /// every SQL we build.
    static func encodeText(_ s: String) -> String {
        func quoted(_ part: Substring) -> String {
            "'" + part.replacingOccurrences(of: "'", with: "''") + "'"
        }
        guard s.contains("\n") || s.contains("\r") else {
            return quoted(s[...])
        }
        var pieces: [String] = []
        var current = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\n" || c == "\r" {
                pieces.append(quoted(s[current..<i]))
                pieces.append(c == "\n" ? "char(10)" : "char(13)")
                i = s.index(after: i)
                current = i
                continue
            }
            i = s.index(after: i)
        }
        pieces.append(quoted(s[current...]))
        return "(" + pieces.joined(separator: " || ") + ")"
    }
}
