import Testing
@testable import ScarfCore

/// Coverage for `SkillFrontmatterParser`. The config-key reader used to
/// parse `required_config:` out of a `skill.yaml`, a file no Hermes version
/// reads; it now reads `metadata.hermes.config` from SKILL.md, as
/// `extract_skill_config_vars` does (`agent/skill_utils.py:666-689` @
/// v2026.9.24). S10-F3, blind re-audit.
@Suite("SkillFrontmatterParser")
struct SkillFrontmatterParserTests {

    @Test func configKeysFromTheDocumentedShape() {
        // `website/docs/user-guide/features/skills.md:288-296` @ v2026.9.24.
        let md = """
        ---
        name: myplugin
        description: Example
        metadata:
          hermes:
            tags: [Example]
            config:
              - key: myplugin.path
                description: Path to the plugin data directory
                default: "~/myplugin-data"
                prompt: Plugin data directory path
              - key: myplugin.mode
                description: "Mode: fast or slow"
        ---

        Body with `config:` text that is not frontmatter.
        """
        #expect(SkillFrontmatterParser.parseConfigKeys(md) == ["myplugin.path", "myplugin.mode"])
    }

    @Test func configEntriesNeedKeyAndDescriptionAndAreDeduplicated() {
        let md = """
        ---
        metadata:
          hermes:
            config:
            - key: a
              description: first
            - key: b
            - description: no key
            - key: a
              description: duplicate
        ---
        """
        #expect(SkillFrontmatterParser.parseConfigKeys(md) == ["a"])
    }

    @Test func configMayBeASingleMap() {
        let md = """
        ---
        metadata:
          hermes:
            config:
              key: solo.key
              description: Only one
        ---
        """
        #expect(SkillFrontmatterParser.parseConfigKeys(md) == ["solo.key"])
    }

    @Test func topLevelOrMisplacedConfigIsIgnored() {
        let md = """
        ---
        config:
          - key: top
            description: not under metadata.hermes
        required_config:
          - legacy
        metadata:
          other:
            config:
              - key: wrong
                description: wrong parent
        ---
        """
        #expect(SkillFrontmatterParser.parseConfigKeys(md).isEmpty)
        #expect(SkillFrontmatterParser.parseConfigKeys("").isEmpty)
        #expect(SkillFrontmatterParser.parseConfigKeys("# no frontmatter").isEmpty)
    }

    /// Hermes reads `metadata.hermes.related_skills` first, then top level
    /// (`tools/skills_tool.py:613-617`); the bundled skills use the nested
    /// flow list.
    @Test func relatedSkillsFromMetadataHermes() {
        let md = """
        ---
        name: grounded-citations
        metadata:
          hermes:
            tags: [Research, Citations]
            related_skills: [arxiv, pdf, reddit-reading]
        related_skills:
          - ignored-when-nested-present
        ---
        """
        #expect(SkillFrontmatterParser.parseV011Fields(md).relatedSkills == ["arxiv", "pdf", "reddit-reading"])
        let flat = """
        ---
        related_skills: "timer, deploy"
        ---
        """
        #expect(SkillFrontmatterParser.parseV011Fields(flat).relatedSkills == ["timer", "deploy"])
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
