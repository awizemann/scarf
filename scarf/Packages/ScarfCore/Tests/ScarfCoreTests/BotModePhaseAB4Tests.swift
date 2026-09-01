import Testing
import Foundation
@testable import ScarfCore

/// Work package B4 — per-bot Routines' verified `[bot:<name>] ` prefix
/// (mirrors Hermes Desktop's `BOT_TAG_RE`, `hermes-bots/cron.tsx:73`).
@Suite("Bot routine prefix (B4)")
struct BotRoutinePrefixTests {

    @Test("a correctly tagged job is matched")
    func matchesTaggedJob() {
        #expect(BotRoutinePrefix.matches(jobName: "[bot:research] Morning digest", bot: "research"))
        #expect(BotRoutinePrefix.taggedBot(inJobName: "[bot:research] Morning digest") == "research")
    }

    @Test("case-insensitive slug comparison, mirroring the regex's /i flag")
    func caseInsensitiveMatch() {
        #expect(BotRoutinePrefix.matches(jobName: "[bot:Research] Digest", bot: "research"))
        #expect(BotRoutinePrefix.matches(jobName: "[bot:research] Digest", bot: "Research"))
    }

    @Test("no whitespace after the bracket still matches — \\s* allows zero")
    func noWhitespaceAfterBracket() {
        #expect(BotRoutinePrefix.matches(jobName: "[bot:research]Digest", bot: "research"))
    }

    @Test("extra whitespace after the bracket still matches")
    func extraWhitespaceAfterBracket() {
        #expect(BotRoutinePrefix.matches(jobName: "[bot:research]   Digest", bot: "research"))
    }

    @Test("an untagged job never matches any bot")
    func untaggedJobDoesNotMatch() {
        #expect(!BotRoutinePrefix.matches(jobName: "Morning digest", bot: "research"))
        #expect(BotRoutinePrefix.taggedBot(inJobName: "Morning digest") == nil)
    }

    @Test("a different bot's tag does not match")
    func differentBotDoesNotMatch() {
        #expect(!BotRoutinePrefix.matches(jobName: "[bot:ops] Digest", bot: "research"))
    }

    @Test("the tag must be at the START of the name, not merely present")
    func tagMustBeAtStart() {
        #expect(BotRoutinePrefix.taggedBot(inJobName: "Digest [bot:research]") == nil)
        #expect(!BotRoutinePrefix.matches(jobName: "Digest [bot:research]", bot: "research"))
    }

    @Test("an empty bracket is not a tag")
    func emptyBracketIsNotATag() {
        #expect(BotRoutinePrefix.taggedBot(inJobName: "[bot:] Digest") == nil)
    }

    @Test("brackets in the slug are refused, exactly like the JS character class")
    func bracketsInSlugRefused() {
        #expect(BotRoutinePrefix.taggedBot(inJobName: "[bot:re[search]] Digest") == nil)
    }

    @Test("unicode in the slug is refused — the character class is a-z0-9_- only")
    func unicodeInSlugRefused() {
        #expect(BotRoutinePrefix.taggedBot(inJobName: "[bot:résearch] Digest") == nil)
        #expect(BotRoutinePrefix.taggedBot(inJobName: "[bot:研究] Digest") == nil)
        #expect(!BotRoutinePrefix.matches(jobName: "[bot:研究] Digest", bot: "研究"))
    }

    @Test("a slug can't start with a dash or underscore")
    func slugCannotStartWithDashOrUnderscore() {
        #expect(BotRoutinePrefix.taggedBot(inJobName: "[bot:-research] Digest") == nil)
        #expect(BotRoutinePrefix.taggedBot(inJobName: "[bot:_research] Digest") == nil)
    }

    @Test("dashes and underscores inside the slug are fine")
    func dashesAndUnderscoresInsideSlugAllowed() {
        #expect(BotRoutinePrefix.taggedBot(inJobName: "[bot:research-bot_2] Digest") == "research-bot_2")
    }

    @Test("matching against an empty bot name never succeeds")
    func emptyBotNameNeverMatches() {
        #expect(!BotRoutinePrefix.matches(jobName: "[bot:] Digest", bot: ""))
        #expect(!BotRoutinePrefix.matches(jobName: "Untagged", bot: ""))
    }

    @Test("compose round-trips through the same matcher")
    func composeRoundTrips() {
        let name = BotRoutinePrefix.routineName(forBot: "research", title: "Morning digest")
        #expect(name == "[bot:research] Morning digest")
        #expect(BotRoutinePrefix.matches(jobName: name, bot: "research"))
    }

    @Test("compose trims the title but never the bot name")
    func composeTrimsTitleOnly() {
        let name = BotRoutinePrefix.routineName(forBot: "research", title: "  Morning digest  ")
        #expect(name == "[bot:research] Morning digest")
    }

    @Test("a job tagged for one bot is never picked up by a lookalike bot name")
    func noCrossBotBleed() {
        let jobs = [
            "[bot:research] Digest",
            "[bot:research-2] Digest",
            "[bot:esearch] Digest"
        ]
        let matchesResearch = jobs.filter { BotRoutinePrefix.matches(jobName: $0, bot: "research") }
        #expect(matchesResearch == ["[bot:research] Digest"])
    }
}
