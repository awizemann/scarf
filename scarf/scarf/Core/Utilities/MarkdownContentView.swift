import SwiftUI
import Marker
import ScarfDesign

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
        renderedBody
            // Applied at THIS container, which covers the markdown surfaces
            // rendered through it (chat transcript, markdown_file and text
            // widgets, session detail, activity, skills). Scoping it here
            // rather than at a screen root is deliberate: it cannot reach the
            // app's own hardcoded buttons/links elsewhere, which are trusted
            // and sometimes need other schemes.
            //
            // It is NOT, however, the app's only markdown container — an
            // earlier comment here claimed it was. `TemplateMarkdown` and the
            // iOS widget views render markdown through their own containers
            // and apply `.scarfSafeLinks()` themselves. The policy lives in
            // ScarfDesign so all of them share one definition. (F9)
            .scarfSafeLinks()
    }

    @ViewBuilder
    private var renderedBody: some View {
        if streaming {
            // gh#140 phase 2: the previous single
            // `Text(inlineAttributedString(content))` re-parsed and
            // re-laid-out the FULL accumulated reply on every flush —
            // O(reply length) each time, quadratic over the turn, and
            // the dominant remaining cost once the flush rate itself
            // was throttled. `StreamingMarkdownText` splits the reply
            // at the last completed paragraph: the settled prefix is
            // parsed once and its `Text` input never changes (SwiftUI
            // skips its layout), so each flush only re-renders the
            // small live tail.
            StreamingMarkdownText(content: content)
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

// MARK: - Streaming renderer (gh#140)

/// Incremental renderer for the in-flight streaming bubble.
///
/// The stream is append-only, and everything before the last completed
/// paragraph boundary (`\n\n`) can never change again. So we keep a
/// settled prefix — parsed into one `AttributedString` exactly once,
/// extended only when new paragraphs complete — and a live tail that is
/// the only part re-parsed and re-laid-out per flush. The settled
/// `Text`'s input is value-equal between flushes, so SwiftUI skips its
/// diff and layout entirely; per-flush render cost is O(tail) instead
/// of O(full reply). On finalize the bubble's id flips off 0 and the
/// caller switches to the full block pipeline, so this view's output
/// only needs to match the OLD streaming rendering (inline markdown,
/// literal newlines), which it does: paragraphs are joined by the same
/// visual gap the `\n\n` used to produce.
///
/// Inline spans (bold/code/links) never legitimately cross a blank
/// line, so parsing settled paragraphs separately from the tail yields
/// the same attributed output as one whole-string parse.
struct StreamingMarkdownText: View {
    let content: String

    /// Everything up to (and including) the last absorbed `\n\n`.
    /// Invariant: `content.hasPrefix(settledSource)` — checked each
    /// absorb; a mismatch (new turn reusing the view, or a reset)
    /// rebuilds from scratch.
    @State private var settledSource = ""
    /// `settledSource` parsed, WITHOUT its trailing paragraph gap —
    /// the gap between settled and tail comes from the VStack spacing.
    @State private var settledText = AttributedString()
    /// Incremental fence-scan cursor over the CURRENT unsettled tail.
    /// While a fenced block streams nothing settles, so the tail grows
    /// without bound and a from-scratch scan per delta is O(n²) on the
    /// main actor. This carries the scan position and fence state at the
    /// last scanned prefix so each delta only walks the bytes it added.
    /// Invalidated whenever the tail's own start moves (a settle) or the
    /// append invariant breaks (the `hasPrefix` reset path).
    @State private var scanState = StreamingFenceScanner.ResumeState()

    var body: some View {
        // Derive the tail directly from current inputs so the very
        // first body eval after a flush is correct even before
        // `.onChange` absorbs the new boundary — the tail is just
        // briefly longer than optimal, never wrong.
        let tail = content.hasPrefix(settledSource)
            ? String(content[settledSource.endIndex...])
            : content
        VStack(alignment: .leading, spacing: 6) {
            if !settledText.characters.isEmpty {
                Text(settledText)
                    .textSelection(.enabled)
            }
            if !tail.isEmpty {
                Text(MarkdownRenderer.inlineAttributedString(tail))
                    .textSelection(.enabled)
            }
        }
        .onAppear { absorbSettledParagraphs() }
        .onChange(of: content) { absorbSettledParagraphs() }
    }

    /// Move any newly-completed paragraphs from the tail into the
    /// settled prefix. The `hasPrefix` guard is a memcmp — cheap
    /// relative to the parse it saves — and doubles as the reset
    /// detector for non-append mutations.
    private func absorbSettledParagraphs() {
        if !content.hasPrefix(settledSource) {
            settledSource = ""
            settledText = AttributedString()
            scanState = StreamingFenceScanner.ResumeState()
        }
        let tail = content[settledSource.endIndex...]
        // Only settle at a blank line that is OUTSIDE a code fence. A
        // plain "last \n\n" split happily landed between a fence's
        // opening ``` and its body, which put an unbalanced backtick
        // run in the settled prefix and another in the tail; each half
        // was then inline-parsed on its own, so the code block rendered
        // as garbled prose (and stayed that way until finalize swapped
        // in the block pipeline). See `StreamingFenceScanner`.
        guard let boundary = StreamingFenceScanner.lastSettleBoundary(
            in: tail,
            resuming: &scanState
        ) else { return }
        let completed = tail[..<boundary.completedEnd]
        if !completed.isEmpty {
            if !settledText.characters.isEmpty {
                settledText.append(AttributedString("\n\n"))
            }
            settledText.append(MarkdownRenderer.inlineAttributedString(String(completed)))
        }
        // Consume the separator too — the settled/tail visual gap is
        // owned by the VStack spacing from here on. The tail's start
        // index moves with it, so the resume cursor no longer describes
        // this tail and must be dropped.
        settledSource = String(content[..<boundary.boundaryEnd])
        scanState = StreamingFenceScanner.ResumeState()
    }
}

// MARK: - Fence-aware settle boundary

/// Finds the last point in a streaming chunk where the renderer may
/// safely cut a settled prefix off the live tail.
///
/// The rule is the old one — a blank line, i.e. a literal `\n\n` —
/// *plus* the constraint that the blank line must not be inside a
/// fenced code block. Fence state is tracked with CommonMark's rules
/// so the common adversarial chunkings behave:
///
/// - ``` and ~~~ are independent fence characters; a ~~~ never closes
///   a ``` run and vice versa.
/// - A closing fence must use the same character and be at least as
///   long as the opener, with nothing but whitespace after it. So
///   ```` ```` inside a ``` block doesn't close it early.
/// - An opening ``` fence may carry an info string (` ```swift `), but
///   a backtick fence's info string may not itself contain a backtick.
/// - Up to 3 leading spaces still opens a fence; 4+ (or a leading tab)
///   is an indented code block where ``` is literal text, not a fence.
/// - Blockquote markers are stripped, so a fence inside a `>` quote
///   still suppresses settling rather than leaking a half fence into
///   the settled prefix.
///
/// An unterminated fence simply means nothing new settles until it
/// closes: the tail grows, output stays correct, and finalize hands
/// off to the full block pipeline regardless. That is the intended
/// trade — correctness over an incremental-render optimization.
///
/// Cost is one linear pass over the *new* bytes of the unsettled tail
/// per delta when the caller carries a ``ResumeState`` (see
/// ``lastSettleBoundary(in:resuming:)``), which matters because an open
/// fence means nothing settles and the tail grows without bound —
/// rescanning it whole per delta is O(n²) on the main actor. The
/// stateless ``lastSettleBoundary(in:)`` overload keeps the original
/// whole-tail behavior and is the oracle the incremental path is pinned
/// against.
enum StreamingFenceScanner {
    /// Scan position plus fence state at the last scanned prefix of one
    /// specific unsettled tail.
    ///
    /// The stored indices are `String.Index` values into the base string
    /// the tail slices — valid across deltas for exactly the same reason
    /// `content[settledSource.endIndex...]` is: the content only ever
    /// grows by append, and every stored index sits immediately after a
    /// `\n` (or at the tail start), which is always a scalar *and*
    /// grapheme boundary that appending cannot move.
    ///
    /// A fresh value means "scan from the beginning". The owner must
    /// reset to a fresh value whenever the tail's own start moves (a
    /// settle) or the append invariant breaks.
    struct ResumeState {
        /// Start of the first not-yet-scanned line; nil = tail start.
        fileprivate var nextLineStart: Substring.Index?
        fileprivate var inFence = false
        fileprivate var fenceChar: Character = "`"
        fileprivate var fenceLength = 0
        fileprivate var result: (completedEnd: Substring.Index, boundaryEnd: Substring.Index)?

        init() {}
    }

    /// `completedEnd` is the end of the text to settle (exclusive of
    /// the separator); `boundaryEnd` is the index just past the `\n\n`.
    /// Nil when there is no eligible boundary yet.
    ///
    /// Stateless whole-tail scan — behaviorally identical to the
    /// resuming overload started from a fresh state.
    static func lastSettleBoundary(
        in tail: Substring
    ) -> (completedEnd: Substring.Index, boundaryEnd: Substring.Index)? {
        var fresh = ResumeState()
        return lastSettleBoundary(in: tail, resuming: &fresh)
    }

    /// Incremental form: resumes at `state`'s cursor and only walks the
    /// lines appended since the last call, then writes the new cursor
    /// and fence state back.
    static func lastSettleBoundary(
        in tail: Substring,
        resuming state: inout ResumeState
    ) -> (completedEnd: Substring.Index, boundaryEnd: Substring.Index)? {
        // A cursor that no longer addresses this tail means the caller
        // failed to invalidate; fall back to a full rescan rather than
        // trusting it.
        var lineStart = tail.startIndex
        if let saved = state.nextLineStart, saved >= tail.startIndex, saved <= tail.endIndex {
            lineStart = saved
        } else if state.nextLineStart != nil {
            state = ResumeState()
        }

        var inFence = state.inFence
        var fenceChar = state.fenceChar
        var fenceLength = state.fenceLength
        var result = state.result

        // Only fully-terminated lines are considered: an unterminated
        // trailing line can't be half of a `\n\n` separator, and its
        // fence marker may still be mid-delta (` `` ` before the third
        // backtick arrives), so judging it would flip state on a
        // partial token. That is also what makes the cursor safe to
        // persist: every line it has already consumed was complete, so
        // no later delta can change how it was classified.
        while let newline = tail[lineStart...].firstIndex(of: "\n") {
            let line = tail[lineStart..<newline]
            if inFence {
                if closesFence(line, char: fenceChar, length: fenceLength) {
                    inFence = false
                    fenceLength = 0
                }
            } else if let opener = opensFence(line) {
                inFence = true
                fenceChar = opener.char
                fenceLength = opener.length
            } else if line.isEmpty, lineStart > tail.startIndex {
                // `lineStart > startIndex` guarantees the character
                // before it is the previous line's newline, so this
                // empty line really is the second half of a `\n\n`.
                result = (
                    completedEnd: tail.index(before: lineStart),
                    boundaryEnd: tail.index(after: newline)
                )
            }
            lineStart = tail.index(after: newline)
        }

        state.nextLineStart = lineStart
        state.inFence = inFence
        state.fenceChar = fenceChar
        state.fenceLength = fenceLength
        state.result = result
        return result
    }

    /// Strips up to 3 leading spaces and any blockquote markers.
    /// Returns nil when the line is indented 4+ spaces (or starts with
    /// a tab) — that's an indented code block, where a ``` run is
    /// literal text and must not toggle fence state.
    private static func stripped(_ line: Substring) -> Substring? {
        var s = line
        var indent = 0
        while let first = s.first, first == " ", indent < 4 {
            s = s.dropFirst()
            indent += 1
        }
        if indent >= 4 { return nil }
        if s.first == "\t" { return nil }
        while s.first == ">" {
            s = s.dropFirst()
            if s.first == " " { s = s.dropFirst() }
            var quoteIndent = 0
            while s.first == " ", quoteIndent < 3 {
                s = s.dropFirst()
                quoteIndent += 1
            }
        }
        return s
    }

    private static func opensFence(_ line: Substring) -> (char: Character, length: Int)? {
        guard let s = stripped(line), let first = s.first,
              first == "`" || first == "~" else { return nil }
        let length = s.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        let info = s.dropFirst(length)
        // A backtick fence's info string may not contain a backtick —
        // "``` a ``` b" is an inline-code paragraph, not a fence.
        if first == "`", info.contains("`") { return nil }
        return (first, length)
    }

    private static func closesFence(
        _ line: Substring,
        char: Character,
        length: Int
    ) -> Bool {
        guard let s = stripped(line), s.first == char else { return false }
        let run = s.prefix { $0 == char }.count
        guard run >= length else { return false }
        return s.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
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
