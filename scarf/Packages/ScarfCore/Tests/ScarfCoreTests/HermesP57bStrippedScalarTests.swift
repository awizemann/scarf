import Foundation
import Testing
@testable import ScarfCore

/// P57b finding 3: ``HermesYAML/strippedScalar(_:)`` handed a DOUBLE-quoted
/// body back verbatim, so a backslash escape reached the word compare as its
/// literal characters.
///
/// This is not a hypothetical spelling. `yaml.dump({"k": "false\t"})` on
/// PyYAML 6.0.3 emits `k: "false\t"` — the emitter picks double quotes
/// precisely because the value carries a character it must escape — and
/// `_bool_token` then sees `str("false\t").strip().lower()` == `false`, i.e.
/// the key is OFF on the host. Pre-fix Scarf read the eight characters
/// `f a l s e \ t`, matched neither token set, and a true-by-default reader
/// drew the key ON.
@Suite("P57b — a double-quoted body is escape-decoded before it is stripped")
struct HermesP57bStrippedScalarTests {

    /// Every `written` column is the literal text after `k: ` in a document
    /// **emitted by PyYAML 6.0.3's own `yaml.dump`** for the value in the
    /// comment; `token` is what `_bool_token` (`gateway/config.py:29-32` @
    /// `v2026.9.7`) answers for it, printed by the same interpreter.
    struct Row: Sendable { let written: String; let token: Bool?; let why: String
        init(_ w: String, _ t: Bool?, _ why: String) { written = w; token = t; self.why = why } }

    static let dumped: [Row] = [
        Row("\"true\\t\"",  true,  #"yaml.dump({"k": "true\t"})  -> k: "true\t""#),
        Row("\"false\\t\"", false, #"yaml.dump({"k": "false\t"}) -> k: "false\t""#),
        Row("\"\\ttrue\"",  true,  #"yaml.dump({"k": "\ttrue"})  -> k: "\ttrue""#),
        Row("\"on\\r\"",    true,  #"yaml.dump({"k": "on\r"})    -> k: "on\r""#),
        Row("\"\\nno\\n\"", false, #"a \n on both sides of a falsy word"#),
        Row("\"\\tyes\\t\"", true, #"tabs both sides"#),
        Row("\" false\"",   false, #"yaml.dump({"k": " false"})  -> k: ' false' (the P57 case, still right)"#),
        Row("\"\\x09off\"", false, #"\xNN is the same tab by another spelling"#),
        Row("\"\\u0009on\"", true, #"\uNNNN likewise"#),
        Row("\"\\x0100\"",  nil,   #"\x01 is not whitespace: the body stays "\u{1}00" and matches nothing"#),
    ]

    @Test(arguments: dumped)
    func boolishValueMatchesTheOracle(_ row: Row) {
        #expect(HermesYAML.boolishValue(row.written) == row.token, "\(row.written) — \(row.why)")
    }

    /// The discriminator: the SAME seven characters written BARE are a plain
    /// scalar, PyYAML never decodes them, and the value really is the string
    /// `false\t` — `yaml.safe_load("k: false\\t")` prints `'false\\t'`, whose
    /// token is neither truthy nor falsy. Decoding outside double quotes
    /// would be its own bug, so the fix is pinned from both sides.
    @Test func escapesAreDecodedOnlyInsideDoubleQuotes() {
        #expect(HermesYAML.boolishValue(#"false\t"#) == nil)
        #expect(HermesYAML.strippedScalar(#"false\t"#) == #"false\t"#)
        // Single-quoted YAML has no backslash escape either.
        #expect(HermesYAML.boolishValue(#"'false\t'"#) == nil)
        #expect(HermesYAML.strippedScalar(#"'false\t'"#) == #"false\t"#)
        // Double-quoted: decoded, then stripped.
        #expect(HermesYAML.strippedScalar("\"false\\t\"") == "false")
        #expect(HermesYAML.boolishValue("\"false\\t\"") == false)
    }

    /// ``HermesYAML/normalizedScalar(_:)`` is the RE-EMIT path and must stay
    /// verbatim: decoding there would rewrite the file on the next save.
    /// The two functions are deliberately different, and that difference is
    /// the whole reason ``HermesYAML/unquotedScalar(_:)`` exists.
    @Test func normalizedScalarStillHandsTheBodyBackVerbatim() {
        #expect(HermesYAML.normalizedScalar("\"false\\t\"") == #"false\t"#)
        #expect(HermesYAML.unquotedScalar("\"false\\t\"") == "false\t")
        #expect(HermesYAML.strippedScalar("\"false\\t\"") == "false")
        // Single quotes: the two agree, `''` undoubling included.
        #expect(HermesYAML.normalizedScalar("'it''s'") == "it's")
        #expect(HermesYAML.unquotedScalar("'it''s'") == "it's")
        // A trailing comment after the closing quote is still discarded, and
        // the body is still decoded — `unquote` alone could not do this,
        // because the raw text does not END in a quote.
        #expect(HermesYAML.unquotedScalar("\"true\\t\"  # was on") == "true\t")
        #expect(HermesYAML.boolishValue("\"true\\t\"  # was on") == true)
    }

    /// An escape Scarf's decoder does not recognise, and a malformed hex
    /// body, are passed through rather than half-decoded — the same contract
    /// ``YAMLScalar/unquote(_:)`` already documents, now reachable from the
    /// typed-read path.
    ///
    /// There is no oracle row for these two: PyYAML 6.0.3 REJECTS both
    /// documents outright (`found unknown escape character 'q'`, `expected
    /// escape sequence of 2 hexadecimal numbers`), so Hermes never loads such
    /// a config at all. Pass-through is the answer that invents nothing.
    @Test func unknownEscapesArePassedThrough() {
        #expect(HermesYAML.unquotedScalar(#""a\qb""#) == #"a\qb"#)
        #expect(HermesYAML.unquotedScalar(#""a\x+9b""#) == #"a\x+9b"#)
    }
}
