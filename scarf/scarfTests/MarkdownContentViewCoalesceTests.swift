import Testing
@testable import scarf

/// Coalescing invariants behind issue #93 ("Chat Text Not Selectable
/// Across Paragraphs"). The chat surface previously rendered each
/// markdown paragraph as its own `Text`, which terminated SwiftUI's
/// `.textSelection(.enabled)` at the block boundary. The fix pre-
/// merges runs of `.paragraph` (with optional intervening `.blank`)
/// into a single `RenderableUnit.paragraphGroup` so the rendered
/// `Text(AttributedString)` covers the whole run as one selection
/// scope.
@Suite struct MarkdownContentViewCoalesceTests {

    @Test func emptyInputProducesEmptyOutput() {
        let units = MarkdownContentView.coalesceParagraphs([])
        #expect(units.isEmpty)
    }

    @Test func singleParagraphCoalescesToOneGroup() {
        let units = MarkdownContentView.coalesceParagraphs([
            .paragraph("Just one paragraph.")
        ])
        #expect(units == [.paragraphGroup(["Just one paragraph."])])
    }

    @Test func consecutiveParagraphsCoalesce() {
        let units = MarkdownContentView.coalesceParagraphs([
            .paragraph("First."),
            .paragraph("Second."),
            .paragraph("Third.")
        ])
        #expect(units == [.paragraphGroup(["First.", "Second.", "Third."])])
    }

    @Test func paragraphsSeparatedByBlankStillCoalesce() {
        // The canonical agent-reply shape: `\n\n` between paragraphs
        // becomes `[paragraph, blank, paragraph]` after parseBlocks().
        // Coalescing must absorb the blank into the `\n\n` join, not
        // split the run.
        let units = MarkdownContentView.coalesceParagraphs([
            .paragraph("First paragraph."),
            .blank,
            .paragraph("Second paragraph.")
        ])
        #expect(units == [.paragraphGroup(["First paragraph.", "Second paragraph."])])
    }

    @Test func headingBreaksTheParagraphRun() throws {
        let units = MarkdownContentView.coalesceParagraphs([
            .paragraph("Intro."),
            .blank,
            .heading(2, "Section"),
            .paragraph("Body.")
        ])
        // Intro is its own group; heading is its own block; body is
        // its own group. Trailing blank before the heading is rendered
        // as a vertical gap so the visual spacing matches pre-fix.
        try #require(units.count == 4)
        #expect(units[0] == .paragraphGroup(["Intro."]))
        #expect(units[1] == .block(.blank))
        #expect(units[2] == .block(.heading(2, "Section")))
        #expect(units[3] == .paragraphGroup(["Body."]))
    }

    @Test func codeBlockBreaksTheParagraphRun() throws {
        let units = MarkdownContentView.coalesceParagraphs([
            .paragraph("Run this:"),
            .codeBlock("ls -la", language: "bash"),
            .paragraph("Then check the output.")
        ])
        try #require(units.count == 3)
        #expect(units[0] == .paragraphGroup(["Run this:"]))
        #expect(units[1] == .block(.codeBlock("ls -la", language: "bash")))
        #expect(units[2] == .paragraphGroup(["Then check the output."]))
    }

    @Test func bulletListBreaksTheParagraphRun() throws {
        let units = MarkdownContentView.coalesceParagraphs([
            .paragraph("Options:"),
            .bulletItem("First", indent: 0),
            .bulletItem("Second", indent: 0),
            .paragraph("Pick one.")
        ])
        try #require(units.count == 4)
        #expect(units[0] == .paragraphGroup(["Options:"]))
        #expect(units[1] == .block(.bulletItem("First", indent: 0)))
        #expect(units[2] == .block(.bulletItem("Second", indent: 0)))
        #expect(units[3] == .paragraphGroup(["Pick one."]))
    }

    @Test func leadingBlankRendersAsGap() throws {
        let units = MarkdownContentView.coalesceParagraphs([
            .blank,
            .paragraph("After a gap.")
        ])
        // Blank before any paragraph run — emit as a gap, not absorbed
        // into a group (there's no preceding paragraph to absorb into).
        try #require(units.count == 2)
        #expect(units[0] == .block(.blank))
        #expect(units[1] == .paragraphGroup(["After a gap."]))
    }

    @Test func trailingBlankAfterParagraphIsFlushedAsGap() {
        // A trailing blank after the last paragraph run was pending in
        // the coalescer state when input ended, so flushRun() emits it
        // verbatim. Visually invisible inside the chat bubble's tail
        // padding anyway — matches pre-fix behavior (the previous code
        // rendered every `.blank` as `Spacer().frame(height: 4)`).
        let units = MarkdownContentView.coalesceParagraphs([
            .paragraph("Last paragraph."),
            .blank
        ])
        #expect(units == [.paragraphGroup(["Last paragraph."]), .block(.blank)])
    }

    @Test func interleavedParagraphBlankBlockProducesSeparateGroupsAndGap() throws {
        // Two paragraph runs separated by a heading — each run gets
        // its own selection scope; both `.blank`s are emitted verbatim
        // (one absorbs into the flushed pendingBlank before the
        // heading; the other is between the heading and the next
        // paragraph run, where currentRun is empty so it renders as
        // a real gap).
        let units = MarkdownContentView.coalesceParagraphs([
            .paragraph("p1a"),
            .paragraph("p1b"),
            .blank,
            .heading(1, "Title"),
            .blank,
            .paragraph("p2a")
        ])
        try #require(units.count == 5)
        #expect(units[0] == .paragraphGroup(["p1a", "p1b"]))
        #expect(units[1] == .block(.blank))
        #expect(units[2] == .block(.heading(1, "Title")))
        #expect(units[3] == .block(.blank))
        #expect(units[4] == .paragraphGroup(["p2a"]))
    }
}
