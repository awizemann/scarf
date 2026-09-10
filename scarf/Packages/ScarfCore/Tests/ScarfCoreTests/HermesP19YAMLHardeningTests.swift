import Foundation
import Testing
@testable import ScarfCore

/// P19 — YAML writer hardening.
///
/// Same stakes as P10: `gateway/config.py:775-791` at `v2026.9.7` wraps the
/// config.yaml load in a bare `except Exception` that logs "Failed to
/// process config.yaml — falling back to .env / gateway.json values." and
/// CONTINUES, so anything Scarf emits that PyYAML mis-reads costs the user
/// their ENTIRE config.yaml layer without a word. Every writer assertion
/// here is therefore round-tripped through the real PyYAML when it is
/// present; the structural half runs either way.
struct HermesP19YAMLHardeningTests {

    // MARK: - PyYAML harness

    static let pyYAMLAvailable: Bool = { PyYAML.run("import yaml") != nil }()

    enum PyYAML {
        static func run(_ script: String, stdin text: String = "") -> String? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", "-c", script]
            let out = Pipe(), err = Pipe(), input = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            proc.standardInput = input
            do { try proc.run() } catch { return nil }
            input.fileHandleForWriting.write(Data(text.utf8))
            input.fileHandleForWriting.closeFile()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        /// `repr(yaml.safe_load(stdin))`, or nil when PyYAML refuses the
        /// document — which is exactly the failure that costs the user
        /// their whole config.yaml layer.
        static func load(_ yaml: String) -> String? {
            run("import sys,yaml; print(repr(yaml.safe_load(sys.stdin.read())))", stdin: yaml)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func parses(_ yaml: String) -> Bool { load(yaml) != nil }
    }

    /// The round-trip half of this suite is the half that proves Hermes can
    /// still READ what Scarf writes. When PyYAML is missing that half simply
    /// evaporates, so say so out loud rather than reporting a clean pass.
    @Test func pyYAMLRoundTripLaneIsPresent() {
        withKnownIssue(
            """
            PyYAML is not installed for `python3` on this machine — the \
            round-trip half of HermesP19YAMLHardeningTests did NOT run. \
            Install it (`python3 -m pip install pyyaml`) to exercise the \
            lane that proves Hermes can still read what Scarf writes.
            """,
            isIntermittent: true
        ) {
            #expect(Self.pyYAMLAvailable)
        }
    }

    // MARK: - Implicitly-typed scalars (finding 7)

    /// Every one of these is a plain spelling PyYAML's implicit resolvers
    /// RETYPE. Emitted bare, the user's string comes back as `None`, a
    /// bool, an int, a float or a `datetime.date`; after the fix each one
    /// round-trips as the string that was typed.
    @Test(arguments: [
        "~", "null", "Null", "NULL", ".inf", "-.inf", ".nan",
        "0", "007", "0x1F", "0b101", "1_000", "1.5", "1.0e+3", ".5",
        "2026-09-09", "yes", "no", "on", "off", "true", "False",
        "12:30", "<<", "="
    ])
    func implicitlyTypedScalarsAreQuotedAndRoundTripAsStrings(_ raw: String) {
        #expect(
            YAMLScalar.resolvesToNonString(raw),
            "\(raw) is retyped by a PyYAML implicit resolver and must be quoted"
        )
        let emitted = YAMLScalar.quoteIfNeeded(raw)
        #expect(emitted != raw, "\(raw) was emitted bare")

        guard Self.pyYAMLAvailable else { return }
        let doc = "slack:\n  allowed_channels:\n  - \(emitted)\n"
        #expect(PyYAML.load(doc) == "{'slack': {'allowed_channels': ['\(raw)']}}")

        // And the same spelling emitted BARE is what the fix prevents: it
        // loads as something that is not the user's string.
        let bare = "slack:\n  allowed_channels:\n  - \(raw)\n"
        let bareLoaded = PyYAML.load(bare)
        #expect(bareLoaded != "{'slack': {'allowed_channels': ['\(raw)']}}")
    }

    /// Plain identifiers stay unquoted — the byte-for-byte contract for the
    /// overwhelmingly common case.
    /// `1e3` is one of them: PyYAML's float resolver REQUIRES a signed
    /// exponent, so `1e3` really is a string and quoting it would be
    /// churn.
    @Test(arguments: ["C123ABC", "general", "my-channel", "a_b.c", "user@host", "1e3", "1e+3", "1.2.3"])
    func ordinaryIdentifiersAreStillEmittedBare(_ raw: String) {
        #expect(!YAMLScalar.resolvesToNonString(raw))
        #expect(YAMLScalar.quoteIfNeeded(raw) == raw)
    }

    // MARK: - BOM (finding 3)

    private static let bom = "\u{FEFF}"

    /// A U+FEFF is in NEITHER `.whitespaces` nor `.whitespacesAndNewlines`,
    /// so it stayed glued to the first line and the file's FIRST top-level
    /// section read as missing. The write then appended a SECOND `slack:` —
    /// and PyYAML is last-wins, so `reply_to_mode` silently disappeared.
    @Test func bomDoesNotDuplicateTheFirstSection() {
        let yaml = Self.bom + "slack:\n  reply_to_mode: first\n\ntelegram:\n  token: t\n"
        let updated = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        )
        let headers = updated.components(separatedBy: "\n")
            .filter { YAMLScalar.strippingBOM($0) == "slack:" }
        #expect(headers.count == 1)
        // The BOM is preserved byte-for-byte, exactly where it was.
        #expect(updated.hasPrefix(Self.bom))
        #expect(!YAMLScalar.strippingBOM(updated).contains(Self.bom))

        guard Self.pyYAMLAvailable else { return }
        let loaded = PyYAML.load(updated)
        #expect(loaded?.contains("'reply_to_mode': 'first'") == true)
        #expect(loaded?.contains("'allowed_channels': ['C1']") == true)
        #expect(loaded?.contains("'token': 't'") == true)
    }

    /// Same root cause on the read side: the first section and its whole
    /// subtree were invisible to the parser.
    @Test func bomDoesNotHideTheFirstSectionFromTheParser() {
        let parsed = HermesYAML.parseNestedYAML(
            Self.bom + "slack:\n  reply_to_mode: first\n  allowed_channels:\n  - C1\n"
        )
        #expect(parsed.values["slack.reply_to_mode"] == "first")
        #expect(parsed.lists["slack.allowed_channels"] == ["C1"])
    }

    // MARK: - Mixed line endings (finding 8)

    /// A uniformly-CRLF file still round-trips as CRLF.
    @Test func uniformCRLFIsPreserved() {
        let yaml = "slack:\r\n  reply_to_mode: thread\r\n"
        guard case .updated(let updated) = GatewayConfigWriter.setListChecked(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        ) else {
            Issue.record("expected an update for a uniformly-CRLF file")
            return
        }
        #expect(!updated.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    /// A MIXED file keeps every surviving line's OWN terminator. The old
    /// code re-emitted the whole file as CRLF the moment it saw one `\r\n`,
    /// contradicting its own "byte-for-byte outside the edited key" contract.
    /// `HermesBotProfileYAML` already did this per line; P19 lifted that into
    /// `YAMLLineEndings` and pointed this writer at it.
    @Test func mixedLineEndingsArePreservedPerLineNotFlippedWholesale() {
        let yaml = "model: gpt-5\nslack:\r\n  reply_to_mode: thread\r\n"
        guard case .updated(let updated) = GatewayConfigWriter.setListChecked(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        ) else {
            Issue.record("expected an update for a mixed-ending file")
            return
        }
        // The untouched LF-only line stayed LF; the CRLF lines stayed CRLF.
        #expect(updated.hasPrefix("model: gpt-5\nslack:\r\n"))
        #expect(updated.contains("  reply_to_mode: thread\r\n"))
        #expect(!updated.contains("\r\r"))
        // The row Scarf wrote takes the file's dominant ending.
        #expect(updated.contains("  - C1"))

        guard Self.pyYAMLAvailable else { return }
        let loaded = PyYAML.load(updated)
        #expect(loaded?.contains("'model': 'gpt-5'") == true)
        #expect(loaded?.contains("'reply_to_mode': 'thread'") == true)
        #expect(loaded?.contains("'allowed_channels': ['C1']") == true)
    }

    // MARK: - Comment preservation (finding 5)

    @Test func commentsInsideAListBlockSurviveTheRewrite() {
        let yaml = """
        slack:
          allowed_channels:  # work only
          - C1
          # the ops channel, do not remove
          - C2
          reply_to_mode: thread
        """
        let updated = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1", "C3"]
        )
        #expect(updated.contains("# the ops channel, do not remove"))
        #expect(updated.contains("allowed_channels:  # work only"))
        #expect(updated.contains("- C3"))
        #expect(updated.contains("reply_to_mode: thread"))

        // Idempotent: a second save of the same items changes nothing, so
        // the comments cannot drift or duplicate.
        #expect(GatewayConfigWriter.setList(
            in: updated, platform: "slack", key: "allowed_channels", items: ["C1", "C3"]
        ) == updated)

        guard Self.pyYAMLAvailable else { return }
        #expect(PyYAML.load(updated)?.contains("'allowed_channels': ['C1', 'C3']") == true)
    }

    @Test func trailingCommentOnAnInlineListSurvives() {
        let yaml = "slack:\n  allowed_channels: []  # none yet\n"
        let updated = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        )
        #expect(updated.contains("# none yet"))
        guard Self.pyYAMLAvailable else { return }
        #expect(PyYAML.load(updated)?.contains("'allowed_channels': ['C1']") == true)
    }

    @Test func commentsInsideAMapBlockSurviveTheRewrite() {
        let yaml = """
        agent:
          reasoning_overrides:
          # cheap models only
            gpt-4: low
          verbose: false
        """
        let updated = GatewayConfigWriter.setMap(
            in: yaml, section: "agent", key: "reasoning_overrides",
            pairs: [("gpt-4", "high")]
        )
        #expect(updated.contains("# cheap models only"))
        #expect(updated.contains("gpt-4: high"))
        #expect(updated.contains("verbose: false"))
        guard Self.pyYAMLAvailable else { return }
        #expect(PyYAML.load(updated)?.contains("'gpt-4': 'high'") == true)
    }

    /// A `#` that is part of a value is not a comment (`a#b`), and a `#`
    /// inside quotes is not a comment either — neither may be mistaken for
    /// one and hoisted onto the key line.
    @Test func hashInsideAValueIsNotTreatedAsAComment() {
        let yaml = "slack:\n  allowed_channels: ['#general']\n"
        let updated = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["#random"]
        )
        #expect(updated.contains("allowed_channels:\n"))
        #expect(!updated.contains("allowed_channels:  #"))
        guard Self.pyYAMLAvailable else { return }
        #expect(PyYAML.load(updated)?.contains("'allowed_channels': ['#random']") == true)
    }

    // MARK: - Single-quote un-doubling (finding 4)

    @Test func singleQuotedScalarsAreUnDoubledOnTheWayBackIn() {
        #expect(HermesYAML.stripYAMLQuotes("'#it''s'") == "#it's")
        #expect(HermesYAML.normalizedScalar("'#it''s'") == "#it's")
        // The doubled pair inside a value with a trailing comment, too.
        #expect(HermesYAML.normalizedScalar("'it''s'  # note") == "it's")
        // Nothing to un-double stays byte-identical.
        #expect(HermesYAML.stripYAMLQuotes("'plain'") == "plain")
        #expect(HermesYAML.normalizedScalar("\"a\"") == "a")
    }

    /// The asymmetric pair grew one `'` per save: `#it's` → `'#it''s'` →
    /// read back as `#it''s` → `'#it''''s'`, at which point PyYAML really
    /// does load `#it''s` and the value on disk has CHANGED.
    @Test func apostropheValueIsIdempotentAcrossSaveReadSave() {
        let value = "#it's"
        let first = GatewayConfigWriter.setList(
            in: "slack:\n  reply_to_mode: thread\n",
            platform: "slack", key: "allowed_channels", items: [value]
        )
        let readBack = HermesYAML.parseNestedYAML(first).lists["slack.allowed_channels"]
        #expect(readBack == [value])

        let second = GatewayConfigWriter.setList(
            in: first, platform: "slack", key: "allowed_channels", items: readBack ?? []
        )
        #expect(second == first, "a second save of the value we just read must be a no-op")

        guard Self.pyYAMLAvailable else { return }
        // Python's repr switches to double quotes for a string carrying an
        // apostrophe: `["#it's"]`.
        #expect(PyYAML.load(first)?.contains(##"["#it's"]"##) == true)
    }

    // MARK: - Duplicate list key (finding 9)

    /// PyYAML is LAST-WINS on a duplicate key. A file already carrying the
    /// block twice (which is what the pre-fix BOM path produced) used to
    /// render both lists concatenated — a set Hermes never sees.
    @Test func duplicateListKeyIsLastWinsLikePyYAML() {
        let yaml = """
        slack:
          allowed_channels:
          - C1
        slack:
          allowed_channels:
          - C2
        """
        #expect(HermesYAML.parseNestedYAML(yaml).lists["slack.allowed_channels"] == ["C2"])
        guard Self.pyYAMLAvailable else { return }
        #expect(PyYAML.load(yaml) == "{'slack': {'allowed_channels': ['C2']}}")
    }

    // MARK: - Line breaks

    @Test func lineBreakDetectionScansUnicodeScalars() {
        // `"\r\n"` is ONE Swift Character, so `contains("\n")` is false.
        #expect(YAMLScalar.containsLineBreak("a\r\nb"))
        #expect(YAMLScalar.containsLineBreak("a\nb"))
        #expect(YAMLScalar.containsLineBreak("a\rb"))
        #expect(!YAMLScalar.containsLineBreak("a b"))
    }
}
