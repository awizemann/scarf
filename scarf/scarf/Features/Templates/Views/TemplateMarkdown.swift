import SwiftUI
import Foundation

/// Minimal markdown renderer used by the template install/config UIs.
///
/// SwiftUI `Text` has built-in inline-markdown support via
/// `AttributedString(markdown:)` — bold, italic, inline code, links.
/// That's enough for field descriptions + template taglines. For
/// longer content (README preview, full doc blocks), this helper adds
/// block-level handling: lines starting with `#`/`##`/`###` render
/// as bigger bold text; lines starting with `-`/`*`/`1.` render as
/// list items with a hanging indent; fenced ``` ``` blocks render as
/// monospaced; blank lines become paragraph breaks.
///
/// Scope is intentionally small. This isn't a full CommonMark
/// renderer — it's "enough markdown to make template READMEs look
/// right in the install sheet without pulling in a dependency." If
/// the set of templates needs more over time, evolve this file or
/// graduate to a proper library.
enum TemplateMarkdown {

    /// Render a markdown source string as a SwiftUI view. Preserves
    /// reading order and approximate visual hierarchy. Safe with
    /// untrusted input — we never execute HTML or scripts.
    @ViewBuilder
    static func render(_ source: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let blocks = parse(source)
            ForEach(blocks.indices, id: \.self) { i in
                block(blocks[i])
            }
        }
    }

    /// Inline-only markdown (bold/italic/code/links) as a single
    /// `Text`. Use for short strings where block structure doesn't
    /// apply — field labels, one-line descriptions.
    static func inlineText(_ source: String) -> Text {
        if let attr = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(source)
    }

    // MARK: - Block model

    fileprivate enum Block {
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        case bullet(AttributedString)
        case numbered(index: Int, text: AttributedString)
        case code(String)
    }

    // MARK: - Parser

    fileprivate static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let inner = lines[i]
                    if inner.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    body.append(inner)
                    i += 1
                }
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            // Heading.
            if let headingMatch = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                let level = (headingMatch.1).count
                let text = String(headingMatch.2)
                blocks.append(.heading(level: level, text: renderInline(text)))
                i += 1
                continue
            }

            // Bullet list.
            if let bulletMatch = line.firstMatch(of: /^\s*[-*]\s+(.*)$/) {
                let text = String(bulletMatch.1)
                blocks.append(.bullet(renderInline(text)))
                i += 1
                continue
            }

            // Numbered list.
            if let numMatch = line.firstMatch(of: /^\s*(\d+)\.\s+(.*)$/) {
                let index = Int(String(numMatch.1)) ?? 1
                let text = String(numMatch.2)
                blocks.append(.numbered(index: index, text: renderInline(text)))
                i += 1
                continue
            }

            // Blank line — skip.
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph — collect contiguous non-blank lines that
            // aren't headings/lists/fences into one paragraph block.
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrim = next.trimmingCharacters(in: .whitespaces)
                if nextTrim.isEmpty { break }
                if nextTrim.hasPrefix("```") { break }
                if nextTrim.firstMatch(of: /^#{1,6}\s/) != nil { break }
                if next.firstMatch(of: /^\s*[-*]\s+/) != nil { break }
                if next.firstMatch(of: /^\s*\d+\.\s+/) != nil { break }
                paragraphLines.append(next)
                i += 1
            }
            let joined = paragraphLines.joined(separator: " ")
            blocks.append(.paragraph(renderInline(joined)))
        }
        return blocks
    }

    /// Parse inline markdown (bold, italic, inline code, links) into
    /// an AttributedString. Falls back to plain text on parse failure.
    fileprivate static func renderInline(_ source: String) -> AttributedString {
        if let attr = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attr
        }
        return AttributedString(source)
    }

    // MARK: - Rendering

    @ViewBuilder
    fileprivate static func block(_ b: Block) -> some View {
        switch b {
        case .paragraph(let text):
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            headingText(text: text, level: level)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").font(.callout)
                Text(text).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let index, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index).").font(.callout.monospacedDigit())
                Text(text).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let src):
            Text(src)
                .font(.caption.monospaced())
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    fileprivate static func headingText(text: AttributedString, level: Int) -> some View {
        switch level {
        case 1: Text(text).font(.title2.bold()).padding(.top, 8)
        case 2: Text(text).font(.title3.bold()).padding(.top, 6)
        case 3: Text(text).font(.headline).padding(.top, 4)
        default: Text(text).font(.subheadline.bold()).padding(.top, 2)
        }
    }
}
