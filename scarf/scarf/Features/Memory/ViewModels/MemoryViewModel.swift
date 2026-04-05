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

    enum EditTarget {
        case memory, user
    }

    var memoryCharCount: Int { memoryContent.count }
    var userCharCount: Int { userContent.count }

    var hasExternalProvider: Bool {
        !memoryProvider.isEmpty && memoryProvider != "file"
    }

    func load() {
        memoryContent = fileService.loadMemory()
        userContent = fileService.loadUserProfile()
        memoryProvider = fileService.loadConfig().memoryProvider
    }

    func startEditing(_ target: EditTarget) {
        editingFile = target
        editText = target == .memory ? memoryContent : userContent
        isEditing = true
    }

    func save() {
        switch editingFile {
        case .memory:
            fileService.saveMemory(editText)
            memoryContent = editText
        case .user:
            fileService.saveUserProfile(editText)
            userContent = editText
        }
        isEditing = false
    }

    func cancelEditing() {
        isEditing = false
    }
}
