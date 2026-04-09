import Foundation

enum MarkdownRenderer {
    /// Inline-only rendering — bold, italic, code spans, links. Preserves whitespace/newlines.
    static func inlineAttributedString(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(text)
    }
}
