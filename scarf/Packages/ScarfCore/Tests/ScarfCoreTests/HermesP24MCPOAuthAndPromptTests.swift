import Foundation
import Testing
@testable import ScarfCore

/// P24 — the OAuth token PATH, the PyYAML bool resolver split, and the
/// device-prompt stream tolerances.
///
/// Every expectation in `safeFilenameMatchesPython` was produced by running
/// Hermes's own expression (`tools/mcp_oauth.py:104-106` at `v2026.9.7`)
/// under CPython, not by reasoning about it — Python's `\w` is Unicode-aware
/// and its `[:128]` counts code points, and both of those bite exactly where
/// a hand-rolled port looks right.
@Suite("P24 MCP OAuth paths and device prompt")
struct HermesP24MCPOAuthAndPromptTests {

    // MARK: - `_safe_filename`

    /// Captured from:
    /// ```python
    /// re.sub(r"[^\w\-]", "_", name).strip("_")[:128] or "default"
    /// ```
    /// run under CPython 3 against each `name`.
    ///
    /// The interesting rows: `github.com` (the reported bug), `café` spelled
    /// with a COMBINING acute (`e` + U+0301 — Python replaces the mark,
    /// which `\w` does not match, then strips the resulting trailing `_`,
    /// giving `cafe`; a grapheme-cluster port would have kept `café`),
    /// `日本語-server` (Unicode letters survive), `mixed_-.:;` (strip removes
    /// only underscores, and only at the ends) and `..` (everything
    /// substitutes away, so the whole name becomes `default`).
    static let pythonTable: [(String, String)] = [
        ("github.com", "github_com"),
        ("my server", "my_server"),
        ("simple", "simple"),
        ("_leading_", "leading"),
        ("a/b/c", "a_b_c"),
        ("", "default"),
        (".", "default"),
        ("..", "default"),
        ("__", "default"),
        ("caf\u{00E9}", "caf\u{00E9}"),          // precomposed é — a letter
        ("cafe\u{0301}", "cafe"),                // e + combining acute
        ("日本語-server", "日本語-server"),
        ("-dash-", "-dash-"),
        ("a.b c/d", "a_b_c_d"),
        ("Ünïcödé 42", "Ünïcödé_42"),
        ("emoji🙂name", "emoji_name"),
        ("tab\tname", "tab_name"),
        ("0", "0"),
        ("mixed_-.:;", "mixed_-"),
        (String(repeating: "x", count: 200), String(repeating: "x", count: 128))
    ]

    @Test(arguments: pythonTable)
    func safeFilenameMatchesPython(_ row: (String, String)) {
        let (name, expected) = row
        #expect(HermesMCPOAuthPaths.safeFilename(name) == expected, "name: \(name.debugDescription)")
    }

    /// The exact shape the reported bug had: a dotted name is NOT its own
    /// filename, so a detector using the raw name finds nothing.
    @Test func dottedNameIsNotItsOwnFilename() {
        #expect(HermesMCPOAuthPaths.safeFilename("github.com") != "github.com")
        let paths = HermesMCPOAuthPaths.tokenPaths(serverName: "github.com", tokensDir: "/h/mcp-tokens")
        #expect(paths.first == "/h/mcp-tokens/github_com.json")
    }

    /// A name that needs no sanitizing probes ONE path — a second identical
    /// probe is a wasted remote round trip.
    @Test func cleanNameProbesASingleSpelling() {
        #expect(HermesMCPOAuthPaths.basenames(for: "simple") == ["simple"])
        #expect(
            HermesMCPOAuthPaths.tokenPaths(serverName: "simple", tokensDir: "/h/t")
                == ["/h/t/simple.json"]
        )
    }

    /// Pre-v0.8.0 Hermes stored under the RAW name, and such a file can
    /// still be sitting in a long-lived `mcp-tokens/`. Both spellings are
    /// probed, sanitized first.
    @Test func legacyRawSpellingIsStillProbed() {
        #expect(
            HermesMCPOAuthPaths.tokenPaths(serverName: "github.com", tokensDir: "/h/t")
                == ["/h/t/github_com.json", "/h/t/github.com.json"]
        )
    }

    /// …but never one that could escape `mcp-tokens/`. The sanitizer is what
    /// makes a server name safe as a path component, so the legacy spelling
    /// — the one that skips it — must not be turned into an unlink.
    @Test(arguments: ["../../.ssh/id_rsa", "a/b", "..", "."])
    func legacySpellingNeverEscapesTheTokenDirectory(_ name: String) {
        let paths = HermesMCPOAuthPaths.statePaths(serverName: name, tokensDir: "/h/t")
        for path in paths {
            #expect(path.hasPrefix("/h/t/"), "\(name) produced \(path)")
            let leaf = String(path.dropFirst("/h/t/".count))
            #expect(!leaf.contains("/") && !leaf.contains(".."), "\(name) produced \(path)")
        }
    }

    /// "Clear Token" must unlink the whole state set `remove_oauth_tokens`
    /// unlinks — the tokens AND the DCR client registration, the metadata
    /// and the CIMD marker. Leaving `client.json` behind is what makes the
    /// next login fail with an `invalid_client` the user cannot clear.
    @Test func statePathsCoverEverythingHermesRemoves() {
        let paths = HermesMCPOAuthPaths.statePaths(serverName: "github.com", tokensDir: "/h/t")
        for suffix in [".json", ".client.json", ".meta.json", ".cimd-off"] {
            #expect(paths.contains("/h/t/github_com\(suffix)"), "missing \(suffix)")
        }
        // Tokens first, so a half-done clear reads as "no token".
        #expect(paths.first == "/h/t/github_com.json")
        #expect(paths.count == 8)  // both spellings × four files
    }

    // MARK: - PyYAML bool resolver, split out for readers

    /// `_parse_boolish` honours a real `bool` and falls back to its default
    /// for an `int`, so a reader has to tell those apart. The writer-facing
    /// `resolvesToNonString` must keep saying yes to both.
    @Test(arguments: ["yes", "No", "TRUE", "false", "on", "Off"])
    func boolSpellingsResolveToBool(_ s: String) {
        #expect(YAMLScalar.resolvesToBool(s))
        #expect(YAMLScalar.resolvesToNonString(s))
    }

    @Test(arguments: ["0", "1", "007", "0x1F", "1.0", "~", "null", "2026-09-09", "y", "n", "hello"])
    func nonBoolSpellingsDoNotResolveToBool(_ s: String) {
        #expect(!YAMLScalar.resolvesToBool(s))
    }

    // MARK: - Device prompt

    /// Verbatim v2026.9.7 block (`tools/mcp_oauth_device.py`), as one
    /// `print(..., file=sys.stderr, flush=True)`.
    private static let block = """

      MCP OAuth: open https://example.com/device on any device.
      Code: WDJB-MJHT
      Waiting for approval...
    """

    /// The stream ends ON the sentinel with no trailing newline — which is
    /// what a single `print` of the block looks like the instant it lands,
    /// before Hermes prints anything else (and on the device flow it prints
    /// nothing else until the user approves). Requiring a newline after the
    /// sentinel left the sheet spinning on a prompt it already had.
    @Test func unterminatedSentinelLineCompletesTheBlock() {
        let parsed = HermesMCPDevicePrompt.parse(Self.block)
        #expect(parsed?.userCode == "WDJB-MJHT")
        #expect(parsed?.verificationURL == "https://example.com/device")
    }

    /// CRLF: `.whitespaces` does not contain `\r`, so every field kept a
    /// trailing carriage return — "Copy" put `WDJB-MJHT\r` on the pasteboard
    /// and the URL never parsed as a URL.
    @Test func crlfStreamYieldsCleanFields() {
        let crlf = (Self.block + "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = HermesMCPDevicePrompt.parse(crlf)
        #expect(parsed?.userCode == "WDJB-MJHT")
        #expect(parsed?.verificationURL == "https://example.com/device")
    }

    /// Both tolerances at once: CRLF *and* no terminator on the sentinel.
    @Test func crlfWithUnterminatedSentinelStillCompletes() {
        let crlf = Self.block.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(HermesMCPDevicePrompt.parse(crlf)?.userCode == "WDJB-MJHT")
    }

    /// The tolerance must not become a latch. A half-arrived block whose
    /// last fragment is NOT the sentinel is still incomplete, and a
    /// truncated code must never be handed to the user.
    @Test(arguments: [
        "\n  MCP OAuth: open https://example.com/device on any device.\n  Code: WDJB-MJ",
        "\n  MCP OAuth: open https://example.com/device on any device.\n  Code: WDJB-MJHT\n  Waiting for approv",
        "\n  MCP OAuth: open https://example.com/device on any device.\r\n  Code: WDJB-MJHT\r\n  Waiting for approv"
    ])
    func partialBlocksStayUnparsed(_ partial: String) {
        #expect(HermesMCPDevicePrompt.parse(partial) == nil)
    }
}
