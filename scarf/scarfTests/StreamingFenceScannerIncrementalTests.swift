import Testing
@testable import scarf

/// Pins the incremental fence scan (`lastSettleBoundary(in:resuming:)`)
/// against the stateless whole-tail scan it replaced.
///
/// While a fenced block streams nothing settles, so the unsettled tail
/// grows without bound and the old from-scratch-per-delta scan was
/// O(n²) on the main actor. The resuming overload carries the scan
/// cursor and fence state at the last scanned prefix of the tail and
/// only walks the lines each delta added.
///
/// The safety property is not "faster" but **byte-identical**: for every
/// chunking of every input, the sequence of settled prefixes produced by
/// the incremental path must equal the sequence produced by rescanning
/// the whole tail every time.
@Suite struct StreamingFenceScannerIncrementalTests {

    /// Mirror of `StreamingMarkdownText.absorbSettledParagraphs` — the
    /// only consumer of the scanner — reduced to the settle bookkeeping.
    /// `incremental: false` re-derives the scan from scratch per delta,
    /// which is exactly the pre-change behavior.
    private func settleSequence(
        chunks: [String],
        incremental: Bool
    ) -> [String] {
        var content = ""
        var settledSource = ""
        var state = StreamingFenceScanner.ResumeState()
        var out: [String] = []

        for chunk in chunks {
            content += chunk
            if !content.hasPrefix(settledSource) {
                settledSource = ""
                state = StreamingFenceScanner.ResumeState()
            }
            let tail = content[settledSource.endIndex...]
            let boundary: (completedEnd: Substring.Index, boundaryEnd: Substring.Index)?
            if incremental {
                boundary = StreamingFenceScanner.lastSettleBoundary(in: tail, resuming: &state)
            } else {
                boundary = StreamingFenceScanner.lastSettleBoundary(in: tail)
            }
            if let boundary {
                settledSource = String(content[..<boundary.boundaryEnd])
                state = StreamingFenceScanner.ResumeState()
            }
            out.append(settledSource)
        }
        return out
    }

    /// Deterministic, seeded splitter so a failure is reproducible.
    private func chunks(_ text: String, seed: UInt64, maxChunk: Int) -> [String] {
        var rng = SplitMix64(seed: seed)
        var out: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let n = 1 + Int(rng.next() % UInt64(maxChunk))
            let end = text.index(idx, offsetBy: n, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[idx..<end]))
            idx = end
        }
        return out
    }

    private struct SplitMix64 {
        var seed: UInt64
        mutating func next() -> UInt64 {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let corpus: [String] = [
        // Plain prose only.
        "One.\n\nTwo.\n\nThree.\n",
        // A fence with blank lines inside it — the whole point of the scanner.
        "Intro:\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nOutro.\n\nTail.\n",
        // Tilde fence, and a ``` run inside it that must not close it.
        "A\n\n~~~\n```\n\nstill inside\n~~~\n\nB\n",
        // Longer opener than closer attempt.
        "A\n\n````\n```\n\nnope\n````\n\nB\n",
        // Unterminated fence: nothing settles past the intro, forever.
        "Intro:\n\n```\nline one\n\nline two\n\nline three\n",
        // Blockquoted fence.
        "Q:\n\n> ```\n> code\n>\n> more\n> ```\n\nAfter.\n",
        // Indented code block — ``` there is literal, not a fence.
        "A\n\n    ```\n    x\n\n    y\n\nB\n",
        // Info string containing a backtick is NOT a fence opener.
        "A\n\n``` a ``` b\n\nC\n",
        // Back-to-back fences.
        "```\nx\n```\n\n```\ny\n```\n\nend\n",
        // Multi-byte content, to prove the persisted cursor stays on a
        // grapheme boundary across appends.
        "héllo 🇺🇸👨‍👩‍👧‍👦\n\n```\né 🙂\n\nzwj 👨‍💻\n```\n\ndöne é\n",
        // Trailing partial fence marker.
        "Intro:\n\n``",
        // No boundary at all.
        "just one line with no blank line",
    ]

    @Test(arguments: corpus)
    func incrementalMatchesFromScratchForEveryOneCharacterDelta(_ text: String) {
        let oneChar = text.map(String.init)
        #expect(
            settleSequence(chunks: oneChar, incremental: true)
                == settleSequence(chunks: oneChar, incremental: false)
        )
    }

    @Test(arguments: corpus)
    func incrementalMatchesFromScratchForWholeInputInOneDelta(_ text: String) {
        #expect(
            settleSequence(chunks: [text], incremental: true)
                == settleSequence(chunks: [text], incremental: false)
        )
    }

    @Test func incrementalMatchesFromScratchAcrossRandomChunkings() {
        for text in Self.corpus {
            for seed in UInt64(1)...UInt64(24) {
                for maxChunk in [2, 3, 5, 11, 40] {
                    let parts = chunks(text, seed: seed, maxChunk: maxChunk)
                    let a = settleSequence(chunks: parts, incremental: true)
                    let b = settleSequence(chunks: parts, incremental: false)
                    #expect(a == b, "seed \(seed) maxChunk \(maxChunk) text \(text.debugDescription)")
                    // And both must land on the same final answer as a
                    // single whole-string scan.
                    #expect(a.last == settleSequence(chunks: [text], incremental: false).last)
                }
            }
        }
    }

    /// The reset path: a non-append mutation (a new turn reusing the
    /// view) must not let a stale cursor leak into the new content.
    @Test func nonAppendMutationRescansFromScratch() {
        var state = StreamingFenceScanner.ResumeState()
        let first = "A\n\n```\nx\n\ny\n"
        _ = StreamingFenceScanner.lastSettleBoundary(in: first[...], resuming: &state)
        // Caller detected the break and reset, as `StreamingMarkdownText`
        // does on the `hasPrefix` failure.
        state = StreamingFenceScanner.ResumeState()
        let second = "Totally different.\n\nSecond para.\n"
        let inc = StreamingFenceScanner.lastSettleBoundary(in: second[...], resuming: &state)
        let scratch = StreamingFenceScanner.lastSettleBoundary(in: second[...])
        #expect(inc?.completedEnd == scratch?.completedEnd)
        #expect(inc?.boundaryEnd == scratch?.boundaryEnd)
    }

    /// Calling the resuming overload repeatedly on an UNCHANGED tail is
    /// idempotent — it must keep reporting the same boundary rather than
    /// forgetting it because there were no new lines to walk.
    @Test func repeatedScansOfAnUnchangedTailAreStable() {
        let text = "A\n\nB\n\nC"
        var state = StreamingFenceScanner.ResumeState()
        let expected = StreamingFenceScanner.lastSettleBoundary(in: text[...])
        for _ in 0..<5 {
            let got = StreamingFenceScanner.lastSettleBoundary(in: text[...], resuming: &state)
            #expect(got?.completedEnd == expected?.completedEnd)
            #expect(got?.boundaryEnd == expected?.boundaryEnd)
        }
    }
}
