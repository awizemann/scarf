import Testing
@testable import ScarfCore

/// Coverage for `SkillFrontmatterParser` — narrow YAML reader for the
/// `required_config:` list in a skill's `skill.yaml`. The parser was
/// extracted from the Mac `HermesFileService` in v2.5 so iOS can flag
/// missing config keys with the same semantics.
@Suite("SkillFrontmatterParser")
struct SkillFrontmatterParserTests {

    @Test func parsesSimpleRequiredConfigList() {
        let yaml = """
        name: example
        required_config:
          - api_key
          - api_secret
        version: 1.0.0
        """
        let keys = SkillFrontmatterParser.parseRequiredConfig(yaml)
        #expect(keys == ["api_key", "api_secret"])
    }

    @Test func returnsEmptyWhenSectionMissing() {
        let yaml = """
        name: example
        version: 1.0.0
        """
        #expect(SkillFrontmatterParser.parseRequiredConfig(yaml).isEmpty)
    }

    @Test func skipsCommentsAndEmptyLines() {
        let yaml = """
        # top comment
        required_config:
          # in-section comment
          - first

          - second
        """
        let keys = SkillFrontmatterParser.parseRequiredConfig(yaml)
        #expect(keys == ["first", "second"])
    }

    @Test func breaksOnNextTopLevelKey() {
        let yaml = """
        required_config:
          - one
          - two
        next_key: hello
          - three
        """
        let keys = SkillFrontmatterParser.parseRequiredConfig(yaml)
        // `next_key:` is at indent 0, terminating the list — `three`
        // is no longer in scope and shouldn't be picked up.
        #expect(keys == ["one", "two"])
    }

    @Test func handlesEmptyInput() {
        #expect(SkillFrontmatterParser.parseRequiredConfig("").isEmpty)
    }
}
