import Testing
import Foundation
@testable import ScarfCore

/// Parser + union tests for `HermesPersonalities`, covering the v0.20.4 move
/// of the built-ins out of config.yaml and the two pre-existing parse bugs
/// (wrong `personalities.` key prefix, `prompt` instead of `system_prompt`).
@Suite struct HermesPersonalitiesTests {

    // MARK: - Built-in canon

    @Test func builtinListMatchesHermesCanon() {
        #expect(HermesPersonalities.builtinNames.count == 14)
        #expect(HermesPersonalities.builtinNames == [
            "helpful", "concise", "technical", "creative", "teacher",
            "kawaii", "catgirl", "pirate", "shakespeare", "surfer",
            "noir", "uwu", "philosopher", "hype",
        ])
        #expect(Set(HermesPersonalities.builtinNames).count == 14)
    }

    @Test func neutralNames() {
        #expect(HermesPersonalities.isNeutral(""))
        #expect(HermesPersonalities.isNeutral("none"))
        #expect(HermesPersonalities.isNeutral("Default"))
        #expect(HermesPersonalities.isNeutral(" neutral "))
        #expect(!HermesPersonalities.isNeutral("pirate"))
    }

    // MARK: - Key prefix (the pre-existing bug)

    @Test func parsesAgentPrefixedKeys() {
        let yaml = """
        agent:
          personalities:
            grumpy:
              system_prompt: "You are grumpy."
        display:
          personality: grumpy
        """
        let entries = HermesPersonalities.parseUserDefined(yaml: yaml)
        #expect(entries.map(\.name) == ["grumpy"])
        #expect(entries[0].prompt == "You are grumpy.")
        #expect(entries[0].isBuiltin == false)
    }

    @Test func parsesTopLevelPersonalitiesBlock() {
        let yaml = """
        personalities:
          grumpy:
            system_prompt: You are grumpy.
        """
        #expect(HermesPersonalities.parseUserDefined(yaml: yaml).map(\.name) == ["grumpy"])
    }

    @Test func ignoresUnrelatedKeys() {
        let yaml = """
        display:
          personality: pirate
        agent:
          model: gpt-5
        """
        #expect(HermesPersonalities.parseUserDefined(yaml: yaml).isEmpty)
    }

    // MARK: - Entry forms

    @Test func readsSystemPromptOverLegacyPrompt() {
        let yaml = """
        agent:
          personalities:
            dual:
              prompt: "legacy"
              system_prompt: "modern"
        """
        let entries = HermesPersonalities.parseUserDefined(yaml: yaml)
        #expect(entries[0].prompt == "modern")
    }

    @Test func fallsBackToLegacyPromptKey() {
        let yaml = """
        agent:
          personalities:
            old:
              prompt: "legacy text"
        """
        #expect(HermesPersonalities.parseUserDefined(yaml: yaml)[0].prompt == "legacy text")
    }

    @Test func readsBareStringEntry() {
        let yaml = """
        agent:
          personalities:
            terse: "You are terse."
        """
        let entries = HermesPersonalities.parseUserDefined(yaml: yaml)
        #expect(entries.map(\.name) == ["terse"])
        #expect(entries[0].prompt == "You are terse.")
    }

    @Test func readsDictWithToneAndStyle() {
        let yaml = """
        agent:
          personalities:
            fancy:
              system_prompt: "Be fancy."
              tone: warm
              style: verbose
        """
        let entries = HermesPersonalities.parseUserDefined(yaml: yaml)
        #expect(entries.map(\.name) == ["fancy"])
        // render_personality_prompt composition: body, then Tone:, then Style:.
        #expect(entries[0].prompt == "Be fancy.\nTone: warm\nStyle: verbose")
    }

    @Test func emptyMappingYieldsNoUserEntries() {
        let yaml = """
        agent:
          personalities: {}
        """
        #expect(HermesPersonalities.parseUserDefined(yaml: yaml).isEmpty)
    }

    // MARK: - Union / dedupe

    @Test func v0204ConfigStillYieldsAllBuiltins() {
        // v0.20.4 ships `agent.personalities: {}` — the pickers must not go empty.
        let yaml = """
        agent:
          personalities: {}
        display:
          personality: pirate
        """
        let names = HermesPersonalities.resolvedNames(yaml: yaml, hasBuiltinPersonalitiesInCode: true)
        #expect(names == HermesPersonalities.builtinNames.sorted())
        #expect(names.contains("pirate"))
    }

    @Test func unionAddsUserEntriesToBuiltins() {
        let yaml = """
        agent:
          personalities:
            grumpy:
              system_prompt: "You are grumpy."
        """
        let names = HermesPersonalities.resolvedNames(yaml: yaml, hasBuiltinPersonalitiesInCode: true)
        #expect(names.count == 15)
        #expect(names.contains("grumpy"))
        #expect(names == names.sorted())
    }

    @Test func userEntryOverlaysBuiltinOfSameName() {
        // Pre-v0.20.4 hosts still ship the built-ins inline: the same names
        // arrive from both sources and must collapse to one list.
        let yaml = """
        agent:
          personalities:
            pirate:
              system_prompt: "Arrr, custom."
            noir:
              system_prompt: "Rain."
        """
        let entries = HermesPersonalities.resolve(yaml: yaml, hasBuiltinPersonalitiesInCode: true)
        #expect(entries.count == 14)
        #expect(entries.map(\.name) == HermesPersonalities.builtinNames.sorted())
        let pirate = entries.first { $0.name == "pirate" }
        #expect(pirate?.prompt == "Arrr, custom.")
        #expect(pirate?.isBuiltin == false)
        #expect(entries.first { $0.name == "hype" }?.isBuiltin == true)
    }

    // MARK: - Picker options

    @Test func pickerOptionsLeadWithNeutralDefault() {
        let options = HermesPersonalities.pickerOptions(yaml: "", current: "default", hasBuiltinPersonalitiesInCode: true)
        #expect(options.first == "default")
        #expect(options.count == 15)
        #expect(Set(options).isSuperset(of: HermesPersonalities.builtinNames))
    }

    @Test func pickerOptionsKeepUnknownCurrentSelection() {
        let options = HermesPersonalities.pickerOptions(yaml: "", current: "handwritten", hasBuiltinPersonalitiesInCode: true)
        #expect(options.contains("handwritten"))
        #expect(options[1] == "handwritten")
    }

    @Test func pickerOptionsDoNotDuplicateKnownCurrent() {
        let options = HermesPersonalities.pickerOptions(yaml: "", current: "pirate", hasBuiltinPersonalitiesInCode: true)
        #expect(options.filter { $0 == "pirate" }.count == 1)
        #expect(options.count == 15)
    }

    @Test func pickerOptionsWithEmptyCurrent() {
        #expect(HermesPersonalities.pickerOptions(yaml: "", current: "", hasBuiltinPersonalitiesInCode: true).count == 15)
    }

    // MARK: - render_personality_prompt composition

    @Test func toneAndStyleOnlyEntryComposesPromptInsteadOfBlank() {
        // No system_prompt at all — Hermes still renders "Tone: …\nStyle: …",
        // so the preview must not be empty.
        let yaml = """
        agent:
          personalities:
            breezy:
              tone: casual
              style: short sentences
        """
        let entries = HermesPersonalities.parseUserDefined(yaml: yaml)
        #expect(entries.map(\.name) == ["breezy"])
        #expect(entries[0].prompt == "Tone: casual\nStyle: short sentences")
    }

    @Test func toneOnlyEntryOmitsStyleLine() {
        let yaml = """
        agent:
          personalities:
            gruff:
              tone: blunt
        """
        #expect(HermesPersonalities.parseUserDefined(yaml: yaml)[0].prompt == "Tone: blunt")
    }

    @Test func toneStyleOnlyEntryOverlaysBuiltinWithComposedText() {
        // A tone/style-only entry named after a built-in is a real overlay —
        // Hermes renders exactly this text in place of the built-in body.
        let yaml = """
        agent:
          personalities:
            pirate:
              tone: gruff
        """
        let entries = HermesPersonalities.resolve(yaml: yaml, hasBuiltinPersonalitiesInCode: true)
        let pirate = entries.first { $0.name == "pirate" }
        #expect(pirate?.prompt == "Tone: gruff")
        #expect(pirate?.isBuiltin == false)
        #expect(entries.count == 14)
    }

    @Test func emptyEntryNamedAfterBuiltinDoesNotBlankIt() {
        // A bare `pirate:` header (no renderable keys) must not turn the
        // built-in into an empty-prompt user row — it degrades back to the
        // built-in instead.
        let yaml = """
        agent:
          personalities:
            pirate:
              description: "just a note"
        """
        let entries = HermesPersonalities.resolve(yaml: yaml, hasBuiltinPersonalitiesInCode: true)
        let pirate = entries.first { $0.name == "pirate" }
        #expect(pirate?.isBuiltin == true)
        #expect(pirate?.prompt == "")
        #expect(entries.count == 14)
    }

    // MARK: - Pre-v0.20.4 hosts (built-ins are editable YAML)

    @Test func preV0204DeletedBuiltinStaysDeleted() {
        // On a pre-v0.20.4 host the built-ins ship inline in config.yaml. A
        // user who removed all but one genuinely removed them — the static
        // list must not resurrect the other 13.
        let yaml = """
        agent:
          personalities:
            pirate:
              system_prompt: "Arrr."
        """
        let names = HermesPersonalities.resolvedNames(yaml: yaml, hasBuiltinPersonalitiesInCode: false)
        #expect(names == ["pirate"])
        #expect(!names.contains("hype"))
    }

    @Test func preV0204EmptyConfigYieldsNoPersonalities() {
        #expect(HermesPersonalities.resolvedNames(yaml: "", hasBuiltinPersonalitiesInCode: false).isEmpty)
        let options = HermesPersonalities.pickerOptions(
            yaml: "",
            current: "",
            hasBuiltinPersonalitiesInCode: false
        )
        #expect(options == ["default"])
    }

    @Test func preV0204UserEntryKeepsItsOwnPromptAndIsNotMarkedBuiltin() {
        let yaml = """
        agent:
          personalities:
            pirate:
              tone: gruff
        """
        let entries = HermesPersonalities.resolve(yaml: yaml, hasBuiltinPersonalitiesInCode: false)
        #expect(entries.count == 1)
        #expect(entries[0].isBuiltin == false)
        #expect(entries[0].prompt == "Tone: gruff")
    }

    @Test func emptyYamlStillYieldsBuiltins() {
        #expect(HermesPersonalities.resolvedNames(yaml: "", hasBuiltinPersonalitiesInCode: true) == HermesPersonalities.builtinNames.sorted())
    }
}
