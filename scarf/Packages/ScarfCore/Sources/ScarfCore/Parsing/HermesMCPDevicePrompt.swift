import Foundation

/// The RFC 8628 device-code prompt Hermes prints during
/// `hermes mcp login <name> --flow device` (v0.21.1+).
///
/// Hermes emits exactly one block, from `tools/mcp_oauth_device.py::_authorize`:
///
/// ```text
///
///   MCP OAuth: open https://example.com/device on any device.
///   Code: WDJB-MJHT
///   Waiting for approval...
/// ```
///
/// Two things about it decide the shape of Scarf's surface:
///
/// * It goes to **stderr**, not stdout (`print(..., file=sys.stderr)`), so a
///   runner that captures only stdout shows the user a spinner and nothing
///   else while the flow silently times out. Scarf merges both streams.
/// * The user code is not in the URL. A "sign in" button that just opens the
///   verification URI is useless on its own — the code has to be readable, and
///   copyable, in the UI.
///
/// See `parse` for the streaming rules the block's single-`print` shape
/// imposes. `HermesMCPOAuthFlowTests` pins the verbatim v2026.9.7 text.
public struct HermesMCPDevicePrompt: Sendable, Equatable {
    /// The verification URI the user opens on any device.
    public let verificationURL: String
    /// The user code they type there. Rendered verbatim — Hermes passes the
    /// provider's string through unchanged, including its grouping dashes.
    public let userCode: String

    public init(verificationURL: String, userCode: String) {
        self.verificationURL = verificationURL
        self.userCode = userCode
    }

    /// The last line of Hermes's single-`print` block. Its arrival is the
    /// only proof that the two lines above it are COMPLETE — see `parse`.
    /// Verbatim from `tools/mcp_oauth_device.py:126-127` at `v2026.9.7`.
    public static let completionSentinel = "Waiting for approval..."

    /// Parse the prompt out of accumulated CLI output, or `nil` while it is
    /// not (yet) fully there.
    ///
    /// **Only newline-terminated lines are considered, and the block counts
    /// as arrived only once `Waiting for approval...` has.** Both rules exist
    /// for the same reason: a `readabilityHandler` chunk boundary falls on a
    /// byte count, not a line. Hermes writes the whole block in one
    /// `print(..., flush=True)` (`tools/mcp_oauth_device.py:126-127`), but the
    /// pipe can still hand Scarf `…\n  Code: WDJB-MJ` — and `WDJB-MJ` is a
    /// perfectly non-empty string. The old parser latched it, the sheet
    /// rendered a truncated code, and re-parsing was skipped forever after
    /// because the caller only re-parsed while `devicePrompt == nil`. A code
    /// the user cannot use, with no way to notice it is wrong, is worse than
    /// a spinner.
    ///
    /// The trailing sentinel makes the whole block atomic: the URL and the
    /// code are both above it in the same `print`, so once it is present in
    /// a newline-terminated line, every line before it is complete.
    ///
    /// Parsing stays tolerant of the surrounding decoration (leading
    /// whitespace, interleaved log lines) but anchored on the literal labels,
    /// so a change in Hermes's wording is a parse failure — visible — rather
    /// than a wrong URL. `HermesMCPOAuthFlowTests` pins the verbatim
    /// v2026.9.7 text.
    public static func parse(_ output: String) -> HermesMCPDevicePrompt? {
        var url: String?
        var code: String?
        var sawSentinel = false
        // Drop the trailing fragment: everything after the LAST newline has
        // not been terminated yet and may be half a line.
        //
        // The one exception is a final fragment that IS the sentinel. The
        // sentinel is the LAST line Hermes's block prints, so it cannot be a
        // truncation of something longer — and its presence is what proves
        // the lines above it are whole. Requiring a newline after it made
        // completion depend on Hermes printing something MORE, which on the
        // device flow it does not do until the user has approved: the sheet
        // sat on its spinner holding a code it had already received.
        //
        // CRLF is normalised BEFORE the split, not trimmed after it. Swift
        // treats `\r\n` as a SINGLE grapheme cluster, so
        // `split(separator: "\n")` does not see it at all — a CRLF stream
        // came through as one enormous "line" and nothing matched. Same
        // trap `YAMLScalar.containsLineBreak` documents from P19.
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        if !isSentinelLine(lines.last) {
            guard lines.count > 1 else { return nil }
            lines.removeLast()
        }
        for rawLine in lines {
            // `.whitespacesAndNewlines`, not `.whitespaces`: the latter does
            // not contain `\r`, so on a CRLF stream every line kept a
            // trailing carriage return — "Copy" put `WDJB-MJHT\r` on the
            // pasteboard and the URL failed to parse. Nothing in the current
            // `-T`/pipe transports produces CRLF, which is exactly why this
            // would have been found by a user and not by us.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.contains(Self.completionSentinel) { sawSentinel = true }
            if url == nil, let range = line.range(of: "MCP OAuth: open ") {
                // "…open <url> on any device." — take the URL token, which
                // cannot contain a space, rather than assuming the trailing
                // clause is exactly as worded.
                let rest = line[range.upperBound...]
                if let token = rest.split(separator: " ", omittingEmptySubsequences: true).first {
                    let candidate = String(token)
                    if candidate.hasPrefix("http://") || candidate.hasPrefix("https://") {
                        url = candidate
                    }
                }
            } else if code == nil, line.hasPrefix("Code: ") {
                let candidate = String(line.dropFirst("Code: ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { code = candidate }
            }
            if url != nil && code != nil && sawSentinel { break }
        }
        guard sawSentinel, let url, let code else { return nil }
        return HermesMCPDevicePrompt(verificationURL: url, userCode: code)
    }

    /// Whether an UNTERMINATED trailing fragment already carries the
    /// sentinel — the only fragment safe to read without its newline.
    private static func isSentinelLine(_ fragment: Substring?) -> Bool {
        guard let fragment else { return false }
        return fragment
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .contains(Self.completionSentinel)
    }
}
