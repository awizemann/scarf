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
                        return HermesSkill(
                            id: categoryName + "/" + skillName,
                            name: skillName,
                            category: categoryName,
                            path: skillPath,
                            files: files,
                            requiredConfig: requiredConfig
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
}
