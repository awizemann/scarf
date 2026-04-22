import Foundation

public struct HermesSkillCategory: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let skills: [HermesSkill]

    public init(
        id: String,
        name: String,
        skills: [HermesSkill]
    ) {
        self.id = id
        self.name = name
        self.skills = skills
    }
}

public struct HermesSkill: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let path: String
    public let files: [String]
    public let requiredConfig: [String]

    public init(
        id: String,
        name: String,
        category: String,
        path: String,
        files: [String],
        requiredConfig: [String]
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.path = path
        self.files = files
        self.requiredConfig = requiredConfig
    }
}
