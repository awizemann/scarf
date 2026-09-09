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
/// Parsing is deliberately tolerant of the surrounding decoration (leading
/// whitespace, interleaved log lines) but anchored on the two literal labels,
/// so a change in Hermes's wording is a parse failure — visible — rather than
/// a wrong URL. `HermesMCPDevicePromptTests` pins the verbatim v2026.9.7 text.
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

    /// Parse the prompt out of accumulated CLI output, or `nil` when it isn't
    /// (yet) there. Safe to call on every chunk: the block is only complete
    /// once BOTH lines have arrived, and a partial read returns nil rather
    /// than a half-built prompt.
    public static func parse(_ output: String) -> HermesMCPDevicePrompt? {
        var url: String?
        var code: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
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
                    .trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { code = candidate }
            }
            if url != nil && code != nil { break }
        }
        guard let url, let code else { return nil }
        return HermesMCPDevicePrompt(verificationURL: url, userCode: code)
    }
}
