import Foundation
import Observation

/// iOS read-only Skills view-state. Scans `~/.hermes/skills/` for
/// category directories, then each category for skill directories,
/// then each skill directory for its file list. Mirrors what the
/// Mac app's `HermesFileService.loadSkills` does but scoped to what
/// the transport's `listDirectory` primitive can surface (no deep
/// YAML frontmatter parsing — users who want to inspect a skill's
/// full definition still do that on the Mac).
///
/// M5 is read-only by design. Installing new skills would need a
/// git-clone over SSH plus schema validation; that's a separate
/// feature in a later phase.
@Observable
@MainActor
public final class IOSSkillsViewModel {
    public let context: ServerContext

    public private(set) var categories: [HermesSkillCategory] = []
    public private(set) var isLoading: Bool = true
    public private(set) var lastError: String?

    public init(context: ServerContext) {
        self.context = context
    }

    public func load() async {
        isLoading = true
        lastError = nil
        let ctx = context
        let skillsRoot = ctx.paths.skillsDir

        let loaded: Result<[HermesSkillCategory], Error> = await Task.detached {
            let transport = ctx.makeTransport()
            guard transport.fileExists(skillsRoot) else {
                // Fresh install → no skills/ dir yet.
                return .success([])
            }
            do {
                let categoryNames = try transport.listDirectory(skillsRoot)
                    .filter { !$0.hasPrefix(".") }
                    .sorted()

                var categories: [HermesSkillCategory] = []
                for categoryName in categoryNames {
                    let categoryPath = skillsRoot + "/" + categoryName
                    // Only include directories.
                    guard transport.stat(categoryPath)?.isDirectory == true else { continue }

                    var skills: [HermesSkill] = []
                    let skillNames: [String]
                    do {
                        skillNames = try transport.listDirectory(categoryPath)
                            .filter { !$0.hasPrefix(".") }
                            .sorted()
                    } catch {
                        // Skip categories we can't read (permissions etc.)
                        // rather than failing the whole load.
                        continue
                    }

                    for skillName in skillNames {
                        let skillPath = categoryPath + "/" + skillName
                        guard transport.stat(skillPath)?.isDirectory == true else { continue }
                        let files: [String] = (try? transport.listDirectory(skillPath)) ?? []
                        // v2.5: parse SKILL.md frontmatter for the
                        // Hermes v2026.4.23 fields (allowed_tools,
                        // related_skills, dependencies). Falls back
                        // to nil-everything on absent/malformed
                        // frontmatter — old skills behave as before.
                        let frontmatter = Self.parseFrontmatter(
                            skillMdPath: skillPath + "/SKILL.md",
                            transport: transport
                        )
                        skills.append(HermesSkill(
                            id: categoryName + "/" + skillName,
                            name: skillName,
                            category: categoryName,
                            path: skillPath,
                            files: files.filter { !$0.hasPrefix(".") }.sorted(),
                            requiredConfig: [],  // skill.yaml parsing still deferred for iOS
                            allowedTools: frontmatter.allowedTools,
                            relatedSkills: frontmatter.relatedSkills,
                            dependencies: frontmatter.dependencies
                        ))
                    }

                    if !skills.isEmpty {
                        categories.append(HermesSkillCategory(
                            id: categoryName,
                            name: categoryName,
                            skills: skills
                        ))
                    }
                }
                return .success(categories)
            } catch {
                return .failure(error)
            }
        }.value

        switch loaded {
        case .success(let cats):
            categories = cats
        case .failure(let err):
            categories = []
            lastError = "Couldn't list skills: \(err.localizedDescription)"
        }
        isLoading = false
    }

    /// Read `<skill>/SKILL.md`'s YAML frontmatter and pull the v2.5
    /// fields (allowed_tools, related_skills, dependencies). Returns
    /// nil-filled tuple on missing file, missing frontmatter, or empty
    /// fields. Mirrors Mac's `HermesFileService.parseSkillFrontmatter`.
    nonisolated static func parseFrontmatter(
        skillMdPath: String,
        transport: any ServerTransport
    ) -> (allowedTools: [String]?, relatedSkills: [String]?, dependencies: [String]?) {
        guard transport.fileExists(skillMdPath),
              let data = try? transport.readFile(skillMdPath),
              let raw = String(data: data, encoding: .utf8)
        else { return (nil, nil, nil) }
        let lines = raw.components(separatedBy: "\n")
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
