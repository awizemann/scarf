import Testing
@testable import scarf

/// Regression coverage for the v2.24.0 audit-board item "streaming
/// markdown fence-split boundary".
///
/// `StreamingMarkdownText` settles a prefix of the in-flight reply at
/// the last blank line so only the tail is re-parsed per delta. It used
/// to take the last `\n\n` unconditionally, which happily cut BETWEEN a
/// fence's opening ``` and its body: the settled half and the tail half
/// were then inline-parsed separately, each with an unbalanced backtick
/// run, so the code block rendered as garbled prose until finalize
/// swapped in the full block pipeline.
///
/// The invariant these tests pin: **no settle boundary ever lands
/// inside a fenced code block**, under any delta chunking.
@Suite struct StreamingFenceScannerTests {

    /// The settled prefix the renderer would produce for `content`,
    /// or nil when nothing settles yet.
    private func settled(_ content: String) -> String? {
        guard let b = StreamingFenceScanner.lastSettleBoundary(in: content[...]) else {
            return nil
        }
        return String(content[..<b.boundaryEnd])
    }

    /// True when the prefix contains an odd number of fence markers —
    /// i.e. it was cut inside a code block.
    private func hasUnbalancedFence(_ text: String) -> Bool {
        var open = false
        var char: Character = "`"
        var length = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            guard let first = trimmed.first, first == "`" || first == "~" else { continue }
            let run = trimmed.prefix { $0 == first }.count
            guard run >= 3 else { continue }
            if open {
                if first == char, run >= length,
                   trimmed.dropFirst(run).allSatisfy({ $0 == " " }) {
                    open = false
                }
            } else {
                if first == "`", trimmed.dropFirst(run).contains("`") { continue }
                open = true
                char = first
                length = run
            }
        }
        return open
    }

    // MARK: - Baseline: behaviour outside fences is unchanged

    @Test func noBlankLineSettlesNothing() {
        #expect(settled("Just a line of prose still streaming") == nil)
    }

    @Test func settlesAtTheLastBlankLineOutsideFences() {
        #expect(settled("One.\n\nTwo.\n\nThree still typing") == "One.\n\nTwo.\n\n")
    }

    /// Matches the old `range(of: "\n\n", options: .backwards)`
    /// semantics for a run of three newlines — the LAST pair wins.
    @Test func tripleNewlineConsumesTheLastPair() {
        let content = "a\n\n\nb"
        let b = StreamingFenceScanner.lastSettleBoundary(in: content[...])
        #expect(b.map { String(content[..<$0.completedEnd]) } == "a\n")
        #expect(b.map { String(content[..<$0.boundaryEnd]) } == "a\n\n\n")
    }

    // MARK: - The bug

    /// The exact artifact: a blank line inside a ``` block used to
    /// settle, splitting the fence.
    @Test func blankLineInsideBacktickFenceDoesNotSettle() {
        let content = """
        Here you go:

        ```swift
        let a = 1

        let b = 2
        """
        #expect(settled(content) == "Here you go:\n\n")
    }

    @Test func settlingResumesAfterTheFenceCloses() {
        let content = """
        Intro:

        ```swift
        let a = 1

        let b = 2
        ```

        Done.
        """
        let s = settled(content)
        #expect(s?.hasSuffix("```\n\n") == true)
        #expect(hasUnbalancedFence(s ?? "") == false)
    }

    // MARK: - Fence-character and length rules

    @Test func tildeFenceIsTrackedIndependentlyOfBackticks() {
        let content = """
        Intro:

        ~~~
        one

        two
        """
        #expect(settled(content) == "Intro:\n\n")
    }

    /// A ``` line must not close a ~~~ fence (and vice versa) — the
    /// classic state-desync when a code sample quotes the other marker.
    @Test func oppositeMarkerDoesNotCloseTheFence() {
        let content = """
        Intro:

        ~~~
        ```

        still inside
        """
        #expect(settled(content) == "Intro:\n\n")
    }

    /// A shorter run cannot close a longer opener, so a ``` line inside
    /// a ```` block leaves the fence open.
    @Test func shorterRunDoesNotCloseALongerFence() {
        let content = """
        Intro:

        ````
        ```

        still inside
        """
        #expect(settled(content) == "Intro:\n\n")
    }

    /// A closing fence may not carry an info string.
    @Test func closingFenceWithTrailingTextDoesNotClose() {
        let content = """
        Intro:

        ```
        code
        ``` nope

        still inside
        """
        #expect(settled(content) == "Intro:\n\n")
    }

    @Test func backtickFenceWithInfoStringOpens() {
        let content = """
        Intro:

        ```swift title=foo
        let a = 1

        let b = 2
        """
        #expect(settled(content) == "Intro:\n\n")
    }

    /// A backtick "fence" whose info string contains a backtick is not
    /// a fence at all — it's an inline-code paragraph.
    @Test func backtickRunWithBacktickInInfoIsNotAFence() {
        let content = """
        Intro:

        ``` a ``` b

        after
        """
        #expect(settled(content) == "Intro:\n\n``` a ``` b\n\n")
    }

    // MARK: - Indentation

    @Test func fenceIndentedUpToThreeSpacesStillOpens() {
        let content = """
        Intro:

           ```
        code

        more
        """
        #expect(settled(content) == "Intro:\n\n")
    }

    /// Four spaces is an indented code block — the ``` there is literal
    /// text and must NOT toggle fence state, or every indented snippet
    /// that mentions a fence would stall settling forever.
    @Test func fourSpaceIndentedFenceMarkerIsLiteral() {
        let content = """
        Intro:

            ```

        after
        """
        #expect(settled(content)?.hasSuffix("after") == false)
        #expect(settled(content) == "Intro:\n\n    ```\n\n")
    }

    // MARK: - Blockquotes

    @Test func fenceInsideBlockquoteSuppressesSettling() {
        let content = """
        Intro:

        > ```
        > code

        > more
        """
        #expect(settled(content) == "Intro:\n\n")
    }

    @Test func closedBlockquoteFenceSettlesAgain() {
        let content = """
        Intro:

        > ```
        > code
        > ```

        after
        """
        #expect(hasUnbalancedFence(settled(content) ?? "") == false)
        #expect(settled(content)?.contains("> ```\n> code\n> ```") == true)
    }

    // MARK: - Adversarial delta chunkings

    /// Feed a fenced reply through every prefix length (the worst-case
    /// delta chunking — one character at a time) and assert the settled
    /// prefix is NEVER cut inside a fence.
    @Test func noPrefixOfAStreamedFenceEverSettlesInsideIt() {
        let full = """
        Sure, here's the fix:

        ```swift
        func a() {

            print("hi")

        }
        ```

        And a second block:

        ~~~python
        x = 1

        y = 2
        ~~~

        That's it.
        """
        for end in full.indices {
            let prefix = String(full[..<end])
            guard let s = settled(prefix) else { continue }
            #expect(
                !hasUnbalancedFence(s),
                "settled prefix cut inside a fence at length \(prefix.count)"
            )
            // The settled prefix must always remain a prefix of the
            // final content — the renderer's `hasPrefix` invariant.
            #expect(full.hasPrefix(s))
        }
    }

    /// The settled prefix must grow monotonically as deltas arrive —
    /// a boundary that "un-settles" would make the renderer rebuild
    /// from scratch mid-stream.
    @Test func settledPrefixGrowsMonotonically() {
        let full = """
        Intro paragraph.

        ```js
        const a = 1;

        const b = 2;
        ```

        Outro paragraph.

        Tail.
        """
        var previous = ""
        for end in full.indices {
            let s = settled(String(full[..<end])) ?? ""
            #expect(s.count >= previous.count)
            #expect(s.hasPrefix(previous) || previous.hasPrefix(s))
            previous = s
        }
    }

    /// An unterminated fence simply stalls settling — correct output,
    /// just a longer tail. It must never settle a half fence.
    @Test func unterminatedFenceStallsSettlingForever() {
        let content = """
        Intro:

        ```
        line one

        line two

        line three

        """
        #expect(settled(content) == "Intro:\n\n")
    }

    /// A partial fence marker still arriving (`` `` `` before the third
    /// backtick) must not be judged: only fully-terminated lines are
    /// considered, so state never flips on a half-received token.
    @Test func partialFenceMarkerOnTheUnterminatedLineIsIgnored() {
        #expect(settled("Intro:\n\n``") == "Intro:\n\n")
    }
}
