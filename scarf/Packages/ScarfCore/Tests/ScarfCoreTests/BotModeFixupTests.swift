import Testing
import Foundation
@testable import ScarfCore

/// The fresh-eyes audit's fixup package for Bot Mode Phase A.
///
/// The headline finding: `HermesBotProfileYAML.quoted` emitted a REAL newline
/// inside a single-quoted YAML scalar for any multi-line value (the editor's
/// "Role" `TextEditor` produces them freely). A single-quoted scalar has no
/// escape for a line break, so PyYAML folded the rest of the `hermes-bots`
/// mapping into the string and Hermes lost every bit of profile metadata —
/// cumulatively, because the next save re-read the wreckage.
///
/// These tests therefore do not assert against Scarf's own parser alone. The
/// round-trips below shell out to the **real PyYAML** (`python3 -c "import
/// yaml…"`) and assert on what Hermes would actually load, which is the only
/// thing that matters. When python3/PyYAML is unavailable the PyYAML tests
/// skip rather than pass vacuously; the Scarf-side round-trip still runs.
@Suite struct BotModeFixupTests {

    // MARK: - PyYAML harness

    /// Load `yaml` with real PyYAML and return `json.dumps` of the result, or
    /// `nil` when python3/PyYAML isn't available here. A PyYAML *parse error*
    /// is not `nil` — it comes back as `"ERROR: …"`, so a corrupt file can
    /// never masquerade as "python missing" and skip the assertion.
    static func pyYAMLLoad(_ yaml: String) -> String? {
        let script = """
        import sys, json
        try:
            import yaml
        except Exception:
            sys.stdout.write("__NO_PYYAML__")
            sys.exit(0)
        raw = sys.stdin.buffer.read().decode("utf-8")
        try:
            sys.stdout.write(json.dumps(yaml.safe_load(raw), sort_keys=True))
        except Exception as exc:
            sys.stdout.write("ERROR: %s" % exc)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        stdin.fileHandleForWriting.write(Data(yaml.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = String(decoding: data, as: UTF8.self)
        return out == "__NO_PYYAML__" ? nil : out
    }

    /// The `hermes-bots` mapping PyYAML sees, as a dictionary — or `nil` when
    /// python is unavailable. Fails the test outright if PyYAML rejects the
    /// file or the block isn't a mapping (i.e. the corruption this suite is
    /// about).
    static func pyYAMLBotBlock(_ yaml: String, _ comment: Comment? = nil) -> [String: Any]?? {
        guard let json = pyYAMLLoad(yaml) else { return .some(nil) }
        if json.hasPrefix("ERROR:") {
            Issue.record("PyYAML refused the file Scarf wrote: \(json)\n---\n\(yaml)")
            return .none
        }
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: Any] else {
            Issue.record("PyYAML did not load a mapping: \(json)")
            return .none
        }
        guard let uiMeta = object["ui_meta"] as? [String: Any],
              let bots = uiMeta[HermesBotProfileYAML.botMetaKey] as? [String: Any] else {
            Issue.record("`ui_meta.hermes-bots` is not a mapping to PyYAML: \(json)")
            return .none
        }
        return .some(bots)
    }

    // MARK: - Fixtures

    static let baseYAML = """
    display_name: Athena
    description: Research.
    ui_meta:
      hermes-bots:
        title: Athena
        color: '#C1502E'
    """

    static func identity(
        title: String? = nil,
        description: String? = nil,
        color: String? = nil,
        shape: String? = nil,
        groups: [String] = []
    ) -> HermesBotIdentity {
        var identity = HermesBotIdentity(profileName: "athena", profileDirectory: "/tmp/athena")
        identity.isBotManaged = true
        identity.displayName = title ?? ""
        identity.profileDescription = description ?? ""
        identity.title = title
        identity.botDescription = description
        identity.color = color
        identity.shape = shape
        identity.groups = groups
        return identity
    }

    /// The nastiest value the editor can produce, in every free-text field at
    /// once: interior newlines, a CR, a tab, both quote flavors, a backslash,
    /// YAML flow punctuation, a comment marker, and a leading `-`.
    static let hostileValue = """
    - line one: with a colon # and a hash
    line 'two' has "both" quotes \\ and a backslash
    \tline three starts with a tab {and} [flow] punctuation,
    """ + "\r\nline four came from a CRLF paste"

    // MARK: - 1. The newline trap

    @Test("every field carrying newlines survives a real PyYAML load, unchanged")
    func newlineInEveryFieldRoundTripsThroughPyYAML() throws {
        let identity = Self.identity(
            title: Self.hostileValue,
            description: Self.hostileValue,
            color: Self.hostileValue,
            shape: Self.hostileValue,
            groups: [Self.hostileValue, "plain"]
        )
        let written = try #require(HermesBotProfileYAML.write(identity: identity, into: Self.baseYAML))

        // A `hermes-bots:` block must be exactly one key per line — if any
        // value's newline leaked, the file's line count would not add up and
        // PyYAML would fold the following keys into the string.
        guard let bots = try #require(Self.pyYAMLBotBlock(written)) else { return }
        #expect(bots["title"] as? String == Self.hostileValue)
        #expect(bots["description"] as? String == Self.hostileValue)
        #expect(bots["color"] as? String == Self.hostileValue)
        #expect(bots["shape"] as? String == Self.hostileValue)
        #expect(bots["groups"] as? [String] == [Self.hostileValue, "plain"])
        // The keys that would vanish first under the old corruption.
        #expect(bots.keys.contains("title") && bots.keys.contains("color"))
    }

    /// The cumulative half of the bug: a corrupt save was re-read on the next
    /// open, so each save degraded the file further. Three consecutive
    /// write→parse→write cycles must be a fixed point.
    @Test("save → reopen → save is a fixed point, so corruption cannot accumulate")
    func repeatedSavesAreStable() throws {
        var yaml = Self.baseYAML
        let original = Self.identity(
            title: Self.hostileValue,
            description: Self.hostileValue,
            color: "#C1502E"
        )
        yaml = try #require(HermesBotProfileYAML.write(identity: original, into: yaml))
        let firstWrite = yaml
        for _ in 0..<3 {
            let parsed = HermesBotProfileYAML.parse(yaml, profileName: "athena", profileDirectory: "/tmp/athena")
            #expect(parsed.isBotManaged)
            #expect(parsed.title == Self.hostileValue)
            #expect(parsed.botDescription == Self.hostileValue)
            yaml = try #require(HermesBotProfileYAML.write(identity: parsed, into: yaml))
        }
        #expect(yaml == firstWrite, "a re-save of an unmodified identity must be a no-op")
    }

    /// The sharp end of the newline bug, kept as its own case because it is
    /// the one that loses EVERYTHING rather than just mangling a value: a
    /// line that is exactly `---` or `...` inside a multi-line flow scalar
    /// terminates the YAML document mid-string, PyYAML raises on the whole
    /// file, and Hermes' `read_profile_meta` swallows the exception and
    /// returns empty defaults — so `display_name`, `description` and the
    /// entire `hermes-bots` block vanish and the profile drops out of the
    /// bot roster. Markdown pasted into the description field produces
    /// `---` routinely.
    @Test(arguments: ["Role\n---\nnotes", "Role\n...\nnotes", "Role\n\n---\n\nnotes"])
    func aDocumentSeparatorInADescriptionDoesNotDestroyTheFile(value: String) throws {
        let written = try #require(
            HermesBotProfileYAML.write(
                identity: Self.identity(title: "Athena", description: value),
                into: Self.baseYAML
            )
        )
        guard let bots = try #require(Self.pyYAMLBotBlock(written)) else { return }
        #expect(bots["description"] as? String == value)
        #expect(bots["title"] as? String == "Athena")
    }

    @Test("Scarf's own parser is the exact inverse of its writer for control characters")
    func scarfParserInvertsTheWriter() throws {
        for value in [
            "one\ntwo", "tab\there", "cr\rhere", "back\\slash", "quote\"and'quote",
            "\u{85}nel", "trailing newline\n", "\u{1}control", "emoji 🐈 and \n newline",
        ] {
            let written = try #require(
                HermesBotProfileYAML.write(identity: Self.identity(title: value), into: Self.baseYAML)
            )
            let parsed = HermesBotProfileYAML.parse(written, profileName: "athena", profileDirectory: "/tmp/athena")
            #expect(parsed.title == value, "round-trip failed for \(value.debugDescription)")
        }
    }

    @Test("a plain value is still written unquoted — no gratuitous churn")
    func ordinaryValuesAreUntouched() {
        #expect(HermesBotProfileYAML.quoted("Athena") == "Athena")
        #expect(HermesBotProfileYAML.quoted("Research bot") == "Research bot")
        #expect(HermesBotProfileYAML.quoted("has: colon") == "'has: colon'")
        // A bare apostrophe mid-word needs no quoting in YAML at all; only a
        // LEADING quote does, and then it is doubled.
        #expect(HermesBotProfileYAML.quoted("it's") == "it's")
        #expect(HermesBotProfileYAML.quoted("'quoted'") == "'''quoted'''")
        #expect(HermesBotProfileYAML.quoted("") == "''")
        // Only a control character forces the double-quoted style.
        #expect(HermesBotProfileYAML.quoted("a\nb") == "\"a\\nb\"")
        #expect(HermesBotProfileYAML.quoted("a\tb") == "\"a\\tb\"")
    }

    // MARK: - 4. Duplicate hermes-bots inside ui_meta

    /// `locateBotBlock` takes the FIRST match; PyYAML takes the LAST. Editing
    /// one of two is a coin flip on whether Hermes ever sees the edit — the
    /// same reason the top-level duplicate-key guard exists.
    @Test("a duplicate hermes-bots inside ui_meta is refused, not half-edited")
    func duplicateBotBlockIsRefused() {
        let yaml = """
        ui_meta:
          hermes-bots:
            title: First
          hermes-bots:
            title: Second
        """
        #expect(HermesBotProfileYAML.write(identity: Self.identity(title: "New"), into: yaml) == nil)
        // A single block in the same shape still writes, so the guard is
        // about duplication and nothing else.
        let single = """
        ui_meta:
          hermes-bots:
            title: First
        """
        #expect(HermesBotProfileYAML.write(identity: Self.identity(title: "New"), into: single) != nil)
    }

    // MARK: - 11. Tab-indented ui_meta

    @Test("a tab-indented ui_meta body is refused instead of silently duplicated")
    func tabIndentedBodyIsRefused() {
        let yaml = "ui_meta:\n\thermes-bots:\n\t\ttitle: First\n"
        #expect(HermesBotProfileYAML.write(identity: Self.identity(title: "New"), into: yaml) == nil)
    }

    // MARK: - 9. Size ceiling measured at the real indent

    /// The ceiling was measured on a `keyIndent: 2` rendering and then a
    /// differently-indented block was written, so a deeply-indented file
    /// could slip past the guard. Measure what is actually written.
    @Test("the size ceiling is measured on the block that is actually written")
    func sizeCeilingMeasuresTheRenderedIndent() {
        // Just under the limit at indent 2; the extra indent per line pushes
        // the deep-indent rendering over it.
        var identity = Self.identity(title: "Athena")
        identity.unknownMetaLines = (0..<500).map { "k\($0): \(String(repeating: "x", count: 110))" }
        let shallow = HermesBotProfileYAML.renderBotMeta(identity, keyIndent: 2)
        let deep = HermesBotProfileYAML.renderBotMeta(identity, keyIndent: 40)
        #expect(shallow.joined(separator: "\n").utf8.count <= HermesBotProfileYAML.maxBotMetaBytes)
        #expect(deep.joined(separator: "\n").utf8.count > HermesBotProfileYAML.maxBotMetaBytes)

        var deeplyIndented = "ui_meta:\n"
        deeplyIndented += String(repeating: " ", count: 40) + "hermes-bots:\n"
        deeplyIndented += String(repeating: " ", count: 42) + "title: Old\n"
        #expect(HermesBotProfileYAML.write(identity: identity, into: deeplyIndented) == nil,
                "the oversized DEEP rendering must be refused, not sized as if it were at indent 2")
        // The same identity at the ordinary indent is under the cap and writes.
        #expect(HermesBotProfileYAML.write(identity: identity, into: Self.baseYAML) != nil)
    }

    // MARK: - 10. Line endings

    @Test("mixed line endings are preserved per line rather than flipped wholesale")
    func mixedLineEndingsSurvive() throws {
        let yaml = "display_name: Athena\r\ndescription: Research.\nui_meta:\r\n  hermes-bots:\r\n    title: Athena\n"
        let written = try #require(
            HermesBotProfileYAML.write(identity: Self.identity(title: "Athena2", description: "Research."), into: yaml)
        )
        // The untouched LF-only line stayed LF; the CRLF lines stayed CRLF.
        #expect(written.contains("description: Research.\nui_meta:\r\n"))
        #expect(written.contains("ui_meta:\r\n"))
        #expect(!written.contains("\r\r"))
        guard let bots = try #require(Self.pyYAMLBotBlock(written)) else { return }
        #expect(bots["title"] as? String == "Athena2")
    }

    @Test("a pure-LF file gains no carriage returns")
    func lfOnlyFilesStayLFOnly() throws {
        let written = try #require(
            HermesBotProfileYAML.write(identity: Self.identity(title: "Athena2"), into: Self.baseYAML)
        )
        #expect(!written.contains("\r"))
    }

    @Test("a pure-CRLF file stays fully CRLF")
    func crlfOnlyFilesStayCRLF() throws {
        let yaml = Self.baseYAML.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
        let written = try #require(
            HermesBotProfileYAML.write(identity: Self.identity(title: "Athena2"), into: yaml)
        )
        for line in written.components(separatedBy: "\r\n") {
            #expect(!line.contains("\n"), "a bare LF survived in a CRLF file")
        }
    }

    // MARK: - 5. Profile-name validation

    /// ICU's `$` matches before a trailing line terminator, so `"work\n"`
    /// validated and then normalized to `"work"` — a validated-one-string,
    /// used-another bug that writes into a different profile than the one
    /// that was checked.
    @Test(arguments: ["work\n", "work\r\n", "work\r", "work\u{2028}", "\nwork", " work", "work "])
    func namesWithLineTerminatorsAreInvalid(name: String) {
        #expect(!HermesProfileScope.isValidName(name), "\(name.debugDescription) must be rejected")
    }

    @Test("a valid name is byte-identical to its own normalization")
    func validNamesAreTheirOwnNormalForm() {
        for name in ["work", "a", "a1_b-c", "1abc", String(repeating: "a", count: 64)] {
            #expect(HermesProfileScope.isValidName(name))
            #expect(HermesProfileScope.normalize(name) == name)
        }
        // `default` stays valid but normalizes to nil — it IS the root home.
        #expect(HermesProfileScope.isValidName("default"))
        #expect(HermesProfileScope.normalize("default") == nil)
    }

    // MARK: - 3. Routine delegation wrapper (format pinned to the TS source)

    /// Byte-matched against `apps/desktop/src/plugins/hermes-bots/cron.tsx`
    /// (Hermes v0.21.0): `:74` `SAFE_ROUTINE_MARKER`, `:270-286`
    /// `routinePrompt`, `:250-256` `normalizedProfileName` / `shellQuote`.
    @Test("the delegation prompt is byte-identical to Hermes Desktop's routinePrompt")
    func delegationPromptMatchesTheDesktop() {
        #expect(BotRoutineDelegation.marker == "[bot-mode:routine:v2] ")
        let prompt = BotRoutineDelegation.prompt(
            bot: "research",
            title: "Morning digest",
            instruction: "Summarize overnight news",
            storeProfile: "work"
        )
        #expect(prompt == """
        [bot-mode:routine:v2] You are running the scheduled routine "Morning digest" for agent \
        'research'. Execute it AS that agent so the run lands in its own history: run this in the \
        terminal and relay the output:

        hermes -p 'research' chat -c 'Routine: Morning digest' -q '[Scheduled routine] Summarize overnight news'

        If the command fails, report the error instead.
        """)
    }

    @Test("normalizedProfileName is trim + lowercase, exactly like the TS helper")
    func normalizedProfileNameMatchesTheDesktop() {
        #expect(BotRoutineDelegation.normalizedProfileName("  Research  ") == "research")
        #expect(BotRoutineDelegation.normalizedProfileName(nil) == "")
        #expect(!BotRoutineDelegation.requiresDelegation(bot: "Research", storeProfile: " research "))
        #expect(BotRoutineDelegation.requiresDelegation(bot: "research", storeProfile: "work"))
        // Falsy bot name → the TS guard's early return is skipped.
        #expect(BotRoutineDelegation.requiresDelegation(bot: "  ", storeProfile: "  "))
    }

    @Test("shellQuote uses the POSIX '\"'\"' escape, so a quoted instruction can't break out")
    func shellQuoteMatchesTheDesktop() {
        #expect(BotRoutineDelegation.shellQuote("plain") == "'plain'")
        #expect(BotRoutineDelegation.shellQuote("it's") == "'it'\"'\"'s'")
        #expect(BotRoutineDelegation.shellQuote("'; rm -rf /; '") == "''\"'\"'; rm -rf /; '\"'\"''")
    }
}
