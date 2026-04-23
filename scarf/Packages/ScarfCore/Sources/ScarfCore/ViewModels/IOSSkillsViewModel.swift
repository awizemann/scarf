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
                        skills.append(HermesSkill(
                            id: categoryName + "/" + skillName,
                            name: skillName,
                            category: categoryName,
                            path: skillPath,
                            files: files.filter { !$0.hasPrefix(".") }.sorted(),
                            requiredConfig: []  // Skills frontmatter parsing deferred.
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
}
