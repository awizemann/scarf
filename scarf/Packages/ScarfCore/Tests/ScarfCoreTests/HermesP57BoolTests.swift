import Foundation
import Testing
@testable import ScarfCore

@Suite("P57 — boolish scalars are stripped inside their quotes")
struct HermesP57BoolishTests {

    /// `(raw scalar as written, what `_bool_token` answers)`.
    /// `_bool_token(value) = str(value).strip().lower()` then membership in
    /// `_TRUTHY_STRINGS` / `_FALSY_STRINGS` (`gateway/config.py:25-32` @
    /// `v2026.9.7`), over the object PyYAML loaded. Every row was produced by
    /// the P57 oracle running the real 6.0.3 loader.
    struct BoolCase { let raw: String; let token: Bool? }

    static let cases: [BoolCase] = [
        // The quoted-body trim. The body is a Python `str`; `.strip()` runs
        // on it, so the padding never reaches the word compare.
        BoolCase(raw: "' false'",  token: false),
        BoolCase(raw: "\" false\"", token: false),
        BoolCase(raw: "'false '",  token: false),
        BoolCase(raw: "'\tyes\t'", token: true),
        BoolCase(raw: "' 1'",      token: true),
        BoolCase(raw: "'  on  '",  token: true),
        BoolCase(raw: "\" OFF \"", token: false),
        // PyYAML's int resolver, then `str(int)`.
        BoolCase(raw: "01",   token: true),   // octal 1 -> "1"
        BoolCase(raw: "00",   token: false),  // octal 0 -> "0"
        BoolCase(raw: "+1",   token: true),   // str(1) drops the `+`
        BoolCase(raw: "-0",   token: false),  // str(0)
        BoolCase(raw: "0x1",  token: true),
        BoolCase(raw: "0b1",  token: true),
        BoolCase(raw: "0x0",  token: false),
        BoolCase(raw: "0b0",  token: false),
        BoolCase(raw: "0_1",  token: true),
        // Near-misses the resolver does NOT claim, or claims at a value whose
        // `str()` is in neither set.
        BoolCase(raw: "0o0",  token: nil),    // no `0o` alternative: a string
        BoolCase(raw: "0X0",  token: nil),    // the pattern is lower-case only
        BoolCase(raw: "0B1",  token: nil),
        BoolCase(raw: "08",   token: nil),    // not octal, not decimal: a string
        BoolCase(raw: "2",    token: nil),    // str(2) == "2"
        BoolCase(raw: "-1",   token: nil),    // str(-1) == "-1"
        BoolCase(raw: "16",   token: nil),
        // A QUOTED int spelling is a `str` and no resolver touches it.
        BoolCase(raw: "'01'",  token: nil),
        BoolCase(raw: "'0x0'", token: nil),
        BoolCase(raw: "'00'",  token: nil),
        // Quoted bool WORDS still work: `str.lower()` is applied to the text.
        BoolCase(raw: "'True'", token: true),
        BoolCase(raw: "\"nO\"", token: false),
        BoolCase(raw: "yEs",    token: true),  // a plain string, lowered
        // Unchanged baseline.
        BoolCase(raw: "true",  token: true),
        BoolCase(raw: "off",   token: false),
        BoolCase(raw: "maybe", token: nil),
        BoolCase(raw: "''",    token: nil),
    ]

    /// Fails at every padded and every integer row without the fix.
    @Test(arguments: cases)
    func boolishValueMirrorsBoolToken(c: BoolCase) {
        #expect(HermesYAML.boolishValue(c.raw) == c.token, "raw \(c.raw.debugDescription)")
    }

    /// The same rows read through a TRUE-by-default key: only an explicit
    /// falsy scalar turns it off, so every `false` row above must land OFF.
    /// Before the fix `" false"` and `0x0` read as ON — the unsafe direction.
    @Test(arguments: cases)
    func boolTrueDefaultMirrorsBoolToken(c: BoolCase) {
        let cfg = HermesConfig(yaml: "display:\n  inline_diffs: \(c.raw)\n")
        #expect(cfg.display.inlineDiffs == (c.token != false), "raw \(c.raw.debugDescription)")
    }

    /// The oracle's own probe: PyYAML really does answer this way. Reads the
    /// token back out of the live interpreter for the rows above.
    @Test(arguments: cases)
    func theRealPyYAMLAgreesWithTheTable(c: BoolCase) throws {
        guard let answer = P57PyYAML.boolToken(scalar: c.raw) else { return }
        if answer == "__NO_PYYAML__" { return }
        let want = c.token.map { $0 ? "true" : "false" } ?? "none"
        #expect(answer == want, "raw \(c.raw.debugDescription)")
    }

    @Test func theRealPyYAMLLaneIsPresent() {
        let answer = P57PyYAML.boolToken(scalar: "yes")
        withKnownIssue("PyYAML unavailable on this host", isIntermittent: true) {
            #expect(answer == "true")
        }
    }

    /// `strippedScalar` strips INSIDE the quotes; `normalizedScalar` does not.
    /// The two must keep disagreeing — round-5 decision 14's invariant, from
    /// the other side.
    @Test func strippedScalarAndNormalizedScalarDisagreeInsideQuotes() {
        #expect(HermesYAML.normalizedScalar("' false'") == " false")
        #expect(HermesYAML.strippedScalar("' false'") == "false")
        // Outside the quotes they agree — that trim was already there.
        #expect(HermesYAML.normalizedScalar("  false  ") == "false")
        #expect(HermesYAML.strippedScalar("  false  ") == "false")
    }

    /// `display.busy_ack_enabled` keeps its NARROWER vocabulary: `1` must not
    /// read as ON, because the comparison downstream is against the literal
    /// `"true"`.
    ///
    /// **P57b corrected this test's first row.** P57 gave the key
    /// `strippedScalar` and asserted quoted `' true'` reads as ON. It does
    /// not: nothing on this key's path strips —
    /// `_bridge_section_to_env` exports `str(section[key])` verbatim
    /// (`gateway/run.py:1816-1821` @ `v2026.9.7`) and `run_busy.py:727`
    /// compares that to `"true"` — so the host has the ack OFF. The full
    /// argument and its 918-row oracle corpus are in
    /// ``HermesP57bBusyAckCorpusTests``.
    @Test func busyAckKeepsItsOwnVocabularyAndTakesNoTrim() {
        #expect(HermesConfig(yaml: "display:\n  busy_ack_enabled: ' true'\n").displayBusyAckEnabled == false)
        #expect(HermesConfig(yaml: "display:\n  busy_ack_enabled: 'true'\n").displayBusyAckEnabled == true)
        #expect(HermesConfig(yaml: "display:\n  busy_ack_enabled: '  no  '\n").displayBusyAckEnabled == false)
        // Still NOT boolish: an int `1` is `str(1)` == "1", not "true".
        #expect(HermesConfig(yaml: "display:\n  busy_ack_enabled: 1\n").displayBusyAckEnabled == false)
        #expect(HermesConfig(yaml: "display:\n  busy_ack_enabled: 01\n").displayBusyAckEnabled == false)
    }
}
