import Testing
import Foundation
@testable import ScarfCore

/// Parity with the Hermes desktop's own tests at tag v2026.9.14:
/// `use-voice-live-conversation.test.ts`, `voice-stop-word.test.ts` and
/// `speech-text.test.ts`. Cases are ported verbatim where they exist.
@Suite struct VoiceLiveTextTests {

    // MARK: delegationPrompt (use-voice-live-conversation.test.ts:9-22)

    @Test func latestUserWordsAreTheTurnAndTheExchangeIsContext() {
        let (prompt, context) = VoiceLiveText.delegationPrompt([
            .init(speaker: .assistant, text: "Hi, how ", startMs: 0, endMs: 1000),
            .init(speaker: .assistant, text: "can I help?", startMs: 1000, endMs: 1500),
            .init(speaker: .user, text: "What is ", startMs: 1500, endMs: 2500),
            .init(speaker: .user, text: "the weather in Paris?", startMs: 2500, endMs: 3200),
        ])
        #expect(prompt == "What is the weather in Paris?")
        #expect(context == "Voice assistant: Hi, how can I help?\nUser: What is the weather in Paris?")
    }

    @Test func noUserWordsFallsBackToTheTranscriptTail() {
        let (prompt, context) = VoiceLiveText.delegationPrompt([
            .init(speaker: .assistant, text: "Let me check that.", startMs: 0, endMs: 1),
        ])
        #expect(context == "Voice assistant: Let me check that.")
        #expect(prompt == context)
    }

    @Test func emptyTurnsAreDroppedFromContext() {
        let (_, context) = VoiceLiveText.delegationPrompt([
            .init(speaker: .assistant, text: "  ", startMs: 0, endMs: 1),
            .init(speaker: .user, text: "yes", startMs: 1, endMs: 2),
        ])
        #expect(context == "User: yes")
    }

    @Test func contextWindowIsFiveMinutesAndEightyFragments() {
        let old = VoiceTranscriptFragment(speaker: .user, text: "old", startMs: 0, endMs: 1_000)
        let recent = (0..<100).map { VoiceTranscriptFragment(speaker: .user, text: "\($0)", startMs: 400_000 + $0, endMs: 400_000 + $0) }
        let window = VoiceLiveText.contextWindow([old] + recent)
        #expect(window.count == 80)
        #expect(window.first?.text == "20")
        #expect(!window.contains(old))
        #expect(VoiceLiveText.contextWindow([]).isEmpty)
    }

    // MARK: chunkForCommentary (…test.ts:24-32)

    @Test func longRepliesSplitOnSentenceBoundaries() {
        let sentence = "This is a sentence about the result. "
        let text = String(repeating: sentence, count: 80)
        let chunks = VoiceLiveText.chunkForCommentary(text, limit: 400)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 400 })
        #expect(chunks.allSatisfy { $0.hasSuffix(".") })
        #expect(chunks.joined(separator: " ") == text.trimmingCharacters(in: .whitespaces))
    }

    @Test func anOverlongSentenceIsHardSplit() {
        let chunks = VoiceLiveText.chunkForCommentary("Short. " + String(repeating: "x", count: 25), limit: 10)
        #expect(chunks == ["Short.", "xxxxxxxxxx", "xxxxxxxxxx", "xxxxx"])
    }

    @Test func shortAndEmptyReplies() {
        #expect(VoiceLiveText.chunkForCommentary("  hello \n world ") == ["hello world"])
        #expect(VoiceLiveText.chunkForCommentary("   ").isEmpty)
    }

    // MARK: toLiveHistory (…test.ts:34-47)

    @Test func seedHistoryKeepsTheMostRecentTurnsWithinBudget() {
        let turns = (0..<40).map { VoiceLiveText.SeedTurn(role: $0 % 2 == 0 ? .user : .assistant, text: "turn \($0)") }
        let history = VoiceLiveText.liveHistory(from: turns, maxMessages: 6)
        #expect(history.count == 6)
        #expect(history.last?.content.first?.text == "turn 39")
        #expect(history.first?.role == .user)
        #expect(history.first(where: { $0.role == .assistant })?.content.first?.type == "output_text")
    }

    @Test func seedHistoryStopsAtTheCharBudgetAndTrimsLongTurns() {
        let turns = [
            VoiceLiveText.SeedTurn(role: .user, text: String(repeating: "a", count: 5_000)),
            VoiceLiveText.SeedTurn(role: .assistant, text: String(repeating: "b", count: 1_300)),
            VoiceLiveText.SeedTurn(role: .user, text: "   "),
        ]
        let history = VoiceLiveText.liveHistory(from: turns, maxChars: 2_000)
        // Newest first: the blank turn is skipped, "b" is trimmed to 1,200
        // (budget 2,000 → 800), and "a" (1,200) no longer fits.
        #expect(history.count == 1)
        #expect(history.first?.role == .assistant)
        #expect(history.first?.content.first?.text == String(repeating: "b", count: 1_200))
    }

    // MARK: isVoiceStopCommand (voice-stop-word.test.ts)

    @Test(arguments: ["stop", "Stop", "STOP", "stop.", "stop!", " stop ", "stop…",
                      "stop listening", "stop it", "please stop", "stop please", "that's all", "that is all",
                      "never mind", "nevermind", "end conversation", "end the conversation", "goodbye", "bye", "cancel",
                      "hermes stop", "hey hermes stop", "hey hermes, stop", "ok stop", "okay stop"])
    func stopPhrasesMatch(_ phrase: String) {
        #expect(VoiceLiveText.isStopCommand(phrase))
    }

    @Test(arguments: ["stop the docker container", "how do I stop a running process", "can you stop the deployment",
                      "stop the music and play something else", "don't stop now", "the bus stop is closed",
                      "", "  ", "hermes", "hey hermes", "ok", "okay", "hey", "hello", "yes", "what time is it", "thanks"])
    func substantiveRequestsAreNotStops(_ phrase: String) {
        #expect(!VoiceLiveText.isStopCommand(phrase))
    }

    // MARK: sanitizeTextForSpeech (speech-text.test.ts)

    @Test(arguments: [
        ("Here is code:\n```ts\nconst x = 1\n```\nDone.", "Here is code: code block omitted Done."),
        ("Use `git status` after the change.", "Use git status after the change."),
        ("Here is the quick takeaway: the totals remain unchanged.\n\n| Item | Value | Notes |\n| --- | ---: | --- |\n| Example A | 10 | first row |\n| Example B | 20 | second row |\n\nFull detail stays visible on screen.",
         "Here is the quick takeaway: the totals remain unchanged. Full detail stays visible on screen."),
        ("Use the summary first | keep the table on screen when it matters.", "Use the summary first | keep the table on screen when it matters."),
        ("First sentence.\n\nSecond sentence.", "First sentence. Second sentence."),
        ("**First sentence.**\n\nSecond sentence.", "First sentence. Second sentence."),
        ("“First sentence.”\n\nSecond sentence.", "“First sentence.” Second sentence."),
        ("(First sentence.)\n\nSecond sentence.", "(First sentence.) Second sentence."),
        ("Main takeaway: total is unchanged.\n\nItem | Value\n--- | ---:\nExample A | 10\nExample B | 20\n\nDone.", "Main takeaway: total is unchanged. Done."),
        ("Before the table.\n\n> | Item | Value |\n> | --- | ---: |\n> | Example A | 10 |\n> | Example B | 20 |\n\nAfter the table.", "Before the table. After the table."),
        ("Before the table.\n\n>    | Item | Value |\n>    | --- | ---: |\n>    | Example A | 10 |\n\nAfter the table.", "Before the table. After the table."),
        ("Before the table.\n\n| Item |\n| --- |\n| Example A |\n\nAfter the table.", "Before the table. After the table."),
        ("> | Item | Value |\n> | --- | ---: |\n> | Example A | 10 |\nOutside | prose", "Outside | prose"),
        ("Before the table.\n\n| Item | Value |\n| --- | ---: |\n| Example A |\n| Example B | 20 | ignored |\n\nAfter the table.", "Before the table. After the table."),
        ("Before the table.\n\n| Item \\| detail | Value |\n| --- | ---: |\n| Example A | 10 |\n\nAfter the table.", "Before the table. After the table."),
    ])
    func sanitizeMatchesTheDesktop(_ input: String, _ expected: String) {
        #expect(VoiceLiveText.sanitizeForSpeech(input) == expected)
    }

    /// Differential fixtures: inputs run through the TAGGED
    /// `speech-text.ts` with node (`--experimental-strip-types`) on
    /// 2026-09-18; the right-hand sides are node's output, verbatim.
    @Test(arguments: [
        ("See [the docs](https://example.com/a) or https://example.com/b now.", "See the docs or link now."),
        ("# Title\n- one\n- two 🎉", "Title - one - two"),
        ("# Title\n\n- one\n- two", "Title. - one - two"),
        ("Thinking... The answer is **42**.", "The answer is 42."),
        ("(pondering) Analyzing... ok", "ok"),
        ("Run:\n```\nls -la\n", "Run: code block omitted"),
        ("multi-\nline hyphen-\nated words", "multiline hyphenated words"),
        ("A\r\nB\r\n\r\nC", "A B. C"),
        ("Use ~/bin and #tag and a_b_c.", "Use /bin and tag and abc."),
        ("* star bullet\n+ plus bullet", "star bullet + plus bullet"),
        ("Emoji 👍🏽 and ❤️ here", "Emoji and here"),
        ("Done!\n\n> quoted line", "Done! quoted line"),
    ])
    func sanitizeMatchesNodeOnTheTaggedSource(_ input: String, _ expected: String) {
        #expect(VoiceLiveText.sanitizeForSpeech(input) == expected)
    }

    @Test func malformedAndIndentedTablesArePreserved() {
        #expect(VoiceLiveText.sanitizeForSpeech("Heading | Detail\n--- | --- | ---\nKeep this prose.").contains("Heading | Detail"))
        #expect(VoiceLiveText.sanitizeForSpeech("    Item | Value\n    --- | ---\n    Example A | 10").contains("Item | Value"))
    }

    // MARK: speakableBoundary (Scarf: streaming speech on the raw reply)

    private func speakable(_ raw: String) -> String {
        let chars = Array(raw)
        return String(chars[..<VoiceLiveText.speakableBoundary(in: chars)])
    }

    @Test func theSpeakablePrefixEndsAtTheLastCompletedSentence() {
        #expect(speakable("It is sunny today. The high is") == "It is sunny today.")
        #expect(speakable("Really? Yes! And") == "Really? Yes!")
        #expect(speakable("Version 3.5 is out") == "")
        #expect(speakable("Done.") == "")                    // no whitespace after it yet
        #expect(speakable("Line one.\nLine two") == "Line one.")
    }

    @Test func theSpeakablePrefixNeverEndsInsideCodeLinksOrTables() {
        #expect(speakable("Run this. ```\nmake all. then\n") == "Run this.")
        #expect(speakable("Use `a. b` now") == "")
        #expect(speakable("See [the docs. More](http://x") == "")
        #expect(speakable("Intro.\n| Mr. A | 3 |\n") == "Intro.")
        #expect(speakable("Row. | a | b |") == "")           // a pipe voids the whole line
    }

    /// Piecewise sanitizing at these boundaries says the same words as
    /// sanitizing the whole reply once.
    @Test func piecewiseSpeechMatchesWholeSpeech() {
        let reply = "## Plan\nFirst, **build** it. Then run `make test`.\n\n| a | b |\n|---|---|\n| 1 | 2 |\nSee [docs](https://x.y/z). ```\nlet x = 1. y\n```\nDone! Bye."
        let chars = Array(reply)
        var spoken: [String] = []
        var offset = 0
        for length in 1...chars.count {
            let end = length == chars.count ? length : VoiceLiveText.speakableBoundary(in: Array(chars[..<length]))
            guard end > offset else { continue }
            spoken.append(VoiceLiveText.speechSegment(chars, offset..<end))
            offset = end
        }
        #expect(spoken.joined(separator: " ") == VoiceLiveText.sanitizeForSpeech(reply))
    }
}
