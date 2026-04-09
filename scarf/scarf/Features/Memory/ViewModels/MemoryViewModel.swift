import Foundation

@Observable
final class MemoryViewModel {
    private let fileService = HermesFileService()

    var memoryContent = ""
    var userContent = ""
    var memoryProvider = ""
    var isEditing = false
    var editingFile: EditTarget = .memory
    var editText = ""
    var profiles: [String] = []
    var activeProfile = ""

    enum EditTarget {
        case memory, user
    }

    var memoryCharCount: Int { memoryContent.count }
    var userCharCount: Int { userContent.count }

    var hasExternalProvider: Bool {
        let stripped = memoryProvider
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return !stripped.isEmpty && stripped != "file"
    }

    var hasMultipleProfiles: Bool { !profiles.isEmpty }

    func load() {
        let config = fileService.loadConfig()
        memoryProvider = config.memoryProvider
        profiles = fileService.loadMemoryProfiles()
        if activeProfile.isEmpty {
            activeProfile = config.memoryProfile
        }
        memoryContent = fileService.loadMemory(profile: activeProfile)
        userContent = fileService.loadUserProfile(profile: activeProfile)
    }

    func switchProfile(_ profile: String) {
        activeProfile = profile
        memoryContent = fileService.loadMemory(profile: profile)
        userContent = fileService.loadUserProfile(profile: profile)
    }

    func startEditing(_ target: EditTarget) {
        editingFile = target
        editText = target == .memory ? memoryContent : userContent
        isEditing = true
    }

    func save() {
        switch editingFile {
        case .memory:
            fileService.saveMemory(editText, profile: activeProfile)
            memoryContent = editText
        case .user:
            fileService.saveUserProfile(editText, profile: activeProfile)
            userContent = editText
        }
        isEditing = false
    }

    func cancelEditing() {
        isEditing = false
    }
}
