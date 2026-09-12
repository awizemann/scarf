import Testing
import Foundation
@testable import ScarfCore

/// P37 of the whole-surface audit — the ScarfCore half of the cross-phase
/// review of P30–P36.
///
/// Findings covered here:
/// * **2** — `/steer` is an ACP row with a v0.13.0 floor
///   (`acp_adapter/server.py:170` @ `v2026.5.7`, absent at `v2026.4.30`),
///   and the composer's roster offered it on every host.
/// * **3 / 13** — the `profile_routes` writer emits through
///   `YAMLScalar.quoteIfNeeded` (which can double-quote with escapes) while
///   its reader went through `HermesYAML.stripYAMLQuotes`, which hands a
///   double-quoted body back verbatim. One shared decoder now, and its hex
///   arm rejects a non-hex-digit body (`UInt32("+9", radix: 16)` is 9).
/// * **7** — `YAMLScalar.doubleQuoted`'s comment claimed a tab stays raw
///   while the `< 0x20` arm escaped it as `\x09`.
/// * **11** — `HermesYAML.parseNestedYAML`'s last-wins purge fired on EVERY
///   section header, so a flat dotted key was deleted by the first opening
///   of its would-be parent block.
@Suite("P37 — cross-phase review remediation (ScarfCore)")
struct HermesP37RemediationTests {

    // MARK: - Finding 2: the `/steer` floor

    /// `/steer` and `/queue` arrived in the ACP adapter together at
    /// `v2026.5.7` (`acp_adapter/server.py:170` / `:171`); neither exists at
    /// `v2026.4.30`. Fails before the fix: the roster's `default: return
    /// true` arm offered `/steer` on a v0.12 host, where the adapter has no
    /// such command and `_handle_slash_command` returns `None` — so the text
    /// fell through to the LLM and burned a turn.
    @Test func steerIsNotOfferedBelowItsV013Floor() {
        let v012 = HermesCapabilities.parseLine("Hermes Agent v0.12.0 (2026.4.30)")
        let v013 = HermesCapabilities.parseLine("Hermes Agent v0.13.0 (2026.5.7)")

        #expect(!v012.hasACPSteer, "a v0.12 host has no `steer` in acp_adapter/")
        #expect(v013.hasACPSteer)
        // The floor is shared with `/queue` — the two names are adjacent
        // lines in the same dict at the same first tag.
        #expect(v012.hasACPSteer == v012.hasACPQueue)
        #expect(v013.hasACPSteer == v013.hasACPQueue)
        // P44 (round-4 decision 14) retired `hasACPSteerOnIdle`: it was
        // `hasACPSteer` expressed a second time and its only reader was an
        // unreachable arm. The single floor is what these two lines pin.
    }

    /// C1's degradation arm: `.empty` (no version known) offers neither.
    @Test func anUnknownHostOffersNeitherNonInterruptiveCommand() {
        #expect(!HermesCapabilities.empty.hasACPSteer)
        #expect(!HermesCapabilities.empty.hasACPQueue)
    }

    /// C1's patch arm: a v0.13 patch release keeps it.
    @Test func aV013PatchReleaseStillOffersSteer() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.13.4 (2026.5.20)").hasACPSteer)
    }

    /// C1's all-on arm: the target host has it.
    @Test func theTargetHostOffersSteer() {
        #expect(HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)").hasACPSteer)
    }

    // MARK: - Finding 7: the tab escape

    /// The doc block said a tab is emitted raw; the `< 0x20` arm escaped it
    /// as `\x09`. Fails before the fix.
    @Test func aTabIsEscapedAsBackslashTNotAsAHexByte() {
        #expect(YAMLScalar.doubleQuoted("a\tb") == "\"a\\tb\"")
        // The other C0 controls keep their `\xNN` form — `\t` is the one
        // with a dedicated YAML escape in this set.
        #expect(YAMLScalar.doubleQuoted("a\u{01}b") == "\"a\\x01b\"")
        #expect(YAMLScalar.doubleQuoted("a\u{7F}b") == "\"a\\x7fb\"")
    }

    // MARK: - Finding 3 / 13: one shared decoder

    /// Every shape the emitter can produce must come back byte-identical
    /// through the ONE decoder, and re-emitting the decoded value must be
    /// idempotent.
    @Test(arguments: [
        "a\\b", "a\nb", "a\u{01}b", "\"quoted\"", "a\tb", "it's",
        "a\r\nb", "a\u{85}b", "a\u{2028}b", "plain", "", "  padded  ",
        "123", "true", "null", "*star", "#hash", "}brace", "a: b",
    ])
    func theSharedDecoderReversesEveryEmittedShape(raw: String) {
        let emitted = YAMLScalar.quoteIfNeeded(raw)
        #expect(YAMLScalar.unquote(emitted) == raw, "round trip failed for \(raw.debugDescription)")
        #expect(YAMLScalar.quoteIfNeeded(YAMLScalar.unquote(emitted)) == emitted,
                "not idempotent for \(raw.debugDescription)")
    }

    /// `UInt32(_:radix:)` accepts a leading sign, so `\x+9` decoded to a
    /// TAB before the fix (`HermesFileService.unquote` had the same hole —
    /// `HermesBotProfileYAML.unquote` already guarded it). A malformed
    /// escape is emitted verbatim instead.
    @Test func aSignedHexBodyIsNotAValidEscape() {
        #expect(YAMLScalar.unquote("\"a\\x+9b\"") == "a\\x+9b")
        #expect(YAMLScalar.unquote("\"a\\u+009b\"") == "a\\u+009b")
        #expect(YAMLScalar.unquote("\"a\\xzzb\"") == "a\\xzzb")
        // Truncated escapes keep their bytes rather than being dropped.
        #expect(YAMLScalar.unquote("\"a\\x0\"") == "a\\x0")
        // An escape Scarf never emits is passed through with its backslash.
        #expect(YAMLScalar.unquote("\"a\\qb\"") == "a\\qb")
        // A well-formed one still decodes.
        #expect(YAMLScalar.unquote("\"a\\x09b\"") == "a\tb")
        #expect(YAMLScalar.unquote("\"a\\u0041b\"") == "aAb")
    }

    /// The rest of PyYAML's escape table, which the shared decoder accepts so
    /// a hand-edited config.yaml round-trips. Hermes's own writer emits these
    /// four RAW inside single quotes (`allow_unicode=True`,
    /// `utils.py:271` @ `v2026.9.7`) and `doubleQuoted` spells them `\uNNNN`,
    /// so this arm exists for the hand-written case only — both forms decode
    /// to the same scalar.
    @Test func theWholePyYAMLEscapeTableDecodes() {
        #expect(YAMLScalar.unquote("\"a\\Nb\"") == "a\u{85}b")
        #expect(YAMLScalar.unquote("\"a\\_b\"") == "a\u{A0}b")
        #expect(YAMLScalar.unquote("\"a\\Lb\"") == "a\u{2028}b")
        #expect(YAMLScalar.unquote("\"a\\Pb\"") == "a\u{2029}b")
        // `doubleQuoted`'s own spelling for the same scalars.
        for raw in ["a\u{85}b", "a\u{2028}b", "a\u{2029}b"] {
            #expect(YAMLScalar.unquote(YAMLScalar.doubleQuoted(raw)) == raw)
        }
        #expect(YAMLScalar.unquote("\"a\\0\\a\\b\\f\\v\\e\\/b\"")
                == "a\0\u{07}\u{08}\u{0C}\u{0B}\u{1B}/b")
        #expect(YAMLScalar.unquote("\"\\U0001F600\"") == "\u{1F600}")
    }

    /// Finding 3's headline: the `profile_routes` READER could not decode
    /// what its own writer emits. Fails before the fix — `stripYAMLQuotes`
    /// returned `a\\b` for the writer's `"a\\\\b"`.
    @Test func profileRoutesRoundTripEveryHostileScalar() throws {
        for raw in ["a\\b", "a\nb", "a\u{01}b", "\"quoted\"", "a\tb", "it's"] {
            let caps = HermesCapabilities.parseLine("Hermes Agent v0.21.1 (2026.9.7)")
            let base = "gateway:\n  enabled: true\n"
            let route = HermesProfileRoute(name: raw, platform: "discord", profile: "work")
            let yaml = try #require(ProfileRoutesWriter.setProfileRoutes(
                in: base, routes: [route], location: .gateway, capabilities: caps
            ))
            let back = try #require(ProfileRoutesYAML.parse(yaml).routes.first)
            #expect(back.name == raw, "route name did not survive: \(raw.debugDescription)")

            // …and a second write of the parsed value is byte-identical, so
            // an edit-save-edit-save cycle cannot drift.
            let again = ProfileRoutesWriter.setProfileRoutes(
                in: base, routes: [back], location: .gateway, capabilities: caps
            )
            #expect(again == yaml, "not idempotent for \(raw.debugDescription)")
        }
    }

    // MARK: - Finding 11: the last-wins purge fires on a RE-OPENED path only

    /// A flat dotted key is a DIFFERENT key to PyYAML
    /// (`{"gateway.enabled": True, "gateway": {...}}`), so the first opening
    /// of `gateway:` must not delete it. Fails before the fix: the purge ran
    /// unconditionally on every section header, and `gateway.enabled`
    /// matched the `gateway.` descendant prefix.
    @Test func afreshSectionHeaderDoesNotPurgeAFlatDottedSibling() {
        let parsed = HermesYAML.parseNestedYAML("""
        gateway.enabled: true
        gateway:
          port: 8080
        """)
        #expect(parsed.values["gateway.enabled"] == "true",
                "the first opening of `gateway:` deleted a flat key PyYAML keeps")
        #expect(parsed.values["gateway.port"] == "8080")
    }

    /// The regression the `openedPaths` guard introduced, caught in P37's own
    /// fresh-eyes pass: the INLINE-FLOW-LIST branch writes `lists[path]` and
    /// `continue`s without recording the path, so a later block header at the
    /// same path looked like a first open, the purge was skipped and the two
    /// lists CONCATENATED. `agent.toolsets` is exactly the shape — a
    /// list-valued key people write either way — and PyYAML is last-wins.
    @Test func aFlowListFollowedByABlockListIsStillLastWins() {
        let parsed = HermesYAML.parseNestedYAML("""
        agent:
          toolsets: [hermes-cli]
          toolsets:
            - browser
        """)
        #expect(parsed.lists["agent.toolsets"] == ["browser"],
                "the flow list and the block list were concatenated")
    }

    /// The mirror: block first, flow second. Both orders must answer with the
    /// SECOND value, whichever shape each one happens to be in.
    @Test func aBlockListFollowedByAFlowListIsStillLastWins() {
        let parsed = HermesYAML.parseNestedYAML("""
        agent:
          toolsets:
            - browser
          toolsets: [hermes-cli]
        """)
        #expect(parsed.lists["agent.toolsets"] == ["hermes-cli"])
    }

    /// …and a genuine duplicate block is still last-wins across `values`,
    /// `maps` and `lists` — P32's rule, unchanged.
    @Test func aReOpenedBlockStillPurgesItsEarlierSelf() {
        let parsed = HermesYAML.parseNestedYAML("""
        gateway:
          shared: first
          only_in_first: gone
        model:
          a: 3
        gateway:
          shared: second
        """)
        #expect(parsed.values["gateway.shared"] == "second")
        #expect(parsed.values["gateway.only_in_first"] == nil,
                "PyYAML replaces the first mapping outright")
        #expect(parsed.values["model.a"] == "3", "an unrelated sibling block is untouched")
    }
}
