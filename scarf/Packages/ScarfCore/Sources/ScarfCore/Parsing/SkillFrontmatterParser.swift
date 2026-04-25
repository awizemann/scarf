import Foundation

/// Pure-Swift YAML parsers for skill manifests + SKILL.md frontmatter.
///
/// Two readers ship here:
///
/// - `parseRequiredConfig(_:)` — the original v2.5 reader. Pulls the
///   `required_config:` list out of a skill's `skill.yaml`. Extracted
///   from `HermesFileService.parseSkillRequiredConfig` in v2.5 so iOS
///   can flag missing config keys without depending on the Mac target.
/// - `parseV011Fields(_:)` — Hermes v2026.4.23+ SKILL.md frontmatter
///   reader. Extracts `allowed_tools`, `related_skills`, and
///   `dependencies` lists from the YAML block between `---` markers
///   at the top of a SKILL.md file. Used by `SkillsScanner` to populate
///   `HermesSkill`'s v0.11 fields so chip rows in the detail views
///   render correctly. Returns nil for fields that are absent or
///   empty (callers treat nil as "don't show this section").
///
/// Intentionally not a full YAML parser — Hermes skill manifests use a
/// very narrow subset of YAML. `parseV011Fields` reuses `HermesYAML`;
/// `parseRequiredConfig` stays inline because tests pin its behaviour.
public enum SkillFrontmatterParser: Sendable {

    /// Parse the `required_config:` list from a skill.yaml's text. Empty
    /// result on any kind of malformation — callers treat it as "no
    /// required config, proceed".
    public static func parseRequiredConfig(_ content: String) -> [String] {
        var result: [String] = []
        var inRequiredConfig = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if trimmed == "required_config:" || trimmed.hasPrefix("required_config:") {
                inRequiredConfig = true
                continue
            }
            if inRequiredConfig {
                if indent < 2 && !trimmed.isEmpty {
                    break
                }
                if trimmed.hasPrefix("- ") {
                    result.append(String(trimmed.dropFirst(2)))
                }
            }
        }
        return result
    }

    /// Parse Hermes v2026.4.23+ SKILL.md frontmatter for the v0.11
    /// fields. The frontmatter block is the YAML region between two
    /// `---` markers at the top of the file. Anything outside the
    /// markers is ignored. Returns nil-everything when the file has
    /// no frontmatter or no recognised fields — callers should hide
    /// the corresponding chip rows in that case.
    ///
    /// Caller pre-condition: `content` is the full SKILL.md text. We
    /// detect the frontmatter shape ourselves rather than requiring
    /// callers to pre-strip it.
    public static func parseV011Fields(
        _ content: String
    ) -> (allowedTools: [String]?, relatedSkills: [String]?, dependencies: [String]?) {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---",
              let endIdx = lines.dropFirst().firstIndex(of: "---")
        else { return (nil, nil, nil) }
        let frontmatter = lines[1..<endIdx].joined(separator: "\n")
        let parsed = HermesYAML.parseNestedYAML(frontmatter)
        let allowed = parsed.lists["allowed_tools"]
        let related = parsed.lists["related_skills"]
        let deps = parsed.lists["dependencies"]
        return (
            allowedTools: (allowed?.isEmpty ?? true) ? nil : allowed,
            relatedSkills: (related?.isEmpty ?? true) ? nil : related,
            dependencies: (deps?.isEmpty ?? true) ? nil : deps
        )
    }
}
