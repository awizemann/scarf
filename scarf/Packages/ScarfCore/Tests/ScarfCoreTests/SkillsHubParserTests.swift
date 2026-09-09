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

    // MARK: - parseSearchJSON (B1)

    /// Fixture emitted by Hermes's own `do_search(..., as_json=True)` line
    /// (`json.dumps([_row(r, "name","identifier","source","trust_level",
    /// "description") for r in results], indent=2)`) at v2026.9.7.
    private static let searchJSONFixture = """
    [
      {
        "name": "skill-creator",
        "identifier": "openai/skills/skill-creator",
        "source": "github",
        "trust_level": "community",
        "description": "Create new skills from a spec."
      },
      {
        "name": "reddit",
        "identifier": "reddit",
        "source": "official",
        "trust_level": "official",
        "description": "Read Reddit without an API key."
      },
      {
        "name": "notes",
        "identifier": "browse-sh/notes.example.com/notes",
        "source": "browse-sh",
        "trust_level": "unverified",
        "description": "Take notes \u{2014} long description that the table would wrap."
      }
    ]
    """

    @Test func parsesSearchJSONWithFullIdentifiers() {
        let result = HermesSkillsHubParser.parseSearchJSON(Self.searchJSONFixture)
        #expect(result?.count == 3)
        // The identifier is the whole point: the table path used the Name
        // cell, which installs the wrong thing for a tap or a browse-sh slug.
        #expect(result?[0].identifier == "openai/skills/skill-creator")
        #expect(result?[0].name == "skill-creator")
        #expect(result?[0].source == "github")
        #expect(result?[2].identifier == "browse-sh/notes.example.com/notes")
    }

    /// An empty search legitimately prints `[]` — that is a RESULT (no
    /// matches), not a parse failure, so it must not fall back to the table.
    @Test func parsesEmptySearchJSONAsEmptyNotNil() {
        #expect(HermesSkillsHubParser.parseSearchJSON("[]")?.isEmpty == true)
    }

    /// Scarf's CLI runner concatenates stdout+stderr, so a warning line can
    /// precede the array. The payload is still found.
    @Test func parsesSearchJSONAfterLeadingNoise() {
        let noisy = "WARNING: index cache is stale\n" + Self.searchJSONFixture
        #expect(HermesSkillsHubParser.parseSearchJSON(noisy)?.count == 3)
    }

    /// Nil (not []) when there is no payload, so the caller falls back to
    /// the table parse instead of rendering "no results" over a live host.
    @Test func returnsNilWhenSearchJSONIsAbsent() {
        #expect(HermesSkillsHubParser.parseSearchJSON("usage: hermes skills search ...") == nil)
        #expect(HermesSkillsHubParser.parseSearchJSON("") == nil)
    }

    /// A row without an identifier is unusable — installing by Name is the
    /// bug this replaced — so it is dropped rather than guessed.
    @Test func dropsSearchJSONRowsWithNoIdentifier() {
        let payload = """
        [{"name": "orphan", "identifier": "", "source": "github", "trust_level": "community", "description": "x"}]
        """
        #expect(HermesSkillsHubParser.parseSearchJSON(payload)?.isEmpty == true)
    }

    /// **Drift alarm for the reason B1 existed.** This fixture was rendered
    /// by Hermes's own Rich table code from `do_search`'s non-JSON branch at
    /// v2026.9.7: `Name | Description | Source | Trust | Identifier` — with
    /// NO leading `#` column, unlike `skills browse`. `parseHubList` keys
    /// every data row off an integer in cell 1, so it returns NOTHING here.
    /// If a future Hermes adds a `#` column to search, this test flips and
    /// tells us the JSON path is no longer the only correct one.
    @Test func searchTableHasNoIndexColumnSoTheRowParserYieldsNothing() {
        let table = """
                                              Skills Hub \u{2014} 2 result(s)
        \u{250f}\u{2501}\u{2501}\u{2501}\u{2501}\u{2501}\u{2513}
        \u{2503} Name          \u{2503} Description                 \u{2503} Source   \u{2503} Trust     \u{2503} Identifier                  \u{2503}
        \u{2521}\u{2501}\u{2501}\u{2501}\u{2501}\u{2529}
        \u{2502} skill-creator \u{2502} Create new skills from a    \u{2502} openai   \u{2502} community \u{2502} openai/skills/skill-creator \u{2502}
        \u{2502}               \u{2502} spec.                       \u{2502}          \u{2502}           \u{2502}                             \u{2502}
        \u{2502} reddit        \u{2502} Read Reddit without an API  \u{2502} official \u{2502} official  \u{2502} reddit                      \u{2502}
        \u{2502}               \u{2502} key.                        \u{2502}          \u{2502}           \u{2502}                             \u{2502}
        \u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}
        """
        #expect(HermesSkillsHubParser.parseHubList(table).isEmpty)
    }
}
