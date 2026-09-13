import Foundation
import Testing
@testable import ScarfCore

// Round-6 P57, finding 1 of 3 — the folded-scalar continuation holes.
// Its siblings are `HermesP57BoolTests.swift` (the boolish trim that ran
// outside the quotes) and `HermesP57DottedKeyTests.swift` (a flat dotted key
// read as a platform block); both use the `P57PyYAML` interpreter below.
//
// Every YAML fixture in this file is VERBATIM `yaml.dump` output captured from
// PyYAML 6.0.3 with Hermes's own options — `atomic_yaml_write`'s
// `yaml.dump(data, Dumper=IndentDumper, default_flow_style=False,
// sort_keys=False, allow_unicode=True)` (`utils.py:262-271` @ `v2026.9.7`),
// i.e. NO `width=`, so the emitter folds at its default 80 columns.
// `theFoldedFixturesAreVerbatimEmitterOutput` re-runs that emitter and pins
// the bytes, so a hand-edited fixture cannot drift into this file.

@Suite("P57 — folded scalar continuations")
struct HermesP57FoldedContinuationTests {

    /// `(what PyYAML folded, the object it reads back)` — the oracle's answer.
    struct Fold {
        let name: String
        /// The JSON object handed to `yaml.dump`.
        let json: String
        /// Its `yaml.dump` output, verbatim.
        let yaml: String
        /// `parseNestedYAML().values` paths → the scalar PyYAML loads.
        let expected: [String: String]
    }

    static let folds: [Fold] = [
        // A PLAIN scalar whose fold point lands before a `- ` token: the
        // continuation line opens exactly like a block-sequence item.
        Fold(
            name: "plain fold onto a `- ` line",
            json: #"{"note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron - trailing guard here", "sibling": "keepme"}"#,
            yaml: """
            note: alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron
              - trailing guard here
            sibling: keepme

            """,
            expected: [
                "note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron - trailing guard here",
                "sibling": "keepme",
            ]
        ),
        // Three `- ` tokens on the continuation: the old reader produced a
        // phantom list entry, so this also pins that `lists` stays empty.
        Fold(
            name: "plain fold onto a line of several `- ` tokens",
            json: #"{"note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron - one - two - three", "sibling": "keepme"}"#,
            yaml: """
            note: alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron
              - one - two - three
            sibling: keepme

            """,
            expected: [
                "note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron - one - two - three",
                "sibling": "keepme",
            ]
        ),
        // A `#` in the string forces SINGLE quoting, and the fold then leaves
        // a continuation that opens with `#` while the quote is still open.
        Fold(
            name: "single-quoted fold onto a `# ` line",
            json: #"{"note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron # hashed tail here", "sibling": "keepme"}"#,
            yaml: """
            note: 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron
              # hashed tail here'
            sibling: keepme

            """,
            expected: [
                "note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron # hashed tail here",
                "sibling": "keepme",
            ]
        ),
        Fold(
            name: "single-quoted fold onto a `#`-no-space line",
            json: #"{"note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron #hashed tail here", "sibling": "keepme"}"#,
            yaml: """
            note: 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron
              #hashed tail here'
            sibling: keepme

            """,
            expected: [
                "note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron #hashed tail here",
                "sibling": "keepme",
            ]
        ),
        // Both hazards, and the continuation OPENS with them.
        Fold(
            name: "single-quoted fold onto a `# - ` line",
            json: #"{"note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron # - both hazards here", "sibling": "keepme"}"#,
            yaml: """
            note: 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron
              # - both hazards here'
            sibling: keepme

            """,
            expected: [
                "note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron # - both hazards here",
                "sibling": "keepme",
            ]
        ),
        // The same shape three levels deep, where the continuation indent is 8.
        Fold(
            name: "single-quoted fold onto a `# ` line, nested three deep",
            json: #"{"gateway": {"platforms": {"slack": {"note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu # hashed tail here", "sibling": "keepme"}}}}"#,
            yaml: """
            gateway:
              platforms:
                slack:
                  note: 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu
                    # hashed tail here'
                  sibling: keepme

            """,
            expected: [
                "gateway.platforms.slack.note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu # hashed tail here",
                "gateway.platforms.slack.sibling": "keepme",
            ]
        ),
        // The embedded `''` escape survives the fold — the closing quote is on
        // the continuation line, so the scalar is "open" across the break.
        Fold(
            name: "single-quoted fold whose continuation carries `''` and a `#`",
            json: #"{"note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu it's a #hashed tail", "sibling": "keepme"}"#,
            yaml: """
            note: 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu it''s a
              #hashed tail'
            sibling: keepme

            """,
            expected: [
                "note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu it's a #hashed tail",
                "sibling": "keepme",
            ]
        ),
        // A `- ` continuation carrying `key: value` decoy text, one level in.
        Fold(
            name: "fold onto a `- url: …` decoy line",
            json: #"{"note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron - url: http://decoy", "sibling": "keepme"}"#,
            yaml: """
            note: 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron
              - url: http://decoy'
            sibling: keepme

            """,
            expected: [
                "note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron - url: http://decoy",
                "sibling": "keepme",
            ]
        ),
        // A PLAIN scalar folded onto a `- ` line at depth 3.
        Fold(
            name: "plain fold onto a `- ` line, nested three deep",
            json: #"{"gateway": {"platforms": {"slack": {"note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu - trailing guard here", "sibling": "keepme"}}}}"#,
            yaml: """
            gateway:
              platforms:
                slack:
                  note: alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu
                    - trailing guard here
                  sibling: keepme

            """,
            expected: [
                "gateway.platforms.slack.note": "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu - trailing guard here",
                "gateway.platforms.slack.sibling": "keepme",
            ]
        ),
    ]

    /// The drift alarm. Each fixture FAILS with the continuation test below
    /// the comment skip / the `!isListItem` gate: `- ` truncated the value and
    /// planted a phantom `lists[…]` entry, `#` dropped the line and left the
    /// single-quoted scalar with a dangling opening `'`.
    @Test(arguments: folds)
    func aFoldedScalarSurvivesEveryContinuationLineShape(fold: Fold) throws {
        let parsed = HermesYAML.parseNestedYAML(fold.yaml)
        for (path, want) in fold.expected {
            let got = try #require(parsed.values[path], "\(fold.name): no value at \(path)")
            #expect(HermesYAML.normalizedScalar(got) == want, "\(fold.name) at \(path)")
        }
        #expect(parsed.lists.isEmpty, "\(fold.name): a continuation must never create a list")
    }

    /// The fixtures above are `yaml.dump` output, not typed by hand. Re-emits
    /// each one through the real interpreter with Hermes's exact options and
    /// pins the bytes. Skips (loudly, via the companion lane below) when
    /// PyYAML is unavailable.
    @Test(arguments: folds)
    func theFoldedFixturesAreVerbatimEmitterOutput(fold: Fold) throws {
        guard let emitted = P57PyYAML.hermesDump(json: fold.json) else { return }
        if emitted == "__NO_PYYAML__" { return }
        #expect(emitted == fold.yaml, "\(fold.name): fixture is not verbatim `yaml.dump` output")
    }

    /// Guards the two lanes above against passing vacuously: reports an ABSENT
    /// interpreter rather than letting the skip look like a pass.
    @Test func theRealPyYAMLLaneIsPresent() {
        let emitted = P57PyYAML.hermesDump(json: #"{"k": "v"}"#)
        withKnownIssue("PyYAML unavailable on this host", isIntermittent: true) {
            #expect(emitted == "k: v\n")
        }
    }

    /// The claim the `#` arm's narrowing rests on, RE-MEASURED rather than
    /// asserted: over a sweep of strings that carry a `#` and fold, PyYAML
    /// never emits a PLAIN scalar whose continuation line begins with `#` —
    /// a `#` after a space forces a quoting style. So a deeper `#` line
    /// outside an open quote really can only be a comment. Fails if a future
    /// PyYAML learns to fold a plain scalar that way.
    @Test func theEmitterNeverFoldsAPlainScalarOntoAHashLine() throws {
        guard let report = P57PyYAML.plainHashFoldSweep(), report != "__NO_PYYAML__" else { return }
        // "<documents that folded>,<of those, plain scalars folded onto `#`>"
        let parts = report.split(separator: ",").map(String.init)
        try #require(parts.count == 2, "sweep reported \(report)")
        let folded = try #require(Int(parts[0]))
        let plainHash = try #require(Int(parts[1]))
        #expect(folded >= 20, "the sweep must actually fold something; it folded \(folded)")
        #expect(plainHash == 0, "\(plainHash) plain scalars folded onto a `#` line")
    }

    /// The `#` arm's clamp. A deeper `#` line that does NOT sit inside an open
    /// quoted scalar is a genuine indented comment, which PyYAML discards —
    /// `{'gateway': {'port': 8080, 'host': 'local'}}` — and so must Scarf.
    /// Without the "open quote" narrowing, the comment is joined onto `port`.
    @Test func anIndentedCommentAfterAPlainScalarIsStillAComment() {
        let parsed = HermesYAML.parseNestedYAML("""
        gateway:
          port: 8080
              # an indented comment
          host: local
        """)
        #expect(parsed.values["gateway.port"] == "8080")
        #expect(parsed.values["gateway.host"] == "local")
    }

    /// The same clamp after a CLOSED quoted scalar.
    @Test func anIndentedCommentAfterAClosedQuotedScalarIsStillAComment() {
        let parsed = HermesYAML.parseNestedYAML("""
        note: 'hello'
            # an indented comment
        sibling: keepme
        """)
        #expect(HermesYAML.normalizedScalar(parsed.values["note"] ?? "") == "hello")
        #expect(parsed.values["sibling"] == "keepme")
    }

    @Test func isOpenQuotedScalarSeparatesTheTwoCases() {
        #expect(HermesYAML.isOpenQuotedScalar("'abc") == true)
        #expect(HermesYAML.isOpenQuotedScalar("\"abc") == true)
        #expect(HermesYAML.isOpenQuotedScalar("'abc'") == false)
        #expect(HermesYAML.isOpenQuotedScalar("'it''s") == true)
        #expect(HermesYAML.isOpenQuotedScalar("'it''s'") == false)
        #expect(HermesYAML.isOpenQuotedScalar("plain text") == false)
        #expect(HermesYAML.isOpenQuotedScalar("") == false)
    }
}

// MARK: - The interpreter

/// P57's slice of the PyYAML oracle: Hermes's own emitter options, its
/// `_bool_token`, and a plain load. Returns `"__NO_PYYAML__"` when the module
/// is missing so a lane can report absence rather than pass vacuously, and
/// `nil` only when python3 itself cannot be launched.
enum P57PyYAML {

    /// `utils.atomic_yaml_write`'s exact call (`utils.py:262-271` @
    /// `v2026.9.7`) — note there is no `width=`, which is the whole reason
    /// folded continuations exist.
    static func hermesDump(json: String) -> String? {
        run(script: """
        import sys, json
        try:
            import yaml
        except Exception:
            sys.stdout.write("__NO_PYYAML__"); sys.exit(0)
        class IndentDumper(yaml.Dumper):
            def increase_indent(self, flow=False, indentless=False):
                return super().increase_indent(flow, False)
        obj = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        sys.stdout.write(yaml.dump(obj, Dumper=IndentDumper, default_flow_style=False,
                                   sort_keys=False, allow_unicode=True))
        """, stdin: json)
    }

    /// `(documents that folded, of those the ones where a PLAIN scalar's
    /// continuation line begins with `#`)` over a sweep of `#`-carrying
    /// strings at every length that folds.
    static func plainHashFoldSweep() -> String? {
        run(script: """
        import sys
        try:
            import yaml
        except Exception:
            sys.stdout.write("__NO_PYYAML__"); sys.exit(0)
        class IndentDumper(yaml.Dumper):
            def increase_indent(self, flow=False, indentless=False):
                return super().increase_indent(flow, False)
        folded = 0
        plain_hash = 0
        for tail in ("# spaced tail here", "#tight tail here", "# - both hazards"):
            for n in range(2, 60):
                s = " ".join("word%d" % i for i in range(n)) + " " + tail
                d = yaml.dump({"k": s}, Dumper=IndentDumper, default_flow_style=False,
                              sort_keys=False, allow_unicode=True)
                lines = d.split("\\n")
                conts = [l for l in lines[1:] if l.startswith("  ")]
                if not conts:
                    continue
                folded += 1
                is_plain = not (d.startswith("k: '") or d.startswith('k: "'))
                if is_plain and any(l.strip().startswith("#") for l in conts):
                    plain_hash += 1
        sys.stdout.write("%d,%d" % (folded, plain_hash))
        """, stdin: "")
    }

    /// `_bool_token(value)` (`gateway/config.py:29-32` @ `v2026.9.7`) over the
    /// object PyYAML loads for `k: <scalar>`. `"true"` / `"false"` / `"none"`.
    static func boolToken(scalar: String) -> String? {
        run(script: """
        import sys
        try:
            import yaml
        except Exception:
            sys.stdout.write("__NO_PYYAML__"); sys.exit(0)
        TRUTHY = {"1", "true", "yes", "on"}
        FALSY = {"0", "false", "no", "off"}
        raw = sys.stdin.buffer.read().decode("utf-8")
        try:
            v = yaml.safe_load("k: " + raw + "\\n")["k"]
        except Exception as exc:
            sys.stdout.write("ERROR: %s" % exc); sys.exit(0)
        t = str(v).strip().lower()
        sys.stdout.write("true" if t in TRUTHY else "false" if t in FALSY else "none")
        """, stdin: scalar)
    }

    /// The OUTERMOST mapping's keys, sorted and comma-joined — what
    /// `yaml_cfg.get(name)` in `platform_section` can possibly find.
    static func topLevelKeys(_ text: String) -> String? {
        run(script: """
        import sys
        try:
            import yaml
        except Exception:
            sys.stdout.write("__NO_PYYAML__"); sys.exit(0)
        raw = sys.stdin.buffer.read().decode("utf-8")
        try:
            sys.stdout.write(",".join(sorted(str(k) for k in yaml.safe_load(raw).keys())))
        except Exception as exc:
            sys.stdout.write("ERROR: %s" % exc)
        """, stdin: text)
    }

    private static func run(script: String, stdin input: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
