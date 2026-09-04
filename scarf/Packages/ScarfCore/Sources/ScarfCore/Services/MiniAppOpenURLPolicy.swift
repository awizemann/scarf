import Foundation

/// What `scarf.openURL(url)` is allowed to hand to the user's browser.
///
/// The string arrives from untrusted — usually agent-generated — web
/// content, and what happens next is that the user's default browser is
/// pointed at it. So the URL is not "sanitized"; it is either recognized as
/// one of a narrow shape or refused outright. Nothing is repaired: a URL we
/// half-understand is a URL we cannot describe honestly in the confirmation
/// the user is about to answer.
///
/// The shape:
/// - `https` only. `http` is refused (not downgraded), and so is every
///   other scheme — `file:` reads the disk, `x-apple…`/`sh…` and friends
///   hand the string to whatever app claims the scheme, which is a launcher,
///   not a link.
/// - A host must be present and must be plain ASCII `[a-z0-9.-]` after
///   `URL`'s own normalization. A Unicode host is not rejected — `URL`
///   punycodes it, and the confirmation then says `xn--pple-43d.com`
///   rather than `аpple.com`, so a homograph domain announces itself
///   instead of borrowing the name it imitates. Punycode shown as punycode
///   is ugly and is the safe direction, matching `ImageHostConsentStore`.
///   What the charset does refuse outright is anything that isn't a name a
///   person can judge at all: IPv6 literals, and any residue that survives
///   with a `:`, `/`, `@` or worse in it.
/// - No userinfo. `https://apple.com@evil.example/` has host `evil.example`
///   and reads as Apple to a person; there is no legitimate use of userinfo
///   in a link a mini-app asks to open.
/// - Length capped, and no control characters or whitespace anywhere — both
///   so the confirmation renders as one line that means what it says.
///
/// Note what is NOT restricted: the path and the query. They travel to the
/// host on the click, so a mini-app can encode a message in a link the user
/// chooses to follow. That is accepted — it is exactly the power a rendered
/// `<a href>` has in any app, the user is shown the URL before it opens, and
/// restricting it would break ordinary links (`?q=`, share URLs, deep
/// links) for no real gain.
public enum MiniAppOpenURLPolicy {

    /// Longest URL that will be opened. Comfortably above real links, well
    /// under the point where the confirmation stops being readable.
    public static let maxLength = 2048

    /// Why a URL was refused. Carries no page-supplied text, so it is safe
    /// to log publicly and to hand back to the page as an error.
    public enum Refusal: String, Sendable, Equatable, Error {
        case empty
        case tooLong
        case illegalCharacters
        case malformed
        case schemeNotHTTPS
        case userInfoPresent
        case missingHost
        case illegalHost

        /// Message sent back over the bridge (and shown in logs).
        public var message: String {
            switch self {
            case .empty: return "openURL needs a URL"
            case .tooLong: return "URL is too long (max \(MiniAppOpenURLPolicy.maxLength) characters)"
            case .illegalCharacters: return "URL contains control characters or whitespace"
            case .malformed: return "URL could not be parsed"
            case .schemeNotHTTPS: return "only https URLs can be opened"
            case .userInfoPresent: return "URLs with embedded credentials are not allowed"
            case .missingHost: return "URL has no host"
            case .illegalHost: return "host must be plain ASCII letters, digits, '.' or '-'"
            }
        }
    }

    /// A URL that passed, with the host exactly as it will be shown to the
    /// user and stored as consent (lowercased, trailing dot stripped —
    /// `ImageHostConsentStore.normalizedHost`, so the string the user
    /// approves and the string that is remembered can never diverge).
    public struct Approved: Sendable, Equatable {
        public let url: URL
        public let host: String
    }

    public static func validate(_ raw: String) -> Result<Approved, Refusal> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.count <= maxLength else { return .failure(.tooLong) }
        // Checked on the TRIMMED string, so an interior newline (which could
        // make the confirmation's URL line hide a second line) is refused
        // while a stray trailing one is not.
        let illegal = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)
        guard trimmed.unicodeScalars.allSatisfy({ !illegal.contains($0) }) else {
            return .failure(.illegalCharacters)
        }
        guard let components = URLComponents(string: trimmed) else { return .failure(.malformed) }
        guard components.scheme?.lowercased() == "https" else { return .failure(.schemeNotHTTPS) }
        guard components.user == nil, components.password == nil else { return .failure(.userInfoPresent) }
        guard let url = components.url else { return .failure(.malformed) }
        guard let host = ImageHostConsentStore.normalizedHost(url) else { return .failure(.missingHost) }
        guard isDisplayableHost(host) else { return .failure(.illegalHost) }
        return .success(Approved(url: url, host: host))
    }

    /// A host that cannot misrepresent itself in the confirmation: ASCII
    /// letters, digits, `.` and `-` only, and no empty label.
    public static func isDisplayableHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("."), !host.contains("..") else { return false }
        return host.allSatisfy { c in
            guard c.isASCII else { return false }
            return c.isLowercase || c.isNumber || c == "." || c == "-"
        }
    }

    /// The URL as the confirmation shows it: capped so a very long query
    /// can't push the buttons off the sheet, and truncation is VISIBLE
    /// (`…`) so a user is never shown a prefix that reads as the whole URL.
    public static func displayString(_ url: URL, maxLength: Int = 300) -> String {
        let s = url.absoluteString
        return s.count <= maxLength ? s : String(s.prefix(maxLength)) + "…"
    }
}
