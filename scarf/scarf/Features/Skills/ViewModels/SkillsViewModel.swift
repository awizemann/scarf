import Foundation

@Observable
final class SkillsViewModel {
    private let fileService = HermesFileService()

    var categories: [HermesSkillCategory] = []
    var selectedSkill: HermesSkill?
    var skillContent = ""
    var selectedFileName: String?
    var searchText = ""

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
    }

    func selectFile(_ file: String) {
        guard let skill = selectedSkill else { return }
        selectedFileName = file
        skillContent = fileService.loadSkillContent(path: skill.path + "/" + file)
    }
}
