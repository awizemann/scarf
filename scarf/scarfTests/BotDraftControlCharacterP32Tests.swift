import Testing
import Foundation
import ScarfCore
@testable import scarf

/// P32 — round-3 decision 6 in the Bot editor: a control character in a
/// user-typed scalar is a visible validation error that blocks Save, not a
/// silent reshape at the writer.
///
/// The consequence the refusal prevents is the one
/// `HermesBotProfileYAML`'s own doc block calls total metadata loss: PyYAML
/// refuses a `profile.yaml` carrying a raw control character in EVERY
/// quoting style, `_load_yaml_dict` catches and returns `None`
/// (`hermes_cli/profiles.py:471-480` @ `v2026.9.7`), `read_profile_meta`
/// hands back empty defaults (`:609-618`), and the bot loses its
/// `display_name`, `description` and whole `hermes-bots` block.
@Suite("P32 bot editor control-character refusal")
struct BotDraftControlCharacterP32Tests {

    private func draft() -> BotDraft {
        BotDraft(identity: HermesBotIdentity(profileName: "research", profileDirectory: "/tmp/research"))
    }

    /// `BotEditorSheet.canSave` is `draft.controlCharacterFieldLabel == nil`
    /// AND the create-only id rule, so this predicate is what blocks Save.
    @Test(arguments: ["a\tb", "a\u{01}b", "a\u{7F}b"])
    func aControlCharacterInASingleLineFieldIsAValidationError(_ raw: String) {
        for (label, set) in [
            ("Profile id", { (d: inout BotDraft) in d.profileName = raw }),
            ("Name", { (d: inout BotDraft) in d.title = raw }),
            ("Color", { (d: inout BotDraft) in d.color = raw }),
            ("Shape", { (d: inout BotDraft) in d.shape = raw }),
            ("Role", { (d: inout BotDraft) in d.description = raw })
        ] as [(String, (inout BotDraft) -> Void)] {
            var d = draft()
            set(&d)
            #expect(
                d.controlCharacterFieldLabel == label,
                "\(raw.debugDescription) in \(label) was accepted"
            )
        }
    }

    /// The Role field is deliberately multi-line and Hermes round-trips real
    /// newlines through `yaml.safe_dump`, so a line break there is content,
    /// not an error. In Name / Color / Shape a pasted newline is already
    /// flattened by `BotDraft.singleLine`, so there is nothing left to
    /// refuse — refusing it would make an ordinary paste un-saveable.
    @Test func lineBreaksAreNotRefused() {
        var d = draft()
        d.description = "First line.\n\nSecond paragraph."
        #expect(d.controlCharacterFieldLabel == nil)

        var titled = draft()
        titled.title = "Research\nBot"
        #expect(titled.controlCharacterFieldLabel == nil)
    }

    /// Ordinary text — including every shape that only needs QUOTING — is
    /// never a validation error. Over-refusing would make an ordinary bot
    /// name untypable, which is the failure mode P19 named for a
    /// fail-closed gate that runs before the mutation.
    @Test(arguments: ["Research", "}brace-first", "`backtick", "<<", ".inf", "#C1502E", "2026-09-09", "it's"])
    func ordinaryTextIsAccepted(_ raw: String) {
        var d = draft()
        d.title = raw
        d.description = raw
        d.color = raw
        #expect(d.controlCharacterFieldLabel == nil)
    }

    /// P32 widened `YAMLScalar.doubleQuoted` with a control-character arm,
    /// so `HermesFileService.unquote` — the reader on the other side of that
    /// emitter — had to learn `\xNN` / `\uNNNN` in the same commit. P19's
    /// rule: the test for an escaping pair is idempotence, not equality.
    @Test(arguments: ["a\u{01}b", "a\u{7F}b", "line\nbreak", "back\\slash", "quote\"here", "a\u{2028}b"])
    func doubleQuotedEmissionAndUnquoteAreInverses(_ raw: String) {
        let emitted = YAMLScalar.doubleQuoted(raw)
        #expect(HermesFileService.unquote(emitted) == raw)
        // Idempotent: a second save must not grow an escape.
        #expect(YAMLScalar.doubleQuoted(HermesFileService.unquote(emitted)) == emitted)
    }

    /// A truncated or non-hex escape in a hand-edited file is passed through
    /// verbatim rather than swallowed — the decoder must not lose bytes it
    /// does not understand.
    @Test func aMalformedHexEscapeIsLeftAsWritten() {
        #expect(HermesFileService.unquote("\"a\\xzzb\"") == "a\\xzzb")
        #expect(HermesFileService.unquote("\"a\\x0\"") == "a\\x0")
        #expect(HermesFileService.unquote("\"a\\qb\"") == "a\\qb")
    }

    /// And the accepted text still survives the writer — the refusal is for
    /// control characters only because everything else is quotable.
    @Test func acceptedTextStillRoundTripsThroughTheWriter() throws {
        var d = draft()
        d.title = "}brace `tick <<"
        d.description = ".inf"
        var identity = HermesBotIdentity(profileName: "research", profileDirectory: "/tmp/research")
        d.apply(to: &identity)
        let out = try #require(HermesBotProfileYAML.write(identity: identity, into: "version: 1\n"))
        let reparsed = HermesBotProfileYAML.parse(
            out, profileName: "research", profileDirectory: "/tmp/research"
        )
        #expect(reparsed.title == "}brace `tick <<")
        #expect(reparsed.botDescription == ".inf")
    }
}
