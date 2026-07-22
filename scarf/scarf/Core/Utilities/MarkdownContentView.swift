import SwiftUI
import Marker

struct MarkdownContentView: View {
    let content: String

    /// Skip the block-AST pipeline mid-stream. `parseBlocks()` walks the
    /// full content on every body re-eval; at Hermes's ~30–60 chunks/sec
    /// that's quadratic over the message lifetime and was a dominant
    /// per-token render cost (cross-reference with the bubble-level
    /// `parseContentBlocks` skip in `RichMessageBubble.contentView`).
    /// Inline bold/italic/code/links still render via
    /// `MarkdownRenderer.inlineAttributedString`; tables (gh#134), code
    /// fences, headings, lists materialize on finalize when the caller
    /// flips this back to the full pipeline (block grammar now comes
    /// from the Marker engine — see `parseBlocks(from:)`).
    var streaming: Bool = false

    /// Chat font scale plumbed from `RichChatView` (issue #68). Defaults
    /// to 1.0 when this view is used outside the chat surface so other
    /// callers see the un-scaled rendering.
    @Environment(\.chatFontScale) private var chatFontScale: Double

    var body: some View {
        if streaming {
            Text(MarkdownRenderer.inlineAttributedString(content))
                .textSelection(.enabled)
                .font(ChatFontScale.body(chatFontScale))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Coalesce consecutive `.paragraph` blocks (with optional
                // `.blank` between them) into a single `Text(AttributedString)`
                // so the cursor can select across paragraphs (issue #93).
                // SwiftUI's `.textSelection(.enabled)` is per-Text — without
                // this pre-pass, every `\n\n` in the agent's reply silently
                // terminates the selection.
                let units = Self.coalesceParagraphs(parseBlocks())
                ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                    unitView(unit)
                }
            }
            // Paragraphs are rendered as plain `Text(AttributedString)` and
            // inherit whatever font is set on the enclosing scope. Pin the
            // scope to the scaled body font so the chat slider actually
            // moves the visible text.
            .font(ChatFontScale.body(chatFontScale))
        }
    }

    @ViewBuilder
    private func unitView(_ unit: RenderableUnit) -> some View {
        switch unit {
        case .block(let block):
            blockView(block)
        case .paragraphGroup(let texts):
            paragraphGroupView(texts: texts)
        }
    }

    /// Render a run of consecutive paragraphs as ONE Text, joining the
    /// per-paragraph AttributedStrings with `\n\n`. The single-Text
    /// shape is what makes selection span paragraph breaks — that's
    /// issue #93's whole point.
    private func paragraphGroupView(texts: [String]) -> some View {
        var combined = AttributedString()
        for (idx, text) in texts.enumerated() {
            if idx > 0 {
                combined.append(AttributedString("\n\n"))
            }
            combined.append(MarkdownRenderer.inlineAttributedString(text))
        }
        return Text(combined)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            // Reached only for a paragraph that wasn't coalesced (e.g.
            // a single paragraph adjacent to non-paragraph blocks). Same
            // selection semantics — the coalesced path is just a wider
            // selection scope.
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
        case .taskItem(let text, let checked, let indent):
            taskItemView(text: text, checked: checked, indent: indent)
        case .table(let table):
            tableView(table)
        case .horizontalRule:
            Divider().padding(.vertical, 4)
        case .blank:
            Spacer().frame(height: 4)
        }
    }

    // MARK: - Block Views

    private func headingView(level: Int, text: String) -> some View {
        // Heading sizes scale with `chatFontScale` (issue #68). Bases
        // mirror the SwiftUI semantic tokens we used previously
        // (`.title` ≈ 28, `.title2` ≈ 22, `.title3` ≈ 20, `.headline`
        // ≈ 17, `.subheadline` ≈ 15) so 100% matches today's UI.
        let baseSize: CGFloat = switch level {
        case 1: 28
        case 2: 22
        case 3: 20
        case 4: 17
        default: 15
        }
        return Text(MarkdownRenderer.inlineAttributedString(text))
            .font(.system(size: baseSize * chatFontScale, weight: .semibold))
            .textSelection(.enabled)
            .padding(.top, level <= 2 ? 8 : 4)
    }

    private func codeBlockView(code: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(ChatFontScale.caption2(chatFontScale).bold())
                    .foregroundStyle(.secondary)
            }
            Text(code)
                .font(ChatFontScale.codeInline(chatFontScale))
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

    private func taskItemView(text: String, checked: Bool, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: checked ? "checkmark.square" : "square")
                .foregroundStyle(.secondary)
            Text(MarkdownRenderer.inlineAttributedString(text))
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    /// GFM grid table (gh#134) — header row, hairline, data rows. Column
    /// alignment comes from the separator row (`:--`, `:-:`, `--:`); cell
    /// text goes through the same inline renderer as paragraphs so bold /
    /// code / links inside cells work. Chrome matches `codeBlockView`.
    private func tableView(_ table: MarkdownTableModel) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    Text(MarkdownRenderer.inlineAttributedString(cell))
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                        .gridColumnAlignment(Self.columnAlignment(table.alignments[column]))
                }
            }
            Divider()
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(MarkdownRenderer.inlineAttributedString(cell))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(.textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private static func columnAlignment(_ alignment: MarkdownTableModel.ColumnAlignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
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

    // MARK: - Parser (Marker engine)

    private func parseBlocks() -> [MarkdownBlock] {
        Self.parseBlocks(from: content)
    }

    /// Classify `content` with the Marker engine's block parser and map
    /// the result onto Scarf's renderable block model. Marker owns block
    /// grammar — including GFM tables, the gap behind gh#134 — while the
    /// mapping preserves this view's established semantics: each source
    /// line of a paragraph stays its own `.paragraph` (line breaks render
    /// as visual breaks), blockquote lines join with a space, consecutive
    /// blanks collapse, and bullet indent is 2-spaces-per-level.
    ///
    /// `internal` so scarfTests can pin the mapping without a view.
    static func parseBlocks(from content: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []

        func appendBlank() {
            if blocks.last != .blank { blocks.append(.blank) }
        }
        // Old-parser paragraph semantics, also the fallback for a pipe
        // fragment that isn't a real grid table.
        func appendParagraphLines(_ text: String) {
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                trimmed.isEmpty ? appendBlank() : blocks.append(.paragraph(trimmed))
            }
        }

        for block in MarkdownParser.parse(strippingFrontmatter(content)).blocks {
            switch block.kind {
            case .blank:
                appendBlank()
            case .heading(let level):
                blocks.append(.heading(level, block.contentText))
            case .paragraph:
                appendParagraphLines(block.contentText)
            case .blockquote:
                blocks.append(.blockquote(block.contentText.replacingOccurrences(of: "\n", with: " ")))
            case .bulletItem:
                blocks.append(.bulletItem(block.contentText, indent: block.indent / 2))
            case .taskItem(let checked):
                blocks.append(.taskItem(block.contentText, checked: checked, indent: block.indent / 2))
            case .orderedItem(let number):
                blocks.append(.numberedItem(number, block.contentText))
            case .codeBlock(let language):
                blocks.append(.codeBlock(block.contentText, language: language))
            case .thematicBreak:
                blocks.append(.horizontalRule)
            case .table:
                if let table = Marker.MarkdownTable.parse(block.text) {
                    blocks.append(.table(MarkdownTableModel(table)))
                } else {
                    appendParagraphLines(block.contentText)
                }
            }
        }
        return blocks
    }

    /// Skip a `---`-delimited YAML frontmatter block at the start of the
    /// file (SKILL.md, memory notes). Unterminated frontmatter consumes
    /// the rest of the document — same behavior as the previous parser.
    private static func strippingFrontmatter(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return content }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(i + 1)...].joined(separator: "\n")
        }
        return ""
    }

    /// Walk the parsed block list and collapse runs of `.paragraph`
    /// (with optional `.blank` separators between them) into a single
    /// `RenderableUnit.paragraphGroup`. Non-paragraph blocks stay as
    /// `.block(...)` units.
    ///
    /// Why: each block previously rendered to its own SwiftUI `Text`,
    /// and SwiftUI's `.textSelection(.enabled)` is per-Text. The user
    /// could drag-select within one paragraph but not across the
    /// `\n\n` gap to the next — issue #93. Joining a run into one
    /// AttributedString preserves the visual gap (real `\n\n` in the
    /// rendered text) while giving the cursor one continuous selection
    /// scope.
    ///
    /// Visible behavior change is scoped to consecutive paragraphs.
    /// Selection across a heading/list/code-block boundary still
    /// terminates — fixing that requires NSTextView and a much larger
    /// refactor; the common case (multi-paragraph agent reply) is what
    /// the user actually reported.
    ///
    /// `internal` so the scarfTests target can pin the coalescing
    /// invariants without touching the SwiftUI render path.
    static func coalesceParagraphs(_ blocks: [MarkdownBlock]) -> [RenderableUnit] {
        var units: [RenderableUnit] = []
        var currentRun: [String] = []
        var pendingBlank = false

        func flushRun() {
            if !currentRun.isEmpty {
                units.append(.paragraphGroup(currentRun))
                currentRun.removeAll()
            }
            if pendingBlank {
                units.append(.block(.blank))
                pendingBlank = false
            }
        }

        for block in blocks {
            switch block {
            case .paragraph(let text):
                // Trailing blank from earlier is absorbed by the
                // `\n\n` join in the rendered paragraphGroup.
                pendingBlank = false
                currentRun.append(text)
            case .blank:
                if currentRun.isEmpty {
                    // Not in a paragraph run — emit the vertical gap
                    // verbatim (matches pre-fix rendering between
                    // non-paragraph blocks).
                    units.append(.block(.blank))
                } else {
                    // In a run. Defer: if the next block is another
                    // paragraph the run continues; if it's a
                    // structural block we'll flush + render the
                    // blank as a real visual gap.
                    pendingBlank = true
                }
            default:
                flushRun()
                units.append(.block(block))
            }
        }
        flushRun()
        return units
    }
}

// MARK: - Block Model

/// Parsed markdown block. `internal` so scarfTests can pin the
/// `coalesceParagraphs` invariants without re-implementing the parser
/// from scratch.
enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case codeBlock(String, language: String?)
    case bulletItem(String, indent: Int)
    case numberedItem(Int, String)
    case taskItem(String, checked: Bool, indent: Int)
    case blockquote(String)
    case table(MarkdownTableModel)
    case horizontalRule
    case blank
}

/// A parsed GFM grid table, decoupled from the Marker engine's own
/// `MarkdownTable` (which carries byte-range bookkeeping Scarf's
/// display-only rendering doesn't need) so `MarkdownBlock` and the
/// tests that pin it stay free of vendor types. Cell strings are
/// display text — `\|` unescaped, padding trimmed, rows normalized
/// to the header's column count by Marker.
struct MarkdownTableModel: Equatable {
    enum ColumnAlignment: Equatable {
        case leading, center, trailing
    }

    let header: [String]
    /// Always `header.count` entries.
    let alignments: [ColumnAlignment]
    let rows: [[String]]
}

extension MarkdownTableModel {
    init(_ table: Marker.MarkdownTable) {
        self.init(
            header: table.header.map(\.text),
            alignments: table.alignments.map { alignment in
                switch alignment {
                case .left: .leading
                case .center: .center
                case .right: .trailing
                }
            },
            rows: table.rows.map { $0.map(\.text) }
        )
    }
}

/// Output of `MarkdownContentView.coalesceParagraphs(_:)`. Either a
/// single non-paragraph block we render verbatim, or a coalesced run
/// of paragraphs that becomes one selectable `Text(AttributedString)`.
enum RenderableUnit: Equatable {
    case block(MarkdownBlock)
    case paragraphGroup([String])
}
