import SwiftUI

struct MarkdownContentView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            Text(MarkdownRenderer.inlineAttributedString(text))
                .textSelection(.enabled)
        case .codeBlock(let code, let language):
            codeBlockView(code: code, language: language)
        case .bulletItem(let text, let indent):
            bulletView(text: text, indent: indent)
        case .numberedItem(let number, let text):
            numberedView(number: number, text: text)
        case .blockquote(let text):
            blockquoteView(text: text)
        case .horizontalRule:
            Divider().padding(.vertical, 4)
        case .blank:
            Spacer().frame(height: 4)
        }
    }

    // MARK: - Block Views

    private func headingView(level: Int, text: String) -> some View {
        let font: Font = switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        case 3: .title3.bold()
        case 4: .headline
        default: .subheadline.bold()
        }
        return Text(MarkdownRenderer.inlineAttributedString(text))
            .font(font)
            .textSelection(.enabled)
            .padding(.top, level <= 2 ? 8 : 4)
    }

    private func codeBlockView(code: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
            }
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private func bulletView(text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\u{2022}")
                .foregroundStyle(.secondary)
            Text(MarkdownRenderer.inlineAttributedString(text))
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    private func numberedView(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(MarkdownRenderer.inlineAttributedString(text))
                .textSelection(.enabled)
        }
    }

    private func blockquoteView(text: String) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(.blue.opacity(0.5))
                .frame(width: 3)
            Text(MarkdownRenderer.inlineAttributedString(text))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 10)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Parser

    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0

        // Skip YAML frontmatter (--- delimited block at start of file)
        if i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            i += 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                    i += 1
                    break
                }
                i += 1
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line
            if trimmed.isEmpty {
                if blocks.last != .blank {
                    blocks.append(.blank)
                }
                i += 1
                continue
            }

            // Code block (fenced)
            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(codeLines.joined(separator: "\n"), language: language.isEmpty ? nil : language))
                continue
            }

            // Heading
            if let heading = parseHeading(trimmed) {
                blocks.append(heading)
                i += 1
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("> ") {
                        quoteLines.append(String(l.dropFirst(2)))
                    } else if l.hasPrefix(">") {
                        quoteLines.append(String(l.dropFirst(1)))
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: " ")))
                continue
            }

            // Bullet list
            if let bullet = parseBullet(line) {
                blocks.append(bullet)
                i += 1
                continue
            }

            // Numbered list
            if let numbered = parseNumbered(trimmed) {
                blocks.append(numbered)
                i += 1
                continue
            }

            // Paragraph — each line is its own paragraph to preserve line breaks
            blocks.append(.paragraph(trimmed))
            i += 1
        }

        return blocks
    }

    private func parseHeading(_ line: String) -> MarkdownBlock? {
        let levels: [(prefix: String, level: Int)] = [
            ("##### ", 5), ("#### ", 4), ("### ", 3), ("## ", 2), ("# ", 1)
        ]
        for (prefix, level) in levels {
            if line.hasPrefix(prefix) {
                return .heading(level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private func parseBullet(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix(while: { $0 == " " }).count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") {
            return .bulletItem(String(trimmed.dropFirst(2)), indent: indent)
        }
        if trimmed.hasPrefix("* ") {
            return .bulletItem(String(trimmed.dropFirst(2)), indent: indent)
        }
        return nil
    }

    private func parseNumbered(_ line: String) -> MarkdownBlock? {
        guard let dotIdx = line.firstIndex(of: ".") else { return nil }
        let numStr = String(line[line.startIndex..<dotIdx])
        guard let num = Int(numStr), line[line.index(after: dotIdx)...].hasPrefix(" ") else { return nil }
        let text = String(line[line.index(dotIdx, offsetBy: 2)...])
        return .numberedItem(num, text)
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        return (stripped.allSatisfy({ $0 == "-" }) && stripped.count >= 3) ||
               (stripped.allSatisfy({ $0 == "*" }) && stripped.count >= 3) ||
               (stripped.allSatisfy({ $0 == "_" }) && stripped.count >= 3)
    }
}

// MARK: - Block Model

private enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case codeBlock(String, language: String?)
    case bulletItem(String, indent: Int)
    case numberedItem(Int, String)
    case blockquote(String)
    case horizontalRule
    case blank
}
