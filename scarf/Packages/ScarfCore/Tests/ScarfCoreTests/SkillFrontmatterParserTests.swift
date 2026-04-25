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

    // MARK: - parseV011Fields (Hermes v2026.4.23 SKILL.md frontmatter)

    @Test func v011_extractsAllThreeLists() {
        let md = """
        ---
        allowed_tools:
          - read_file
          - write_file
        related_skills:
          - timer
          - deploy
        dependencies:
          - npx
          - node
        ---

        # Skill body — body content is ignored by the parser.
        """
        let r = SkillFrontmatterParser.parseV011Fields(md)
        #expect(r.allowedTools == ["read_file", "write_file"])
        #expect(r.relatedSkills == ["timer", "deploy"])
        #expect(r.dependencies == ["npx", "node"])
    }

    @Test func v011_handlesAbsentFields() {
        // Frontmatter present but only one v0.11 field declared.
        let md = """
        ---
        allowed_tools:
          - run_shell
        ---

        Body.
        """
        let r = SkillFrontmatterParser.parseV011Fields(md)
        #expect(r.allowedTools == ["run_shell"])
        #expect(r.relatedSkills == nil)
        #expect(r.dependencies == nil)
    }

    @Test func v011_returnsNilOnMissingFrontmatter() {
        // SKILL.md without --- markers — pre-v0.11 file shape.
        let md = "# Skill\n\nBody only, no frontmatter."
        let r = SkillFrontmatterParser.parseV011Fields(md)
        #expect(r.allowedTools == nil)
        #expect(r.relatedSkills == nil)
        #expect(r.dependencies == nil)
    }

    @Test func v011_returnsNilWhenFieldEmpty() {
        // Field declared but with an empty list — treated same as absent
        // (no chip row, no ghost section).
        let md = """
        ---
        allowed_tools:
        related_skills:
          - foo
        ---
        """
        let r = SkillFrontmatterParser.parseV011Fields(md)
        #expect(r.allowedTools == nil)
        #expect(r.relatedSkills == ["foo"])
        #expect(r.dependencies == nil)
    }

    @Test func v011_returnsNilOnEmptyInput() {
        let r = SkillFrontmatterParser.parseV011Fields("")
        #expect(r.allowedTools == nil)
        #expect(r.relatedSkills == nil)
        #expect(r.dependencies == nil)
    }
}
