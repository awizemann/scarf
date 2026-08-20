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
        #expect(entries[0].prompt == "Be fancy.")
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
        let names = HermesPersonalities.resolvedNames(yaml: yaml)
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
        let names = HermesPersonalities.resolvedNames(yaml: yaml)
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
        let entries = HermesPersonalities.resolve(yaml: yaml)
        #expect(entries.count == 14)
        #expect(entries.map(\.name) == HermesPersonalities.builtinNames.sorted())
        let pirate = entries.first { $0.name == "pirate" }
        #expect(pirate?.prompt == "Arrr, custom.")
        #expect(pirate?.isBuiltin == false)
        #expect(entries.first { $0.name == "hype" }?.isBuiltin == true)
    }

    // MARK: - Picker options

    @Test func pickerOptionsLeadWithNeutralDefault() {
        let options = HermesPersonalities.pickerOptions(yaml: "", current: "default")
        #expect(options.first == "default")
        #expect(options.count == 15)
        #expect(Set(options).isSuperset(of: HermesPersonalities.builtinNames))
    }

    @Test func pickerOptionsKeepUnknownCurrentSelection() {
        let options = HermesPersonalities.pickerOptions(yaml: "", current: "handwritten")
        #expect(options.contains("handwritten"))
        #expect(options[1] == "handwritten")
    }

    @Test func pickerOptionsDoNotDuplicateKnownCurrent() {
        let options = HermesPersonalities.pickerOptions(yaml: "", current: "pirate")
        #expect(options.filter { $0 == "pirate" }.count == 1)
        #expect(options.count == 15)
    }

    @Test func pickerOptionsWithEmptyCurrent() {
        #expect(HermesPersonalities.pickerOptions(yaml: "", current: "").count == 15)
    }

    @Test func emptyYamlStillYieldsBuiltins() {
        #expect(HermesPersonalities.resolvedNames(yaml: "") == HermesPersonalities.builtinNames.sorted())
    }
}
