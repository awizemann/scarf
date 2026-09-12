import Testing
@testable import ScarfCore

/// Coverage for `HermesSkillsHubParser` — the Rich-table parser that
/// translates `hermes skills browse|search|check` stdout into typed
/// `HermesHubSkill` / `HermesSkillUpdate` arrays. The parser is shared
/// by Mac + iOS in v2.5; this suite locks in the canonical fixtures
/// so regressions on either platform fail here first.
@Suite("HermesSkillsHubParser")
struct SkillsHubParserTests {

    // MARK: - parseHubList (browse)

    /// **Verbatim `hermes skills browse` output.** Rendered by Hermes's own
    /// Rich table code at tag `v2026.9.7` — the column specs of
    /// `_render_browse_page` (`hermes_cli/skills_hub.py:393-399`) plus
    /// `_ident_col` / `_table` / `_truncate` / `_trust_cell` — through a
    /// non-tty `Console(width: 80)`, which is what Hermes's module-level
    /// `_console` becomes when Scarf pipes it.
    ///
    /// Note the second row: at 80 columns the Identifier column FOLDS
    /// (`overflow="fold"`), so `pdf-tools-a1b2c3` arrives as
    /// `pdf-tools-a1b` + `2c3` on two lines.
    static let browseFixture = """
    ┏━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━┳━━━━━━━━━━━━┳━━━━━━━━━━━━━━━┓
    ┃    # ┃ Name      ┃ Description   ┃ Source       ┃ Trust      ┃ Identifier    ┃
    ┡━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━╇━━━━━━━━━━━━╇━━━━━━━━━━━━━━━┩
    │    1 │ 1password │ Set up and    │ official     │ ★ official │ 1password     │
    │      │           │ use the       │              │            │               │
    │      │           │ 1Password CLI │              │            │               │
    │      │           │ to read       │              │            │               │
    │      │           │ sec...        │              │            │               │
    │    2 │ pdf-tools │ Split, merge  │ skills-sh    │ community  │ pdf-tools-a1b │
    │      │           │ and OCR PDF   │              │            │ 2c3           │
    │      │           │ documents     │              │            │               │
    │      │           │ from the ...  │              │            │               │
    │    3 │ nv-rag    │ NVIDIA        │ github       │ unknown    │ nvidia/skills │
    │      │           │ retrieval     │              │            │ /nv-rag       │
    │      │           │ augmented     │              │            │               │
    │      │           │ generation    │              │            │               │
    │      │           │ helper        │              │            │               │
    └──────┴───────────┴───────────────┴──────────────┴────────────┴───────────────┘
    """

    /// The install target is the Identifier cell, never the Name. Fails
    /// without the fix: the old parser returned `identifier == name` for
    /// every row, so `pdf-tools` (no hash) and `nv-rag` (no owner path)
    /// installed nothing or installed the wrong skill.
    @Test func browseUsesTheIdentifierColumnAsTheInstallTarget() {
        let result = HermesSkillsHubParser.parseHubList(Self.browseFixture)
        #expect(result.count == 3)
        #expect(result.map(\.identifier) == ["1password", "pdf-tools-a1b2c3", "nvidia/skills/nv-rag"])
        // Name stays the display string.
        #expect(result.map(\.name) == ["1password", "pdf-tools", "nv-rag"])
        #expect(result.map(\.source) == ["official", "skills-sh", "github"])
    }

    /// A folded identifier is CONCATENATED, not space-joined: `overflow="fold"`
    /// is a hard character wrap. A space would make the slug uninstallable.
    @Test func foldedIdentifierContinuationRowsAreConcatenatedNotSpaceJoined() {
        let result = HermesSkillsHubParser.parseHubList(Self.browseFixture)
        #expect(result[1].identifier == "pdf-tools-a1b2c3")
        #expect(!result[1].identifier.contains(" "))
        #expect(result[2].identifier == "nvidia/skills/nv-rag")
    }

    /// Description continuation rows keep the space join — Rich word-wraps
    /// that column, so the words either side of the break are separate.
    @Test func descriptionContinuationRowsAreSpaceJoined() {
        let result = HermesSkillsHubParser.parseHubList(Self.browseFixture)
        #expect(result[0].description == "Set up and use the 1Password CLI to read sec...")
        #expect(result[2].description == "NVIDIA retrieval augmented generation helper")
    }

    @Test func browseSkipsHeaderAndBorderRows() {
        // Three data rows out of a fixture with a header row, three border
        // rows and eleven continuation rows.
        #expect(HermesSkillsHubParser.parseHubList(Self.browseFixture).count == 3)
    }

    @Test func returnsEmptyOnNoTable() {
        let result = HermesSkillsHubParser.parseHubList("Just plain text\n no table here")
        #expect(result.isEmpty)
    }

    // MARK: - parseUpdateList (skills check)

    /// **Verbatim `hermes skills check` output**, rendered from `do_check`'s
    /// own table spec (`hermes_cli/skills_hub.py:806-808` at `v2026.9.7`)
    /// with one row per status `check_for_skill_updates` can produce
    /// (`tools/skills_hub_install.py:277-302`).
    static let checkFixture = """
                     Skill Updates                  
    ┏━━━━━━━━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━┓
    ┃ Name          ┃ Source    ┃ Status           ┃
    ┡━━━━━━━━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━┩
    │ 1password     │ official  │ update_available │
    │ pdf-tools     │ skills-sh │ up_to_date       │
    │ gone-skill    │ github    │ orphaned         │
    │ dead-registry │ clawhub   │ unavailable      │
    │ bad-path      │ official  │ invalid_install  │
    └───────────────┴───────────┴──────────────────┘
    """

    /// **The drift alarm for the Updates tab.** Fails without the fix: the
    /// old parser hunted for `→` between two version strings, which
    /// `skills check` has never printed, so this fixture yielded zero rows
    /// and the tab could never show an update.
    @Test func parsesEveryStatusFromTheCheckTable() {
        let result = HermesSkillsHubParser.parseUpdateList(Self.checkFixture)
        #expect(result.count == 5)
        #expect(result.map(\.identifier)
            == ["1password", "pdf-tools", "gone-skill", "dead-registry", "bad-path"])
        #expect(result.map(\.source)
            == ["official", "skills-sh", "github", "clawhub", "official"])
        #expect(result.map(\.status) == [
            .updateAvailable, .upToDate, .orphaned, .unavailable, .invalidInstall,
        ])
    }

    /// Only `update_available` is something `hermes skills update` acts on
    /// (`hermes_cli/skills_hub.py:843` filters on exactly that word).
    @Test func onlyUpdateAvailableIsActionable() {
        let statuses = HermesSkillUpdateStatus.allCases.filter(\.isActionable)
        #expect(statuses == [.updateAvailable])
        // …and the three fault statuses each carry a remedy to show.
        #expect(HermesSkillUpdateStatus.allCases.filter { $0.faultDescription != nil }
            == [.orphaned, .unavailable, .invalidInstall])
    }

    /// A status word Scarf does not know must be DROPPED, never badged as an
    /// available update — the C5 rule applied to a table cell.
    @Test func unknownStatusWordIsDropped() throws {
        let table = """
        │ future-skill │ official │ needs_migration │
        │ 1password    │ official │ update_available │
        """
        let result = HermesSkillsHubParser.parseUpdateList(table)
        try #require(result.count == 1)
        #expect(result[0].identifier == "1password")
    }

    /// The Status cell is what keys a data row, so a row that merely LOOKS
    /// like one — the header, a title line, a Name-column continuation —
    /// is rejected. Rich draws the header with `┃`, but this must not depend
    /// on the box glyph: the same row with the data separator `│` is still
    /// not an update.
    @Test func checkTableHeaderRowIsNotAnUpdate() {
        #expect(HermesSkillsHubParser.parseUpdateList(
            "┃ Name          ┃ Source    ┃ Status           ┃").isEmpty)
        #expect(HermesSkillsHubParser.parseUpdateList(
            "│ Name          │ Source    │ Status           │").isEmpty)
        // A wrapped Name continuation carries an EMPTY status cell.
        #expect(HermesSkillsHubParser.parseUpdateList(
            "│ a-very-long-n │           │                  │").isEmpty)
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

    @Test func parsesSearchJSONWithFullIdentifiers() throws {
        let result = HermesSkillsHubParser.parseSearchJSON(Self.searchJSONFixture)
        try #require(result?.count == 3)
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
