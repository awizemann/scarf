import Foundation
import Testing
@testable import ScarfCore

/// P32 — the last two bespoke YAML quoting routines, unified on
/// ``YAMLScalar``.
///
/// Same stakes as P10/P19, in two files instead of one:
///
/// - `ProfileRoutesWriter` writes `~/.hermes/config.yaml`, whose load is
///   wrapped in a bare `except Exception` that logs and CONTINUES
///   (`gateway/config.py:773-792` @ `v2026.9.7`, `yaml.safe_load` at
///   `gateway/config_loader.py:346`). One byte PyYAML refuses discards the
///   user's ENTIRE config.yaml layer without a word.
/// - `HermesBotProfileYAML` writes a profile's `profile.yaml`, read through
///   `_load_yaml_dict` → `yaml.safe_load` inside a `try/except: return None`
///   (`hermes_cli/profiles.py:471-480` @ `v2026.9.7`), which
///   `read_profile_meta` (`:609-618`) turns into empty defaults: the profile
///   loses `display_name`, `description` and the whole `hermes-bots` block
///   and drops out of the bot roster.
///
/// The fuzz classes below are the ones the round-3 audit found both routines
/// getting wrong. Round-tripped through the real PyYAML via the P19 harness
/// (`HermesP19YAMLHardeningTests.PyYAML`) — no second harness.
struct HermesP32YAMLUnificationTests {

    private typealias PyYAML = HermesP19YAMLHardeningTests.PyYAML
    private static var pyYAMLAvailable: Bool { HermesP19YAMLHardeningTests.pyYAMLAvailable }

    /// Every class the audit fuzzed both bespoke routines into failing on.
    ///
    /// - `}x` / `]x` / `` `x `` — a LEADING flow-close or backtick makes
    ///   PyYAML *raise* (`ParserError` / `ScannerError`), the sharp case.
    /// - `<<` / `=` — the merge and value keys: `ConstructorError`.
    /// - `.inf` / `.nan` / `2026-09-09` / `0b101` / `12_000` — silently
    ///   retyped to float / date / int.
    static let fuzzClasses: [String] = [
        "}x", "]x", "`x", "{x", "[x",
        "<<", "=",
        ".inf", "-.inf", ".nan",
        "2026-09-09", "0b101", "12_000", "0x1F", "007",
        "a\tb", "\tlead", "trail\t",
        "a\nb", "a\r\nb", "a\u{1}b"
    ]

    /// The subset that is legal in a single-line scalar field once quoted;
    /// the tab classes are refused by the editors (decision 6) but the
    /// writer still has to be safe if one ever reaches it.
    private static func route(name: String) -> HermesProfileRoute {
        HermesProfileRoute(name: name, platform: "discord", profile: "p", guildID: "123")
    }

    private static let v019 = HermesCapabilities(
        versionLine: "hermes 0.19.0",
        semver: HermesCapabilities.SemVer(major: 0, minor: 19, patch: 0),
        dateVersion: nil
    )

    // MARK: - ProfileRoutesWriter (H1)

    /// A route *Name* is free text (`ProfileRoutesSection.swift:330`,
    /// "Shown in Hermes logs. Optional.") and `normalizedRoute()` only
    /// whitespace-trims it, so every one of these survives to the file.
    @Test(arguments: fuzzClasses)
    func profileRouteNameRoundTripsThroughRealPyYAML(_ raw: String) throws {
        try #require(Self.pyYAMLAvailable)
        let out = try #require(ProfileRoutesWriter.setProfileRoutes(
            in: "model:\n  default: gpt-5\n",
            routes: [Self.route(name: raw)],
            location: .absent,
            capabilities: Self.v019
        ))
        let loaded = try #require(
            PyYAML.load(out),
            "PyYAML REFUSED the config.yaml Scarf wrote for name \(raw.debugDescription) — Hermes discards the whole layer"
        )
        #expect(
            loaded.contains(Self.pythonRepr(raw)),
            "name \(raw.debugDescription) did not round-trip as a string; PyYAML read \(loaded)"
        )
    }

    /// The ids go through the same routine. `quotedID` had no line-break or
    /// control guard at all, and an id field is as free as the name.
    @Test(arguments: ["}x", "`x", "a\tb", "12_000", "a\nb", "it's"])
    func profileRouteIDRoundTripsThroughRealPyYAML(_ raw: String) throws {
        try #require(Self.pyYAMLAvailable)
        let out = try #require(ProfileRoutesWriter.setProfileRoutes(
            in: "model:\n  default: gpt-5\n",
            routes: [HermesProfileRoute(platform: "discord", profile: "p", guildID: raw)],
            location: .absent,
            capabilities: Self.v019
        ))
        let loaded = try #require(PyYAML.load(out), "PyYAML refused guild_id \(raw.debugDescription)")
        #expect(loaded.contains(Self.pythonRepr(raw)), "guild_id read back as \(loaded)")
    }

    /// `platform` and `profile` are normalised to lowercase slugs by the
    /// editor, but the writer is a public entry point and the parse→write
    /// round-trip carries whatever a hand-edited file held.
    @Test func profileRouteWriterKeepsOrdinaryNamesUnquoted() throws {
        let out = try #require(ProfileRoutesWriter.setProfileRoutes(
            in: "model:\n  default: gpt-5\n",
            routes: [Self.route(name: "server-default")],
            location: .absent,
            capabilities: Self.v019
        ))
        #expect(out.contains("- name: server-default"))
        // Ids stay quoted — Discord ids are digit strings compared with `!=`
        // against string source ids (`ProfileRoute.matches`,
        // `gateway/profile_routing.py:76-87` @ `v2026.9.7`).
        #expect(out.contains("guild_id: '123'"))
    }

    // MARK: - HermesBotProfileYAML (H2)

    /// `display_name`, the profile `description` and the bot block's
    /// `title` / `description` / `color` / `shape` / `group` all go through
    /// the one routine. Its doc block claimed "for ANY input string this
    /// returns a single line of valid YAML that PyYAML loads back as that
    /// exact string"; the audit fuzzed 166 failures out of ~6000 inputs.
    @Test(arguments: fuzzClasses)
    func botProfileScalarsRoundTripThroughRealPyYAML(_ raw: String) throws {
        try #require(Self.pyYAMLAvailable)
        let identity = HermesBotIdentity(
            profileName: "research",
            profileDirectory: "/tmp/research",
            displayName: raw,
            profileDescription: raw,
            isBotManaged: true,
            title: raw,
            botDescription: raw,
            color: raw,
            shape: raw,
            legacyGroup: raw
        )
        let out = try #require(HermesBotProfileYAML.write(identity: identity, into: "version: 1\n"))
        let loaded = try #require(
            PyYAML.load(out),
            "PyYAML REFUSED the profile.yaml Scarf wrote for \(raw.debugDescription) — total metadata loss"
        )
        #expect(
            loaded.contains(Self.pythonRepr(raw)),
            "\(raw.debugDescription) did not round-trip as a string; PyYAML read \(loaded)"
        )
    }

    /// A multi-line Role/description is a deliberate feature of the bot
    /// editor (`BotsViewModel.swift:185-192`), and Hermes round-trips real
    /// newlines through `yaml.safe_dump`. It must stay lossless.
    @Test func botDescriptionKeepsRealNewlines() throws {
        try #require(Self.pyYAMLAvailable)
        let prose = "First line.\n\nSecond paragraph with a `backtick`."
        let identity = HermesBotIdentity(
            profileName: "research",
            profileDirectory: "/tmp/research",
            isBotManaged: true,
            botDescription: prose
        )
        let out = try #require(HermesBotProfileYAML.write(identity: identity, into: "version: 1\n"))
        let loaded = try #require(PyYAML.load(out), "PyYAML refused a multi-line description")
        #expect(loaded.contains(Self.pythonRepr(prose)))
        // And Scarf reads its own file back to the same string.
        let reparsed = HermesBotProfileYAML.parse(
            out, profileName: "research", profileDirectory: "/tmp/research"
        )
        #expect(reparsed.botDescription == prose)
    }

    // MARK: - Control characters are refused, not reshaped (decision 6)

    /// Decision 6: a control character in a user-typed *single-line* scalar
    /// is a visible editor validation error, in the same shape as
    /// `MCPServerEditorViewModel.duplicateKey` — not a silent double-quote.
    @Test(arguments: ["a\tb", "a\nb", "a\r\nb", "a\u{01}b", "a\u{7F}b", "a\u{85}b"])
    func aControlCharacterIsAValidationErrorOnEverySingleLineRouteField(_ raw: String) {
        #expect(YAMLScalar.containsControlCharacter(raw))
        for keyPath in [
            \HermesProfileRoute.name, \HermesProfileRoute.platform,
            \HermesProfileRoute.profile, \HermesProfileRoute.guildID,
            \HermesProfileRoute.chatID, \HermesProfileRoute.threadID
        ] {
            var route = HermesProfileRoute(platform: "discord", profile: "p")
            route[keyPath: keyPath] = raw
            #expect(
                route.controlCharacterFieldLabel != nil,
                "\(raw.debugDescription) in \(keyPath) was accepted"
            )
        }
    }

    /// Ordinary text — including the flow characters that only need
    /// QUOTING — is not a validation error. The refusal is for control
    /// characters alone; over-refusing would make an ordinary name
    /// untypable.
    @Test(arguments: ["}x", "`x", "<<", ".inf", "2026-09-09", "Support — EU", "a b"])
    func ordinaryTextIsNotAValidationError(_ raw: String) {
        #expect(!YAMLScalar.containsControlCharacter(raw))
        var route = HermesProfileRoute(platform: "discord", profile: "p")
        route.name = raw
        #expect(route.controlCharacterFieldLabel == nil)
    }

    /// A line break is legal in the ONE field that is deliberately
    /// multi-line; every other control character still is not.
    @Test func lineBreaksAreAllowedOnlyWhereTheFieldIsMultiLine() {
        #expect(!YAMLScalar.containsControlCharacter("a\nb", allowingLineBreaks: true))
        #expect(YAMLScalar.containsControlCharacter("a\tb", allowingLineBreaks: true))
        #expect(YAMLScalar.containsControlCharacter("a\u{01}b", allowingLineBreaks: true))
    }

    // MARK: - Duplicate sections are last-wins for scalars too (L8)

    /// P19 made `parseNestedYAML` last-wins for a duplicate section's
    /// BULLETS and left the scalars and maps: a sibling that appeared only
    /// in the FIRST block survived in Scarf and is gone on the host, because
    /// PyYAML replaces the whole mapping. Cross-checked against real PyYAML
    /// rather than asserted from the spec.
    @Test func aDuplicateSectionDropsTheFirstBlocksSiblings() throws {
        let yaml = """
        gateway:
          only_in_first: keep-me-not
          shared: first
          list_in_first:
          - a
        gateway:
          shared: second
        """
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(parsed.values["gateway.shared"] == "second")
        #expect(parsed.values["gateway.only_in_first"] == nil)
        #expect(parsed.lists["gateway.list_in_first"] == nil)

        guard Self.pyYAMLAvailable else { return }
        let loaded = try #require(PyYAML.load(yaml))
        #expect(loaded == "{'gateway': {'shared': 'second'}}", "PyYAML read \(loaded)")
    }

    /// …and an ordinary nested document is untouched by that purge — the
    /// rule fires on a RE-OPENED path, and every fresh header is a no-op.
    @Test func ordinaryNestingIsUnaffected() {
        let parsed = HermesYAML.parseNestedYAML("""
        gateway:
          a: 1
          nested:
            b: 2
        model:
          a: 3
        """)
        #expect(parsed.values["gateway.a"] == "1")
        #expect(parsed.values["gateway.nested.b"] == "2")
        #expect(parsed.values["model.a"] == "3")
    }

    // MARK: - Helpers

    /// `repr()` of a Python `str`, so a `contains` check against
    /// `repr(yaml.safe_load(...))` cannot pass on a retyped value.
    static func pythonRepr(_ s: String) -> String {
        // Python's own delimiter rule: `'` normally, `"` when the string
        // carries a `'` and no `"`.
        let delimiter: Character = (s.contains("'") && !s.contains("\"")) ? "\"" : "'"
        var out = String(delimiter)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'" where delimiter == "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\x%02x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + String(delimiter)
    }
}
