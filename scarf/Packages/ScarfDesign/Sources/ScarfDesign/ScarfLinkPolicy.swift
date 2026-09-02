import SwiftUI

/// The scheme allowlist every markdown-rendering container in Scarf — Mac
/// and iOS alike — puts in front of `openURL`.
///
/// **Why this exists.** Markdown we render is not ours: it arrives in chat
/// replies, `markdown_file` / `text` dashboard widgets, session detail,
/// activity, skills, and third-party template READMEs. SwiftUI's
/// `AttributedString(markdown:)` turns `[click here](…)` into a live link
/// with *any* scheme, and the default `openURL` action hands it straight to
/// the system: `file:` opens the user's local files, `javascript:` and
/// `data:` are script/exfil vectors, and a custom `x-…` scheme silently
/// hands the URL to whatever other app registered it. One crafted link in a
/// summarized document is enough. Only the three schemes a document link
/// can legitimately mean are forwarded.
///
/// **Why it is a shared modifier and not a per-view closure.** The Mac fix
/// originally lived inline in `MarkdownContentView` with a comment claiming
/// it covered every markdown link in the app. It did not: `TemplateMarkdown`
/// (template install/config sheets) and the whole iOS widget stack render
/// markdown through their own containers and never saw it. A container that
/// renders untrusted markdown must apply `.scarfSafeLinks()` explicitly —
/// there is no single chokepoint, and pretending there was is what let the
/// gap sit. (F9)
public enum ScarfLinkPolicy {

    /// `http`, `https`, `mailto` — nothing else. Deliberately narrow: `tel:`
    /// and `sms:` are not document-link semantics, and every custom scheme
    /// is an app hand-off we have not vetted.
    public static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// True when `url` may be handed to the system from rendered markdown.
    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedLinkSchemes.contains(scheme)
    }
}

private struct ScarfSafeLinksModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            ScarfLinkPolicy.allows(url) ? .systemAction : .discarded
        })
    }
}

public extension View {
    /// Constrain every link opened from this subtree to
    /// ``ScarfLinkPolicy/allowedLinkSchemes``.
    ///
    /// Apply this to any container that renders markdown Scarf did not
    /// author. Do NOT apply it at a screen root that also contains Scarf's
    /// own hardcoded buttons — those are trusted and occasionally need other
    /// schemes.
    func scarfSafeLinks() -> some View {
        modifier(ScarfSafeLinksModifier())
    }
}
