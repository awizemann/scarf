import Foundation

@Observable
final class SkillsViewModel {
    private let fileService = HermesFileService()

    var categories: [HermesSkillCategory] = []
    var selectedSkill: HermesSkill?
    var skillContent = ""
    var selectedFileName: String?
    var searchText = ""
    var missingConfig: [String] = []
    var isEditing = false
    var editText = ""
    private var currentConfig = HermesConfig.empty

    var filteredCategories: [HermesSkillCategory] {
        guard !searchText.isEmpty else { return categories }
        return categories.compactMap { category in
            let filtered = category.skills.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.category.localizedCaseInsensitiveContains(searchText)
            }
            guard !filtered.isEmpty else { return nil }
            return HermesSkillCategory(id: category.id, name: category.name, skills: filtered)
        }
    }

    var totalSkillCount: Int {
        categories.reduce(0) { $0 + $1.skills.count }
    }

    func load() {
        categories = fileService.loadSkills()
        currentConfig = fileService.loadConfig()
    }

    func selectSkill(_ skill: HermesSkill) {
        selectedSkill = skill
        let mainFile = skill.files.first(where: { $0.hasSuffix(".md") }) ?? skill.files.first
        if let file = mainFile {
            selectedFileName = file
            skillContent = fileService.loadSkillContent(path: skill.path + "/" + file)
        } else {
            selectedFileName = nil
            skillContent = ""
        }
        missingConfig = computeMissingConfig(for: skill)
    }

    private func computeMissingConfig(for skill: HermesSkill) -> [String] {
        guard !skill.requiredConfig.isEmpty else { return [] }
        guard let yaml = try? String(contentsOfFile: HermesPaths.configYAML, encoding: .utf8) else {
            return skill.requiredConfig
        }
        return skill.requiredConfig.filter { key in
            !yaml.contains(key)
        }
    }

    func selectFile(_ file: String) {
        guard let skill = selectedSkill else { return }
        selectedFileName = file
        skillContent = fileService.loadSkillContent(path: skill.path + "/" + file)
    }

    var isMarkdownFile: Bool {
        selectedFileName?.hasSuffix(".md") == true
    }

    private var currentFilePath: String? {
        guard let skill = selectedSkill, let file = selectedFileName else { return nil }
        return skill.path + "/" + file
    }

    func startEditing() {
        editText = skillContent
        isEditing = true
    }

    func saveEdit() {
        guard let path = currentFilePath else { return }
        fileService.saveSkillContent(path: path, content: editText)
        skillContent = editText
        isEditing = false
    }

    func cancelEditing() {
        isEditing = false
    }
}
