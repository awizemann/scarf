import Foundation
import Testing
@testable import ScarfCore

/// P10 — the config.yaml writers and the reader must never produce (or
/// silently mis-read) a document PyYAML rejects.
///
/// Why this matters, cited: at Hermes v2026.9.7, `gateway/config.py:776-791`
/// wraps `config_loader.load_yaml_layer(...)` in a bare `except Exception`
/// that logs "Failed to process config.yaml — falling back to .env /
/// gateway.json values." and CONTINUES. So a single syntax error does not
/// fail loudly — it makes Hermes discard the ENTIRE config.yaml layer. Every
/// byte Scarf writes there has to parse.
///
/// The assertions therefore round-trip the emitted text through the real
/// PyYAML when it is available on the machine running the tests, and fall
/// back to structural Swift assertions when it is not (the structural checks
/// run either way, so the suite still fails without the fixes).
struct ConfigYAMLWriterSafetyTests {

    // MARK: - PyYAML harness

    /// `python3 -c 'import yaml'` succeeds on this machine.
    static let pyYAMLAvailable: Bool = {
        PythonYAML.run(script: "import yaml") != nil
    }()

    private enum PythonYAML {
        /// Runs `python3 -c <script>` with `text` on stdin. Returns stdout on
        /// exit 0, nil otherwise (missing python3, missing PyYAML, or a
        /// parse error raised by the script).
        static func run(script: String, stdin text: String = "") -> String? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", "-c", script]
            let out = Pipe(), err = Pipe(), inPipe = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            proc.standardInput = inPipe
            do { try proc.run() } catch { return nil }
            inPipe.fileHandleForWriting.write(Data(text.utf8))
            inPipe.fileHandleForWriting.closeFile()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }

        /// `yaml.safe_load(stdin)` → repr, or nil when PyYAML refuses the
        /// document (exactly the failure that costs the user their whole
        /// config.yaml layer).
        static func safeLoad(_ yaml: String) -> String? {
            run(
                script: "import sys,yaml; print(repr(yaml.safe_load(sys.stdin.read())))",
                stdin: yaml
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// The value of `data[section][key]` as a repr, or nil when the
        /// document doesn't parse or the path is absent.
        static func value(_ yaml: String, _ section: String, _ key: String) -> String? {
            let script = """
            import sys,yaml
            d = yaml.safe_load(sys.stdin.read())
            print(repr(d[\(quoted(section))][\(quoted(key))]))
            """
            return run(script: script, stdin: yaml)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func quoted(_ s: String) -> String { "'\(s)'" }
    }

    /// The whole point of this suite is that Hermes discards the config.yaml
    /// layer on ONE PyYAML error, so a run where PyYAML is missing has tested
    /// only the structural half. That used to be invisible — every
    /// `if Self.pyYAMLAvailable` arm simply evaporated and the suite reported
    /// a clean pass. This records it as a KNOWN ISSUE instead: green when the
    /// lane ran, an explicit "known issue" line naming the missing dependency
    /// when it did not, and never a false failure on a machine without it.
    @Test func pyYAMLRoundTripLaneIsPresent() {
        withKnownIssue(
            """
            PyYAML is not installed for `python3` on this machine — the \
            round-trip half of ConfigYAMLWriterSafetyTests did NOT run. \
            Install it (`python3 -m pip install pyyaml`) to exercise the \
            lane that proves Hermes can still read what Scarf writes.
            """,
            isIntermittent: true
        ) {
            #expect(Self.pyYAMLAvailable)
        }
    }

    /// Assert the emitted YAML parses under PyYAML (no-op when PyYAML isn't
    /// installed here — `pyYAMLRoundTripLaneIsPresent` is what makes that
    /// visible in the run).
    private func expectParses(_ yaml: String, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard Self.pyYAMLAvailable else { return }
        #expect(
            PythonYAML.safeLoad(yaml) != nil,
            "PyYAML rejected \(what) — Hermes would discard the whole config.yaml layer:\n\(yaml)",
            sourceLocation: sourceLocation
        )
    }

    // MARK: - 1. Indent is derived from the file, never assumed

    /// A config.yaml written with 4-space body indent is ordinary YAML and
    /// PyYAML accepts it. Splicing a 2-space key into it produced a document
    /// where `allowed_channels` sat SHALLOWER than its siblings — PyYAML
    /// raises on that outright.
    @Test func fourSpaceSectionKeepsItsOwnIndentWhenKeyIsSpliced() {
        let yaml = """
        slack:
            reply_to_mode: first
            busy_ack_enabled: true
        """
        let out = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C123", "C456"]
        )
        #expect(out.contains("    allowed_channels:"))
        #expect(!out.contains("\n  allowed_channels:"))
        #expect(out.contains("        - C123"))  // 4-space file → 4/8, not 4/6
        expectParses(out, "a 4-space-indented section with a spliced key")
        if Self.pyYAMLAvailable {
            #expect(PythonYAML.value(out, "slack", "allowed_channels") == "['C123', 'C456']")
            // Siblings survive.
            #expect(PythonYAML.value(out, "slack", "reply_to_mode") == "'first'")
        }
    }

    /// The same file, but the key already exists at 4-space indent. The old
    /// writer matched keys only at indent 2, so it never found this one and
    /// spliced a SECOND `allowed_channels` — a duplicate key inside one
    /// mapping, resolved last-wins by PyYAML.
    @Test func fourSpaceSectionReplacesExistingKeyRatherThanDuplicatingIt() {
        let yaml = """
        slack:
            allowed_channels:
                - OLD
            reply_to_mode: first
        """
        let out = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["NEW"]
        )
        let occurrences = out.components(separatedBy: "allowed_channels:").count - 1
        #expect(occurrences == 1, "key was duplicated:\n\(out)")
        #expect(!out.contains("OLD"))
        #expect(out.contains("        - NEW"))   // the file's own item indent, preserved
        expectParses(out, "a 4-space-indented existing key replacement")
        if Self.pyYAMLAvailable {
            #expect(PythonYAML.value(out, "slack", "allowed_channels") == "['NEW']")
            #expect(PythonYAML.value(out, "slack", "reply_to_mode") == "'first'")
        }
    }

    /// The canonical 2/4 file must be byte-for-byte what it always was.
    @Test func twoSpaceSectionIsUnchangedFromThePreviousRelease() {
        let yaml = """
        slack:
          reply_to_mode: first
        """
        let out = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        )
        #expect(out == """
        slack:
          reply_to_mode: first
          allowed_channels:
            - C1
        """)
        expectParses(out, "the canonical 2/4 shape")
    }

    // MARK: - 2. A non-empty inline flow mapping is expanded, never clobbered

    /// `slack: {reply_to_mode: first}` is what a hand-written (or
    /// tool-written) config can hold. It fell through to `.platformMissing`,
    /// so the writer appended a whole second top-level `slack:` — PyYAML
    /// takes the last one, and `reply_to_mode` was gone.
    @Test func nonEmptyInlineFlowMappingIsExpandedNotDuplicated() {
        let yaml = "slack: {reply_to_mode: first, busy_ack_enabled: true}\n"
        let out = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        )
        let topLevelSlack = out.components(separatedBy: "\n").filter { $0.hasPrefix("slack:") }.count
        #expect(topLevelSlack == 1, "duplicate top-level section:\n\(out)")
        expectParses(out, "an expanded inline flow mapping")
        if Self.pyYAMLAvailable {
            // The pre-existing keys MUST survive — this is the data-loss test.
            #expect(PythonYAML.value(out, "slack", "reply_to_mode") == "'first'")
            #expect(PythonYAML.value(out, "slack", "busy_ack_enabled") == "True")
            #expect(PythonYAML.value(out, "slack", "allowed_channels") == "['C1']")
        }
    }

    /// A trailing comment on the flow line survives the expansion.
    @Test func inlineFlowMappingKeepsItsTrailingComment() {
        let yaml = "slack: {reply_to_mode: first}  # work workspace\n"
        let out = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        )
        #expect(out.contains("# work workspace"))
        expectParses(out, "an expanded flow mapping with a comment")
    }

    /// A flow mapping this line editor cannot read back verbatim is REFUSED,
    /// not guessed at — the file is left alone and the caller learns why.
    @Test func nestedInlineFlowMappingIsRefusedRatherThanClobbered() {
        let yaml = "slack: {thread: {mode: first}}\n"
        let outcome = GatewayConfigWriter.setListChecked(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        )
        guard case .refused = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        // The String-returning entry point leaves the file byte-identical.
        #expect(GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        ) == yaml)
    }

    /// The empty flow mapping keeps its existing, already-correct behaviour.
    @Test func emptyInlineFlowMappingStillBecomesABlockSection() {
        let yaml = "slack: {}\n"
        let out = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        )
        #expect(out.components(separatedBy: "\n").filter { $0.hasPrefix("slack:") }.count == 1)
        expectParses(out, "an expanded empty flow section")
        if Self.pyYAMLAvailable {
            #expect(PythonYAML.value(out, "slack", "allowed_channels") == "['C1']")
        }
    }

    // MARK: - 3. Scalar quoting covers every YAML indicator

    /// Flow indicators and the leading-position indicators are structure to
    /// PyYAML. Emitted bare, each one either changes the value's meaning or
    /// raises — and a raise costs the user the whole config.yaml layer.
    @Test func flowAndReservedIndicatorsAreQuoted() {
        let hostile = [
            "[bracketed]", "{braced}", "a,b", "!tagish", "%directive",
            "`backtick", "?question", "&anchor", "*alias", "=equals",
            "#hash", "colon: here", "-leading", "trailing ", " leading",
            "tab\there",
        ]
        let out = GatewayConfigWriter.setList(
            in: "slack:\n  reply_to_mode: first\n",
            platform: "slack", key: "allowed_channels", items: hostile
        )
        expectParses(out, "an allowlist of YAML-indicator-bearing items")
        if Self.pyYAMLAvailable {
            let script = """
            import sys,yaml
            print(repr(yaml.safe_load(sys.stdin.read())['slack']['allowed_channels']))
            """
            let parsed = PythonYAML.run(script: script, stdin: out)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Every item must come back EXACTLY as it went in — quoting that
            // parses but changes the value is just a quieter bug.
            for item in hostile where !item.hasSuffix(" ") && !item.hasPrefix(" ") {
                #expect(
                    parsed?.contains(item.replacingOccurrences(of: "\t", with: "\\t")) == true
                        || parsed?.contains(item) == true,
                    "round-trip lost \(item) — got \(parsed ?? "nil")"
                )
            }
        }
    }

    /// An item carrying a literal line break cannot be one YAML row. The
    /// writer refuses the whole save rather than emitting a broken document.
    @Test func itemWithEmbeddedNewlineIsRefused() {
        let yaml = "slack:\n  reply_to_mode: first\n"
        for hostile in ["C1\nC2", "C1\rC2", "C1\r\nC2"] {
            let outcome = GatewayConfigWriter.setListChecked(
                in: yaml, platform: "slack", key: "allowed_channels", items: [hostile]
            )
            guard case .refused = outcome else {
                Issue.record("expected refusal for \(hostile.debugDescription), got \(outcome)")
                continue
            }
        }
        // …and the file is untouched.
        #expect(GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1\nC2"]
        ) == yaml)
    }

    /// `setMap` shares the guard (the reasoning-overrides editor writes
    /// user-typed model patterns).
    @Test func mapPairWithEmbeddedNewlineIsRefused() {
        let yaml = "agent:\n  verbose: false\n"
        let outcome = GatewayConfigWriter.setMapChecked(
            in: yaml, section: "agent", key: "reasoning_overrides",
            pairs: [(key: "gpt\n5", value: "high")]
        )
        guard case .refused = outcome else {
            Issue.record("expected refusal, got \(outcome)")
            return
        }
    }

    /// Map keys and values go through the same hardened quoter.
    @Test func mapEntriesWithIndicatorsParseUnderPyYAML() {
        let out = GatewayConfigWriter.setMap(
            in: "agent:\n  verbose: false\n",
            section: "agent", key: "reasoning_overrides",
            pairs: [(key: "llama3:8b", value: "high"), (key: "*star", value: "low")]
        )
        expectParses(out, "reasoning overrides with indicator-bearing keys")
    }

    // MARK: - 4. CRLF files survive byte-for-byte outside the edited key

    @Test func crlfFileKeepsItsLineEndingsAndItsSiblings() {
        let yaml = "slack:\r\n  reply_to_mode: first\r\n  busy_ack_enabled: true\r\n"
        let out = GatewayConfigWriter.setList(
            in: yaml, platform: "slack", key: "allowed_channels", items: ["C1"]
        )
        #expect(!out.contains("\n\n"), "a bare LF leaked into a CRLF file")
        #expect(out.components(separatedBy: "\n").filter { $0.hasPrefix("slack:") }.count == 1)
        #expect(out.contains("reply_to_mode: first"))
        expectParses(out, "a CRLF config.yaml after an edit")
        if Self.pyYAMLAvailable {
            #expect(PythonYAML.value(out, "slack", "reply_to_mode") == "'first'")
            #expect(PythonYAML.value(out, "slack", "allowed_channels") == "['C1']")
        }
    }

    // MARK: - 6. HermesYAML reads a CRLF config.yaml

    /// `.whitespaces` does not contain `\r`, so `slack:\r` failed the
    /// `key: value` separator scan and EVERY section header in a CRLF file
    /// was dropped, taking its whole subtree with it.
    @Test func hermesYAMLParsesCRLFSectionsAndSubtrees() {
        let yaml = "slack:\r\n  reply_to_mode: first\r\n  allowed_channels:\r\n    - C1\r\n    - C2\r\n"
        let parsed = HermesYAML.parseNestedYAML(yaml)
        #expect(parsed.values["slack.reply_to_mode"] == "first")
        #expect(parsed.lists["slack.allowed_channels"] == ["C1", "C2"])
        #expect(parsed.maps["slack"]?["reply_to_mode"] == "first")
    }

    // MARK: - 7. Block-scalar headers open a block, not a mapping

    /// `|-`, `|+`, `>-`, `|2` are all block-SCALAR headers. Only bare `|`
    /// and `>` were recognised, so the body of a `|-` scalar was parsed as a
    /// nested mapping and its `key: value`-looking lines became phantom
    /// config keys.
    /// **P57b turned this from a spelling into a rule.** It used to assert
    /// `values["agent.system_prompt"] == nil`, which pinned the old
    /// behaviour (the header opened a stack frame and the body was parsed as
    /// YAML) rather than the invariant it was written for: the header must
    /// never come back as the folded garbage `"|- role: assistant tone: dry"`,
    /// and the sibling key must survive. Both still hold — and the value is
    /// now the BODY, which is what PyYAML loads. Every expectation below is
    /// `yaml.safe_load(doc)["agent"]["system_prompt"]` printed by 6.0.3.
    @Test func chompedAndIndentedBlockScalarHeadersCarryTheirBody() {
        let expected: [String: String] = [
            "|-":        "role: assistant\ntone: dry",
            "|+":        "role: assistant\ntone: dry\n",
            ">-":        "role: assistant tone: dry",
            ">+":        "role: assistant tone: dry\n",
            "|2":        "role: assistant\ntone: dry\n",
            "|2-":       "role: assistant\ntone: dry",
            "|  # note": "role: assistant\ntone: dry\n",
        ]
        for (header, body) in expected {
            let yaml = """
            agent:
              system_prompt: \(header)
                role: assistant
                tone: dry
              verbose: false
            """
            let parsed = HermesYAML.parseNestedYAML(yaml)
            #expect(parsed.values["agent.system_prompt"] == body,
                    "\(header): got \(parsed.values["agent.system_prompt"] ?? "nil")")
            // Never the folded garbage the pre-P19 reader produced.
            #expect(parsed.values["agent.system_prompt"]?.hasPrefix("|") != true)
            #expect(parsed.values["agent.system_prompt"]?.hasPrefix(">") != true)
            // The body is not parsed as YAML: no phantom child keys.
            #expect(parsed.values["agent.system_prompt.role"] == nil, "\(header): phantom child key")
            #expect(parsed.values["agent.verbose"] == "false", "\(header): lost the sibling key")
        }
    }

    /// A plain scalar that merely starts with `|`/`>` is still a scalar.
    @Test func plainScalarStartingWithABarIsNotABlockHeader() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  note: '|piped value'\n")
        #expect(parsed.values["agent.note"] == "'|piped value'")
    }

    // MARK: - Emitted text is stable

    /// Re-running an identical write is a byte-for-byte no-op on every shape
    /// above — a writer that churns the file on every save is a writer that
    /// eventually churns it wrong.
    @Test func writesAreIdempotent() {
        let inputs = [
            "slack:\n    reply_to_mode: first\n",
            "slack: {reply_to_mode: first}\n",
            "slack: {}\n",
            "slack:\r\n  reply_to_mode: first\r\n",
        ]
        for input in inputs {
            let once = GatewayConfigWriter.setList(
                in: input, platform: "slack", key: "allowed_channels", items: ["C1"]
            )
            let twice = GatewayConfigWriter.setList(
                in: once, platform: "slack", key: "allowed_channels", items: ["C1"]
            )
            #expect(once == twice, "not idempotent for \(input.debugDescription)")
            #expect(
                GatewayConfigWriter.setListChecked(
                    in: once, platform: "slack", key: "allowed_channels", items: ["C1"]
                ) == .unchanged
            )
        }
    }
}
