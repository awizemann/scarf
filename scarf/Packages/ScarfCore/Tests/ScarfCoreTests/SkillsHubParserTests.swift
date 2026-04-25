import Testing
@testable import ScarfCore

/// Coverage for `HermesSkillsHubParser` — the Rich-table parser that
/// translates `hermes skills browse|search|check` stdout into typed
/// `HermesHubSkill` / `HermesSkillUpdate` arrays. The parser is shared
/// by Mac + iOS in v2.5; this suite locks in the canonical fixtures
/// so regressions on either platform fail here first.
@Suite("HermesSkillsHubParser")
struct SkillsHubParserTests {

    // MARK: - parseHubList

    @Test func parsesSingleRowFromBrowseOutput() {
        let output = """
        ┏━━━━━━┳━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━┳━━━━━━━━━━━━┓
        ┃    # ┃ Name           ┃ Description                                            ┃ Source       ┃ Trust      ┃
        ┡━━━━━━╇━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━╇━━━━━━━━━━━━┩
        │    1 │ 1password      │ Set up and use 1Password integration.                  │ official     │ ★ official │
        └──────┴────────────────┴────────────────────────────────────────────────────────┴──────────────┴────────────┘
        """
        let result = HermesSkillsHubParser.parseHubList(output)
        #expect(result.count == 1)
        #expect(result[0].identifier == "1password")
        #expect(result[0].name == "1password")
        #expect(result[0].description == "Set up and use 1Password integration.")
        #expect(result[0].source == "official")
    }

    @Test func mergesContinuationRowsIntoDescription() {
        // Continuation rows have an empty `#` cell — the parser should
        // append their description to the previous skill rather than
        // emit a blank entry.
        let output = """
        │    1 │ skill-creator  │ Create new skills, modify and improve existing skills, │ official     │ ★ official │
        │      │                │ and measure skill performance.                         │              │            │
        """
        let result = HermesSkillsHubParser.parseHubList(output)
        #expect(result.count == 1)
        #expect(result[0].identifier == "skill-creator")
        #expect(result[0].description.contains("Create new skills"))
        #expect(result[0].description.contains("measure skill performance"))
    }

    @Test func skipsHeaderAndBorderRows() {
        let output = """
        ┏━━━━━━┳━━━━━━━━┳━━━━━━━━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━━━━┓
        ┃    # ┃ Name   ┃ Description   ┃ Source    ┃ Trust      ┃
        ┡━━━━━━╇━━━━━━━━╇━━━━━━━━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━━━┩
        │    1 │ alpha  │ alpha skill   │ official  │ ★ official │
        │    2 │ beta   │ beta skill    │ skills-sh │            │
        └──────┴────────┴───────────────┴───────────┴────────────┘
        """
        let result = HermesSkillsHubParser.parseHubList(output)
        #expect(result.count == 2)
        #expect(result[0].name == "alpha")
        #expect(result[1].name == "beta")
    }

    @Test func stripsStarFromSourceCell() {
        // The Trust column shows `★ official` for trusted sources;
        // the Source column itself doesn't, but if the layout shifts
        // and we end up with the star in our captured cell we should
        // strip it.
        let output = """
        │    1 │ widget │ a widget │ ★ official │ official │
        """
        let result = HermesSkillsHubParser.parseHubList(output)
        #expect(result.count == 1)
        #expect(result[0].source == "official")
    }

    @Test func returnsEmptyOnNoTable() {
        let result = HermesSkillsHubParser.parseHubList("Just plain text\n no table here")
        #expect(result.isEmpty)
    }

    // MARK: - parseUpdateList

    @Test func parsesArrowVersionMarker() {
        let output = """
        Checking for updates…
        skill-creator   1.0.0 → 1.1.0
        another-skill   2.3.4 → 2.3.5
        """
        let result = HermesSkillsHubParser.parseUpdateList(output)
        #expect(result.count == 2)
        #expect(result[0].identifier == "skill-creator")
        #expect(result[0].currentVersion == "1.0.0")
        #expect(result[0].availableVersion == "1.1.0")
        #expect(result[1].identifier == "another-skill")
        #expect(result[1].currentVersion == "2.3.4")
        #expect(result[1].availableVersion == "2.3.5")
    }

    @Test func parsesAsciiArrowMarker() {
        // Some terminals or older Hermes versions emit `->` instead of
        // the unicode `→`. Both should parse identically.
        let output = "skill-creator   1.0.0 -> 1.1.0"
        let result = HermesSkillsHubParser.parseUpdateList(output)
        #expect(result.count == 1)
        #expect(result[0].identifier == "skill-creator")
        #expect(result[0].availableVersion == "1.1.0")
    }

    @Test func updateListIgnoresLinesWithoutArrow() {
        let output = """
        Checking for updates…
        Skill named foo is up to date.
        skill-creator   1.0.0 → 1.1.0
        """
        let result = HermesSkillsHubParser.parseUpdateList(output)
        #expect(result.count == 1)
        #expect(result[0].identifier == "skill-creator")
    }
}
