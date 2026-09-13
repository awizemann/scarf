import Foundation
import Testing
@testable import ScarfCore

/// P60 finding 1 (the P57b class): a `+`-chomped block scalar that is the
/// LAST thing in the document grew one spurious trailing newline.
///
/// `HermesYAML.parseNestedYAML` split the document with
/// `components(separatedBy: "\n")`, which yields a PHANTOM final `""` for any
/// text ending in its terminating newline. Outside a block scalar that
/// element is skipped as blank; inside one it was appended as a body line, so
/// the KEEP arm counted it as a trailing blank:
/// `agent:\n  system_prompt: |+\n    a\n` rendered `"a\n\n"` where PyYAML 6.0.3
/// says `"a\n"`. Every `|+` / `>+` / `|2+` document that ENDS with its scalar
/// was wrong — 36 of them — and the P57b corpus could not see it because
/// every one of its 96 documents carries a `note: end` sibling after the
/// block, which closes the block before the phantom line is reached.
///
/// This is the shape a real `~/.hermes/config.yaml` has: the prompt is
/// usually the last key in the file.
///
/// The corpus below is **10 headers** (`|`, `|-`, `|+`, `>`, `>-`, `>+`,
/// `|2`, `|2-`, `|2+`, `>2`) × the 16 P57b bodies = **160 documents**, every
/// one of them newline-terminated — the shape a file on disk has, and the
/// only shape in which the phantom line exists — each `expected` printed by
/// `yaml.safe_load(doc)["agent"]["prompt"]` under PyYAML 6.0.3.
@Suite("P60 — a block scalar at the end of the document")
struct HermesP60TerminalBlockScalarTests {

    struct B: Sendable { let doc: String; let expected: String
        init(_ d: String, _ e: String) { doc = d; expected = e } }

    static let corpus: [B] = [
        B("agent:\n  prompt: |\n    hello\n", "hello\n"),
        B("agent:\n  prompt: |\n    - a\n    # b\n", "- a\n# b\n"),
        B("agent:\n  prompt: |\n    line one\n    line two\n", "line one\nline two\n"),
        B("agent:\n  prompt: |\n    line one\n    \n    line two\n", "line one\n\nline two\n"),
        B("agent:\n  prompt: |\n    a\n      more\n    b\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: |\n    a\n    \n    \n    b\n", "a\n\n\nb\n"),
        B("agent:\n  prompt: |\n    x\n    \n    \n", "x\n"),
        B("agent:\n  prompt: |\n    #####################\n    from now on\n", "#####################\nfrom now on\n"),
        B("agent:\n  prompt: |\n    key: value\n    other: 2\n", "key: value\nother: 2\n"),
        B("agent:\n  prompt: |\n    \n    start\n", "\nstart\n"),
        B("agent:\n  prompt: |\n    a\n      b\n      c\n    d\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: |\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n", "Format responses like this: Your Response.\ninsert divider: .-.-.-\n"),
        B("agent:\n  prompt: |\n    - one\n    - two\n", "- one\n- two\n"),
        B("agent:\n  prompt: |\n      indented first\n", "indented first\n"),
        B("agent:\n  prompt: |\n    tab\there\n", "tab\there\n"),
        B("agent:\n  prompt: |\n    trailing spaces   \n    next\n", "trailing spaces   \nnext\n"),
        B("agent:\n  prompt: |-\n    hello\n", "hello"),
        B("agent:\n  prompt: |-\n    - a\n    # b\n", "- a\n# b"),
        B("agent:\n  prompt: |-\n    line one\n    line two\n", "line one\nline two"),
        B("agent:\n  prompt: |-\n    line one\n    \n    line two\n", "line one\n\nline two"),
        B("agent:\n  prompt: |-\n    a\n      more\n    b\n", "a\n  more\nb"),
        B("agent:\n  prompt: |-\n    a\n    \n    \n    b\n", "a\n\n\nb"),
        B("agent:\n  prompt: |-\n    x\n    \n    \n", "x"),
        B("agent:\n  prompt: |-\n    #####################\n    from now on\n", "#####################\nfrom now on"),
        B("agent:\n  prompt: |-\n    key: value\n    other: 2\n", "key: value\nother: 2"),
        B("agent:\n  prompt: |-\n    \n    start\n", "\nstart"),
        B("agent:\n  prompt: |-\n    a\n      b\n      c\n    d\n", "a\n  b\n  c\nd"),
        B("agent:\n  prompt: |-\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n", "Format responses like this: Your Response.\ninsert divider: .-.-.-"),
        B("agent:\n  prompt: |-\n    - one\n    - two\n", "- one\n- two"),
        B("agent:\n  prompt: |-\n      indented first\n", "indented first"),
        B("agent:\n  prompt: |-\n    tab\there\n", "tab\there"),
        B("agent:\n  prompt: |-\n    trailing spaces   \n    next\n", "trailing spaces   \nnext"),
        B("agent:\n  prompt: |+\n    hello\n", "hello\n"),
        B("agent:\n  prompt: |+\n    - a\n    # b\n", "- a\n# b\n"),
        B("agent:\n  prompt: |+\n    line one\n    line two\n", "line one\nline two\n"),
        B("agent:\n  prompt: |+\n    line one\n    \n    line two\n", "line one\n\nline two\n"),
        B("agent:\n  prompt: |+\n    a\n      more\n    b\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: |+\n    a\n    \n    \n    b\n", "a\n\n\nb\n"),
        B("agent:\n  prompt: |+\n    x\n    \n    \n", "x\n\n\n"),
        B("agent:\n  prompt: |+\n    #####################\n    from now on\n", "#####################\nfrom now on\n"),
        B("agent:\n  prompt: |+\n    key: value\n    other: 2\n", "key: value\nother: 2\n"),
        B("agent:\n  prompt: |+\n    \n    start\n", "\nstart\n"),
        B("agent:\n  prompt: |+\n    a\n      b\n      c\n    d\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: |+\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n", "Format responses like this: Your Response.\ninsert divider: .-.-.-\n"),
        B("agent:\n  prompt: |+\n    - one\n    - two\n", "- one\n- two\n"),
        B("agent:\n  prompt: |+\n      indented first\n", "indented first\n"),
        B("agent:\n  prompt: |+\n    tab\there\n", "tab\there\n"),
        B("agent:\n  prompt: |+\n    trailing spaces   \n    next\n", "trailing spaces   \nnext\n"),
        B("agent:\n  prompt: >\n    hello\n", "hello\n"),
        B("agent:\n  prompt: >\n    - a\n    # b\n", "- a # b\n"),
        B("agent:\n  prompt: >\n    line one\n    line two\n", "line one line two\n"),
        B("agent:\n  prompt: >\n    line one\n    \n    line two\n", "line one\nline two\n"),
        B("agent:\n  prompt: >\n    a\n      more\n    b\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: >\n    a\n    \n    \n    b\n", "a\n\nb\n"),
        B("agent:\n  prompt: >\n    x\n    \n    \n", "x\n"),
        B("agent:\n  prompt: >\n    #####################\n    from now on\n", "##################### from now on\n"),
        B("agent:\n  prompt: >\n    key: value\n    other: 2\n", "key: value other: 2\n"),
        B("agent:\n  prompt: >\n    \n    start\n", "\nstart\n"),
        B("agent:\n  prompt: >\n    a\n      b\n      c\n    d\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: >\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n", "Format responses like this: Your Response. insert divider: .-.-.-\n"),
        B("agent:\n  prompt: >\n    - one\n    - two\n", "- one - two\n"),
        B("agent:\n  prompt: >\n      indented first\n", "indented first\n"),
        B("agent:\n  prompt: >\n    tab\there\n", "tab\there\n"),
        B("agent:\n  prompt: >\n    trailing spaces   \n    next\n", "trailing spaces    next\n"),
        B("agent:\n  prompt: >-\n    hello\n", "hello"),
        B("agent:\n  prompt: >-\n    - a\n    # b\n", "- a # b"),
        B("agent:\n  prompt: >-\n    line one\n    line two\n", "line one line two"),
        B("agent:\n  prompt: >-\n    line one\n    \n    line two\n", "line one\nline two"),
        B("agent:\n  prompt: >-\n    a\n      more\n    b\n", "a\n  more\nb"),
        B("agent:\n  prompt: >-\n    a\n    \n    \n    b\n", "a\n\nb"),
        B("agent:\n  prompt: >-\n    x\n    \n    \n", "x"),
        B("agent:\n  prompt: >-\n    #####################\n    from now on\n", "##################### from now on"),
        B("agent:\n  prompt: >-\n    key: value\n    other: 2\n", "key: value other: 2"),
        B("agent:\n  prompt: >-\n    \n    start\n", "\nstart"),
        B("agent:\n  prompt: >-\n    a\n      b\n      c\n    d\n", "a\n  b\n  c\nd"),
        B("agent:\n  prompt: >-\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n", "Format responses like this: Your Response. insert divider: .-.-.-"),
        B("agent:\n  prompt: >-\n    - one\n    - two\n", "- one - two"),
        B("agent:\n  prompt: >-\n      indented first\n", "indented first"),
        B("agent:\n  prompt: >-\n    tab\there\n", "tab\there"),
        B("agent:\n  prompt: >-\n    trailing spaces   \n    next\n", "trailing spaces    next"),
        B("agent:\n  prompt: >+\n    hello\n", "hello\n"),
        B("agent:\n  prompt: >+\n    - a\n    # b\n", "- a # b\n"),
        B("agent:\n  prompt: >+\n    line one\n    line two\n", "line one line two\n"),
        B("agent:\n  prompt: >+\n    line one\n    \n    line two\n", "line one\nline two\n"),
        B("agent:\n  prompt: >+\n    a\n      more\n    b\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: >+\n    a\n    \n    \n    b\n", "a\n\nb\n"),
        B("agent:\n  prompt: >+\n    x\n    \n    \n", "x\n\n\n"),
        B("agent:\n  prompt: >+\n    #####################\n    from now on\n", "##################### from now on\n"),
        B("agent:\n  prompt: >+\n    key: value\n    other: 2\n", "key: value other: 2\n"),
        B("agent:\n  prompt: >+\n    \n    start\n", "\nstart\n"),
        B("agent:\n  prompt: >+\n    a\n      b\n      c\n    d\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: >+\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n", "Format responses like this: Your Response. insert divider: .-.-.-\n"),
        B("agent:\n  prompt: >+\n    - one\n    - two\n", "- one - two\n"),
        B("agent:\n  prompt: >+\n      indented first\n", "indented first\n"),
        B("agent:\n  prompt: >+\n    tab\there\n", "tab\there\n"),
        B("agent:\n  prompt: >+\n    trailing spaces   \n    next\n", "trailing spaces    next\n"),
        B("agent:\n  prompt: |2\n    hello\n", "hello\n"),
        B("agent:\n  prompt: |2\n    - a\n    # b\n", "- a\n# b\n"),
        B("agent:\n  prompt: |2\n    line one\n    line two\n", "line one\nline two\n"),
        B("agent:\n  prompt: |2\n    line one\n    \n    line two\n", "line one\n\nline two\n"),
        B("agent:\n  prompt: |2\n    a\n      more\n    b\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: |2\n    a\n    \n    \n    b\n", "a\n\n\nb\n"),
        B("agent:\n  prompt: |2\n    x\n    \n    \n", "x\n"),
        B("agent:\n  prompt: |2\n    #####################\n    from now on\n", "#####################\nfrom now on\n"),
        B("agent:\n  prompt: |2\n    key: value\n    other: 2\n", "key: value\nother: 2\n"),
        B("agent:\n  prompt: |2\n    \n    start\n", "\nstart\n"),
        B("agent:\n  prompt: |2\n    a\n      b\n      c\n    d\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: |2\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n", "Format responses like this: Your Response.\ninsert divider: .-.-.-\n"),
        B("agent:\n  prompt: |2\n    - one\n    - two\n", "- one\n- two\n"),
        B("agent:\n  prompt: |2\n      indented first\n", "  indented first\n"),
        B("agent:\n  prompt: |2\n    tab\there\n", "tab\there\n"),
        B("agent:\n  prompt: |2\n    trailing spaces   \n    next\n", "trailing spaces   \nnext\n"),
        B("agent:\n  prompt: |2-\n    hello\n", "hello"),
        B("agent:\n  prompt: |2-\n    - a\n    # b\n", "- a\n# b"),
        B("agent:\n  prompt: |2-\n    line one\n    line two\n", "line one\nline two"),
        B("agent:\n  prompt: |2-\n    line one\n    \n    line two\n", "line one\n\nline two"),
        B("agent:\n  prompt: |2-\n    a\n      more\n    b\n", "a\n  more\nb"),
        B("agent:\n  prompt: |2-\n    a\n    \n    \n    b\n", "a\n\n\nb"),
        B("agent:\n  prompt: |2-\n    x\n    \n    \n", "x"),
        B("agent:\n  prompt: |2-\n    #####################\n    from now on\n", "#####################\nfrom now on"),
        B("agent:\n  prompt: |2-\n    key: value\n    other: 2\n", "key: value\nother: 2"),
        B("agent:\n  prompt: |2-\n    \n    start\n", "\nstart"),
        B("agent:\n  prompt: |2-\n    a\n      b\n      c\n    d\n", "a\n  b\n  c\nd"),
        B("agent:\n  prompt: |2-\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n", "Format responses like this: Your Response.\ninsert divider: .-.-.-"),
        B("agent:\n  prompt: |2-\n    - one\n    - two\n", "- one\n- two"),
        B("agent:\n  prompt: |2-\n      indented first\n", "  indented first"),
        B("agent:\n  prompt: |2-\n    tab\there\n", "tab\there"),
        B("agent:\n  prompt: |2-\n    trailing spaces   \n    next\n", "trailing spaces   \nnext"),
        B("agent:\n  prompt: |2+\n    hello\n", "hello\n"),
        B("agent:\n  prompt: |2+\n    - a\n    # b\n", "- a\n# b\n"),
        B("agent:\n  prompt: |2+\n    line one\n    line two\n", "line one\nline two\n"),
        B("agent:\n  prompt: |2+\n    line one\n    \n    line two\n", "line one\n\nline two\n"),
        B("agent:\n  prompt: |2+\n    a\n      more\n    b\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: |2+\n    a\n    \n    \n    b\n", "a\n\n\nb\n"),
        B("agent:\n  prompt: |2+\n    x\n    \n    \n", "x\n\n\n"),
        B("agent:\n  prompt: |2+\n    #####################\n    from now on\n", "#####################\nfrom now on\n"),
        B("agent:\n  prompt: |2+\n    key: value\n    other: 2\n", "key: value\nother: 2\n"),
        B("agent:\n  prompt: |2+\n    \n    start\n", "\nstart\n"),
        B("agent:\n  prompt: |2+\n    a\n      b\n      c\n    d\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: |2+\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n", "Format responses like this: Your Response.\ninsert divider: .-.-.-\n"),
        B("agent:\n  prompt: |2+\n    - one\n    - two\n", "- one\n- two\n"),
        B("agent:\n  prompt: |2+\n      indented first\n", "  indented first\n"),
        B("agent:\n  prompt: |2+\n    tab\there\n", "tab\there\n"),
        B("agent:\n  prompt: |2+\n    trailing spaces   \n    next\n", "trailing spaces   \nnext\n"),
        B("agent:\n  prompt: >2\n    hello\n", "hello\n"),
        B("agent:\n  prompt: >2\n    - a\n    # b\n", "- a # b\n"),
        B("agent:\n  prompt: >2\n    line one\n    line two\n", "line one line two\n"),
        B("agent:\n  prompt: >2\n    line one\n    \n    line two\n", "line one\nline two\n"),
        B("agent:\n  prompt: >2\n    a\n      more\n    b\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: >2\n    a\n    \n    \n    b\n", "a\n\nb\n"),
        B("agent:\n  prompt: >2\n    x\n    \n    \n", "x\n"),
        B("agent:\n  prompt: >2\n    #####################\n    from now on\n", "##################### from now on\n"),
        B("agent:\n  prompt: >2\n    key: value\n    other: 2\n", "key: value other: 2\n"),
        B("agent:\n  prompt: >2\n    \n    start\n", "\nstart\n"),
        B("agent:\n  prompt: >2\n    a\n      b\n      c\n    d\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: >2\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n", "Format responses like this: Your Response. insert divider: .-.-.-\n"),
        B("agent:\n  prompt: >2\n    - one\n    - two\n", "- one - two\n"),
        B("agent:\n  prompt: >2\n      indented first\n", "  indented first\n"),
        B("agent:\n  prompt: >2\n    tab\there\n", "tab\there\n"),
        B("agent:\n  prompt: >2\n    trailing spaces   \n    next\n", "trailing spaces    next\n"),
    ]

    @Test func theCorpusIsTheSizeThisSuiteClaims() {
        #expect(Self.corpus.count == 160)          // 10 headers × 16 bodies
        #expect(Set(Self.corpus.map(\.doc)).count == 160)
        #expect(Self.corpus.allSatisfy { $0.doc.hasSuffix("\n") })
    }

    /// The `+` lane is the one the defect lived in, and it must be exercised
    /// on NEWLINE-TERMINATED documents or the phantom line never appears.
    /// 3 keep headers (`|+`, `>+`, `|2+`) × 16 bodies = 48 rows, all of them
    /// `\n`-terminated. Every one of these 48 was wrong before the fix; the
    /// reviewer counted 36 because the `|2+` lane was not in the P57b
    /// vocabulary at all.
    @Test func theKeepLaneIsExercisedOnNewlineTerminatedDocuments() {
        let keep = Self.corpus.filter { $0.doc.contains("prompt: |+\n") || $0.doc.contains("prompt: >+\n") || $0.doc.contains("prompt: |2+\n") }
        #expect(keep.count == 48)
        #expect(keep.allSatisfy { $0.doc.hasSuffix("\n") })
    }

    /// 0 disagreements over the 160 documents above.
    @Test func terminalBlockScalarsMatchTheOracle() {
        var wrong: [String] = []
        for row in Self.corpus {
            let got = HermesYAML.parseNestedYAML(row.doc).values["agent.prompt"]
            if got != row.expected {
                wrong.append("\(row.doc.debugDescription) → \(String(describing: got)), PyYAML says \(row.expected.debugDescription)")
            }
        }
        #expect(wrong.isEmpty, "terminal block-scalar disagreements: \(wrong.count)/\(Self.corpus.count) — \(wrong.prefix(5).joined(separator: " | "))")
    }

    /// The reviewer's exact fixture, spelled out. Pre-fix Scarf answered
    /// `"a\n\n"`.
    @Test func theReviewersFixture() {
        let parsed = HermesYAML.parseNestedYAML("agent:\n  system_prompt: |+\n    a\n")
        #expect(parsed.values["agent.system_prompt"] == "a\n")
        #expect(parsed.maps["agent"]?["system_prompt"] == "a\n")
    }
}
