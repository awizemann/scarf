import Foundation

public struct HermesSkillCategory: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let skills: [HermesSkill]

    public init(
        id: String,
        name: String,
        skills: [HermesSkill]
    ) {
        self.id = id
        self.name = name
        self.skills = skills
    }
}

public struct HermesSkill: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let path: String
    public let files: [String]
    public let requiredConfig: [String]
    /// Tools the skill author declared the skill is allowed to invoke
    /// (Hermes v2026.4.23 SKILL.md frontmatter `allowed_tools`).
    /// `nil` when the skill ships no SKILL.md or the frontmatter
    /// doesn't declare the field — pre-v0.11 behaviour preserved.
    public let allowedTools: [String]?
    /// Skill names the author cross-references as related (`related_skills`
    /// in SKILL.md frontmatter). Surfaced as chips in the skill detail
    /// view so users can hop between connected skills.
    public let relatedSkills: [String]?
    /// External runtime dependencies the skill needs on the host
    /// (`dependencies` in SKILL.md frontmatter; e.g. `npx`, `ffmpeg`,
    /// Python packages). Used by `SkillPrereqService` to know what to
    /// probe; nil when the field is absent.
    public let dependencies: [String]?
    /// `false` when the skill name appears in `skills.disabled` in
    /// `~/.hermes/config.yaml`. Hermes v0.12 stores disable state in
    /// the config rather than per-skill markers; this is read-only
    /// from Scarf's side until the toggle UI lands. Defaults to `true`.
    public let enabled: Bool
    /// `true` when the skill is pinned via `hermes curator pin <name>`.
    /// Pinned skills are protected from auto-archive / consolidation.
    /// Read from the `pinned` field of the skill's record in
    /// `skills/.usage.json`; `false` when the host has no curator sidecar.
    public let pinned: Bool

    public init(
        id: String,
        name: String,
        category: String,
        path: String,
        files: [String],
        requiredConfig: [String],
        allowedTools: [String]? = nil,
        relatedSkills: [String]? = nil,
        dependencies: [String]? = nil,
        enabled: Bool = true,
        pinned: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.path = path
        self.files = files
        self.requiredConfig = requiredConfig
        self.allowedTools = allowedTools
        self.relatedSkills = relatedSkills
        self.dependencies = dependencies
        self.enabled = enabled
        self.pinned = pinned
    }
}
