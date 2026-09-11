import Foundation

/// Where Hermes keeps one MCP server's OAuth state on disk, and what the
/// whole set of files is.
///
/// Hermes does NOT name these files after the server. `HermesTokenStorage`
/// sanitizes the name first (`tools/mcp_oauth.py:104-106` at `v2026.9.7`):
///
/// ```python
/// def _safe_filename(name: str) -> str:
///     return re.sub(r"[^\w\-]", "_", name).strip("_")[:128] or "default"
/// ```
///
/// and then hangs four files off it (`:272-287`): `.json` (the tokens),
/// `.client.json` (the DCR client registration), `.meta.json` (the
/// discovered server metadata) and `.cimd-off` (the "this server refused
/// CIMD" marker). `remove_oauth_tokens` (`:690-693`) deletes all four via
/// `HermesTokenStorage.remove` (`:391-394`), and the manager deletes the
/// client/meta pair on its own when a server rejects our `client_id`
/// (`tools/mcp_oauth_manager.py:174`) — a stale registration is precisely
/// what "Clear Token" has to drop, or the next login re-sends a dead
/// `client_id`.
///
/// Reading the raw name instead was a real bug twice over: a server called
/// `github.com` stores its token as `github_com.json`, so Scarf's "OAuth"
/// badge and its token section never appeared, and "Clear Token" happily
/// reported success for deleting a path that never existed.
///
/// **Floor.** `_safe_filename` has been in `mcp_oauth.py` since
/// `v2026.4.8` (**v0.8.0**) — below every capability floor Scarf models —
/// so on any host Scarf supports the sanitized spelling is the one Hermes
/// uses, and this needs no capability gate. `v2026.4.3` (v0.7.0) and older
/// stored under the RAW name, and a long-lived `~/.hermes/mcp-tokens/`
/// can still carry such a file from an install that old. Detection
/// therefore accepts EITHER spelling and the clear removes whichever
/// exists, which keeps a pre-target host rendering exactly as it did
/// (charter C1) and never leaves a credential behind.
///
/// The sidecars arrived later — `.client.json` with the sanitizer at
/// `v2026.4.8`, `.meta.json` at `v2026.6.19` (v0.16.0), `.cimd-off` at
/// `v2026.8.19` (v0.20.5) — so on an older host some of them simply do not
/// exist. That needs no gate either: both transports' `removeFile` is
/// already `rm -f`-shaped (`LocalTransport.swift:207-214`,
/// `SSHTransport.swift:635-640`), so a missing sidecar is a no-op rather
/// than a failure, and an ungated unlink of an absent path cannot be
/// distinguished from the pre-target behaviour.
public enum HermesMCPOAuthPaths {

    /// The four suffixes `HermesTokenStorage` hangs off the sanitized name,
    /// in the order `remove()` unlinks them (`mcp_oauth.py:284-290,391-394`).
    /// `.json` first: it is the one whose presence Scarf reports as "has a
    /// token", so if the run dies halfway the state left behind reads as
    /// "no token" rather than "token, with dead sidecars".
    public static let stateSuffixes = [".json", ".client.json", ".meta.json", ".cimd-off"]

    /// Hermes's `_safe_filename`, ported exactly.
    ///
    /// Three details are load-bearing and none of them survive a casual
    /// translation:
    ///
    /// * Python's `\w` in `str` mode is **Unicode-aware**: CPython's
    ///   `SRE_UNI_IS_WORD` is `Py_UNICODE_ISALNUM(ch) || ch == '_'`, i.e.
    ///   general categories `L*` ∪ `N*` plus `_`. So a server named `café`
    ///   keeps its `é`, and only `[^\w\-]` — punctuation, spaces, `/`, `.`
    ///   — becomes `_`. Scarf mirrors that with an explicit
    ///   `generalCategory` test rather than `Character.isLetter`, which is
    ///   close but not the same set.
    /// * The substitution, the strip and the slice all run over **code
    ///   points**, not grapheme clusters. `e` + U+0301 is one Swift
    ///   `Character` but two scalars, and Python replaces the combining
    ///   mark (category `Mn`, not `\w`) with `_`. Iterating `Character`s
    ///   would keep it — a different filename from the one Hermes wrote.
    ///   The `[:128]` cut is likewise 128 scalars.
    /// * The order is sub → `strip("_")` → `[:128]` → `or "default"`. The
    ///   strip runs BEFORE the slice, so a truncated name may legitimately
    ///   end in `_`, and only an empty RESULT falls back to `default`.
    public static func safeFilename(_ name: String) -> String {
        var substituted: [Unicode.Scalar] = []
        substituted.reserveCapacity(name.unicodeScalars.count)
        for scalar in name.unicodeScalars {
            substituted.append(isWordScalar(scalar) || scalar == "-" ? scalar : "_")
        }
        // `.strip("_")` — only the underscore, and only at the two ends.
        var start = substituted.startIndex
        var end = substituted.endIndex
        while start < end, substituted[start] == "_" { start += 1 }
        while end > start, substituted[end - 1] == "_" { end -= 1 }
        let stripped = substituted[start..<end].prefix(128)
        var out = ""
        out.unicodeScalars.append(contentsOf: stripped)
        return out.isEmpty ? "default" : out
    }

    /// `true` for the scalars Python's `\w` matches: `L*` ∪ `N*` ∪ `_`.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// The basenames to probe for this server, sanitized spelling first.
    ///
    /// One element when the name needs no sanitizing (the common case) —
    /// the raw and sanitized spellings are then the same string, and
    /// probing the same path twice would just cost a second remote `test`.
    ///
    /// The legacy raw spelling is dropped when it carries a path separator.
    /// A server name is user-chosen text out of `mcp_servers`, and the
    /// sanitizer is exactly what keeps `../../.ssh/id_rsa` from naming a
    /// file outside `mcp-tokens/` — so a DELETE built from the raw name is
    /// the one place this could do damage. Nothing is lost: a pre-v0.8.0
    /// Hermes could not have written such a file either, since `open()`
    /// of `<tokens>/../../x.json` needs the parent dirs to exist.
    public static func basenames(for serverName: String) -> [String] {
        let safe = safeFilename(serverName)
        guard safe != serverName else { return [safe] }
        let legacyIsSafe = !serverName.isEmpty
            && !serverName.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" })
            && serverName != "." && serverName != ".."
        return legacyIsSafe ? [safe, serverName] : [safe]
    }

    /// Candidate token files (`<basename>.json`) whose existence means
    /// "this server has an OAuth token", sanitized spelling first.
    public static func tokenPaths(serverName: String, tokensDir: String) -> [String] {
        basenames(for: serverName).map { "\(tokensDir)/\($0).json" }
    }

    /// Does this server have an OAuth token, given ONE listing of
    /// `mcp-tokens/`?
    ///
    /// The per-server ``tokenPaths(serverName:tokensDir:)`` probe answers the
    /// same question with up to two `fileExists` calls EACH — a serialized SSH
    /// round trip apiece on a remote context, so a dozen MCP servers cost up
    /// to two dozen of them inside one load. `listDirectory` answers every
    /// server at once, and the entries are bare filenames on both transports
    /// (`LocalTransport.swift:191-197` is `contentsOfDirectory`,
    /// `SSHTransport.swift:613-626` is `ls -A`).
    public static func hasToken(serverName: String, tokenDirEntries: Set<String>) -> Bool {
        basenames(for: serverName).contains { tokenDirEntries.contains("\($0).json") }
    }

    /// Every file `remove_oauth_tokens` would delete, for every spelling
    /// Scarf accepts — what "Clear Token" must unlink.
    public static func statePaths(serverName: String, tokensDir: String) -> [String] {
        basenames(for: serverName).flatMap { base in
            stateSuffixes.map { "\(tokensDir)/\(base)\($0)" }
        }
    }
}
