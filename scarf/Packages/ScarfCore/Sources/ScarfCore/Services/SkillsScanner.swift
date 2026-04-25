import Foundation
import os

/// Walks `~/.hermes/skills/<category>/<name>/` and returns a populated
/// list of `HermesSkillCategory`. Body ported from
/// `HermesFileService.loadSkills` in v2.5 so iOS and Mac share the same
/// scan logic — only difference vs the Mac function is that this one
/// reads through the supplied transport rather than holding its own.
///
/// Synchronous + transport-backed: callers running on the MainActor
/// should wrap in `Task.detached` (the iOS pattern) since SFTP `stat` /
/// `listDirectory` calls block.
public enum SkillsScanner: Sendable {
    private static let logger = Logger(subsystem: "com.scarf", category: "SkillsScanner")

    public static func scan(context: ServerContext, transport: any ServerTransport) -> [HermesSkillCategory] {
        let dir = context.paths.skillsDir
        // Fresh install: skills/ may not exist yet — return [] without
        // logging an error.
        guard transport.fileExists(dir) else { return [] }
        guard let categories = try? transport.listDirectory(dir) else { return [] }

        return categories
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .compactMap { categoryName -> HermesSkillCategory? in
                let categoryPath = dir + "/" + categoryName
                guard transport.stat(categoryPath)?.isDirectory == true else { return nil }
                guard let skillNames = try? transport.listDirectory(categoryPath) else { return nil }

                let skills = skillNames
                    .filter { !$0.hasPrefix(".") }
                    .sorted()
                    .compactMap { skillName -> HermesSkill? in
                        let skillPath = categoryPath + "/" + skillName
                        guard transport.stat(skillPath)?.isDirectory == true else { return nil }
                        let files = ((try? transport.listDirectory(skillPath)) ?? [])
                            .filter { !$0.hasPrefix(".") }
                            .sorted()
                        let requiredConfig = readRequiredConfig(
                            yamlPath: skillPath + "/skill.yaml",
                            transport: transport
                        )
                        // v2.5 Hermes v0.11 SKILL.md frontmatter
                        // (allowed_tools, related_skills, dependencies).
                        // Opportunistic read — old skills without the
                        // file or without those fields keep nil, and
                        // the chip rows hide themselves.
                        let v011 = readV011Fields(
                            mdPath: skillPath + "/SKILL.md",
                            transport: transport
                        )
                        return HermesSkill(
                            id: categoryName + "/" + skillName,
                            name: skillName,
                            category: categoryName,
                            path: skillPath,
                            files: files,
                            requiredConfig: requiredConfig,
                            allowedTools: v011.allowedTools,
                            relatedSkills: v011.relatedSkills,
                            dependencies: v011.dependencies
                        )
                    }

                guard !skills.isEmpty else { return nil }
                return HermesSkillCategory(id: categoryName, name: categoryName, skills: skills)
            }
    }

    private static func readRequiredConfig(yamlPath: String, transport: any ServerTransport) -> [String] {
        guard let data = try? transport.readFile(yamlPath),
              let content = String(data: data, encoding: .utf8)
        else { return [] }
        return SkillFrontmatterParser.parseRequiredConfig(content)
    }

    /// Read SKILL.md (Hermes v2026.4.23+) and parse its YAML frontmatter
    /// for the v0.11 fields. Nil-everything when the file is absent or
    /// has no frontmatter — fully back-compatible with older skills.
    private static func readV011Fields(
        mdPath: String,
        transport: any ServerTransport
    ) -> (allowedTools: [String]?, relatedSkills: [String]?, dependencies: [String]?) {
        guard transport.fileExists(mdPath),
              let data = try? transport.readFile(mdPath),
              let content = String(data: data, encoding: .utf8)
        else { return (nil, nil, nil) }
        return SkillFrontmatterParser.parseV011Fields(content)
    }
}
