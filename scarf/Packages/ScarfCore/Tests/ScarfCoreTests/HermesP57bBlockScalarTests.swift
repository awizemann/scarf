import Foundation
import Testing
@testable import ScarfCore

/// P57b finding 5: a `|` / `>` block scalar opened a stack frame like an
/// empty section, so `parseNestedYAML` read its BODY as YAML — `- ` lines
/// became a phantom list, `#` lines were dropped as comments, and the key's
/// value was lost entirely.
///
/// This is not a theoretical shape for Scarf. Hermes's own documentation
/// tells users to hand-edit `~/.hermes/config.yaml` with
/// `agent:` / `  system_prompt: |` over a body of `#####` and prose lines
/// (`optional-skills/security/godmode/SKILL.md:136-148` @ `v2026.9.7`), and
/// `HermesPersonalities.parseUserDefined(yaml:)` reads
/// `agent.personalities.<name>.system_prompt` — a multi-line prompt whose
/// natural hand-written spelling is exactly this. Before the fix such a
/// personality rendered with an EMPTY prompt.
///
/// Every `expected` below is `yaml.safe_load(doc)["agent"]["prompt"]` printed
/// by PyYAML 6.0.3: 6 headers (`|`, `|-`, `|+`, `>`, `>-`, `>+`) × 16 bodies
/// = **96 documents**, covering clip/strip/keep chomping, folding, blank
/// lines, more-indented lines, `- ` and `#` bodies, and a body line that
/// looks like `key: value`.
@Suite("P57b — a block scalar's body is not YAML")
struct HermesP57bBlockScalarTests {

    struct B: Sendable { let doc: String; let expected: String
        init(_ d: String, _ e: String) { doc = d; expected = e } }

    static let corpus: [B] = [
        B("agent:\n  prompt: |\n    hello\n  note: end\n", "hello\n"),
        B("agent:\n  prompt: |\n    - a\n    # b\n  note: end\n", "- a\n# b\n"),
        B("agent:\n  prompt: |\n    line one\n    line two\n  note: end\n", "line one\nline two\n"),
        B("agent:\n  prompt: |\n    line one\n    \n    line two\n  note: end\n", "line one\n\nline two\n"),
        B("agent:\n  prompt: |\n    a\n      more\n    b\n  note: end\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: |\n    a\n    \n    \n    b\n  note: end\n", "a\n\n\nb\n"),
        B("agent:\n  prompt: |\n    x\n    \n    \n  note: end\n", "x\n"),
        B("agent:\n  prompt: |\n    #####################\n    from now on\n  note: end\n", "#####################\nfrom now on\n"),
        B("agent:\n  prompt: |\n    key: value\n    other: 2\n  note: end\n", "key: value\nother: 2\n"),
        B("agent:\n  prompt: |\n    \n    start\n  note: end\n", "\nstart\n"),
        B("agent:\n  prompt: |\n    a\n      b\n      c\n    d\n  note: end\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: |\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n  note: end\n", "Format responses like this: Your Response.\ninsert divider: .-.-.-\n"),
        B("agent:\n  prompt: |\n    - one\n    - two\n  note: end\n", "- one\n- two\n"),
        B("agent:\n  prompt: |\n      indented first\n  note: end\n", "indented first\n"),
        B("agent:\n  prompt: |\n    tab\there\n  note: end\n", "tab\there\n"),
        B("agent:\n  prompt: |\n    trailing spaces   \n    next\n  note: end\n", "trailing spaces   \nnext\n"),
        B("agent:\n  prompt: |-\n    hello\n  note: end\n", "hello"),
        B("agent:\n  prompt: |-\n    - a\n    # b\n  note: end\n", "- a\n# b"),
        B("agent:\n  prompt: |-\n    line one\n    line two\n  note: end\n", "line one\nline two"),
        B("agent:\n  prompt: |-\n    line one\n    \n    line two\n  note: end\n", "line one\n\nline two"),
        B("agent:\n  prompt: |-\n    a\n      more\n    b\n  note: end\n", "a\n  more\nb"),
        B("agent:\n  prompt: |-\n    a\n    \n    \n    b\n  note: end\n", "a\n\n\nb"),
        B("agent:\n  prompt: |-\n    x\n    \n    \n  note: end\n", "x"),
        B("agent:\n  prompt: |-\n    #####################\n    from now on\n  note: end\n", "#####################\nfrom now on"),
        B("agent:\n  prompt: |-\n    key: value\n    other: 2\n  note: end\n", "key: value\nother: 2"),
        B("agent:\n  prompt: |-\n    \n    start\n  note: end\n", "\nstart"),
        B("agent:\n  prompt: |-\n    a\n      b\n      c\n    d\n  note: end\n", "a\n  b\n  c\nd"),
        B("agent:\n  prompt: |-\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n  note: end\n", "Format responses like this: Your Response.\ninsert divider: .-.-.-"),
        B("agent:\n  prompt: |-\n    - one\n    - two\n  note: end\n", "- one\n- two"),
        B("agent:\n  prompt: |-\n      indented first\n  note: end\n", "indented first"),
        B("agent:\n  prompt: |-\n    tab\there\n  note: end\n", "tab\there"),
        B("agent:\n  prompt: |-\n    trailing spaces   \n    next\n  note: end\n", "trailing spaces   \nnext"),
        B("agent:\n  prompt: |+\n    hello\n  note: end\n", "hello\n"),
        B("agent:\n  prompt: |+\n    - a\n    # b\n  note: end\n", "- a\n# b\n"),
        B("agent:\n  prompt: |+\n    line one\n    line two\n  note: end\n", "line one\nline two\n"),
        B("agent:\n  prompt: |+\n    line one\n    \n    line two\n  note: end\n", "line one\n\nline two\n"),
        B("agent:\n  prompt: |+\n    a\n      more\n    b\n  note: end\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: |+\n    a\n    \n    \n    b\n  note: end\n", "a\n\n\nb\n"),
        B("agent:\n  prompt: |+\n    x\n    \n    \n  note: end\n", "x\n\n\n"),
        B("agent:\n  prompt: |+\n    #####################\n    from now on\n  note: end\n", "#####################\nfrom now on\n"),
        B("agent:\n  prompt: |+\n    key: value\n    other: 2\n  note: end\n", "key: value\nother: 2\n"),
        B("agent:\n  prompt: |+\n    \n    start\n  note: end\n", "\nstart\n"),
        B("agent:\n  prompt: |+\n    a\n      b\n      c\n    d\n  note: end\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: |+\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n  note: end\n", "Format responses like this: Your Response.\ninsert divider: .-.-.-\n"),
        B("agent:\n  prompt: |+\n    - one\n    - two\n  note: end\n", "- one\n- two\n"),
        B("agent:\n  prompt: |+\n      indented first\n  note: end\n", "indented first\n"),
        B("agent:\n  prompt: |+\n    tab\there\n  note: end\n", "tab\there\n"),
        B("agent:\n  prompt: |+\n    trailing spaces   \n    next\n  note: end\n", "trailing spaces   \nnext\n"),
        B("agent:\n  prompt: >\n    hello\n  note: end\n", "hello\n"),
        B("agent:\n  prompt: >\n    - a\n    # b\n  note: end\n", "- a # b\n"),
        B("agent:\n  prompt: >\n    line one\n    line two\n  note: end\n", "line one line two\n"),
        B("agent:\n  prompt: >\n    line one\n    \n    line two\n  note: end\n", "line one\nline two\n"),
        B("agent:\n  prompt: >\n    a\n      more\n    b\n  note: end\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: >\n    a\n    \n    \n    b\n  note: end\n", "a\n\nb\n"),
        B("agent:\n  prompt: >\n    x\n    \n    \n  note: end\n", "x\n"),
        B("agent:\n  prompt: >\n    #####################\n    from now on\n  note: end\n", "##################### from now on\n"),
        B("agent:\n  prompt: >\n    key: value\n    other: 2\n  note: end\n", "key: value other: 2\n"),
        B("agent:\n  prompt: >\n    \n    start\n  note: end\n", "\nstart\n"),
        B("agent:\n  prompt: >\n    a\n      b\n      c\n    d\n  note: end\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: >\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n  note: end\n", "Format responses like this: Your Response. insert divider: .-.-.-\n"),
        B("agent:\n  prompt: >\n    - one\n    - two\n  note: end\n", "- one - two\n"),
        B("agent:\n  prompt: >\n      indented first\n  note: end\n", "indented first\n"),
        B("agent:\n  prompt: >\n    tab\there\n  note: end\n", "tab\there\n"),
        B("agent:\n  prompt: >\n    trailing spaces   \n    next\n  note: end\n", "trailing spaces    next\n"),
        B("agent:\n  prompt: >-\n    hello\n  note: end\n", "hello"),
        B("agent:\n  prompt: >-\n    - a\n    # b\n  note: end\n", "- a # b"),
        B("agent:\n  prompt: >-\n    line one\n    line two\n  note: end\n", "line one line two"),
        B("agent:\n  prompt: >-\n    line one\n    \n    line two\n  note: end\n", "line one\nline two"),
        B("agent:\n  prompt: >-\n    a\n      more\n    b\n  note: end\n", "a\n  more\nb"),
        B("agent:\n  prompt: >-\n    a\n    \n    \n    b\n  note: end\n", "a\n\nb"),
        B("agent:\n  prompt: >-\n    x\n    \n    \n  note: end\n", "x"),
        B("agent:\n  prompt: >-\n    #####################\n    from now on\n  note: end\n", "##################### from now on"),
        B("agent:\n  prompt: >-\n    key: value\n    other: 2\n  note: end\n", "key: value other: 2"),
        B("agent:\n  prompt: >-\n    \n    start\n  note: end\n", "\nstart"),
        B("agent:\n  prompt: >-\n    a\n      b\n      c\n    d\n  note: end\n", "a\n  b\n  c\nd"),
        B("agent:\n  prompt: >-\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n  note: end\n", "Format responses like this: Your Response. insert divider: .-.-.-"),
        B("agent:\n  prompt: >-\n    - one\n    - two\n  note: end\n", "- one - two"),
        B("agent:\n  prompt: >-\n      indented first\n  note: end\n", "indented first"),
        B("agent:\n  prompt: >-\n    tab\there\n  note: end\n", "tab\there"),
        B("agent:\n  prompt: >-\n    trailing spaces   \n    next\n  note: end\n", "trailing spaces    next"),
        B("agent:\n  prompt: >+\n    hello\n  note: end\n", "hello\n"),
        B("agent:\n  prompt: >+\n    - a\n    # b\n  note: end\n", "- a # b\n"),
        B("agent:\n  prompt: >+\n    line one\n    line two\n  note: end\n", "line one line two\n"),
        B("agent:\n  prompt: >+\n    line one\n    \n    line two\n  note: end\n", "line one\nline two\n"),
        B("agent:\n  prompt: >+\n    a\n      more\n    b\n  note: end\n", "a\n  more\nb\n"),
        B("agent:\n  prompt: >+\n    a\n    \n    \n    b\n  note: end\n", "a\n\nb\n"),
        B("agent:\n  prompt: >+\n    x\n    \n    \n  note: end\n", "x\n\n\n"),
        B("agent:\n  prompt: >+\n    #####################\n    from now on\n  note: end\n", "##################### from now on\n"),
        B("agent:\n  prompt: >+\n    key: value\n    other: 2\n  note: end\n", "key: value other: 2\n"),
        B("agent:\n  prompt: >+\n    \n    start\n  note: end\n", "\nstart\n"),
        B("agent:\n  prompt: >+\n    a\n      b\n      c\n    d\n  note: end\n", "a\n  b\n  c\nd\n"),
        B("agent:\n  prompt: >+\n    Format responses like this: Your Response.\n    insert divider: .-.-.-\n  note: end\n", "Format responses like this: Your Response. insert divider: .-.-.-\n"),
        B("agent:\n  prompt: >+\n    - one\n    - two\n  note: end\n", "- one - two\n"),
        B("agent:\n  prompt: >+\n      indented first\n  note: end\n", "indented first\n"),
        B("agent:\n  prompt: >+\n    tab\there\n  note: end\n", "tab\there\n"),
        B("agent:\n  prompt: >+\n    trailing spaces   \n    next\n  note: end\n", "trailing spaces    next\n"),
    ]

    @Test func theCorpusIsTheSizeThisSuiteClaims() {
        #expect(Self.corpus.count == 96)
        #expect(Set(Self.corpus.map(\.doc)).count == 96)
    }

    /// 0 disagreements over the 96 documents above.
    @Test func blockScalarBodiesMatchTheOracle() {
        var wrong: [String] = []
        for row in Self.corpus {
            let parsed = HermesYAML.parseNestedYAML(row.doc)
            let got = parsed.values["agent.prompt"]
            if got != row.expected {
                wrong.append("\(row.doc.debugDescription) → \(String(describing: got)), PyYAML says \(row.expected.debugDescription)")
            }
        }
        #expect(wrong.isEmpty, "block-scalar disagreements: \(wrong.count)/\(Self.corpus.count) — \(wrong.prefix(5).joined(separator: " | "))")
    }

    /// The block ENDS at the first line back at or above the key's indent,
    /// and the sibling after it parses normally — `note: end` in every one of
    /// the 96 documents.
    @Test func theSiblingAfterTheBlockSurvives() {
        for row in Self.corpus {
            let parsed = HermesYAML.parseNestedYAML(row.doc)
            #expect(parsed.values["agent.note"] == "end")
        }
    }

    /// The reviewer's exact inputs, spelled out. PyYAML 6.0.3 loads this
    /// document as `{'agent': {'prompt': '- a\n# b\n', 'note': 'end'}}`.
    /// Pre-fix Scarf had no `agent.prompt` value at all and carried a phantom
    /// `lists["agent.prompt"] == ["a"]` — the `#` line silently gone.
    @Test func theReviewersFixture() {
        let parsed = HermesYAML.parseNestedYAML("""
        agent:
          prompt: |
            - a
            # b
          note: end
        """)
        #expect(parsed.values["agent.prompt"] == "- a\n# b\n")
        #expect(parsed.lists["agent.prompt"] == nil)
        #expect(parsed.values["agent.note"] == "end")
        #expect(parsed.maps["agent"]?["prompt"] == "- a\n# b\n")
    }

    /// The surface that made this a fix rather than a filed task: a
    /// user-defined personality whose prompt is written as a block scalar.
    /// `render_personality_prompt` (`hermes_cli/personality.py:59`) takes
    /// `value.get("system_prompt", "")`, so the host renders the whole body;
    /// Scarf used to render nothing.
    @Test func aPersonalityPromptWrittenAsABlockScalarIsRead() {
        let entries = HermesPersonalities.parseUserDefined(yaml: """
        agent:
          personalities:
            pirate:
              system_prompt: |-
                Arrr, matey.
                # not a comment
                - not a bullet
              tone: gruff
        """)
        let pirate = entries.first { $0.name == "pirate" }
        #expect(pirate != nil)
        #expect(pirate?.prompt.contains("Arrr, matey.") == true)
        #expect(pirate?.prompt.contains("# not a comment") == true)
        #expect(pirate?.prompt.contains("- not a bullet") == true)
    }
}
