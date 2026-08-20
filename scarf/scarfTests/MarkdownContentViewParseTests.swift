import Testing
@testable import scarf

/// Pins `MarkdownContentView.parseBlocks(from:)` — the mapping from the
/// Marker engine's block classification onto Scarf's renderable model.
/// Two jobs: (1) tables actually parse now (gh#134), and (2) everything
/// that rendered before the Marker swap still maps the same way —
/// per-line paragraphs, space-joined blockquotes, collapsed blanks,
/// 2-space bullet indent, skipped frontmatter.
@Suite struct MarkdownContentViewParseTests {

    // MARK: - Tables (gh#134)

    @Test func tableParsesIntoStructuredBlock() {
        let blocks = MarkdownContentView.parseBlocks(from: """
        | Model | Context | Use |
        |:------|--------:|-----|
        | Haiku | 200k | Fast \\| cheap |
        | Opus | 200k | Deep work |
        """)
        #expect(blocks == [.table(MarkdownTableModel(
            header: ["Model", "Context", "Use"],
            alignments: [.leading, .trailing, .leading],
            rows: [
                ["Haiku", "200k", "Fast | cheap"],
                ["Opus", "200k", "Deep work"],
            ]
        ))])
    }

    @Test func pipeFragmentWithoutSeparatorFallsBackToParagraphs() {
        // A lone pipe-ish line isn't a grid table — render raw, as before.
        let blocks = MarkdownContentView.parseBlocks(from: "| just | pipes |\n")
        #expect(blocks == [.paragraph("| just | pipes |")])
    }

    @Test func tableBetweenParagraphsKeepsItsNeighbors() {
        let blocks = MarkdownContentView.parseBlocks(from: """
        Before.

        | A | B |
        |---|---|
        | 1 | 2 |

        After.
        """)
        #expect(blocks.count == 5)
        #expect(blocks[0] == .paragraph("Before."))
        #expect(blocks[1] == .blank)
        guard case .table(let table) = blocks[2] else {
            Issue.record("expected table, got \(blocks[2])")
            return
        }
        #expect(table.header == ["A", "B"])
        #expect(table.rows == [["1", "2"]])
        #expect(blocks[3] == .blank)
        #expect(blocks[4] == .paragraph("After."))
    }

    // MARK: - Parity with the previous hand-rolled parser

    @Test func frontmatterIsSkipped() {
        let blocks = MarkdownContentView.parseBlocks(from: """
        ---
        name: my-skill
        ---
        # Title
        """)
        #expect(blocks == [.heading(1, "Title")])
    }

    @Test func paragraphLinesStaySeparateAndBlanksCollapse() {
        // Note: unlike the old `components(separatedBy: "\n")` parser,
        // Marker's line scan emits no phantom blank after the final
        // terminator — the invisible trailing `.blank` is gone.
        let blocks = MarkdownContentView.parseBlocks(from: "line one\nline two\n\n\nline three\n")
        #expect(blocks == [
            .paragraph("line one"),
            .paragraph("line two"),
            .blank,
            .paragraph("line three"),
        ])
    }

    @Test func blockquoteLinesJoinWithSpaces() {
        let blocks = MarkdownContentView.parseBlocks(from: "> first\n> second\n")
        #expect(blocks == [.blockquote("first second")])
    }

    @Test func listsMapWithIndentAndNumbers() {
        let blocks = MarkdownContentView.parseBlocks(from: "- top\n  - nested\n1. one\n")
        #expect(blocks == [
            .bulletItem("top", indent: 0),
            .bulletItem("nested", indent: 1),
            .numberedItem(1, "one"),
        ])
    }

    @Test func taskItemsCarryCheckedState() {
        let blocks = MarkdownContentView.parseBlocks(from: "- [ ] todo\n- [x] done\n")
        #expect(blocks == [
            .taskItem("todo", checked: false, indent: 0),
            .taskItem("done", checked: true, indent: 0),
        ])
    }

    @Test func paddedTaskCheckboxesParseWithCorrectCheckedStateAndText() {
        // Marker 0.9.0's `MarkdownParser.taskState` is lenient about
        // whitespace inside the checkbox — "[ x]", "[x ]", "[  ]",
        // "[ X ]" all parse as task items (checked iff x/X present),
        // and `contentText` strips the whole padded box span.
        let blocks = MarkdownContentView.parseBlocks(from: """
        - [ x] a
        - [x ] b
        - [  ] c
        - [ X ] d
        """)
        #expect(blocks == [
            .taskItem("a", checked: true, indent: 0),
            .taskItem("b", checked: true, indent: 0),
            .taskItem("c", checked: false, indent: 0),
            .taskItem("d", checked: true, indent: 0),
        ])
    }

    @Test func bareEmptyBracketsAreNotATaskBox() {
        // "- []" (no space inside the brackets at all) isn't a task
        // checkbox per Marker 0.9.0 — it stays a plain bullet.
        let blocks = MarkdownContentView.parseBlocks(from: "- [] e\n")
        #expect(blocks == [.bulletItem("[] e", indent: 0)])
    }

    @Test func codeFenceKeepsInteriorVerbatim() {
        let blocks = MarkdownContentView.parseBlocks(from: "```bash\nls -la\n# comment, not heading\n```\n")
        #expect(blocks == [.codeBlock("ls -la\n# comment, not heading", language: "bash")])
    }

    @Test func headingAndRule() {
        let blocks = MarkdownContentView.parseBlocks(from: "## Section\n\n---\n")
        #expect(blocks == [.heading(2, "Section"), .blank, .horizontalRule])
    }
}
