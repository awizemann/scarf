import Foundation

/// Pure-Swift YAML-frontmatter parser for skill manifests' `required_config:`
/// list. Extracted from `HermesFileService.parseSkillRequiredConfig` in
/// v2.5 so iOS can flag missing config keys without depending on the
/// Mac target.
///
/// Intentionally not a full YAML parser — Hermes skill manifests use a
/// very narrow subset of YAML for this list. We look for a top-level
/// `required_config:` key followed by `- key` entries with at least one
/// space of indent. Lines outside that section are ignored.
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
}
